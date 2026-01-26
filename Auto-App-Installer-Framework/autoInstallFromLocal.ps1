#requires -version 5.1
<#
.SYNOPSIS
  Auto App Installer – CLI Only – v2.1.0 (by rhshourav)

.DESCRIPTION
  - Auto-elevates to Admin (PowerShell 5.1 safe, uses -EncodedCommand)
  - CLI "GUI-style" UX (colors, headers, progress bars)
  - Network locations (UNC) + local fallback
  - Lists .exe & .msi (RECURSIVE scan for ALL sources)
  - CLI selection (numbers/ranges/all/filter/back)
  - Rule system:
      * preselect installers by filename match
      * override EXE/MSI args (string or string[])
      * first-match wins
  - Post-install hooks:
      * Local: <InstallerBaseName>.post.ps1/.cmd/.bat (same folder)
      * Remote: rule-based PostUrl (download to %TEMP%, optional; OFF by default)
  - Explicit user permission before install
  - Sequential execution (waits each installer) + exit code capture
  - Robust logging (Transcript + meta log)
  - Graceful fallback after 30s with progress bar (NO IEX)
  - Windows 10 / 11 compatible, PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [switch]$ConfirmEach = $false,
    [string]$LocalFallbackDir = "$PSScriptRoot\Installers",
    [string]$FrameworkUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1',

    # Post-install controls
    [switch]$SkipPostInstall         = $false,
    [switch]$RunPostOnFail           = $false,
    [switch]$EnableLocalPostInstall  = $true,
    [switch]$EnableRemotePostInstall = $false,  # safer default: OFF
    [string[]]$TrustedPostDomains    = @('raw.githubusercontent.com')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

# ==========================================================
# Rule Configuration (EDIT THIS SECTION)
# ==========================================================
<#
Rule fields:
  Name      : label for display/logging
  AppliesTo : 'Exe' | 'Msi' | 'Any'
  MatchType : 'Contains' | 'Like' | 'Regex'
  Match     : match text/pattern
  Args      : OPTIONAL. Overrides default args. Can be string or string[]
  Preselect : OPTIONAL. If $true, app is pre-selected automatically
  PostUrl   : OPTIONAL. Remote post-install script URL (ps1/cmd/bat). Requires -EnableRemotePostInstall

Notes:
  - First-match wins. Put specific rules above general ones.
  - EXE defaults to '/S' when no rule args exist.
  - MSI defaults to msiexec /i <msi> /qn /norestart when no rule args exist.
#>

$global:InstallerRules = @(
    [pscustomobject]@{
        Name      = 'Green apps: all users'
        AppliesTo = 'Exe'
        MatchType = 'Contains'
        Match     = 'green'
        Args      = @('/ALLUSER')
        Preselect = $true

        # Example remote post (pin to commit SHA if you enable remote execution):
        # PostUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/<COMMIT_SHA>/PostInstall/green.post.ps1'
    }

    # Add more rules below:
    #,[pscustomobject]@{
    #    Name      = 'Chrome silent'
    #    AppliesTo = 'Exe'
    #    MatchType = 'Like'
    #    Match     = '*chrome*'
    #    Args      = @('/silent','/install')
    #    Preselect = $true
    #    PostUrl   = 'https://raw.githubusercontent.com/.../chrome.post.ps1'
    #}
)

# ---------------------------
# UI + logging helpers
# ---------------------------
function Write-Header {
    param([string]$Title)
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host ('   {0}' -f $Title).PadRight(46) -ForegroundColor Cyan
    Write-Host '==============================================' -ForegroundColor Cyan
}
function Write-Info { param([string]$m) Write-Host ('[*] {0}' -f $m) -ForegroundColor Cyan }
function Write-Good { param([string]$m) Write-Host ('[+] {0}' -f $m) -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host ('[!] {0}' -f $m) -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host ('[-] {0}' -f $m) -ForegroundColor Red }

function Log-Line {
    param(
        [ValidateSet('INFO','WARN','ERROR','OK')] [string]$Level,
        [string]$Message
    )
    $ts = (Get-Date).ToString('s')
    Add-Content -Path $global:MetaLog -Value ('{0} [{1}] {2}' -f $ts, $Level, $Message) -Encoding UTF8
}

