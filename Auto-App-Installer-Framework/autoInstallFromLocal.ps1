#requires -version 5.1
<#
.SYNOPSIS
  Auto App Installer – CLI Only – V3.0.3 (by rhshourav)

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
  - Pre-install hooks:
      * Local: <InstallerBaseName>.pre.ps1/.cmd/.bat (same folder)
      * Remote: rule-based PreUrl (download to %TEMP%, optional; OFF by default)
  - Post-install hooks:
      * Local: <InstallerBaseName>.post.ps1/.cmd/.bat (same folder)
      * Remote: rule-based PostUrl (download to %TEMP%, optional; OFF by default)
  - Explicit user permission before install
  - Sequential execution (waits each installer) + exit code capture
  - Robust logging (Transcript + meta log)
  - Graceful fallback after 30s with progress bar (NO IEX)
  - Windows 10 / 11 compatible, PowerShell 5.1+

NOTES
  - Remote hook execution is OFF by default.
  - Trust is domain-based AND HTTPS-only. Prefer pinning raw GitHub URLs to commit SHA.

V3.0.3 changes:
  - EXE watchdog support (fixes installers that spawn an app and wait for it to exit, e.g., Greenshot):
      * Rule fields:
          WatchCloseProcesses       = @('Greenshot')
          WatchCloseAfterSeconds    = 8
          WatchCloseIncludeExisting = $true
      * Installer will be watched; after N seconds the spawned app(s) are closed/killed so installer can exit.
#>

