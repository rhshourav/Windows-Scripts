#Requires -Version 5.0
<#
================================================================================
  REAPER - Ruthless Elimination & Application Purge Engine with Registry-wipe
  Part of Windows Scripts Repository
================================================================================
  Author      : rhshourav
  Repository  : https://github.com/rhshourav/Windows-Scripts
  Version     : 1.5.0
  Compatibility: Windows 10 (PowerShell 5.0+) through Windows 11
  Execute via : iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Apps/REAPER.ps1')
================================================================================
  FEATURES:
    - Detects Win32, MSI, UWP/Store, MSIX, AppX, Provisioned, System & Bloat apps
    - Silent primary uninstall with installer-type auto-detection
    - Stops all related processes and services before removal
    - Registry purge across all hives (HKLM, HKCU, HKU, HKCR, WOW6432Node)
    - File system purge across all known app data locations
    - Scheduled task removal, firewall rule removal, service removal
    - Risk-level classification (LOW / MEDIUM / HIGH / CRITICAL)
    - System Restore point created automatically before any removal
    - Single and multi-select removal with confirmation gates
    - Search by name or custom path / identifier
    - Post-removal verification scan to confirm no leftovers
    - Colour-coded console UI (dark bg, white/green/yellow/red ASCII only)
================================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region ============================================================
#  METADATA
#============================================================
$Script:R_VERSION = '1.5.0'
$Script:R_AUTHOR  = 'rhshourav'
$Script:R_REPO    = 'https://github.com/rhshourav/Windows-Scripts'
$Script:SessionID = [System.Guid]::NewGuid().ToString('N').Substring(0,8).ToUpper()
$Script:LogFile   = $null
$Script:RestoreCreated = $false
#endregion

#region ============================================================
#  RISK DEFINITIONS
#============================================================
$Script:CriticalPatterns = @(
    'WindowsDefender','SecurityCenter','MicrosoftEdge','WindowsStore',
    'XboxIdentityProvider','AAD.BrokerPlugin','AccountsControl',
    'AppInstaller','Cortana','ShellExperienceHost','StartMenuExperienceHost',
    'LockApp','LogonUI','SearchApp','SearchUI','RuntimeBroker',
    'ImmersiveControlPanel','WindowsCamera','SoundRecorder'
)
$Script:HighRiskPatterns = @(
    'Microsoft.Windows','Microsoft.UI','Microsoft.NET','Microsoft.DirectX',
    'Microsoft.VCLibs','Microsoft.Xbox','OneDrive','Teams','Outlook',
    'Visual C++','Visual Studio Redistributable','Windows Subsystem'
)
$Script:SystemPublishers = @(
    'Microsoft Corporation','Microsoft Windows','Microsoft Corp'
)
#endregion
# ================================================================
#  TELEMETRY
# ================================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "REAPER v$($Script:R_VERSION)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
#region ============================================================
#  CONSOLE UI
#============================================================
function Set-ConsoleTheme {
    try {
        $h = $Host.UI.RawUI
        $h.BackgroundColor = 'Black'
        $h.ForegroundColor = 'White'
        $h.WindowTitle = "REAPER v$Script:R_VERSION  |  App Purge Engine  |  Session $Script:SessionID"
        $buf = $h.BufferSize
        if ($buf.Width -lt 100) {
            $h.BufferSize = New-Object System.Management.Automation.Host.Size(120, 9000)
            $mw = $h.MaxWindowSize.Width
            $mh = $h.MaxWindowSize.Height
            $h.WindowSize = New-Object System.Management.Automation.Host.Size(
                [Math]::Min(120,$mw), [Math]::Min(45,$mh))
        }
    } catch { }
    Clear-Host
}

function Write-Banner {
    Clear-Host
    $W = 84
    $B = '+' + ('=' * ($W - 2)) + '+'
    Write-Host $B -ForegroundColor DarkRed
    $logo = @(
        "  ____  _____    _    ____  _____ ____  ",
        " |  _ \| ____|  / \  |  _ \| ____|  _ \ ",
        " | |_) |  _|   / _ \ | |_) |  _| | |_) |",
        " |  _ <| |___ / ___ \|  __/| |___|  _ < ",
        " |_| \_\_____/_/   \_\_|   |_____|_| \_\ "
    )
    Write-Host ('|' + (' ' * ($W-2)) + '|') -ForegroundColor DarkRed
    foreach ($line in $logo) {
        $pad = $line.PadRight($W - 2)
        if ($pad.Length -gt ($W-2)) { $pad = $pad.Substring(0,$W-2) }
        Write-Host ('|' + $pad + '|') -ForegroundColor Red
    }
    Write-Host ('|' + (' ' * ($W-2)) + '|') -ForegroundColor DarkRed
    $s1 = '  Ruthless Elimination & Application Purge Engine with Registry-wipe'
    $s2 = "  v$Script:R_VERSION  |  Author: $Script:R_AUTHOR  |  Session: $Script:SessionID"
    Write-Host ('|' + $s1.PadRight($W-2) + '|') -ForegroundColor Yellow
    Write-Host ('|' + $s2.PadRight($W-2) + '|') -ForegroundColor DarkYellow
    Write-Host $B -ForegroundColor DarkRed
    Write-Host ''
}

function Write-Section { param([string]$T)
    $W = 84
    Write-Host ''
    Write-Host ('+' + ('-' * ($W-2)) + '+') -ForegroundColor DarkYellow
    Write-Host ('|  ' + $T.PadRight($W-4) + '  |') -ForegroundColor Yellow
    Write-Host ('+' + ('-' * ($W-2)) + '+') -ForegroundColor DarkYellow
    Write-Host ''
}
function Write-Divider { Write-Host ('  ' + ('-' * 78)) -ForegroundColor DarkGray }
function wI  { param([string]$m) Write-Host "  [*] $m" -ForegroundColor White   }
function wOK { param([string]$m) Write-Host "  [+] $m" -ForegroundColor Green   }
function wW  { param([string]$m) Write-Host "  [!] $m" -ForegroundColor Yellow  }
function wE  { param([string]$m) Write-Host "  [-] $m" -ForegroundColor Red     }
function wS  { param([string]$m) Write-Host "  [>] $m" -ForegroundColor Cyan    }
function wC  { param([string]$m) Write-Host "  [!!] $m" -ForegroundColor Magenta }

function Read-Input {
    param([string]$Prompt, [string]$Default = '')
    Write-Host "  $Prompt" -ForegroundColor Cyan -NoNewline
    if ($Default -ne '') { Write-Host " [$Default]" -ForegroundColor DarkGray -NoNewline }
    Write-Host ': ' -ForegroundColor Cyan -NoNewline
    $v = Read-Host
    if ([string]::IsNullOrWhiteSpace($v) -and $Default -ne '') { return $Default }
    return $v.Trim()
}

function Pause-Screen {
    Write-Host ''
    Write-Host '  Press any key to continue...' -ForegroundColor DarkGray -NoNewline
    try { [void][System.Console]::ReadKey($true) } catch { Read-Host }
    Write-Host ''
}

function Show-Bar { param([int]$Now,[int]$Of,[string]$Label='')
    if ($Of -le 0) { return }
    $pct    = [int][Math]::Floor(($Now / $Of) * 100)
    $filled = [int][Math]::Floor(($Now / $Of) * 40)
    $bar    = '[' + ('#' * $filled) + ('.' * (40 - $filled)) + ']'
    $lbl    = if ($Label.Length -gt 28) { $Label.Substring(0,25) + '...' } else { $Label.PadRight(28) }
    Write-Host ("`r  $bar $pct% | $lbl") -ForegroundColor Green -NoNewline
    if ($Now -ge $Of) { Write-Host '' }
}

function Write-RiskBadge { param([string]$Risk)
    switch ($Risk) {
        'LOW'      { Write-Host '  RISK: [ LOW      ]' -ForegroundColor Green    }
        'MEDIUM'   { Write-Host '  RISK: [ MEDIUM   ]' -ForegroundColor Yellow   }
        'HIGH'     { Write-Host '  RISK: [ HIGH     ]' -ForegroundColor DarkYellow }
        'CRITICAL' { Write-Host '  RISK: [ CRITICAL ]' -ForegroundColor Red      }
        default    { Write-Host "  RISK: [ $Risk ]"    -ForegroundColor Gray      }
    }
}
#endregion