function New-Log {
    $root = Join-Path $env:TEMP 'rhshourav\WindowsScripts\AutoAppInstaller'
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $global:LogFile = Join-Path $root ("AppInstall_{0}.log" -f $stamp)
    $global:MetaLog = Join-Path $root ("AppInstall_{0}.meta.log" -f $stamp)

    try { Start-Transcript -Path $global:LogFile -Append | Out-Null } catch {
        Write-Warn ("Transcript could not be started. Continuing. Details: {0}" -f $_.Exception.Message)
    }

    Write-Info ("Log : {0}" -f $global:LogFile)
    Write-Info ("Meta: {0}" -f $global:MetaLog)

    try {
        Log-Line INFO ("Host={0} User={1}\{2}" -f $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME)
        Log-Line INFO ("PSVersion={0}" -f $PSVersionTable.PSVersion)
    } catch {}
}

function Stop-Log { try { Stop-Transcript | Out-Null } catch { } }

function Format-ArgsForLog {
    param($Args)
    if ($null -eq $Args) { return '' }
    if ($Args -is [System.Array]) { return ($Args -join ' ') }
    return [string]$Args
}

# ---------------------------
# Admin elevation (PS 5.1 safe)
# ---------------------------
function Escape-SingleQuote {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return ($s -replace "'", "''")
}

function Quote-ForPsLiteral {
    param([string]$s)
    return "'" + (Escape-SingleQuote $s) + "'"
}

function Get-ForwardedArgs {
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]

        if ($v -is [switch]) {
            if ($v.IsPresent) { $out.Add("-$k") }
        }
        elseif ($null -ne $v) {
            $out.Add("-$k")
            $out.Add((Quote-ForPsLiteral ([string]$v)))
        }
    }

    if ($MyInvocation.UnboundArguments) {
        foreach ($u in $MyInvocation.UnboundArguments) {
            $out.Add((Quote-ForPsLiteral ([string]$u)))
        }
    }

    return ($out -join ' ')
}

function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)

    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[!] Not running as Administrator. Relaunching elevated..." -ForegroundColor Yellow

        $wd     = (Get-Location).Path
        $script = $PSCommandPath
        $args   = Get-ForwardedArgs

        $wdEsc     = Escape-SingleQuote $wd
        $scriptEsc = Escape-SingleQuote $script

        $cmd = @"