[CmdletBinding()]
param(
    [switch]$ConfirmEach = $false,
    [string]$LocalFallbackDir = "$PSScriptRoot\Installers",
    [string]$FrameworkUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1',

    # MSI default mode (global)
    [ValidateSet('Silent','Basic','UI')]
    [string]$DefaultMsiMode = 'Silent',

    # Pre-install controls
    [switch]$SkipPreInstall          = $false,
    [switch]$ContinueOnPreFail       = $false,   # safer default: if pre fails, skip installer
    [switch]$EnableLocalPreInstall   = $true,
    [switch]$EnableRemotePreInstall  = $false,   # safer default: OFF

    # Post-install controls
    [switch]$SkipPostInstall         = $false,
    [switch]$RunPostOnFail           = $false,
    [switch]$EnableLocalPostInstall  = $true,
    [switch]$EnableRemotePostInstall = $false,   # safer default: OFF

    # Hook trust + success codes
    [string[]]$TrustedHookDomains    = @('raw.githubusercontent.com'),
    [int[]]$PreSuccessExitCodes      = @(0),
    [int[]]$PostSuccessExitCodes     = @(0,3010,1641)
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
  Args      : OPTIONAL. Overrides/extends default args. Can be string or string[]
             - For MSI rules:
                 * If Args contains /i or /package or a .msi token, it is treated as FULL msiexec args.
                 * Otherwise it is appended to the base args for the chosen MSI mode.
  MsiMode   : OPTIONAL (MSI only). 'Silent' | 'Basic' | 'UI'
  Preselect : OPTIONAL. If $true, app is pre-selected automatically
  PreUrl    : OPTIONAL. Remote pre-install hook URL (ps1/cmd/bat). Requires -EnableRemotePreInstall
  PostUrl   : OPTIONAL. Remote post-install hook URL (ps1/cmd/bat). Requires -EnableRemotePostInstall

  EXE Watchdog fields (OPTIONAL):
    WatchCloseProcesses       : string[] process names to close/kill if installer blocks (no .exe required)
    WatchCloseAfterSeconds    : int seconds after installer start to perform close/kill
    WatchCloseIncludeExisting : bool; if $true, closes even pre-existing processes with same name

Notes:
  - First-match wins. Put specific rules above general ones.
  - EXE defaults to '/S' when no rule args exist.
  - MSI defaults depend on mode:
      Silent: /i "<msi>" /qn /norestart
      Basic : /i "<msi>" /qb /norestart
      UI    : /i "<msi>" /norestart
    (MSI always adds /L*V "<log>" unless your rule already specifies /l* in FULL mode)
#>

$global:InstallerRules = @(
    # --- Greenshot: installer may launch Greenshot and WAIT for it to exit ---
    [pscustomobject]@{
        Name      = 'Greenshot - silent + watchdog (avoid installer waiting on app)'
        AppliesTo = 'Exe'
        MatchType = 'Contains'
        Match     = 'Greenshot'
        Args      = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/ALLUSERS')
        Preselect = $false

        WatchCloseProcesses       = @('Greenshot')
        WatchCloseAfterSeconds    = 8
        WatchCloseIncludeExisting = $true
    },

    # --- FIX for Sentinel: run MSI with UI (no /qn) ---
    [pscustomobject]@{
        Name      = 'Sentinel MSI - UI mode (avoid silent 1603)'
        AppliesTo = 'Msi'
        MatchType = 'Contains'
        Match     = 'SentinelInstaller'
        MsiMode   = 'UI'
        Args      = $null
        Preselect = $false
    },

    [pscustomobject]@{
        Name      = 'PDF Factory '
        AppliesTo = 'Exe'
        MatchType = 'Contains'
        Match     = 'pdf'
        Args      = @('/quiet /nodisp /reboot=0')
        Preselect = $false
    },
    [pscustomobject]@{
        Name      = 'Sophos Silent'
        AppliesTo = 'Exe'
        MatchType = 'Contains'
        Match     = 'Sophos'
        Args      = @('--quiet')
        Preselect = $false
    },
    [pscustomobject]@{
        Name      = 'Revo Silent '
        AppliesTo = 'Exe'
        MatchType = 'Contains'
        Match     = 'Revo'
        Args      = @('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART')
        Preselect = $false
    }

    # Add more rules below...
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
        @{ Label='DST PC';            Path='\\192.168.18.201\it\PC Setup\Auto\DST';            Recurse=$true },
        @{ Label='Staff PC';          Path='\\192.168.18.201\it\PC Setup\Auto\Staff pc';       Recurse=$true },
        @{ Label='Production PC';     Path='\\192.168.18.201\it\PC Setup\Auto\Production pc';  Recurse=$true }
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

function Get-MsiModeForApp {
    param([Parameter(Mandatory)][System.IO.FileInfo]$App)

    if ($App.Extension -ne '.msi') { return $null }

    $rule = Get-MatchingRule -App $App
    if ($rule -and ($rule.PSObject.Properties.Name -contains 'MsiMode')) {
        $m = [string]$rule.MsiMode
        if ($m -in @('Silent','Basic','UI')) { return $m }
    }
    return $DefaultMsiMode
}

# ---------------------------
# Hook utilities (trust + download + local/remote resolve)
# ---------------------------
function Test-TrustedHookUrl {
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

function Get-RemoteHookUrl {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$App,
        [Parameter(Mandatory)][ValidateSet('Pre','Post')] [string]$Stage
    )

    $rule = Get-MatchingRule -App $App
    if (-not $rule) { return $null }

    $prop = if ($Stage -eq 'Pre') { 'PreUrl' } else { 'PostUrl' }
    if ($rule.PSObject.Properties.Name -contains $prop) {
        $u = [string]$rule.$prop
        if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
    }
    return $null
}

function Download-HookScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('Pre','Post')] [string]$Stage
    )

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $nameFromUrl = ([Uri]$Url).AbsolutePath.Split('/')[-1]
    if ([string]::IsNullOrWhiteSpace($nameFromUrl)) { $nameFromUrl = "hook.$Stage.ps1" }

    $ext = [System.IO.Path]::GetExtension($nameFromUrl)
    if ([string]::IsNullOrWhiteSpace($ext)) { $nameFromUrl += '.ps1' }

    $root = Join-Path $env:TEMP 'rhshourav\WindowsScripts\Hooks'
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    $dst = Join-Path $root ("{0}_{1}_{2}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Stage.ToLowerInvariant(), $nameFromUrl)

    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $dst -ErrorAction Stop
    return (Get-Item -LiteralPath $dst -ErrorAction Stop)
}

function Get-LocalHookScript {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$App,
        [Parameter(Mandatory)][ValidateSet('Pre','Post')] [string]$Stage
    )

    $dir  = $App.DirectoryName
    $base = $App.BaseName
    $suffix = if ($Stage -eq 'Pre') { '.pre' } else { '.post' }

    $candidates = @(
        (Join-Path $dir ($base + $suffix + '.ps1')),
        (Join-Path $dir ($base + $suffix + '.cmd')),
        (Join-Path $dir ($base + $suffix + '.bat'))
    )

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            try { return (Get-Item -LiteralPath $c -ErrorAction Stop) } catch { }
        }
    }
    return $null
}