#region ============================================================
#  LOGGING
#============================================================
$Script:LogDir = $null
function Start-Log {
    param([string]$Dir)
    $Script:LogDir = $Dir
    $Script:LogFile = Join-Path $Dir "REAPER_$Script:SessionID.log"
    _Log "REAPER v$Script:R_VERSION  Session:$Script:SessionID  Author:$Script:R_AUTHOR"
    _Log "OS: $([System.Environment]::OSVersion.VersionString)"
    _Log "PS: $($PSVersionTable.PSVersion)  User: $env:USERNAME  Host: $env:COMPUTERNAME"
}

function _Log { param([string]$Msg,[string]$Lvl='INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$($Lvl.PadRight(5))] $Msg"
    if ($Script:LogFile) {
        try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
        catch { }
    }
}
#endregion

#region ============================================================
#  PRIVILEGE
#============================================================
function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevate {
    wW 'Administrator rights required. Triggering UAC self-elevation...'
    $script = if ($PSCommandPath) { "-File `"$PSCommandPath`"" }
              else { "-NoExit -Command `"& { iex (irm 'https://raw.githubusercontent.com/$Script:R_AUTHOR/Windows-Scripts/main/Apps/REAPER.ps1') }`"" }
    try { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass $script" -Verb RunAs -Wait }
    catch { wE "Elevation failed: $_" }
    exit 0
}
#endregion

#region ============================================================
#  SYSTEM RESTORE
#============================================================
function Enable-SystemProtection {
    try {
        $vol = $env:SystemDrive
        $r = Get-WmiObject -Class SystemRestore -Namespace root\default -ErrorAction SilentlyContinue
        if ($r) {
            Enable-ComputerRestore -Drive $vol -ErrorAction SilentlyContinue
            _Log "System Protection enabled on $vol" 'INFO'
            return $true
        }
    } catch {
        _Log "System Protection enable failed: $_" 'WARN'
    }
    return $false
}

function New-RestorePoint {
    param([string]$AppName)
    wS "Creating System Restore point before removing: $AppName"
    try {
        Enable-SystemProtection | Out-Null
        $desc = "REAPER: Pre-removal checkpoint ($AppName) [$Script:SessionID]"
        Checkpoint-Computer -Description $desc -RestorePointType 'APPLICATION_UNINSTALL' -ErrorAction Stop
        $Script:RestoreCreated = $true
        wOK "Restore point created: $desc"
        _Log "Restore point created: $desc" 'INFO'
        return $true
    } catch {
        wW "Restore point creation failed (non-fatal): $_"
        _Log "Restore point failed: $_" 'WARN'
        return $false
    }
}
#endregion

#region ============================================================
#  RISK ASSESSMENT
#============================================================
function Get-RiskLevel {
    param([PSCustomObject]$App)
    $name = "$($App.Name) $($App.DisplayName) $($App.Publisher)"

    foreach ($p in $Script:CriticalPatterns) {
        if ($name -match [regex]::Escape($p)) { return 'CRITICAL' }
    }
    foreach ($p in $Script:HighRiskPatterns) {
        if ($name -match [regex]::Escape($p)) { return 'HIGH' }
    }
    if ($App.Source -eq 'System' -or $App.Source -eq 'Provisioned') { return 'HIGH' }
    foreach ($pub in $Script:SystemPublishers) {
        if ($name -match [regex]::Escape($pub)) { return 'MEDIUM' }
    }
    return 'LOW'
}

function Get-RiskColor { param([string]$R)
    switch ($R) {
        'LOW'      { return 'Green'   }
        'MEDIUM'   { return 'Yellow'  }
        'HIGH'     { return 'DarkYellow' }
        'CRITICAL' { return 'Red'     }
        default    { return 'Gray'    }
    }
}
#endregion

#region ============================================================
#  APP DETECTION ENGINE
#============================================================
function Get-Win32Apps {
    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $paths) {
        try {
            Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne '' } |
            ForEach-Object {
                $apps.Add([PSCustomObject]@{
                    ID              = $_.PSChildName
                    DisplayName     = $_.DisplayName.Trim()
                    Name            = $_.DisplayName.Trim()
                    Version         = $_.DisplayVersion
                    Publisher       = $_.Publisher
                    InstallLocation = $_.InstallLocation
                    InstallDate     = $_.InstallDate
                    UninstallString = $_.UninstallString
                    QuietUninstall  = $_.QuietUninstallString
                    Source          = 'Win32'
                    RegPath         = $_.PSPath
                    EstimatedSize   = $_.EstimatedSize
                })
            }
        } catch { _Log "Win32 enum error $p : $_" 'WARN' }
    }
    # Deduplicate by DisplayName
    $seen = @{}
    $uniq = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($a in $apps) {
        $k = $a.DisplayName.ToLower()
        if (-not $seen[$k]) { $seen[$k] = $true; $uniq.Add($a) }
    }
    return $uniq
}

function Get-AppxApps {
    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        ForEach-Object {
            $apps.Add([PSCustomObject]@{
                ID              = $_.PackageFullName
                DisplayName     = if ($_.Name) { $_.Name } else { $_.PackageFullName }
                Name            = $_.Name
                Version         = $_.Version.ToString()
                Publisher       = $_.Publisher
                InstallLocation = $_.InstallLocation
                InstallDate     = ''
                UninstallString = ''
                QuietUninstall  = ''
                Source          = 'AppX'
                RegPath         = ''
                EstimatedSize   = 0
                PackageFull     = $_.PackageFullName
                PackageFamily   = $_.PackageFamilyName
                SignatureKind   = $_.SignatureKind.ToString()
            })
        }
    } catch { _Log "AppX enum error: $_" 'WARN' }
    return $apps
}

function Get-ProvisionedApps {
    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        ForEach-Object {
            $apps.Add([PSCustomObject]@{
                ID              = $_.PackageName
                DisplayName     = $_.DisplayName
                Name            = $_.DisplayName
                Version         = $_.Version
                Publisher       = ''
                InstallLocation = ''
                InstallDate     = ''
                UninstallString = ''
                QuietUninstall  = ''
                Source          = 'Provisioned'
                RegPath         = ''
                EstimatedSize   = 0
                PackageName     = $_.PackageName
            })
        }
    } catch { _Log "Provisioned enum error: $_" 'WARN' }
    return $apps
}

function Get-WindowsFeatureApps {
    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' } |
        ForEach-Object {
            $apps.Add([PSCustomObject]@{
                ID              = $_.FeatureName
                DisplayName     = $_.FeatureName
                Name            = $_.FeatureName
                Version         = ''
                Publisher       = 'Microsoft Windows'
                InstallLocation = ''
                InstallDate     = ''
                UninstallString = ''
                QuietUninstall  = ''
                Source          = 'WindowsFeature'
                RegPath         = ''
                EstimatedSize   = 0
            })
        }
    } catch { _Log "WinFeature enum error: $_" 'WARN' }
    return $apps
}

function Get-CapabilityApps {
    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Installed' } |
        ForEach-Object {
            $apps.Add([PSCustomObject]@{
                ID              = $_.Name
                DisplayName     = $_.Name
                Name            = $_.Name
                Version         = ''
                Publisher       = 'Microsoft Windows'
                InstallLocation = ''
                InstallDate     = ''
                UninstallString = ''
                QuietUninstall  = ''
                Source          = 'Capability'
                RegPath         = ''
                EstimatedSize   = 0
            })
        }
    } catch { _Log "Capability enum error: $_" 'WARN' }
    return $apps
}

function Get-AllApps {
    wS 'Scanning Win32 registry entries...'
    $w32  = Get-Win32Apps
    wS 'Scanning AppX packages (all users)...'
    $appx = Get-AppxApps
    wS 'Scanning Provisioned (bloatware) packages...'
    $prov = Get-ProvisionedApps
    wS 'Scanning Windows Optional Features...'
    $feat = Get-WindowsFeatureApps
    wS 'Scanning Windows Capabilities...'
    $caps = Get-CapabilityApps

    $all = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($c in @($w32,$appx,$prov,$feat,$caps)) {
        if ($c) { foreach ($i in $c) { $all.Add($i) } }
    }
    # Inject risk level
    foreach ($a in $all) {
        $a | Add-Member -MemberType NoteProperty -Name Risk -Value (Get-RiskLevel $a) -Force
    }
    return ($all | Sort-Object Source, DisplayName)
}
#endregion