Set-Location -LiteralPath '$wdEsc'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$scriptEsc' $args
`$ec = `$LASTEXITCODE
Write-Host ''
Write-Host ('[i] Finished. ExitCode={0}' -f `$ec) -ForegroundColor Cyan
Read-Host 'Press Enter to close'
"@

        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
        $enc   = [Convert]::ToBase64String($bytes)

        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-NoExit',
            '-EncodedCommand', $enc
        ) | Out-Null

        exit
    }
}

# ---------------------------
# Self-check
# ---------------------------
function Self-Check {
    $os = Get-CimInstance Win32_OperatingSystem
    $ver = [Version]$os.Version
    if ($ver.Major -lt 10) {
        throw ('Unsupported OS: {0} ({1}). Requires Windows 10/11.' -f $os.Caption, $os.Version)
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw ('PowerShell 5.1+ required/recommended. Current: {0}' -f $PSVersionTable.PSVersion)
    }
    Log-Line INFO ("Self-check OK: OS={0} PS={1}" -f $os.Caption, $PSVersionTable.PSVersion)
}

# ---------------------------
# Source resolution (ALL recurse)
# ---------------------------
function Resolve-InstallBasePath {
    $locations = @(
        @{ Label='Antivirus (Sentinel)';       Path='\\192.168.18.201\it\Antivirus\Sentinel';          Recurse=$true },
        @{ Label='Staff PC (18.201)';          Path='\\192.168.18.201\it\PC Setup\Staff pc';           Recurse=$true },
        @{ Label='Production PC (18.201)';     Path='\\192.168.18.201\it\PC Setup\Production pc';      Recurse=$true }
    )

    $available = @()
    foreach ($loc in $locations) {
        if (Test-Path -LiteralPath $loc.Path) { $available += $loc }
    }

    if ($available.Count -gt 0) {
        Write-Host ''
        Write-Header 'Select Installation Source (CLI)'

        for ($i = 0; $i -lt $available.Count; $i++) {
            $n = $i + 1
            Write-Host ('[{0}] {1} -> {2}' -f $n, $available[$i].Label, $available[$i].Path) -ForegroundColor Cyan
        }

        Write-Host ''
        Write-Host ('Press ENTER for default [1], or choose 1-{0}.' -f $available.Count) -ForegroundColor Yellow
        $choice = Read-Host 'Source'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

        if ($choice -match '^\d+$') {
            $idx = [int]$choice
            if ($idx -ge 1 -and $idx -le $available.Count) {
                $selected = $available[$idx - 1]
                Write-Good ('Selected: {0} -> {1}' -f $selected.Label, $selected.Path)
                Log-Line OK ('BasePath={0} ({1}) Recurse={2}' -f $selected.Path, $selected.Label, $selected.Recurse)
                return [pscustomobject]@{ Path=$selected.Path; Label=$selected.Label; Recurse=[bool]$selected.Recurse }
            }
        }

        Write-Warn 'Invalid selection. Defaulting to [1].'
        $selected = $available[0]
        Write-Good ('Selected: {0} -> {1}' -f $selected.Label, $selected.Path)
        Log-Line OK ('BasePath={0} ({1}) Recurse={2}' -f $selected.Path, $selected.Label, $selected.Recurse)
        return [pscustomobject]@{ Path=$selected.Path; Label=$selected.Label; Recurse=[bool]$selected.Recurse }
    }

    Write-Bad 'No valid network location found.'
    Log-Line WARN 'NoNetworkLocation'

    for ($i = 30; $i -ge 1; $i--) {
        $pct = [int](((30 - $i) / 30) * 100)
        Write-Progress -Activity 'Network share unavailable' -Status ('Fallback in {0}s' -f $i) -PercentComplete $pct
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Network share unavailable' -Completed

    if (Test-Path -LiteralPath $LocalFallbackDir) {
        Write-Warn ('Falling back to local installers folder: {0}' -f $LocalFallbackDir)
        Log-Line WARN ('Fallback=LocalDir ({0})' -f $LocalFallbackDir)
        return [pscustomobject]@{ Path=$LocalFallbackDir; Label='LocalFallback'; Recurse=$true }
    }

    Write-Warn ('Local fallback folder not found: {0}' -f $LocalFallbackDir)
    Write-Warn 'Optional: download framework script (NOT auto-executed).'
    $dl = Read-Host 'Download framework script to TEMP for manual review? (Y/N)'

    if ($dl -match '^[Yy]$') {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $dst = Join-Path $env:TEMP ('rhshourav_framework_{0}.ps1' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $FrameworkUrl -OutFile $dst
            Write-Good ('Downloaded to: {0}' -f $dst)
            Write-Info 'Review it, then run it manually if you trust it.'
            Log-Line OK ('FrameworkDownloaded={0}' -f $dst)
        } catch {
            Write-Bad ('Framework download failed: {0}' -f $_.Exception.Message)
            Log-Line ERROR ('FrameworkDownloadFailed={0}' -f $_.Exception.Message)
        }
    }

    return $null
}

function Get-Installers {
    param(
        [Parameter(Mandatory)] [string]$BasePath,
        [switch]$Recurse
    )

    $gciParams = @{
        LiteralPath = $BasePath
        File        = $true
        ErrorAction = 'Stop'
        Recurse     = [bool]$Recurse
    }

    @(
        Get-ChildItem @gciParams |
            Where-Object { $_.Extension -in '.exe', '.msi' } |
            Sort-Object Name
    )
}

# ---------------------------
# Rules engine
# ---------------------------
function Get-AppTypeTag {
    param([System.IO.FileInfo]$App)
    if ($App.Extension -eq '.msi') { return 'Msi' }
    if ($App.Extension -eq '.exe') { return 'Exe' }
    return 'Other'
}

function Test-RuleMatch {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$App,
        [Parameter(Mandatory)] $Rule
    )

    $type = Get-AppTypeTag -App $App
    $applies = [string]$Rule.AppliesTo

    if ($applies -and $applies -ne 'Any') {
        if ($type -ne $applies) { return $false }
    }

    $name = $App.Name
    $mt = [string]$Rule.MatchType
    $m  = [string]$Rule.Match

    switch ($mt) {
        'Contains' { return ($name.ToLowerInvariant().Contains($m.ToLowerInvariant())) }
        'Like'     { return ($name -like $m) }
        'Regex'    { return ($name -match $m) }
        default    { return $false }
    }
}

function Get-MatchingRule {
    param([System.IO.FileInfo]$App)

    foreach ($r in $global:InstallerRules) {
        if (Test-RuleMatch -App $App -Rule $r) { return $r }
    }
    return $null
}

# ---------------------------
# Post-install: local + remote
# ---------------------------
function Test-TrustedPostUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string[]]$TrustedDomains
    )

    try { $u = [Uri]$Url } catch { return $false }
    if ($u.Scheme -ne 'https') { return $false }

    $host = $u.Host.ToLowerInvariant()
    foreach ($d in $TrustedDomains) {
        if ($host -eq $d.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Get-RemotePostUrl {
    param([Parameter(Mandatory)][System.IO.FileInfo]$App)

    $rule = Get-MatchingRule -App $App
    if ($rule -and ($rule.PSObject.Properties.Name -contains 'PostUrl')) {
        $u = [string]$rule.PostUrl
        if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
    }
    return $null
}

function Download-PostScript {
    param([Parameter(Mandatory)][string]$Url)

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $nameFromUrl = ([Uri]$Url).AbsolutePath.Split('/')[-1]
    if ([string]::IsNullOrWhiteSpace($nameFromUrl)) { $nameFromUrl = 'postinstall.ps1' }

    $ext = [System.IO.Path]::GetExtension($nameFromUrl)
    if ([string]::IsNullOrWhiteSpace($ext)) { $nameFromUrl += '.ps1' }

    $root = Join-Path $env:TEMP 'rhshourav\WindowsScripts\PostInstall'
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    $dst = Join-Path $root ("{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $nameFromUrl)

    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $dst -ErrorAction Stop
    return (Get-Item -LiteralPath $dst -ErrorAction Stop)
}

function Get-LocalPostInstallScript {
    param([Parameter(Mandatory)][System.IO.FileInfo]$App)

    $dir  = $App.DirectoryName
    $base = $App.BaseName

    $candidates = @(
        (Join-Path $dir ($base + '.post.ps1')),
        (Join-Path $dir ($base + '.post.cmd')),
        (Join-Path $dir ($base + '.post.bat'))
    )

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            try { return (Get-Item -LiteralPath $c -ErrorAction Stop) } catch { }
        }
    }
    return $null
}

function Invoke-PostInstallScript {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Installer,
        [Parameter(Mandatory)][System.IO.FileInfo]$ScriptFile,
        [string]$Origin = 'Local',
        [string]$Source = ''
    )

    Write-Info ("Post-install ({0}): {1}" -f $Origin, $ScriptFile.Name)
    Log-Line INFO ("PostInstallStart Origin={0} Installer={1} Script={2} Source={3}" -f $Origin, $Installer.Name, $ScriptFile.FullName, $Source)

    try {
        $ext = $ScriptFile.Extension.ToLowerInvariant()
        $p = $null

        if ($ext -eq '.ps1') {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy','Bypass',
                '-File', $ScriptFile.FullName
            ) -Wait -PassThru -WindowStyle Hidden
        }
        elseif ($ext -in '.cmd','.bat') {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @(
                '/c', $ScriptFile.FullName
            ) -Wait -PassThru -WindowStyle Hidden
        }
        else {
            throw ("Unsupported post-install script type: {0}" -f $ScriptFile.Name)
        }

        $ec = $p.ExitCode
        if ($ec -eq 0) {
            Write-Good ("Post-install OK: {0}" -f $ScriptFile.Name)
            Log-Line OK ("PostInstallOK Origin={0} Installer={1} Script={2} ExitCode=0" -f $Origin, $Installer.Name, $ScriptFile.Name)
            return [pscustomobject]@{ PostStatus='OK'; PostExitCode=0; PostScript=$ScriptFile.Name; PostOrigin=$Origin; PostSource=$Source }
        } else {
            Write-Warn ("Post-install finished with ExitCode={0}: {1}" -f $ec, $ScriptFile.Name)
            Log-Line WARN ("PostInstallExit Origin={0} Installer={1} Script={2} ExitCode={3}" -f $Origin, $Installer.Name, $ScriptFile.Name, $ec)
            return [pscustomobject]@{ PostStatus='NonZero'; PostExitCode=$ec; PostScript=$ScriptFile.Name; PostOrigin=$Origin; PostSource=$Source }
        }
    }
    catch {
        Write-Bad ("Post-install error: {0}" -f $_.Exception.Message)
        Log-Line ERROR ("PostInstallError Origin={0} Installer={1} Script={2} Error={3}" -f $Origin, $Installer.Name, $ScriptFile.Name, $_.Exception.Message)
        return [pscustomobject]@{ PostStatus='Error'; PostExitCode=$null; PostScript=$ScriptFile.Name; PostOrigin=$Origin; PostSource=$Source }
    }
}

function Run-PostInstallIfAvailable {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$App,
        [Parameter(Mandatory)][int]$InstallerExitCode,
        [Parameter(Mandatory)]$ResultsArrayRef
    )

    if ($SkipPostInstall) { return }

    $shouldRun = ($InstallerExitCode -eq 0) -or $RunPostOnFail
    if (-not $shouldRun) { return }

    $postRuns = New-Object System.Collections.Generic.List[object]

    if ($EnableLocalPostInstall) {
        $local = Get-LocalPostInstallScript -App $App
        if ($local) {
            $postRuns.Add((Invoke-PostInstallScript -Installer $App -ScriptFile $local -Origin 'Local' -Source $local.FullName))
        }
    }

    if ($EnableRemotePostInstall) {
        $url = Get-RemotePostUrl -App $App
        if ($url) {
            if (-not (Test-TrustedPostUrl -Url $url -TrustedDomains $TrustedPostDomains)) {
                Write-Warn ("Remote post URL not trusted (blocked): {0}" -f $url)
                Log-Line WARN ("PostInstallRemoteBlocked Installer={0} Url={1}" -f $App.Name, $url)
            }
            else {
                try {
                    $dl = Download-PostScript -Url $url
                    $postRuns.Add((Invoke-PostInstallScript -Installer $App -ScriptFile $dl -Origin 'Remote' -Source $url))
                } catch {
                    Write-Bad ("Remote post download/run failed: {0}" -f $_.Exception.Message)
                    Log-Line ERROR ("PostInstallRemoteFail Installer={0} Url={1} Error={2}" -f $App.Name, $url, $_.Exception.Message)
                }
            }
        }
    }

    if ($postRuns.Count -gt 0) {
        $last = $postRuns[$postRuns.Count - 1]
        $ResultsArrayRef.Value[-1] | Add-Member -NotePropertyName PostStatus   -NotePropertyValue $last.PostStatus   -Force
        $ResultsArrayRef.Value[-1] | Add-Member -NotePropertyName PostExitCode -NotePropertyValue $last.PostExitCode -Force
        $ResultsArrayRef.Value[-1] | Add-Member -NotePropertyName PostOrigin   -NotePropertyValue $last.PostOrigin   -Force
        $ResultsArrayRef.Value[-1] | Add-Member -NotePropertyName PostScript   -NotePropertyValue $last.PostScript   -Force
        $ResultsArrayRef.Value[-1] | Add-Member -NotePropertyName PostSource   -NotePropertyValue $last.PostSource   -Force
    }
}

# ---------------------------
# CLI selection
# ---------------------------
function Show-AppsTable {
    param(
        [System.IO.FileInfo[]]$Apps,
        $SelectedSet
    )

    $Apps = @($Apps)

    Write-Host ''
    Write-Header 'Available Installers'
    for ($i=0; $i -lt $Apps.Count; $i++) {
        $n = $i + 1
        $name = $Apps[$i].Name
        $type = $Apps[$i].Extension
        $size = [math]::Round($Apps[$i].Length / 1MB, 2)

        $mark = if ($SelectedSet.Contains($n)) { '[x]' } else { '[ ]' }

        $rule = Get-MatchingRule -App $Apps[$i]
        $ruleInfo = ''
        if ($rule -and ($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
            $ruleInfo = ('  -> Args: {0}' -f (Format-ArgsForLog $rule.Args))
        }

        Write-Host ('{0} [{1}] {2}  ({3}, {4} MB){5}' -f $mark, $n, $name, $type, $size, $ruleInfo) -ForegroundColor Cyan
    }

    Write-Host ''
    Write-Host 'Commands:' -ForegroundColor Yellow
    Write-Host '  all            -> select all' -ForegroundColor Yellow
    Write-Host '  none           -> select none' -ForegroundColor Yellow
    Write-Host '  1,3,5          -> select by numbers (adds to selection)' -ForegroundColor Yellow
    Write-Host '  1-4,8,10-12    -> ranges supported (adds to selection)' -ForegroundColor Yellow
    Write-Host '  filter <text>  -> show only matching names (does not auto-select)' -ForegroundColor Yellow
    Write-Host '  show           -> show full list again' -ForegroundColor Yellow
    Write-Host '  back           -> go back to source selection' -ForegroundColor Yellow
    Write-Host '  done           -> finish selection' -ForegroundColor Yellow
    Write-Host ''
}

function Parse-Selection {
    param(
        [string]$InputText,
        [int]$Max
    )

    $picked = New-Object System.Collections.Generic.SortedSet[int]
    $parts = $InputText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($token in $parts) {
        if ($token -match '^\d+\-\d+$') {
            $a, $b = $token -split '-'
            $a = [int]$a; $b = [int]$b
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }

            for ($n = $a; $n -le $b; $n++) {
                if ($n -ge 1 -and $n -le $Max) { [void]$picked.Add($n) }
            }
        }
        elseif ($token -match '^\d+$') {
            $n = [int]$token
            if ($n -ge 1 -and $n -le $Max) { [void]$picked.Add($n) }
        }
    }

    return [int[]]@($picked)
}

function Select-AppsCli {
    param([System.IO.FileInfo[]]$Apps)

    $Apps = @($Apps)
    if ($Apps.Count -eq 0) {
        return [pscustomobject]@{ Back=$false; Selection=@() }
    }

    $selected = New-Object System.Collections.Generic.HashSet[int]

    # Preselect based on rules
    for ($i=0; $i -lt $Apps.Count; $i++) {
        $rule = Get-MatchingRule -App $Apps[$i]
        if ($rule -and ($rule.PSObject.Properties.Name -contains 'Preselect') -and $rule.Preselect -eq $true) {
            [void]$selected.Add($i + 1)
        }
    }

    Show-AppsTable -Apps $Apps -SelectedSet $selected

    if ($selected.Count -gt 0) {
        Write-Good ("Preselected by rules: {0}" -f $selected.Count)
        Log-Line INFO ("PreselectedCount={0}" -f $selected.Count)
    }

    while ($true) {
        $raw = Read-Host 'Select (type a command)'
        if (-not $raw) { continue }

        if ($raw -match '^(back|BACK)$') {
            Write-Warn 'Going back to source selection...'
            return [pscustomobject]@{ Back=$true; Selection=@() }
        }

        if ($raw -match '^(done|DONE)$') { break }

        if ($raw -match '^(show|SHOW)$') {
            Show-AppsTable -Apps $Apps -SelectedSet $selected
            continue
        }

        if ($raw -match '^(none|NONE)$') {
            $selected.Clear()
            Write-Warn 'Selection cleared.'
            continue
        }

        if ($raw -match '^(all|ALL)$') {
            $selected.Clear()
            for ($i=1; $i -le $Apps.Count; $i++) { [void]$selected.Add($i) }
            Write-Good ('Selected all ({0})' -f $Apps.Count)
            continue
        }

        if ($raw -match '^(filter|FILTER)\s+(.+)$') {
            $filterText = $Matches[2].Trim()
            Write-Host ''
            Write-Header ('Filtered View: {0}' -f $filterText)
            for ($i=0; $i -lt $Apps.Count; $i++) {
                if ($Apps[$i].Name -like ('*{0}*' -f $filterText)) {
                    $n = $i + 1
                    $mark = if ($selected.Contains($n)) { '[x]' } else { '[ ]' }
                    Write-Host ('{0} [{1}] {2}' -f $mark, $n, $Apps[$i].Name) -ForegroundColor Cyan
                }
            }
            Write-Host ''
            continue
        }

        $picked = [int[]](Parse-Selection -InputText $raw -Max $Apps.Count)
        if ($picked.Count -eq 0) {
            Write-Warn 'No valid selection parsed. Use e.g. 1,3,5 or 1-4.'
            continue
        }

        foreach ($n in $picked) { [void]$selected.Add($n) }
        Write-Good ('Selected count now: {0}' -f $selected.Count)
    }

    $final = @(
        foreach ($n in ($selected | Sort-Object)) { $Apps[$n - 1] }
    )

    return [pscustomobject]@{
        Back      = $false
        Selection = $final
    }
}

# ---------------------------
# Install execution (default logic + rule overrides)
# ---------------------------
function Get-InstallSpec {
    param([System.IO.FileInfo]$App)

    $rule = Get-MatchingRule -App $App
    if ($rule) {
        Log-Line INFO ("RuleMatch={0} App={1}" -f $rule.Name, $App.Name)
    }

    if ($App.Extension -eq '.msi') {
        # If a rule provides MSI args, treat it as full msiexec args (string or string[])
        if ($rule -and ($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
            return @{ File='msiexec.exe'; Args=$rule.Args }
        }

        # Default MSI: tokenized args (safe for spaces)
        return @{ File='msiexec.exe'; Args=@('/i', $App.FullName, '/qn', '/norestart') }
    }

    # EXE: if rule provides args use it, else default /S
    if ($rule -and ($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
        return @{ File=$App.FullName; Args=$rule.Args }
    }

    return @{ File=$App.FullName; Args=@('/S') }
}

function Start-ProcessWait {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        $Args
    )

    if ($null -eq $Args) {
        return (Start-Process -FilePath $FilePath -Wait -PassThru -WindowStyle Hidden)
    }

    if ($Args -is [System.Array]) {
        if ($Args.Count -eq 0) {
            return (Start-Process -FilePath $FilePath -Wait -PassThru -WindowStyle Hidden)
        }
        return (Start-Process -FilePath $FilePath -ArgumentList $Args -Wait -PassThru -WindowStyle Hidden)
    }

    $s = [string]$Args
    if ([string]::IsNullOrWhiteSpace($s)) {
        return (Start-Process -FilePath $FilePath -Wait -PassThru -WindowStyle Hidden)
    }

    return (Start-Process -FilePath $FilePath -ArgumentList $s -Wait -PassThru -WindowStyle Hidden)
}

function Install-Apps {
    param([System.IO.FileInfo[]]$Selection)

    $Selection = @($Selection)

    if ($Selection.Count -eq 0) {
        Write-Warn 'No installers selected. Exiting.'
        Log-Line WARN 'NoSelection'
        return
    }

    Write-Host ''
    Write-Header 'Planned Installation'
    foreach ($a in ($Selection | Sort-Object Name)) {
        $spec = Get-InstallSpec -App $a
        $argsText = Format-ArgsForLog $spec.Args
        if (-not [string]::IsNullOrWhiteSpace($argsText)) {
            Write-Host (' - {0}  -> {1} {2}' -f $a.Name, $spec.File, $argsText) -ForegroundColor Green
        } else {
            Write-Host (' - {0}  -> {1}' -f $a.Name, $spec.File) -ForegroundColor Green
        }
    }

    if (-not $SkipPostInstall) {
        Write-Host ''
        Write-Info ("Post-install: Local={0} Remote={1} (Remote default OFF)" -f $EnableLocalPostInstall, $EnableRemotePostInstall)
    }

    $go = Read-Host 'Proceed with installation? (Y/N)'
    if ($go -notmatch '^[Yy]$') {
        Write-Warn 'User declined. Exiting.'
        Log-Line WARN 'UserDeclined'
        return
    }

    $total = $Selection.Count
    $idx = 0
    $results = @()

    foreach ($app in ($Selection | Sort-Object Name)) {
        $idx++
        $pct = [int](($idx / $total) * 100)
        $status = ('{0}/{1}: {2}' -f $idx, $total, $app.Name)
        Write-Progress -Activity 'Installing applications' -Status $status -PercentComplete $pct

        if ($ConfirmEach) {
            $c = Read-Host ('Install {0}? (Y/N)' -f $app.Name)
            if ($c -notmatch '^[Yy]$') {
                Write-Warn ('Skipping {0}' -f $app.Name)
                Log-Line WARN ('Skipped={0}' -f $app.Name)
                $results += [pscustomobject]@{
                    Name=$app.Name; Status='Skipped'; ExitCode=$null
                    PostStatus=''; PostExitCode=$null; PostOrigin=''; PostScript=''; PostSource=''
                }
                continue
            }
        }

        $spec = Get-InstallSpec -App $app
        $cmdArgs = Format-ArgsForLog $spec.Args

        Write-Info ('Installing: {0}' -f $app.Name)
        Log-Line INFO ('InstallStart={0}' -f $app.FullName)
        Log-Line INFO ('Command={0} {1}' -f $spec.File, $cmdArgs)

        try {
            $p = Start-ProcessWait -FilePath $spec.File -Args $spec.Args
            $code = $p.ExitCode

            if ($code -eq 0) {
                Write-Good ('Success: {0} (ExitCode=0)' -f $app.Name)
                Log-Line OK ('InstallOK={0} ExitCode=0' -f $app.Name)
                $results += [pscustomobject]@{
                    Name=$app.Name; Status='OK'; ExitCode=0
                    PostStatus=''; PostExitCode=$null; PostOrigin=''; PostScript=''; PostSource=''
                }
            } else {
                Write-Bad ('Failed: {0} (ExitCode={1})' -f $app.Name, $code)
                Log-Line ERROR ('InstallFail={0} ExitCode={1}' -f $app.Name, $code)
                $results += [pscustomobject]@{
                    Name=$app.Name; Status='Failed'; ExitCode=$code
                    PostStatus=''; PostExitCode=$null; PostOrigin=''; PostScript=''; PostSource=''
                }
            }

            # Post-install hook (after creating results row)
            Run-PostInstallIfAvailable -App $app -InstallerExitCode $code -ResultsArrayRef ([ref]$results)
        }
        catch {
            Write-Bad ('Error installing {0}: {1}' -f $app.Name, $_.Exception.Message)
            Log-Line ERROR ('InstallException={0} {1}' -f $app.Name, $_.Exception.Message)
            $results += [pscustomobject]@{
                Name=$app.Name; Status='Error'; ExitCode=$null
                PostStatus=''; PostExitCode=$null; PostOrigin=''; PostScript=''; PostSource=''
            }

            if ($RunPostOnFail) {
                Run-PostInstallIfAvailable -App $app -InstallerExitCode 9999 -ResultsArrayRef ([ref]$results)
            }
        }
    }

    Write-Progress -Activity 'Installing applications' -Completed

    Write-Host ''
    Write-Header 'Summary'
    $results | Format-Table Name, Status, ExitCode, PostStatus, PostExitCode, PostOrigin, PostScript -AutoSize

    Write-Host ''
    Write-Host ('All done. Transcript: {0}' -f $global:LogFile) -ForegroundColor Cyan
    Write-Host ('Meta log   : {0}' -f $global:MetaLog) -ForegroundColor Cyan
}

# ---------------------------
# Main
# ---------------------------
Ensure-Admin
Write-Header 'Auto App Installer v2.1.0 (CLI only) (by rhshourav)'
New-Log

try {
    Self-Check

    while ($true) {
        $src = Resolve-InstallBasePath
        if (-not $src) { throw 'No installation source available.' }

        Write-Good ('Using installation folder: {0}' -f $src.Path)
        Write-Info 'Recursive scan enabled (subfolders will be scanned).'

        $apps = @(Get-Installers -BasePath $src.Path -Recurse:$src.Recurse)
        if ($apps.Count -eq 0) {
            Write-Warn ('No .exe or .msi files found in: {0}' -f $src.Path)
            Log-Line WARN ('NoInstallersFound={0} Recurse={1}' -f $src.Path, $src.Recurse)

            $back = Read-Host 'Go back to source selection? (Y/N)'
            if ($back -match '^[Yy]$') { continue }
            break
        }

        $pick = Select-AppsCli -Apps $apps
        if ($pick.Back) { continue }

        Install-Apps -Selection $pick.Selection

        $again = Read-Host 'Go back to source selection? (Y/N)'
        if ($again -match '^[Yy]$') { continue }
        break
    }
}
catch {
    Write-Bad $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-Bad ("At {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
        Write-Bad $_.InvocationInfo.Line.Trim()
    }
    try { Log-Line ERROR $_.Exception.Message } catch {}
}
finally {
    Stop-Log
}