function Invoke-HookScript {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Installer,
        [Parameter(Mandatory)][System.IO.FileInfo]$ScriptFile,
        [Parameter(Mandatory)][ValidateSet('Pre','Post')] [string]$Stage,
        [Parameter(Mandatory)][ValidateSet('Local','Remote')] [string]$Origin,
        [string]$Source = ''
    )

    Write-Info ("{0}-install ({1}): {2}" -f $Stage, $Origin, $ScriptFile.Name)
    Log-Line INFO ("{0}InstallStart Origin={1} Installer={2} Script={3} Source={4}" -f $Stage, $Origin, $Installer.Name, $ScriptFile.FullName, $Source)

    try {
        $ext = $ScriptFile.Extension.ToLowerInvariant()
        $p = $null

        # Visible, independent window (no Hidden). If you want it to stay open,
        # add Read-Host/pause inside your hook script itself.
        if ($ext -eq '.ps1') {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy','Bypass',
                '-File', $ScriptFile.FullName
            ) -Wait -PassThru -WindowStyle Normal
        }
        elseif ($ext -in '.cmd','.bat') {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $ScriptFile.FullName) -Wait -PassThru -WindowStyle Normal
        }
        else {
            throw ("Unsupported {0}-install script type: {1}" -f $Stage, $ScriptFile.Name)
        }

        $ec = $p.ExitCode
        if ($ec -eq 0) {
            Write-Good ("{0}-install OK: {1}" -f $Stage, $ScriptFile.Name)
            Log-Line OK ("{0}InstallOK Origin={1} Installer={2} Script={3} ExitCode=0" -f $Stage, $Origin, $Installer.Name, $ScriptFile.Name)
            return [pscustomobject]@{ HookStatus='OK'; HookExitCode=0; HookScript=$ScriptFile.Name; HookOrigin=$Origin; HookSource=$Source }
        } else {
            Write-Warn ("{0}-install finished with ExitCode={1}: {2}" -f $Stage, $ec, $ScriptFile.Name)
            Log-Line WARN ("{0}InstallExit Origin={1} Installer={2} Script={3} ExitCode={4}" -f $Stage, $Origin, $Installer.Name, $ScriptFile.Name, $ec)
            return [pscustomobject]@{ HookStatus='NonZero'; HookExitCode=$ec; HookScript=$ScriptFile.Name; HookOrigin=$Origin; HookSource=$Source }
        }
    }
    catch {
        Write-Bad ("{0}-install error: {1}" -f $Stage, $_.Exception.Message)
        Log-Line ERROR ("{0}InstallError Origin={1} Installer={2} Script={3} Error={4}" -f $Stage, $Origin, $Installer.Name, $ScriptFile.Name, $_.Exception.Message)
        return [pscustomobject]@{ HookStatus='Error'; HookExitCode=$null; HookScript=$ScriptFile.Name; HookOrigin=$Origin; HookSource=$Source }
    }
}

function Run-PreInstallIfAvailable {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$App,
        [Parameter(Mandatory)]$RowRef
    )

    if ($SkipPreInstall) {
        Log-Line INFO ("PreInstallSkippedGlobally Installer={0}" -f $App.Name)
        $RowRef.Value.PreStatus = 'Skipped'
        return $true
    }

    $ranAny = $false
    $last = $null

    if ($EnableLocalPreInstall) {
        $local = Get-LocalHookScript -App $App -Stage 'Pre'
        if ($local) {
            $ranAny = $true
            $last = Invoke-HookScript -Installer $App -ScriptFile $local -Stage 'Pre' -Origin 'Local' -Source $local.FullName
        } else {
            Log-Line INFO ("NoLocalPreFound Installer={0} ExpectedBase={1} Dir={2}" -f $App.Name, $App.BaseName, $App.DirectoryName)
        }
    } else {
        Log-Line INFO ("LocalPreDisabled Installer={0}" -f $App.Name)
    }

    if ($EnableRemotePreInstall) {
        $url = Get-RemoteHookUrl -App $App -Stage 'Pre'
        if ($url) {
            if (-not (Test-TrustedHookUrl -Url $url -TrustedDomains $TrustedHookDomains)) {
                Write-Warn ("Remote pre URL not trusted (blocked): {0}" -f $url)
                Log-Line WARN ("PreInstallRemoteBlocked Installer={0} Url={1}" -f $App.Name, $url)
            } else {
                try {
                    $dl = Download-HookScript -Url $url -Stage 'Pre'
                    $ranAny = $true
                    $last = Invoke-HookScript -Installer $App -ScriptFile $dl -Stage 'Pre' -Origin 'Remote' -Source $url
                } catch {
                    Write-Bad ("Remote pre download/run failed: {0}" -f $_.Exception.Message)
                    Log-Line ERROR ("PreInstallRemoteFail Installer={0} Url={1} Error={2}" -f $App.Name, $url, $_.Exception.Message)
                }
            }
        } else {
            Log-Line INFO ("NoRemotePreUrl Installer={0}" -f $App.Name)
        }
    }

    if (-not $ranAny) {
        $RowRef.Value.PreStatus = ''
        return $true
    }

    if ($last) {
        $RowRef.Value.PreStatus   = $last.HookStatus
        $RowRef.Value.PreExitCode = $last.HookExitCode
        $RowRef.Value.PreOrigin   = $last.HookOrigin
        $RowRef.Value.PreScript   = $last.HookScript
        $RowRef.Value.PreSource   = $last.HookSource
    }

    if ($null -ne $RowRef.Value.PreExitCode) {
        $ok = $PreSuccessExitCodes -contains [int]$RowRef.Value.PreExitCode
        return $ok
    }

    return $false
}