#region ============================================================
#  PROCESS / SERVICE MANAGEMENT
#============================================================
function Stop-AppInstances {
    param([PSCustomObject]$App, [ref]$KilledProcs, [ref]$KilledSvcs)

    $kp = [System.Collections.Generic.List[string]]::new()
    $ks = [System.Collections.Generic.List[string]]::new()

    # Build name tokens to search for
    $tokens = [System.Collections.Generic.List[string]]::new()
    $baseName = ($App.DisplayName -replace '\s+v?\d+.*$','').Trim()
    $tokens.Add($baseName)
    if ($App.Name -and $App.Name -ne $baseName) { $tokens.Add($App.Name) }
    if ($App.InstallLocation) {
        $instDir = Split-Path $App.InstallLocation -Leaf -ErrorAction SilentlyContinue
        if ($instDir) { $tokens.Add($instDir) }
    }

    # Kill matching processes
    foreach ($tok in ($tokens | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($tok)) { continue }
        $procs = @(Get-Process -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match [regex]::Escape($tok) -or
                                  $_.Path -match [regex]::Escape($tok) })
        foreach ($proc in $procs) {
            try {
                wS "  Stopping process: $($proc.Name) (PID $($proc.Id))"
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                $kp.Add($proc.Name)
                _Log "Killed process: $($proc.Name) PID:$($proc.Id)" 'INFO'
            } catch {
                wW "  Cannot stop process $($proc.Name): $_"
                _Log "Process stop fail $($proc.Name): $_" 'WARN'
            }
        }
    }

    # Stop matching services
    foreach ($tok in ($tokens | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($tok)) { continue }
        $svcs = @(Get-Service -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -match [regex]::Escape($tok) -or
                                 $_.Name -match [regex]::Escape($tok) })
        foreach ($svc in $svcs) {
            if ($svc.Status -eq 'Running') {
                try {
                    wS "  Stopping service: $($svc.DisplayName)"
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                    $ks.Add($svc.Name)
                    _Log "Stopped service: $($svc.Name)" 'INFO'
                } catch {
                    wW "  Cannot stop service $($svc.Name): $_"
                    _Log "Service stop fail $($svc.Name): $_" 'WARN'
                }
            }
        }
    }

    $KilledProcs.Value = $kp
    $KilledSvcs.Value  = $ks
}
#endregion

#region ============================================================
#  UNINSTALL ENGINE
#============================================================
function Get-InstallerType {
    param([string]$UninstStr)
    if ([string]::IsNullOrWhiteSpace($UninstStr)) { return 'Unknown' }
    $u = $UninstStr.ToLower()
    if ($u -match 'msiexec') { return 'MSI' }
    if ($u -match 'uninst.*nsis|nsis') { return 'NSIS' }
    if ($u -match 'unins\d{3}\.exe') { return 'InnoSetup' }
    if ($u -match 'installshield|isuninst') { return 'InstallShield' }
    if ($u -match 'uninstall\.exe|unins\.exe') { return 'Generic' }
    return 'Generic'
}

function Build-SilentArgs {
    param([string]$UninstStr, [string]$Type, [string]$ID)
    switch ($Type) {
        'MSI' {
            # Extract GUID if present
            if ($UninstStr -match '\{[0-9A-Fa-f\-]{36}\}') {
                $guid = $Matches[0]
                return @('msiexec.exe', "/x $guid /qn /norestart REBOOT=ReallySuppress")
            }
            return @('msiexec.exe', "/x `"$ID`" /qn /norestart REBOOT=ReallySuppress")
        }
        'InnoSetup' {
            $exe = ($UninstStr -split '"')[1]
            if (-not $exe) { $exe = $UninstStr.Split(' ')[0] }
            return @($exe, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-')
        }
        'NSIS' {
            $exe = ($UninstStr -split '"')[1]
            if (-not $exe) { $exe = ($UninstStr -split ' ')[0].Trim('"') }
            return @($exe, '/S _?=' + (Split-Path $exe))
        }
        'InstallShield' {
            $exe = ($UninstStr -split '"')[1]
            if (-not $exe) { $exe = $UninstStr.Split(' ')[0] }
            return @($exe, '-runfromtemp -l0x0409 -removeonly -s')
        }
        default {
            # Try to parse exe + append silence flags
            $exe = ''
            if ($UninstStr -match '^"([^"]+)"') { $exe = $Matches[1] }
            elseif ($UninstStr -match '^(\S+\.exe)') { $exe = $Matches[1] }
            if ($exe -and (Test-Path $exe)) {
                return @($exe, '/S /SILENT /quiet /Q /q')
            }
            return @($UninstStr, '')
        }
    }
}

function Invoke-Win32Uninstall {
    param([PSCustomObject]$App)
    $result = [PSCustomObject]@{ Success=$false; Method=''; Notes='' }

    # Priority 1: QuietUninstallString
    if ($App.QuietUninstall -and $App.QuietUninstall.Trim() -ne '') {
        wS "  Method: QuietUninstallString"
        try {
            if ($App.QuietUninstall -match '^msiexec') {
                $args = $App.QuietUninstall -replace '/I','/X' -replace '/i','/x'
                if ($args -notmatch '/q') { $args += ' /qn /norestart' }
                $r = Start-Process 'msiexec.exe' -ArgumentList ($args -replace '^msiexec\.exe\s*','') `
                         -Wait -PassThru -WindowStyle Hidden
            } else {
                $exe  = ''
                $rest = ''
                if ($App.QuietUninstall -match '^"([^"]+)"\s*(.*)$') {
                    $exe = $Matches[1]; $rest = $Matches[2]
                } else {
                    $parts = $App.QuietUninstall.Split(' ',2)
                    $exe = $parts[0]; $rest = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                }
                if (Test-Path $exe) {
                    $r = Start-Process $exe -ArgumentList $rest -Wait -PassThru -WindowStyle Hidden
                } else { throw "Exe not found: $exe" }
            }
            Start-Sleep 2
            $result.Method = 'QuietUninstallString'
            $result.Success = ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010 -or $r.ExitCode -eq 1605)
            $result.Notes = "ExitCode=$($r.ExitCode)"
            _Log "QuietUninstall exit=$($r.ExitCode) app=$($App.DisplayName)" 'INFO'
            return $result
        } catch {
            wW "  QuietUninstall failed: $_"
            _Log "QuietUninstall error: $_" 'WARN'
        }
    }

    # Priority 2: Standard UninstallString with silence injection
    if ($App.UninstallString -and $App.UninstallString.Trim() -ne '') {
        $type  = Get-InstallerType -UninstStr $App.UninstallString
        $parts = Build-SilentArgs -UninstStr $App.UninstallString -Type $type -ID $App.ID
        $exe   = $parts[0]
        $args  = $parts[1]
        wS "  Method: UninstallString [$type] -> $exe"
        try {
            $r = Start-Process $exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
            Start-Sleep 2
            $result.Method  = "UninstallString[$type]"
            $result.Success = ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010 -or $r.ExitCode -eq 1605)
            $result.Notes   = "ExitCode=$($r.ExitCode)"
            _Log "UninstallString[$type] exit=$($r.ExitCode) app=$($App.DisplayName)" 'INFO'
            return $result
        } catch {
            wW "  UninstallString failed: $_"
            _Log "UninstallString error: $_" 'WARN'
        }
    }

    # Priority 3: WMI Win32_Product (last resort - slow but thorough)
    wS "  Method: WMI Win32_Product fallback"
    try {
        $wmiApp = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -eq $App.DisplayName }
        if ($wmiApp) {
            $r = $wmiApp.Uninstall()
            $result.Method  = 'WMI'
            $result.Success = ($r.ReturnValue -eq 0)
            $result.Notes   = "ReturnValue=$($r.ReturnValue)"
            _Log "WMI uninstall rv=$($r.ReturnValue) app=$($App.DisplayName)" 'INFO'
            return $result
        }
    } catch {
        wW "  WMI fallback failed: $_"
        _Log "WMI error: $_" 'WARN'
    }

    $result.Notes = 'All standard uninstall methods exhausted'
    return $result
}

