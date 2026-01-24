#requires -version 5.1
<#
.SYNOPSIS
  Auto App Installer – CLI Only – v1.3.2 (by rhshourav)

.DESCRIPTION
  - Auto-elevates to Admin (PowerShell 5.1 safe, uses -EncodedCommand)
  - CLI "GUI-style" UX (colors, headers, progress bars)
  - Network locations (UNC)
  - Lists .exe & .msi (RECURSIVE scan for ALL sources)
  - CLI selection (numbers/ranges/all/filter)
  - Explicit user permission before install
  - Sequential execution (waits each installer) + exit code capture
  - Robust logging (Transcript + meta log)
  - Graceful fallback after 30s with progress bar (NO IEX)
  - Windows 10 / 11 compatible, PowerShell 5.1+
  - INSTALL LOGIC: same as original (MSI silent via msiexec /qn, EXE default /S)
#>

[CmdletBinding()]
param(
    [switch]$ConfirmEach = $false,
    [string]$LocalFallbackDir = "$PSScriptRoot\Installers",
    [string]$FrameworkUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/auto.ps1'
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
        @{ Label='Production PC (18.201)';     Path='\\192.168.18.201\it\PC Setup\Production pc';      Recurse=$true },
        @{ Label='Production PC (19.44)';      Path='\\192.168.19.44\it\PC Setup\Production pc';       Recurse=$true },
        @{ Label='Staff PC (19.44)';           Path='\\192.168.19.44\it\PC Setup\Staff pc';            Recurse=$true }
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
# CLI selection
# ---------------------------
function Show-AppsTable {
    param([System.IO.FileInfo[]]$Apps)

    $Apps = @($Apps)

    Write-Host ''
    Write-Header 'Available Installers'
    for ($i=0; $i -lt $Apps.Count; $i++) {
        $n = $i + 1
        $name = $Apps[$i].Name
        $type = $Apps[$i].Extension
        $size = [math]::Round($Apps[$i].Length / 1MB, 2)
        Write-Host ('[{0}] {1}  ({2}, {3} MB)' -f $n, $name, $type, $size) -ForegroundColor Cyan
    }
    Write-Host ''
    Write-Host 'Commands:' -ForegroundColor Yellow
    Write-Host '  all            -> select all' -ForegroundColor Yellow
    Write-Host '  none           -> select none' -ForegroundColor Yellow
    Write-Host '  1,3,5          -> select by numbers' -ForegroundColor Yellow
    Write-Host '  1-4,8,10-12    -> ranges supported' -ForegroundColor Yellow
    Write-Host '  filter <text>  -> show only matching names (does not auto-select)' -ForegroundColor Yellow
    Write-Host '  show           -> show full list again' -ForegroundColor Yellow
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

    $arr = [int[]]$picked
    Write-Output -NoEnumerate $arr
}

function Select-AppsCli {
    param([System.IO.FileInfo[]]$Apps)

    $Apps = @($Apps)
    if ($Apps.Count -eq 0) { return @() }

    Show-AppsTable -Apps $Apps
    $selected = New-Object System.Collections.Generic.HashSet[int]

    while ($true) {
        $raw = Read-Host 'Select (type a command)'
        if (-not $raw) { continue }

        if ($raw -match '^(done|DONE)$') { break }

        if ($raw -match '^(show|SHOW)$') {
            Show-AppsTable -Apps $Apps
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
                    Write-Host ('[{0}] {1}' -f $n, $Apps[$i].Name) -ForegroundColor Cyan
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

    $final = foreach ($n in ($selected | Sort-Object)) { $Apps[$n - 1] }
    return ,$final
}

# ---------------------------
# Install execution (ORIGINAL LOGIC)
# ---------------------------
function Get-InstallSpec {
    param([System.IO.FileInfo]$App)

    $knownExeArgs = @{
        # 'ChromeSetup.exe' = '/silent /install'
        # '7z.exe'          = '/S'
    }

    if ($App.Extension -eq '.msi') {
        return @{ File='msiexec.exe'; Args=('/i "{0}" /qn /norestart' -f $App.FullName) }
    }

    if ($knownExeArgs.ContainsKey($App.Name)) {
        return @{ File=$App.FullName; Args=$knownExeArgs[$App.Name] }
    }

    return @{ File=$App.FullName; Args='/S' }
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
    $Selection | Sort-Object Name | ForEach-Object { Write-Host (' - {0}' -f $_.Name) -ForegroundColor Green }

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
                $results += [pscustomobject]@{ Name=$app.Name; Status='Skipped'; ExitCode=$null }
                continue
            }
        }

        $spec = Get-InstallSpec -App $app
        Write-Info ('Installing: {0}' -f $app.Name)
        Log-Line INFO ('InstallStart={0}' -f $app.FullName)
        Log-Line INFO ('Command={0} {1}' -f $spec.File, $spec.Args)

        try {
            if ([string]::IsNullOrWhiteSpace($spec.Args)) {
                $p = Start-Process -FilePath $spec.File -Wait -PassThru
            } else {
                $p = Start-Process -FilePath $spec.File -ArgumentList $spec.Args -Wait -PassThru -WindowStyle Hidden
            }

            $code = $p.ExitCode

            if ($code -eq 0) {
                Write-Good ('Success: {0} (ExitCode=0)' -f $app.Name)
                Log-Line OK ('InstallOK={0} ExitCode=0' -f $app.Name)
                $results += [pscustomobject]@{ Name=$app.Name; Status='OK'; ExitCode=0 }
            } else {
                Write-Bad ('Failed: {0} (ExitCode={1})' -f $app.Name, $code)
                Log-Line ERROR ('InstallFail={0} ExitCode={1}' -f $app.Name, $code)
                $results += [pscustomobject]@{ Name=$app.Name; Status='Failed'; ExitCode=$code }
            }
        } catch {
            Write-Bad ('Error installing {0}: {1}' -f $app.Name, $_.Exception.Message)
            Log-Line ERROR ('InstallException={0} {1}' -f $app.Name, $_.Exception.Message)
            $results += [pscustomobject]@{ Name=$app.Name; Status='Error'; ExitCode=$null }
        }
    }

    Write-Progress -Activity 'Installing applications' -Completed

    Write-Host ''
    Write-Header 'Summary'
    $results | Format-Table -AutoSize

    Write-Host ''
    Write-Host ('All done. Transcript: {0}' -f $global:LogFile) -ForegroundColor Cyan
    Write-Host ('Meta log   : {0}' -f $global:MetaLog) -ForegroundColor Cyan
}

# ---------------------------
# Main
# ---------------------------
Ensure-Admin
Write-Header 'Auto App Installer v1.3.2 (CLI only) (by rhshourav)'
New-Log

try {
    Self-Check

    $src = Resolve-InstallBasePath
    if (-not $src) { throw 'No installation source available.' }

    Write-Good ('Using installation folder: {0}' -f $src.Path)
    Write-Info 'Recursive scan enabled (subfolders will be scanned).'

    $apps = @(Get-Installers -BasePath $src.Path -Recurse:$src.Recurse)
    if ($apps.Count -eq 0) {
        Write-Warn ('No .exe or .msi files found in: {0}' -f $src.Path)
        Log-Line WARN ('NoInstallersFound={0} Recurse={1}' -f $src.Path, $src.Recurse)
        exit
    }

    $selection = Select-AppsCli -Apps $apps
    Install-Apps -Selection $selection
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