function Run-PostInstallIfEligible {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$App,
        [Parameter(Mandatory)][int]$InstallerExitCode,
        [Parameter(Mandatory)]$RowRef
    )

    if ($SkipPostInstall) {
        Log-Line INFO ("PostInstallSkippedGlobally Installer={0}" -f $App.Name)
        return
    }

    $isSuccess = $PostSuccessExitCodes -contains $InstallerExitCode
    $shouldRun = $isSuccess -or $RunPostOnFail
    if (-not $shouldRun) {
        Log-Line INFO ("PostInstallNotEligible Installer={0} ExitCode={1} SuccessCodes={2} RunPostOnFail={3}" -f `
            $App.Name, $InstallerExitCode, ($PostSuccessExitCodes -join ','), $RunPostOnFail)
        return
    }

    $ranAny = $false
    $last = $null

    if ($EnableLocalPostInstall) {
        $local = Get-LocalHookScript -App $App -Stage 'Post'
        if ($local) {
            $ranAny = $true
            $last = Invoke-HookScript -Installer $App -ScriptFile $local -Stage 'Post' -Origin 'Local' -Source $local.FullName
        } else {
            Log-Line INFO ("NoLocalPostFound Installer={0} ExpectedBase={1} Dir={2}" -f $App.Name, $App.BaseName, $App.DirectoryName)
        }
    } else {
        Log-Line INFO ("LocalPostDisabled Installer={0}" -f $App.Name)
    }

    if ($EnableRemotePostInstall) {
        $url = Get-RemoteHookUrl -App $App -Stage 'Post'
        if ($url) {
            if (-not (Test-TrustedHookUrl -Url $url -TrustedDomains $TrustedHookDomains)) {
                Write-Warn ("Remote post URL not trusted (blocked): {0}" -f $url)
                Log-Line WARN ("PostInstallRemoteBlocked Installer={0} Url={1}" -f $App.Name, $url)
            } else {
                try {
                    $dl = Download-HookScript -Url $url -Stage 'Post'
                    $ranAny = $true
                    $last = Invoke-HookScript -Installer $App -ScriptFile $dl -Stage 'Post' -Origin 'Remote' -Source $url
                } catch {
                    Write-Bad ("Remote post download/run failed: {0}" -f $_.Exception.Message)
                    Log-Line ERROR ("PostInstallRemoteFail Installer={0} Url={1} Error={2}" -f $App.Name, $url, $_.Exception.Message)
                }
            }
        } else {
            Log-Line INFO ("NoRemotePostUrl Installer={0}" -f $App.Name)
        }
    }

    if ($ranAny -and $last) {
        $RowRef.Value.PostStatus   = $last.HookStatus
        $RowRef.Value.PostExitCode = $last.HookExitCode
        $RowRef.Value.PostOrigin   = $last.HookOrigin
        $RowRef.Value.PostScript   = $last.HookScript
        $RowRef.Value.PostSource   = $last.HookSource
    }
}

function Get-PlannedHookInfo {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$App,
        [Parameter(Mandatory)][ValidateSet('Pre','Post')] [string]$Stage
    )

    $skip = if ($Stage -eq 'Pre') { $SkipPreInstall } else { $SkipPostInstall }
    if ($skip) {
        return [pscustomobject]@{
            Text   = ("{0}: (skipped)" -f $Stage)
            Local  = $null
            Remote = $null
        }
    }

    $localEnabled  = if ($Stage -eq 'Pre') { $EnableLocalPreInstall } else { $EnableLocalPostInstall }
    $remoteEnabled = if ($Stage -eq 'Pre') { $EnableRemotePreInstall } else { $EnableRemotePostInstall }

    $localPath = $null
    if ($localEnabled) {
        $local = Get-LocalHookScript -App $App -Stage $Stage
        if ($local) { $localPath = $local.FullName }
    }

    $remoteUrl = $null
    if ($remoteEnabled) {
        $remoteUrl = Get-RemoteHookUrl -App $App -Stage $Stage
        if ($remoteUrl -and -not (Test-TrustedHookUrl -Url $remoteUrl -TrustedDomains $TrustedHookDomains)) {
            $remoteUrl = ("BLOCKED (untrusted): {0}" -f $remoteUrl)
        }
    }

    $parts = New-Object System.Collections.Generic.List[string]

    if ($localEnabled) {
        if ($localPath) { [void]$parts.Add(("Local={0}" -f $localPath)) }
        else            { [void]$parts.Add("Local=(none)") }
    } else {
        [void]$parts.Add("Local=(disabled)")
    }

    if ($remoteEnabled) {
        if ($remoteUrl) { [void]$parts.Add(("Remote={0}" -f $remoteUrl)) }
        else            { [void]$parts.Add("Remote=(none)") }
    } else {
        [void]$parts.Add("Remote=(disabled)")
    }

    return [pscustomobject]@{
        Text   = ('{0}: ' -f $Stage) + ($parts -join ' | ')
        Local  = $localPath
        Remote = $remoteUrl
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
        if ($rule) {
            if (($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
                $ruleInfo += ('  -> Args: {0}' -f (Format-ArgsForLog $rule.Args))
            }
            if ($Apps[$i].Extension -eq '.msi' -and ($rule.PSObject.Properties.Name -contains 'MsiMode') -and $rule.MsiMode) {
                $ruleInfo += ('  -> MsiMode: {0}' -f $rule.MsiMode)
            }
            if ($Apps[$i].Extension -eq '.exe' -and ($rule.PSObject.Properties.Name -contains 'WatchCloseProcesses') -and $rule.WatchCloseProcesses) {
                $ruleInfo += ('  -> WatchClose: {0}' -f ((@($rule.WatchCloseProcesses)) -join ','))
            }
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

    return [pscustomobject]@{ Back=$false; Selection=$final }
}

# ---------------------------
# Install execution
# ---------------------------
function Start-ProcessWait {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        $Args
    )

    if ($null -eq $Args) {
        return (Start-Process -FilePath $FilePath -Wait -PassThru)
    }

    if ($Args -is [System.Array]) {
        if ($Args.Count -eq 0) {
            return (Start-Process -FilePath $FilePath -Wait -PassThru)
        }
        return (Start-Process -FilePath $FilePath -ArgumentList $Args -Wait -PassThru)
    }

    $s = [string]$Args
    if ([string]::IsNullOrWhiteSpace($s)) {
        return (Start-Process -FilePath $FilePath -Wait -PassThru)
    }

    return (Start-Process -FilePath $FilePath -ArgumentList $s -Wait -PassThru)
}

function Start-ProcessWaitWithWatchdog {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        $Args,

        [string[]]$WatchCloseProcesses = @(),
        [int]$WatchCloseAfterSeconds = 0,
        [bool]$WatchCloseIncludeExisting = $false
    )

    function _NormalizeProcName([string]$n) {
        if ([string]::IsNullOrWhiteSpace($n)) { return $null }
        $n = $n.Trim()
        if ($n.ToLowerInvariant().EndsWith('.exe')) { $n = $n.Substring(0, $n.Length - 4) }
        return $n
    }

    if ($null -eq $WatchCloseProcesses) { $WatchCloseProcesses = @() }
    $watchNames = @()
    foreach ($n in @($WatchCloseProcesses)) {
        $nn = _NormalizeProcName $n
        if ($nn) { $watchNames += $nn }
    }
    $watchNames = @($watchNames | Select-Object -Unique)

    # Snapshot existing PIDs (so we can avoid killing user processes unless explicitly allowed)
    $existing = @{}
    foreach ($n in $watchNames) {
        $pids = @()
        try { $pids = @(Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) } catch {}
        $existing[$n] = $pids
    }

    # Start installer (NO -Wait; we wait in slices)
    if ($null -eq $Args) {
        $p = Start-Process -FilePath $FilePath -PassThru
    }
    elseif ($Args -is [System.Array]) {
        if ($Args.Count -eq 0) { $p = Start-Process -FilePath $FilePath -PassThru }
        else { $p = Start-Process -FilePath $FilePath -ArgumentList $Args -PassThru }
    }
    else {
        $s = [string]$Args
        if ([string]::IsNullOrWhiteSpace($s)) { $p = Start-Process -FilePath $FilePath -PassThru }
        else { $p = Start-Process -FilePath $FilePath -ArgumentList $s -PassThru }
    }

    $start = Get-Date
    $kicked = $false

    while ($true) {
        try {
            if ($p.WaitForExit(500)) { break }
        } catch {
            break
        }

        if (-not $kicked -and $watchNames.Count -gt 0 -and $WatchCloseAfterSeconds -gt 0) {
            $elapsed = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds
            if ($elapsed -ge $WatchCloseAfterSeconds) {
                foreach ($n in $watchNames) {
                    $targets = @()
                    try { $targets = @(Get-Process -Name $n -ErrorAction SilentlyContinue) } catch {}

                    foreach ($tp in $targets) {
                        $shouldClose = $true
                        if (-not $WatchCloseIncludeExisting) {
                            if ($existing.ContainsKey($n) -and ($existing[$n] -contains $tp.Id)) {
                                $shouldClose = $false
                            }
                        }

                        if ($shouldClose) {
                            try { [void]$tp.CloseMainWindow() } catch {}
                            Start-Sleep -Milliseconds 600
                            try { Stop-Process -Id $tp.Id -Force -ErrorAction SilentlyContinue } catch {}
                        }
                    }
                }
                $kicked = $true
            }
        }
    }

    try { $p.WaitForExit() } catch {}
    return $p
}

function Get-InstallSpec {
    param([System.IO.FileInfo]$App)

    $rule = Get-MatchingRule -App $App
    if ($rule) { Log-Line INFO ("RuleMatch={0} App={1}" -f $rule.Name, $App.Name) }

    if ($App.Extension -eq '.msi') {
        $mode = Get-MsiModeForApp -App $App
        $base =
            if ($mode -eq 'UI')    { @('/i', $App.FullName, '/norestart') }
            elseif ($mode -eq 'Basic') { @('/i', $App.FullName, '/qb', '/norestart') }
            else                  { @('/i', $App.FullName, '/qn', '/norestart') }

        if ($rule -and ($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
            return @{ File='msiexec.exe'; Args=$rule.Args }
        }

        return @{ File='msiexec.exe'; Args=$base }
    }

    if ($rule -and ($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
        return @{ File=$App.FullName; Args=$rule.Args }
    }

    return @{ File=$App.FullName; Args=@('/S') }
}

# ---------------------------
# MSI reliability helpers
# ---------------------------
function Get-MsiexecPath {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $p = Join-Path $env:WINDIR 'sysnative\msiexec.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $p2 = Join-Path $env:WINDIR 'System32\msiexec.exe'
    if (Test-Path -LiteralPath $p2) { return $p2 }
    return 'msiexec.exe'
}
function Test-IsUncPath {
    param([Parameter(Mandatory)][string]$Path)
    return ($Path.StartsWith('\\'))
}
function Stage-FileToTemp {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$StageTag
    )

    $root = Join-Path $env:TEMP "rhshourav\WindowsScripts\Staging\$StageTag"
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dst   = Join-Path $root ("{0}_{1}" -f $stamp, $File.Name)

    for ($i=1; $i -le 3; $i++) {
        try {
            Copy-Item -LiteralPath $File.FullName -Destination $dst -Force -ErrorAction Stop
            return (Get-Item -LiteralPath $dst -ErrorAction Stop)
        } catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}
function New-MsiLogPath {
    param([Parameter(Mandatory)][System.IO.FileInfo]$App)
    $root = Join-Path $env:TEMP 'rhshourav\WindowsScripts\MsiLogs'
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safe  = ($App.BaseName -replace '[^\w\.\-]+','_')
    return (Join-Path $root ("{0}_{1}.msi.log" -f $stamp, $safe))
}

function Build-MsiexecArgs {
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        $RuleArgs,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][ValidateSet('Silent','Basic','UI')] [string]$Mode
    )

    $base =
        if ($Mode -eq 'UI')    { "/i `"$MsiPath`" /norestart" }
        elseif ($Mode -eq 'Basic') { "/i `"$MsiPath`" /qb /norestart" }
        else                  { "/i `"$MsiPath`" /qn /norestart" }

    $ruleText = ''
    if ($null -ne $RuleArgs) {
        if ($RuleArgs -is [System.Array]) { $ruleText = ($RuleArgs -join ' ') }
        else { $ruleText = [string]$RuleArgs }
        $ruleText = $ruleText.Trim()
    }

    $looksFull =
        ($ruleText -match '(?i)(^|\s)/i(\s|$)') -or
        ($ruleText -match '(?i)(^|\s)/package(\s|$)') -or
        ($ruleText -match '(?i)\.msi(\s|$)')

    if ([string]::IsNullOrWhiteSpace($ruleText)) {
        $args = $base
    } elseif ($looksFull) {
        $args = $ruleText
    } else {
        $args = ($base + ' ' + $ruleText).Trim()
    }

    $hasLog = ($args -match '(?i)(^|\s)/l') -or ($args -match '(?i)(^|\s)/log(\s|$)')
    if (-not $hasLog) {
        $args += " /L*V `"$LogPath`""
    }

    return $args
}

function Get-InstallRunSpec {
    param([Parameter(Mandatory)][System.IO.FileInfo]$App)

    # Defaults for ALL app types (prevents StrictMode issues)
    $watchNames = @()
    $watchAfter = 0
    $watchExisting = $false

    $rule = Get-MatchingRule -App $App
    if ($rule) {
        if ($rule.PSObject.Properties.Name -contains 'WatchCloseProcesses') {
            $watchNames = @($rule.WatchCloseProcesses)
        }
        if ($rule.PSObject.Properties.Name -contains 'WatchCloseAfterSeconds') {
            $watchAfter = [int]$rule.WatchCloseAfterSeconds
        }
        if ($rule.PSObject.Properties.Name -contains 'WatchCloseIncludeExisting') {
            $watchExisting = [bool]$rule.WatchCloseIncludeExisting
        }
    }

    if ($App.Extension -ne '.msi') {
        $spec = Get-InstallSpec -App $App
        return [pscustomobject]@{
            File        = [string]$spec.File
            Args        = $spec.Args
            PayloadPath = $App.FullName
            LogPath     = ''
            MsiMode     = ''

            WatchCloseProcesses       = $watchNames
            WatchCloseAfterSeconds    = $watchAfter
            WatchCloseIncludeExisting = $watchExisting
        }
    }

    if ($rule) { Log-Line INFO ("RuleMatch={0} App={1}" -f $rule.Name, $App.Name) }

    $mode = Get-MsiModeForApp -App $App

    $payload = $App
    if (Test-IsUncPath -Path $App.FullName) {
        Write-Info ("Staging MSI locally (UNC detected): {0}" -f $App.FullName)
        Log-Line INFO ("MsiStageStart={0}" -f $App.FullName)
        $payload = Stage-FileToTemp -File $App -StageTag 'MSI'
        Log-Line OK ("MsiStagedTo={0}" -f $payload.FullName)
    }

    $msiLog = New-MsiLogPath -App $App
    $msiExe = Get-MsiexecPath

    $ruleArgs = $null
    if ($rule -and ($rule.PSObject.Properties.Name -contains 'Args') -and $null -ne $rule.Args) {
        $ruleArgs = $rule.Args
    }

    $args = Build-MsiexecArgs -MsiPath $payload.FullName -RuleArgs $ruleArgs -LogPath $msiLog -Mode $mode

    return [pscustomobject]@{
        File        = $msiExe
        Args        = $args
        PayloadPath = $payload.FullName
        LogPath     = $msiLog
        MsiMode     = $mode

        WatchCloseProcesses       = @()   # not used for MSI (kept for shape consistency)
        WatchCloseAfterSeconds    = 0
        WatchCloseIncludeExisting = $false
    }
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

        $rule = Get-MatchingRule -App $a
        if ($a.Extension -eq '.exe' -and $rule -and ($rule.PSObject.Properties.Name -contains 'WatchCloseProcesses') -and $rule.WatchCloseProcesses) {
            $wa = 0
            if ($rule.PSObject.Properties.Name -contains 'WatchCloseAfterSeconds') { $wa = [int]$rule.WatchCloseAfterSeconds }
            Write-Host ("   Watchdog: Close/Kill [{0}] after {1}s" -f ((@($rule.WatchCloseProcesses)) -join ','), $wa) -ForegroundColor DarkGray
        }

        $pre  = Get-PlannedHookInfo -App $a -Stage 'Pre'
        $post = Get-PlannedHookInfo -App $a -Stage 'Post'
        Write-Host ('   {0}' -f $pre.Text)  -ForegroundColor DarkGray
        Write-Host ('   {0}' -f $post.Text) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Info ("Default MSI mode: {0} (override per rule with MsiMode)" -f $DefaultMsiMode)
    Write-Info ("Pre-install : Local={0} Remote={1} (Remote default OFF)" -f $EnableLocalPreInstall, $EnableRemotePreInstall)
    Write-Info ("Post-install: Local={0} Remote={1} (Remote default OFF)" -f $EnableLocalPostInstall, $EnableRemotePostInstall)

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

        $row = [pscustomobject]@{
            Name=$app.Name; Status='Pending'; ExitCode=$null

            PayloadPath=''; InstallerLog=''; MsiMode=''

            PreStatus='';  PreExitCode=$null;  PreOrigin='';  PreScript='';  PreSource=''
            PostStatus=''; PostExitCode=$null; PostOrigin=''; PostScript=''; PostSource=''
        }

        if ($ConfirmEach) {
            $c = Read-Host ('Install {0}? (Y/N)' -f $app.Name)
            if ($c -notmatch '^[Yy]$') {
                Write-Warn ('Skipping {0}' -f $app.Name)
                Log-Line WARN ('Skipped={0}' -f $app.Name)
                $row.Status = 'Skipped'
                $results += $row
                continue
            }
        }

        # Pre-install hook
        $preOk = $true
        try {
            $preOk = Run-PreInstallIfAvailable -App $app -RowRef ([ref]$row)
        } catch {
            $preOk = $false
            Write-Bad ('Pre-install stage error for {0}: {1}' -f $app.Name, $_.Exception.Message)
            Log-Line ERROR ('PreInstallException={0} {1}' -f $app.Name, $_.Exception.Message)
            $row.PreStatus = 'Error'
        }

        if (-not $preOk -and -not $ContinueOnPreFail) {
            Write-Bad ('Pre-install failed for {0}. Skipping installer (use -ContinueOnPreFail to override).' -f $app.Name)
            Log-Line WARN ('PreFailedSkipInstall={0}' -f $app.Name)
            $row.Status = 'PreFailed'
            $results += $row
            continue
        }

        # Install (MSI hardened + MSI mode)
        $run = Get-InstallRunSpec -App $app
        $row.PayloadPath  = $run.PayloadPath
        $row.InstallerLog = $run.LogPath
        $row.MsiMode      = $run.MsiMode

        $cmdArgs = Format-ArgsForLog $run.Args

        Write-Info ('Installing: {0}' -f $app.Name)
        if ($app.Extension -eq '.msi') {
            Write-Info ("MSI mode: {0}" -f $run.MsiMode)
        } elseif ($run.WatchCloseProcesses -and $run.WatchCloseProcesses.Count -gt 0 -and $run.WatchCloseAfterSeconds -gt 0) {
            Write-Info ("Watchdog: will close/kill [{0}] after {1}s" -f (($run.WatchCloseProcesses) -join ','), $run.WatchCloseAfterSeconds)
        }

        Log-Line INFO ('InstallStart={0}' -f $app.FullName)
        Log-Line INFO ('Command={0} {1}' -f $run.File, $cmdArgs)
        if ($row.InstallerLog) { Log-Line INFO ("MsiLog={0}" -f $row.InstallerLog) }
        if ($app.Extension -eq '.exe' -and $run.WatchCloseProcesses -and $run.WatchCloseProcesses.Count -gt 0 -and $run.WatchCloseAfterSeconds -gt 0) {
            Log-Line INFO ("Watchdog CloseAfter={0}s IncludeExisting={1} Targets={2}" -f $run.WatchCloseAfterSeconds, $run.WatchCloseIncludeExisting, (($run.WatchCloseProcesses) -join ','))
        }

        try {
            $p = Start-ProcessWaitWithWatchdog `
                -FilePath $run.File `
                -Args $run.Args `
                -WatchCloseProcesses $run.WatchCloseProcesses `
                -WatchCloseAfterSeconds $run.WatchCloseAfterSeconds `
                -WatchCloseIncludeExisting $run.WatchCloseIncludeExisting

            $code = $p.ExitCode
            $row.ExitCode = $code

            $successCodes = @(0,3010,1641)
            $isOk = $successCodes -contains [int]$code

            if ($isOk) {
                Write-Good ('Success: {0} (ExitCode={1})' -f $app.Name, $code)
                Log-Line OK ('InstallOK={0} ExitCode={1}' -f $app.Name, $code)
                $row.Status = 'OK'
            } else {
                Write-Bad ('Failed: {0} (ExitCode={1})' -f $app.Name, $code)
                Log-Line ERROR ('InstallFail={0} ExitCode={1}' -f $app.Name, $code)
                if ($row.InstallerLog) {
                    Write-Warn ("MSI log (if applicable): {0}" -f $row.InstallerLog)
                }
                $row.Status = 'Failed'
            }

            Run-PostInstallIfEligible -App $app -InstallerExitCode $code -RowRef ([ref]$row)
        }
        catch {
            Write-Bad ('Error installing {0}: {1}' -f $app.Name, $_.Exception.Message)
            Log-Line ERROR ('InstallException={0} {1}' -f $app.Name, $_.Exception.Message)
            $row.Status = 'Error'

            if ($RunPostOnFail) {
                try { Run-PostInstallIfEligible -App $app -InstallerExitCode 9999 -RowRef ([ref]$row) } catch {}
            }
        }

        $results += $row
    }

    Write-Progress -Activity 'Installing applications' -Completed

    Write-Host ''
    Write-Header 'Summary'
    $results | Format-Table Name, Status, ExitCode, MsiMode, PreStatus, PreExitCode, PreOrigin, PreScript, PostStatus, PostExitCode, PostOrigin, PostScript -AutoSize

    Write-Host ''
    Write-Host ('All done. Transcript: {0}' -f $global:LogFile) -ForegroundColor Cyan
    Write-Host ('Meta log   : {0}' -f $global:MetaLog) -ForegroundColor Cyan
    Write-Host ('MSI logs   : {0}' -f (Join-Path $env:TEMP 'rhshourav\WindowsScripts\MsiLogs')) -ForegroundColor Cyan
}

# ---------------------------
# Main
# ---------------------------
Ensure-Admin
Write-Header 'Auto App Installer V3.0.3 (CLI only) (by rhshourav)'
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