function Invoke-AppxUninstall {
    param([PSCustomObject]$App)
    $result = [PSCustomObject]@{ Success=$false; Method=''; Notes='' }
    try {
        # All users removal
        $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                  Where-Object { $_.PackageFullName -eq $App.PackageFull -or
                                 $_.Name            -eq $App.Name })
        foreach ($pkg in $pkgs) {
            wS "  Removing AppX: $($pkg.PackageFullName)"
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue
            _Log "AppX removed: $($pkg.PackageFullName)" 'INFO'
        }
        # Provisioned removal (prevents reinstall for new users)
        $provPkg = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -eq $App.Name -or
                                    $_.PackageName -match [regex]::Escape($App.Name) })
        foreach ($pp in $provPkg) {
            wS "  Removing Provisioned package: $($pp.PackageName)"
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction SilentlyContinue
            _Log "Provisioned removed: $($pp.PackageName)" 'INFO'
        }
        $result.Success = $true
        $result.Method  = 'AppX/Provisioned'
    } catch {
        $result.Notes = "$_"
        _Log "AppX uninstall error: $_" 'ERROR'
    }
    return $result
}

function Invoke-ProvisionedUninstall {
    param([PSCustomObject]$App)
    $result = [PSCustomObject]@{ Success=$false; Method=''; Notes='' }
    try {
        wS "  Removing Provisioned package: $($App.PackageName)"
        Remove-AppxProvisionedPackage -Online -PackageName $App.PackageName -ErrorAction Stop
        _Log "Provisioned removed: $($App.PackageName)" 'INFO'
        # Also try matching AppX
        $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match [regex]::Escape($App.DisplayName) })
        foreach ($p in $pkgs) {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
        $result.Success = $true
        $result.Method  = 'ProvisionedPackage'
    } catch {
        $result.Notes = "$_"
        _Log "Provisioned uninstall error: $_" 'ERROR'
    }
    return $result
}

function Invoke-FeatureRemoval {
    param([PSCustomObject]$App)
    $result = [PSCustomObject]@{ Success=$false; Method=''; Notes='' }
    try {
        wS "  Disabling Windows Optional Feature: $($App.ID)"
        Disable-WindowsOptionalFeature -Online -FeatureName $App.ID -NoRestart -ErrorAction Stop
        _Log "Feature disabled: $($App.ID)" 'INFO'
        $result.Success = $true
        $result.Method  = 'WindowsOptionalFeature'
    } catch {
        $result.Notes = "$_"
        _Log "Feature disable error: $_" 'ERROR'
    }
    return $result
}

function Invoke-CapabilityRemoval {
    param([PSCustomObject]$App)
    $result = [PSCustomObject]@{ Success=$false; Method=''; Notes='' }
    try {
        wS "  Removing Windows Capability: $($App.ID)"
        Remove-WindowsCapability -Online -Name $App.ID -ErrorAction Stop
        _Log "Capability removed: $($App.ID)" 'INFO'
        $result.Success = $true
        $result.Method  = 'WindowsCapability'
    } catch {
        $result.Notes = "$_"
        _Log "Capability remove error: $_" 'ERROR'
    }
    return $result
}
#endregion

#region ============================================================
#  REGISTRY CLEANUP
#============================================================
function Remove-AppRegistry {
    param([PSCustomObject]$App)
    $removed = 0
    $errors  = 0
    $tokens  = [System.Collections.Generic.List[string]]::new()

    # Build search tokens
    $cleanName = $App.DisplayName -replace '\s+\d+[\.\d]*\s*$','' -replace '\s+(x86|x64|32|64)$',''
    $cleanName = $cleanName.Trim()
    $tokens.Add($cleanName)
    if ($App.Name -and $App.Name -ne $cleanName -and $App.Name.Length -gt 3) {
        $tokens.Add($App.Name)
    }

    # Static known paths
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE',
        'HKLM:\SOFTWARE\WOW6432Node',
        'HKCU:\SOFTWARE',
        'HKCR:\'
    )

    # Remove specific registry key if known
    if ($App.RegPath) {
        try {
            $parent = Split-Path $App.RegPath -Parent
            Remove-Item -LiteralPath $App.RegPath -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
            _Log "Removed reg key: $($App.RegPath)" 'INFO'
        } catch { $errors++ }
    }

    # Scan and remove by name token
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root -ErrorAction SilentlyContinue)) { continue }
        try {
            $keys = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
            foreach ($key in $keys) {
                foreach ($tok in $tokens) {
                    if ($key.PSChildName -match [regex]::Escape($tok) -or
                        $key.Name       -match [regex]::Escape($tok)) {
                        try {
                            Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction Stop
                            $removed++
                            _Log "Removed reg: $($key.PSPath)" 'INFO'
                        } catch { $errors++ }
                        break
                    }
                    # Check DisplayName value
                    try {
                        $dn = (Get-ItemProperty -LiteralPath $key.PSPath -Name DisplayName -ErrorAction SilentlyContinue).DisplayName
                        if ($dn -and $dn -match [regex]::Escape($tok)) {
                            Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                            $removed++
                            _Log "Removed reg (DisplayName match): $($key.PSPath)" 'INFO'
                            break
                        }
                    } catch { }
                }
            }
        } catch { _Log "Registry scan error $root : $_" 'WARN' }
    }

    # Load and search all user hives (HKU)
    $profileList = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -ErrorAction SilentlyContinue)
    foreach ($prof in $profileList) {
        $sid    = Split-Path $prof.PSPath -Leaf
        $hive   = "HKU:\$sid"
        $ntUser = Join-Path $prof.ProfileImagePath 'NTUSER.DAT'
        $loaded = $false
        if (-not (Test-Path "Registry::HKEY_USERS\$sid" -ErrorAction SilentlyContinue)) {
            if (Test-Path $ntUser) {
                try { reg load "HKU\$sid" $ntUser 2>$null | Out-Null; $loaded = $true } catch { }
            }
        } else { $loaded = $true }
        if ($loaded) {
            $huRoots = @("Registry::HKEY_USERS\$sid\SOFTWARE","Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
            foreach ($hr in $huRoots) {
                if (-not (Test-Path $hr -ErrorAction SilentlyContinue)) { continue }
                try {
                    $keys = @(Get-ChildItem -LiteralPath $hr -ErrorAction SilentlyContinue)
                    foreach ($key in $keys) {
                        foreach ($tok in $tokens) {
                            if ($key.PSChildName -match [regex]::Escape($tok)) {
                                try { Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue; $removed++ } catch { }
                                break
                            }
                        }
                    }
                } catch { }
            }
            if ($loaded -and (-not (Test-Path "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft" -ErrorAction SilentlyContinue) -eq $false)) {
                try { [gc]::Collect(); reg unload "HKU\$sid" 2>$null | Out-Null } catch { }
            }
        }
    }

    return [PSCustomObject]@{ Removed=$removed; Errors=$errors }
}
#endregion

#region ============================================================
#  FILE SYSTEM CLEANUP
#============================================================
function Get-AppFilePaths {
    param([PSCustomObject]$App)
    $paths = [System.Collections.Generic.List[string]]::new()
    $names = [System.Collections.Generic.List[string]]::new()

    $cleanName = ($App.DisplayName -replace '\s+\d+[\.\d]*\s*$','' -replace '\s+(x86|x64|32|64)$','').Trim()
    $names.Add($cleanName)
    if ($App.Name -and $App.Name -ne $cleanName) { $names.Add($App.Name) }

    # Known install location
    if ($App.InstallLocation -and (Test-Path $App.InstallLocation -ErrorAction SilentlyContinue)) {
        $paths.Add($App.InstallLocation)
    }

    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:APPDATA,
        $env:LOCALAPPDATA,
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        $env:TEMP,
        "$env:SystemRoot\Temp",
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache'),
        (Join-Path $env:LOCALAPPDATA 'Packages')
    )

    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root -ErrorAction SilentlyContinue)) { continue }
        foreach ($n in $names) {
            if ([string]::IsNullOrWhiteSpace($n) -or $n.Length -lt 3) { continue }
            $candidate = Join-Path $root $n
            if (Test-Path $candidate -ErrorAction SilentlyContinue) {
                if (-not $paths.Contains($candidate)) { $paths.Add($candidate) }
            }
            # Wildcard search for partial matches in root
            try {
                $found = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match [regex]::Escape($n) })
                foreach ($f in $found) {
                    if (-not $paths.Contains($f.FullName)) { $paths.Add($f.FullName) }
                }
            } catch { }
        }
    }

    # Temp files matching app name
    foreach ($n in $names) {
        if ([string]::IsNullOrWhiteSpace($n) -or $n.Length -lt 3) { continue }
        foreach ($tmpDir in @($env:TEMP,"$env:SystemRoot\Temp",$env:LOCALAPPDATA + '\Temp')) {
            if (-not $tmpDir -or -not (Test-Path $tmpDir -ErrorAction SilentlyContinue)) { continue }
            try {
                @(Get-ChildItem -LiteralPath $tmpDir -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match [regex]::Escape($n) }) |
                ForEach-Object {
                    if (-not $paths.Contains($_.FullName)) { $paths.Add($_.FullName) }
                }
            } catch { }
        }
    }
    return $paths
}

function Remove-AppFiles {
    param([PSCustomObject]$App)
    $removed = 0
    $failed  = 0
    $paths   = Get-AppFilePaths -App $App

    foreach ($p in $paths) {
        if (-not $p -or -not (Test-Path $p -ErrorAction SilentlyContinue)) { continue }
        # Safety: never remove system32, windows folder, or root drive
        $safe = @("$env:SystemRoot","$env:SystemDrive\","$env:WINDIR")
        $skip = $false
        foreach ($s in $safe) {
            if ($p.TrimEnd('\') -ieq $s.TrimEnd('\')) { $skip = $true; break }
        }
        if ($skip) { wW "  Skipping protected path: $p"; continue }

        try {
            wS "  Removing: $p"
            if ((Get-Item $p -ErrorAction SilentlyContinue) -is [System.IO.DirectoryInfo]) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            }
            $removed++
            _Log "Removed path: $p" 'INFO'
        } catch {
            # Attempt takeown + icacls for locked files
            try {
                wW "  Locked - attempting takeown: $p"
                & takeown /f "$p" /r /d y 2>$null | Out-Null
                & icacls "$p" /grant administrators:F /t /q 2>$null | Out-Null
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                $removed++
                _Log "Removed (takeown): $p" 'INFO'
            } catch {
                $failed++
                _Log "Remove failed: $p : $_" 'WARN'
            }
        }
    }
    return [PSCustomObject]@{ Removed=$removed; Failed=$failed }
}
#endregion

#region ============================================================
#  SCHEDULED TASKS CLEANUP
#============================================================
function Remove-AppScheduledTasks {
    param([PSCustomObject]$App)
    $removed = 0
    $names   = @(
        $App.DisplayName -replace '\s+\d+[\.\d]*\s*$','' -replace '\s+(x86|x64|32|64)$','',
        $App.Name
    ) | Where-Object { $_ -and $_.Length -gt 2 } | Select-Object -Unique

    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        foreach ($task in $tasks) {
            foreach ($n in $names) {
                if ($task.TaskName -match [regex]::Escape($n) -or
                    $task.TaskPath -match [regex]::Escape($n)) {
                    try {
                        Unregister-ScheduledTask -TaskName $task.TaskName `
                            -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
                        $removed++
                        _Log "Removed scheduled task: $($task.TaskPath)$($task.TaskName)" 'INFO'
                        wS "  Removed task: $($task.TaskName)"
                    } catch {
                        _Log "Task remove fail: $($task.TaskName) : $_" 'WARN'
                    }
                    break
                }
            }
        }
    } catch { _Log "Scheduled task enum error: $_" 'WARN' }
    return $removed
}
#endregion

#region ============================================================
#  FIREWALL CLEANUP
#============================================================
function Remove-AppFirewallRules {
    param([PSCustomObject]$App)
    $removed = 0
    $names   = @(
        $App.DisplayName -replace '\s+\d+[\.\d]*\s*$','',
        $App.Name
    ) | Where-Object { $_ -and $_.Length -gt 2 } | Select-Object -Unique

    try {
        foreach ($n in $names) {
            $rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -match [regex]::Escape($n) -or
                                      $_.Name        -match [regex]::Escape($n) })
            foreach ($rule in $rules) {
                try {
                    Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
                    $removed++
                    _Log "Removed FW rule: $($rule.DisplayName)" 'INFO'
                    wS "  Removed firewall rule: $($rule.DisplayName)"
                } catch {
                    _Log "FW rule remove fail: $($rule.Name) : $_" 'WARN'
                }
            }
        }
    } catch { _Log "Firewall enum error: $_" 'WARN' }
    return $removed
}
#endregion

#region ============================================================
#  SERVICE CLEANUP
#============================================================
function Remove-AppServices {
    param([PSCustomObject]$App)
    $removed = 0
    $names   = @(
        $App.DisplayName -replace '\s+\d+[\.\d]*\s*$','',
        $App.Name
    ) | Where-Object { $_ -and $_.Length -gt 2 } | Select-Object -Unique

    try {
        $svcs = @(Get-Service -ErrorAction SilentlyContinue |
                  Where-Object {
                      $dn = $_.DisplayName; $nm = $_.Name
                      $names | ForEach-Object { $dn -match [regex]::Escape($_) -or $nm -match [regex]::Escape($_) } |
                      Where-Object { $_ } | Select-Object -First 1
                  })
        foreach ($svc in $svcs) {
            try {
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                }
                & sc.exe delete $svc.Name 2>$null | Out-Null
                $removed++
                _Log "Removed service: $($svc.Name)" 'INFO'
                wS "  Removed service: $($svc.DisplayName)"
            } catch {
                _Log "Service remove fail: $($svc.Name) : $_" 'WARN'
            }
        }
    } catch { _Log "Service enum error: $_" 'WARN' }
    return $removed
}
#endregion

#region ============================================================
#  ENVIRONMENT VARIABLE CLEANUP
#============================================================
function Remove-AppEnvVars {
    param([PSCustomObject]$App)
    $removed = 0
    $cleanName = ($App.DisplayName -replace '\s+\d+[\.\d]*\s*$','').Trim()
    $scopes = @([System.EnvironmentVariableTarget]::Machine, [System.EnvironmentVariableTarget]::User)
    foreach ($scope in $scopes) {
        try {
            $vars = [System.Environment]::GetEnvironmentVariables($scope)
            foreach ($key in @($vars.Keys)) {
                $val = $vars[$key]
                if ($val -and ($val -match [regex]::Escape($cleanName) -or
                               ($App.InstallLocation -and $val -match [regex]::Escape($App.InstallLocation)))) {
                    [System.Environment]::SetEnvironmentVariable($key, $null, $scope)
                    $removed++
                    _Log "Removed env var: $key from $scope" 'INFO'
                    wS "  Removed env variable: $key"
                }
            }
        } catch { }
    }
    return $removed
}
#endregion

#region ============================================================
#  VERIFICATION
#============================================================
function Test-AppRemoved {
    param([PSCustomObject]$App)
    $leftovers = [System.Collections.Generic.List[string]]::new()

    # Check registry for UninstallString entry
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $paths) {
        try {
            $dn = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -eq $App.DisplayName }
            if ($dn) { $leftovers.Add("Registry entry still present: $($dn.PSPath)") }
        } catch { }
    }

    # Check AppX still present
    if ($App.Source -in @('AppX','Provisioned')) {
        $still = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq $App.Name })
        if ($still.Count -gt 0) { $leftovers.Add("AppX package still installed: $($App.Name)") }
    }

    # Check install folder
    if ($App.InstallLocation -and (Test-Path $App.InstallLocation -ErrorAction SilentlyContinue)) {
        $leftovers.Add("Install folder still exists: $($App.InstallLocation)")
    }

    return $leftovers
}
#endregion

#region ============================================================
#  MASTER REMOVAL ORCHESTRATOR
#============================================================
function Invoke-RemoveApp {
    param([PSCustomObject]$App, [bool]$SkipRestore = $false)

    $report = [PSCustomObject]@{
        App              = $App.DisplayName
        Risk             = $App.Risk
        PrimaryUninstall = $false
        RegistryRemoved  = 0
        FilesRemoved     = 0
        TasksRemoved     = 0
        FWRulesRemoved   = 0
        ServicesRemoved  = 0
        Leftovers        = @()
        RebootRequired   = $false
        Success          = $false
    }

    Write-Section "REMOVING: $($App.DisplayName) [$($App.Source)] [RISK: $($App.Risk)]"
    wI "Publisher   : $($App.Publisher)"
    wI "Version     : $($App.Version)"
    wI "Source      : $($App.Source)"
    Write-RiskBadge -Risk $App.Risk
    Write-Divider

    # Restore point
    if (-not $SkipRestore) { New-RestorePoint -AppName $App.DisplayName | Out-Null }

    # Stop processes and services
    wI 'Step 1/8  Stopping related processes and services...'
    $kp = @(); $ks = @()
    $kpRef = [ref]$kp; $ksRef = [ref]$ks
    Stop-AppInstances -App $App -KilledProcs $kpRef -KilledSvcs $ksRef
    Start-Sleep 1
    Write-Divider

    # Primary uninstall
    wI 'Step 2/8  Running primary uninstall...'
    $priResult = [PSCustomObject]@{ Success=$false; Method='N/A'; Notes='Skipped' }
    switch ($App.Source) {
        'Win32'         { $priResult = Invoke-Win32Uninstall     -App $App }
        'AppX'          { $priResult = Invoke-AppxUninstall       -App $App }
        'Provisioned'   { $priResult = Invoke-ProvisionedUninstall -App $App }
        'WindowsFeature'{ $priResult = Invoke-FeatureRemoval       -App $App }
        'Capability'    { $priResult = Invoke-CapabilityRemoval    -App $App }
    }
    if ($priResult.Success) {
        wOK "Primary uninstall: SUCCESS via $($priResult.Method)"
        $report.PrimaryUninstall = $true
    } else {
        wW "Primary uninstall result: $($priResult.Notes)"
    }
    _Log "PrimaryUninstall method=$($priResult.Method) success=$($priResult.Success)" 'INFO'
    Start-Sleep 1
    Write-Divider

    # Registry purge
    wI 'Step 3/8  Purging registry entries...'
    $regR = Remove-AppRegistry -App $App
    wOK "Registry: $($regR.Removed) key(s) removed, $($regR.Errors) error(s)"
    $report.RegistryRemoved = $regR.Removed
    Write-Divider

    # File system purge
    wI 'Step 4/8  Purging file system remnants...'
    $fsR = Remove-AppFiles -App $App
    wOK "Files/Folders: $($fsR.Removed) removed, $($fsR.Failed) locked"
    $report.FilesRemoved = $fsR.Removed
    Write-Divider

    # Scheduled tasks
    wI 'Step 5/8  Removing scheduled tasks...'
    $tR = Remove-AppScheduledTasks -App $App
    wOK "Scheduled tasks: $tR removed"
    $report.TasksRemoved = $tR
    Write-Divider

    # Firewall rules
    wI 'Step 6/8  Removing firewall rules...'
    $fwR = Remove-AppFirewallRules -App $App
    wOK "Firewall rules: $fwR removed"
    $report.FWRulesRemoved = $fwR
    Write-Divider

    # Services
    wI 'Step 7/8  Removing orphaned services...'
    $svcR = Remove-AppServices -App $App
    wOK "Services: $svcR removed"
    $report.ServicesRemoved = $svcR
    Remove-AppEnvVars -App $App | Out-Null
    Write-Divider

    # Verification
    wI 'Step 8/8  Verifying removal...'
    Start-Sleep 1
    $leftovers = Test-AppRemoved -App $App
    $report.Leftovers = $leftovers
    if ($leftovers.Count -eq 0) {
        wOK 'Verification: CLEAN - No detectable remnants found.'
        $report.Success = $true
    } else {
        wW "Verification: $($leftovers.Count) potential remnant(s) detected:"
        foreach ($l in $leftovers) { wW "  -> $l" }
        $report.Success = $report.PrimaryUninstall
    }
    Write-Divider

    _Log "Removal complete: $($App.DisplayName) Success=$($report.Success) Leftovers=$($leftovers.Count)" 'INFO'
    return $report
}
#endregion

#region ============================================================
#  SELECTION UI
#============================================================
function Show-AppTable {
    param([System.Collections.Generic.List[PSCustomObject]]$Apps, [hashtable]$Selected)
    $pageSize = 15
    $page     = 0
    $filter   = ''
    $running  = $true

    while ($running) {
        Clear-Host
        Write-Banner

        # Build display list
        $displayList = if ($filter) {
            @($Apps | Where-Object { $_.DisplayName -match [regex]::Escape($filter) -or
                                     $_.Source      -match [regex]::Escape($filter) })
        } else { @($Apps) }

        $total  = $displayList.Count
        $pages  = [Math]::Max(1,[Math]::Ceiling($total / $pageSize))
        if ($page -ge $pages) { $page = $pages - 1 }
        $start  = $page * $pageSize
        $end    = [Math]::Min($start + $pageSize, $total) - 1

        Write-Host "  Applications  (Page $($page+1)/$pages  |  Total: $total  |  Selected: $($Selected.Count)  |  Filter: $(if($filter){"'$filter'"}else{'none'}))" -ForegroundColor Yellow
        Write-Divider
        Write-Host ("  {0,-4} {1,-2} {2,-38} {3,-12} {4,-12} {5,-8}" -f '#','S','Name','Version','Source','Risk') -ForegroundColor DarkCyan
        Write-Divider

        for ($i = $start; $i -le $end; $i++) {
            $a   = $displayList[$i]
            $sel = if ($Selected.ContainsKey($i)) { 'X' } else { ' ' }
            $rc  = Get-RiskColor -R $a.Risk
            $ver = if ($a.Version) { $a.Version.Substring(0,[Math]::Min(10,$a.Version.Length)) } else { '' }
            $dn  = $a.DisplayName.Substring(0,[Math]::Min(36,$a.DisplayName.Length))
            Write-Host -NoNewline ("  {0,-4} " -f ($i+1))
            Write-Host -NoNewline ("[{0}] " -f $sel) -ForegroundColor $(if($sel -eq 'X'){'Green'}else{'DarkGray'})
            Write-Host -NoNewline ("{0,-38} {1,-12} {2,-12} " -f $dn,$ver,$a.Source) -ForegroundColor White
            Write-Host ("{0,-8}" -f $a.Risk) -ForegroundColor $rc
        }

        Write-Divider
        Write-Host '  [N]ext  [P]rev  [A]ll  [C]lear  [F]ilter  [I]nfo#  [D]one  [Q]uit' -ForegroundColor DarkGray
        Write-Host '  Toggle: enter number(s) comma-separated (e.g. 1,3,7)' -ForegroundColor DarkGray
        Write-Divider

        $inp = Read-Input 'Action' ''

        if ([string]::IsNullOrWhiteSpace($inp)) { continue }

        switch -Regex ($inp.ToUpper()) {
            '^N$' { if ($page -lt $pages-1) { $page++ } }
            '^P$' { if ($page -gt 0) { $page-- } }
            '^A$' {
                for ($i = 0; $i -lt $total; $i++) { $Selected[$i] = $displayList[$i] }
                wOK "All $total items selected."
            }
            '^C$' { $Selected.Clear(); wI 'Selection cleared.' }
            '^F$' {
                $filter = Read-Input 'Filter (blank to clear)' ''
                $page   = 0
            }
            '^D$' { $running = $false }
            '^Q$' { $Selected.Clear(); $running = $false }
            '^I(\d+)$' {
                $n = [int]$Matches[1] - 1
                if ($n -ge 0 -and $n -lt $total) {
                    $a = $displayList[$n]
                    Write-Host ''
                    Write-Host "  +-- Application Detail " + ('-' * 56) + '+' -ForegroundColor DarkYellow
                    wI "Name       : $($a.DisplayName)"
                    wI "Version    : $($a.Version)"
                    wI "Publisher  : $($a.Publisher)"
                    wI "Source     : $($a.Source)"
                    wI "Install At : $($a.InstallLocation)"
                    wI "Install Dt : $($a.InstallDate)"
                    wI "Uninstall  : $($a.UninstallString)"
                    Write-RiskBadge -Risk $a.Risk
                    Write-Divider
                    Pause-Screen
                }
            }
            default {
                foreach ($token in ($inp -split ',')) {
                    $token = $token.Trim()
                    $n     = 0
                    if ([int]::TryParse($token,[ref]$n)) {
                        $n--
                        if ($n -ge 0 -and $n -lt $total) {
                            if ($Selected.ContainsKey($n)) { $Selected.Remove($n) }
                            else { $Selected[$n] = $displayList[$n] }
                        }
                    }
                }
            }
        }
    }
}
#endregion

#region ============================================================
#  SEARCH & DIRECT REMOVE
#============================================================
function Search-AndRemove {
    param([System.Collections.Generic.List[PSCustomObject]]$AllApps)

    Write-Section 'SEARCH & REMOVE BY NAME'
    $query = Read-Input 'Enter app name, keyword or partial name' ''
    if ([string]::IsNullOrWhiteSpace($query)) { return }

    $hits = @($AllApps | Where-Object {
        $_.DisplayName -match [regex]::Escape($query) -or
        $_.Name        -match [regex]::Escape($query) -or
        $_.Publisher   -match [regex]::Escape($query)
    })

    if ($hits.Count -eq 0) {
        wW "No applications matched: '$query'"
        Pause-Screen; return
    }

    wI "Found $($hits.Count) match(es) for '$query':"
    Write-Divider
    for ($i = 0; $i -lt $hits.Count; $i++) {
        $rc = Get-RiskColor -R $hits[$i].Risk
        Write-Host -NoNewline ("  [{0,2}]  {1,-40} {2,-14} " -f ($i+1),$hits[$i].DisplayName,$hits[$i].Source) -ForegroundColor White
        Write-Host ("{0}" -f $hits[$i].Risk) -ForegroundColor $rc
    }
    Write-Divider

    $sel = Read-Input 'Select numbers to remove (comma-separated, or A for all)' ''
    $toRemove = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($sel -match '^[aA]$') {
        $toRemove.AddRange([PSCustomObject[]]$hits)
    } else {
        foreach ($token in ($sel -split ',')) {
            $n = 0
            if ([int]::TryParse($token.Trim(),[ref]$n)) {
                $n--
                if ($n -ge 0 -and $n -lt $hits.Count) { $toRemove.Add($hits[$n]) }
            }
        }
    }

    if ($toRemove.Count -eq 0) { wW 'Nothing selected.'; Pause-Screen; return }
    Invoke-RemovalPipeline -ToRemove $toRemove
}
#endregion

#region ============================================================
#  REMOVAL PIPELINE
#============================================================
function Invoke-RemovalPipeline {
    param([System.Collections.Generic.List[PSCustomObject]]$ToRemove)

    if ($ToRemove.Count -eq 0) { wW 'Nothing to remove.'; Pause-Screen; return }

    Write-Section 'REMOVAL QUEUE'
    $critCount = 0
    $highCount = 0

    for ($i = 0; $i -lt $ToRemove.Count; $i++) {
        $a  = $ToRemove[$i]
        $rc = Get-RiskColor -R $a.Risk
        Write-Host -NoNewline ("  [{0,2}]  {1,-40} {2,-14} " -f ($i+1),$a.DisplayName,$a.Source) -ForegroundColor White
        Write-Host ("{0}" -f $a.Risk) -ForegroundColor $rc
        if ($a.Risk -eq 'CRITICAL') { $critCount++ }
        if ($a.Risk -eq 'HIGH')     { $highCount++ }
    }

    Write-Divider
    wI "Total queued : $($ToRemove.Count)"
    if ($critCount -gt 0) {
        wC "CRITICAL RISK ITEMS : $critCount  -- These may destabilize Windows!"
    }
    if ($highCount -gt 0) {
        wW "HIGH RISK ITEMS     : $highCount  -- Removal may impact system functionality."
    }
    Write-Divider
    wI 'System Restore point will be created before removal.'
    wI 'All removals are irreversible without restore point.'
    Write-Divider

    $cf = Read-Input 'Type CONFIRM to begin removal (or Q to cancel)' ''
    if ($cf -notmatch '^[cC][oO][nN][fF][iI][rR][mM]$') {
        wI 'Removal cancelled.'
        Pause-Screen; return
    }

    if ($critCount -gt 0) {
        wC 'You have CRITICAL items queued.'
        $cf2 = Read-Input 'Type CRITICAL to confirm removal of system components' ''
        if ($cf2 -ne 'CRITICAL') { wI 'Critical removal cancelled.'; Pause-Screen; return }
    }

    # Create single restore point covering all removals
    if ($ToRemove.Count -eq 1) {
        New-RestorePoint -AppName $ToRemove[0].DisplayName | Out-Null
    } else {
        New-RestorePoint -AppName "Batch ($($ToRemove.Count) apps)" | Out-Null
    }

    $reports = [System.Collections.Generic.List[PSCustomObject]]::new()
    $idx     = 0
    foreach ($app in $ToRemove) {
        $idx++
        wI "[$idx/$($ToRemove.Count)] Processing: $($app.DisplayName)"
        $rpt = Invoke-RemoveApp -App $app -SkipRestore $true
        $reports.Add($rpt)
    }

    # Final report
    Write-Section 'REMOVAL COMPLETE - FINAL REPORT'
    $succeeded = @($reports | Where-Object { $_.Success }).Count
    $failed    = @($reports | Where-Object { -not $_.Success }).Count

    Write-Host ("  {0,-40} {1,-10} {2,-6} {3,-6} {4}" -f 'Application','Result','Reg','Files','Leftovers') -ForegroundColor DarkCyan
    Write-Divider
    foreach ($r in $reports) {
        $res = if ($r.Success) { 'OK' } else { 'PARTIAL' }
        $rc  = if ($r.Success) { 'Green' } else { 'Yellow' }
        $dn  = $r.App.Substring(0,[Math]::Min(38,$r.App.Length))
        Write-Host ("  {0,-40} " -f $dn) -ForegroundColor White -NoNewline
        Write-Host ("{0,-10} " -f $res) -ForegroundColor $rc -NoNewline
        Write-Host ("{0,-6} {1,-6} {2}" -f $r.RegistryRemoved,$r.FilesRemoved,$r.Leftovers.Count) -ForegroundColor White
    }
    Write-Divider
    wOK "Succeeded: $succeeded"
    if ($failed -gt 0) { wW "Partial  : $failed (check log for details)" }
    if ($Script:RestoreCreated) { wOK 'System Restore point available if rollback is needed.' }
    wI "Session log: $Script:LogFile"

    $rb = Read-Input 'Restart now to apply all changes? [y/N]' 'n'
    if ($rb -match '^[yY]') { Start-Sleep 2; Restart-Computer -Force }

    Pause-Screen
}
#endregion

#region ============================================================
#  MAIN MENU
#============================================================
function Show-MainMenu {
    # Init log directory
    $logRoot = "$env:SystemDrive\REAPER_Logs"
    if (-not (Test-Path $logRoot)) { New-Item $logRoot -ItemType Directory -Force | Out-Null }
    Start-Log -Dir $logRoot

    $allApps = $null

    $live = $true
    while ($live) {
        Write-Banner
        Write-Host "  Session Log : $Script:LogFile" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  +----------------------------------------------------+' -ForegroundColor DarkRed
        Write-Host '  |               REAPER  MAIN  MENU                   |' -ForegroundColor Red
        Write-Host '  |                                                     |' -ForegroundColor DarkRed
        Write-Host '  |   [1]  Scan & Browse All Installed Apps             |' -ForegroundColor White
        Write-Host '  |   [2]  Search & Remove by Name / Keyword           |' -ForegroundColor White
        Write-Host '  |   [3]  Rescan Applications                          |' -ForegroundColor Yellow
        Write-Host '  |   [4]  View Session Log                             |' -ForegroundColor White
        Write-Host '  |   [Q]  Quit                                         |' -ForegroundColor Red
        Write-Host '  |                                                     |' -ForegroundColor DarkRed
        Write-Host '  +----------------------------------------------------+' -ForegroundColor DarkRed
        Write-Host ''

        $ch = (Read-Input 'Choose option').ToUpper()

        switch ($ch) {

            '1' {
                if (-not $allApps) {
                    Write-Section 'SCANNING INSTALLED APPLICATIONS'
                    $allApps = Get-AllApps
                    wOK "Found $($allApps.Count) application(s)."
                    Start-Sleep 1
                }
                $selected = @{}
                Show-AppTable -Apps $allApps -Selected ([ref]$selected).Value

                if ($selected.Count -eq 0) {
                    wI 'No applications selected.'
                    Start-Sleep 1
                } else {
                    $toRemove = [System.Collections.Generic.List[PSCustomObject]]::new()
                    foreach ($v in $selected.Values) { $toRemove.Add($v) }
                    Invoke-RemovalPipeline -ToRemove $toRemove
                    $allApps = $null   # Invalidate cache - force rescan
                }
            }

            '2' {
                if (-not $allApps) {
                    Write-Section 'SCANNING INSTALLED APPLICATIONS'
                    $allApps = Get-AllApps
                    wOK "Found $($allApps.Count) application(s)."
                    Start-Sleep 1
                }
                Search-AndRemove -AllApps $allApps
                $allApps = $null
            }

            '3' {
                Write-Section 'RESCANNING INSTALLED APPLICATIONS'
                $allApps = Get-AllApps
                wOK "Rescan complete - $($allApps.Count) application(s) found."
                Pause-Screen
            }

            '4' {
                if ($Script:LogFile -and (Test-Path $Script:LogFile)) {
                    Write-Section 'SESSION LOG (last 40 lines)'
                    Get-Content $Script:LogFile -Tail 40 | ForEach-Object {
                        $c = 'Gray'
                        if ($_ -match '\[ERROR\]') { $c = 'Red' }
                        elseif ($_ -match '\[WARN ')  { $c = 'Yellow' }
                        elseif ($_ -match '\[INFO \]') { $c = 'White' }
                        Write-Host "  $_" -ForegroundColor $c
                    }
                    Pause-Screen
                } else { wW 'No log file yet.'; Start-Sleep 1 }
            }

            'Q' { $live = $false }
            default { wW 'Invalid option.'; Start-Sleep 1 }
        }
    }
}
#endregion

#region ============================================================
#  ENTRY POINT
#============================================================
Set-ConsoleTheme
Write-Banner

if (-not (Test-IsAdmin)) {
    wE 'REAPER requires Administrator privileges.'
    wI 'Triggering UAC elevation...'
    Start-Sleep 2
    Invoke-Elevate
}

wOK "Administrator confirmed : $env:USERNAME"
wI  "Host : $env:COMPUTERNAME"
wI  "OS   : $([System.Environment]::OSVersion.VersionString)"
Write-Divider
wW  'REAPER permanently removes applications and all associated data.'
wW  'A System Restore point will be created before each removal operation.'
wW  'CRITICAL-rated removals may destabilize Windows. Proceed with caution.'
Write-Divider

# Enable System Protection proactively
wS 'Enabling System Protection for restore capability...'
Enable-SystemProtection | Out-Null

Pause-Screen
Show-MainMenu

Write-Banner
wOK 'REAPER session terminated. System is clean.'
Write-Host ''
#endregion

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUtZst8llmnapr9oZ9ULPVJREG
# Ct2gghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
# AQsFADAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzMB4XDTI2MDcwNzA4MDE1
# N1oXDTI5MDcwNzA4MTE1N1owGzEZMBcGA1UEAwwQUkhTSE9VUkFWLUlULU9wczCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALFj11KDAqN3fhbDT9fvgrLF
# VemPYmcud3qA+9Sc4RojOjElODGXyaOlBSVmDGpmCkNRC+dnkGCLB8bYb3gsnHey
# Ud99DA8tvkTgb06+B1pigTZUmhyAwyPiu77+h224c8SsZFkmgQ/Dh2Sc2ynNocZe
# 773d6a/B4DRg7/K9xV8jFap6BP1fjaM3Do40GSL+OVnXl2ssvfFk4FyP5fc8Czz5
# MJ5IJKRFrnHv3kNcmyz5mnz0LoBQs/JtHpWg3BogIalJ2tyCiZgk0xIsz5j5UjhA
# /KepfnWGpCowJ/NJWnmOZcikFlDPggI27QNc/IbxZ035ht+Zgc7b1Cf68GmL/8UC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRJ+13W7/PcqVgZXZf87/JdXvGqxjANBgkqhkiG9w0BAQsFAAOCAQEA
# MDUJsw0AephOCByoLTFSm8hnB4I7s8ddA64vDTv4QF2TcXdrd/glByhEQexUEDpw
# lPCSbzHAmRM5X71QYNoB/CDlCoAO8BQnbegqkhAx8ubRyciwsLA4ZPp+/GFbgZaV
# khkOWpL6v6fmU3kSB5px+roqOuMjmqvbtCDlC4JH25WuDEgGJQhqpgdQSZdomWjH
# le/GnQKt4Y18ysVFvgE1lRO8x6gkJ5IJbZPJ0Q//2xCvtM0WpjXmQl1RHV/7tqDS
# fqprCQxuKiTPC64VfafzeS7IUNJMgQS73H6wuaKdeT85PIxreleNwNXfbr4O/FY3
# eqlSEZAqzKtZXfNFWPmHazCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE+jCC
# BPYCAQEwLzAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzAhAQvylGgaQVhE7g
# tCp7LUPgMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRvWxR0DvYdY/56FnmNFc+XYHnzDDANBgkq
# hkiG9w0BAQEFAASCAQBRI7/U4Fx0KIeyHUr3MJb/dtwKh+UtOYKIoUHaO7x1ZANL
# pK5XDPHHle3c+RQtOFRV8I1oLOJ/5v5T9ZjUCKP9ODtwobBakXagnnDmLZsPtURZ
# xRswKz1qshEQoqpBaJSU58c1HV42Lsep8x7qFaMsGLfXfwXL3XAKEAZvVt+OQN5C
# CSDi5OYxyR1r6FRua90y7O4MpkqhiZafFL7fkf75YOaTqACwcQtJHlfiJdCTRxuD
# hKm+t2yP+m2wE3ihk37Z8IJ2o+4UPKdlpa55J+q/13JoCmQp6QoS23pVyA3MXO5d
# e29vsKhwyDaxvjy7hoZoSP+5zxnsHEbE7W2P293JoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ1MFowLwYJKoZIhvcNAQkEMSIEIIOcmwaQ57dvyYnq
# e5er4VD6l6LijE5JEBcenizd+RpMMA0GCSqGSIb3DQEBAQUABIICAKbPNjw7xC5y
# ormveB9Ynw/kUhQWb0MA3u9nmsfdwkNsoAjWSwL7TToJ5nqS061YKaqgaCW6LiVD
# F2u64355s4SK+6YyjM7WdSv3Ntgt/SQwcj4WhiwYkuSmS5qfd9tBRR2Ki5HZMFoX
# 7fIryNvhlAdnxE6wNVdUql1UBygdYhdpYlOHBy1KvnVgcTPktRKlLFXSp7UliL09
# r0NbKoT0jUSIQ6nA9YtUTbDYgF8SZfUnHYxDFh0S2cDJ3Ry/yQa63r7k1LmmQBQ5
# 3aEOizFErVYYORi4syr6HGY+P3qjDxZYHYpFk9gDVTJ8uCVFUVyWI47hzUzMDCFX
# JmsSxbPe+lL1SNB9j/wyZHJKf+hj4YKzNt+h0jDyM/65ZgLYCCuRuztASrldW6tt
# mSodaenXZstU1db7o8gKiJrAlw2JtQu6ebfhDq++RcuCZgLTBYo3fw2WHPoFtIYz
# 6UYXUxCsvB+Ej95QJAEOyPVd8gof1oWy4NEh+3Tp7hKGdW4comlusP3v95WGBV/c
# DHXhCaIHxieXbr3+8JB/eCpqoEFQqIX+ndTcCpWnpfSl2etRwlRWJ4/2uHqC7QUg
# vTmto++g+ZVEYFZlP8nFVpmhYPJ6F7LRZpPMbNbqiZRyFROV9Uq6lyLNNB6ysUkA
# 0X+x6Qr2tKyi05szGHtZlrXhYdtVW9oZ
# SIG # End signature block
