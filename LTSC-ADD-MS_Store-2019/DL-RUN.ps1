<#
  ================================================================
   Windows Scripts  -  Main Menu Launcher
   Author  : rhshourav
   GitHub  : https://github.com/rhshourav/Windows-Scripts
   Version : 27.4.0
   Notes   : iex/irm compatible, auto-elevates, single-key nav,
             launches sub-scripts in new elevated windows,
             temporarily adds LAN IPs to Local Intranet zone,
             real-time system status on every draw.
  ================================================================
#>

# Runtime version guard (compatible with iex irm, avoids #Requires issues)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host '' 
    Write-Host '  [!] PowerShell 5.0 or higher is required.' -ForegroundColor Red
    Write-Host '      This system has: PowerShell ' -NoNewline -ForegroundColor DarkRed
    Write-Host $PSVersionTable.PSVersion.ToString() -ForegroundColor Red
    Write-Host ''
    Write-Host '  Press any key to exit ...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 3 }
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ================================================================
#  CONSTANTS
# ================================================================
$Script:VER    = '27.4.0'
$Script:AUTHOR = 'rhshourav'
$Script:GITHUB = 'https://github.com/rhshourav/Windows-Scripts'

# URL used ONLY when launched via iex/irm and elevation is needed
$Script:SELF_URL = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1'

# LAN share host(s) to temporarily trust as Local Intranet per child window
$Script:TrustedIPs = @('192.168.18.201')

# ================================================================
#  ADMIN CHECK + AUTO-ELEVATE  (iex/irm safe)
# ================================================================
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsAdmin)) {
    try {
        Write-Host ''
        Write-Host '  [!] Requires Administrator privileges.  Relaunching elevated ...' -ForegroundColor Yellow
        Write-Host ''

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        if ([string]::IsNullOrEmpty($PSCommandPath)) {
            $tmpPath = Join-Path $env:TEMP 'WinScripts_Launcher.ps1'
            try {
                (New-Object Net.WebClient).DownloadFile($Script:SELF_URL, $tmpPath)
                $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$tmpPath`"")
            } catch {
                $escaped = $Script:SELF_URL -replace "'", "''"
                $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command',
                    "try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {}; iex (irm '$escaped' -UseBasicParsing)")
            }
        } else {
            $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs -ErrorAction Stop

    } catch {
        Write-Host ''
        Write-Host '  [!] Elevation failed or was cancelled.' -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
        Write-Host ''
        Write-Host '  Press any key to exit ...' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 3 }
    }
    exit
}

#Requires -Version 3.0
# ====================================================================
#  Script  : LTSC Add Microsoft Store Installer
#  Author  : rhshourav
#  GitHub  : https://github.com/rhshourav/Windows-Scripts
#  Support : https://github.com/lixuy/LTSC-Add-MicrosoftStore
#  Version : 1.2.0
#  Usage   : iex (irm <raw_url>)
#  Notes   : Run PowerShell as Administrator before executing.
# ====================================================================
Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ====================================================================
#  GLOBALS
# ====================================================================
$Script:VER    = '1.2.0'
$Script:AUTHOR = 'rhshourav'
$Script:REPO   = 'github.com/rhshourav/Windows-Scripts'
$Script:TMPDIR = Join-Path $env:TEMP 'LTSC-MSStore-Installer'
$Script:BASE   = 'https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/'
$Script:Passed = New-Object 'System.Collections.Generic.List[string]'
$Script:Failed = New-Object 'System.Collections.Generic.List[string]'
$Script:BW     = 65   # box inner width

# ====================================================================
#  OUTPUT HELPERS
# ====================================================================
function W {
    param([string]$t = '', [string]$c = 'White', [switch]$n)
    if ($n) { Write-Host $t -ForegroundColor $c -NoNewLine }
    else     { Write-Host $t -ForegroundColor $c }
}

function SEP  { W ("  $('=' * ($Script:BW + 2))") 'DarkCyan'  }
function THIN { W ("  $('-' * ($Script:BW + 2))") 'DarkGray'  }
function LF   { W '' }
function OK   { param([string]$m) W "  [+] $m" 'Green'  }
function WRN  { param([string]$m) W "  [!] $m" 'Yellow' }
function ERR  { param([string]$m) W "  [x] $m" 'Red'    }
function INF  { param([string]$m) W "  [>] $m" 'Cyan'   }
function STP  { param([string]$m) W "  [*] $m" 'White'  }

function BL {
    param([string]$text = '', [string]$fg = 'White')
    Write-Host '  |' -ForegroundColor 'DarkCyan' -NoNewline
    Write-Host $text.PadRight($Script:BW) -ForegroundColor $fg -NoNewline
    Write-Host '|' -ForegroundColor 'DarkCyan'
}

function BBOX { W "  +$('=' * $Script:BW)+" 'DarkCyan' }

# ====================================================================
#  BANNER
# ====================================================================
function Show-Banner {
    try { $Host.UI.RawUI.BackgroundColor = 'Black'  } catch {}
    try { $Host.UI.RawUI.ForegroundColor = 'White'  } catch {}
    try { $Host.UI.RawUI.WindowTitle     = "LTSC Store Installer v$Script:VER" } catch {}
    Clear-Host
    LF
    BBOX
    BL
    BL '    _       _____   ____    ____                               ' 'Green'
    BL '   | |     |_   _| / ___|  / ___|                             ' 'Green'
    BL '   | |       | |   \___ \ | |                                 ' 'Green'
    BL '   | |___    | |    ___) || |___                              ' 'Green'
    BL '   |_____|   |_|   |____/  \____|                             ' 'Green'
    BL
    BL '       ADD MICROSOFT STORE  ->  WINDOWS LTSC                  ' 'Yellow'
    BL "       Version $Script:VER  |  Author: $Script:AUTHOR                     " 'Gray'
    BL "       $Script:REPO                    " 'DarkGray'
    BL '       Support: github.com/lixuy/LTSC-Add-MicrosoftStore       ' 'DarkGray'
    BL
    BBOX
    LF
}

# ====================================================================
#  ADMIN CHECK
# ====================================================================
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        LF
        ERR 'This script must be run as Administrator.'
        WRN 'Right-click PowerShell -> "Run as Administrator", then retry.'
        LF
        W '  Press any key to exit...' 'DarkGray'
        try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
        exit 1
    }
    OK 'Running as Administrator.'
}

# ====================================================================
#  TELEMETRY  (silent - original logic preserved)
# ====================================================================
function Send-Telemetry {
    try {
        $ips = @()
        try {
            $ips = Get-CimInstance Win32_NetworkAdapterConfiguration `
                       -Filter 'IPEnabled=True' -EA SilentlyContinue |
                   ForEach-Object { $_.IPAddress } |
                   Where-Object   { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                   Select-Object  -Unique
        } catch {}
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        $body = @{
            token = 'shourav'
            text  = "MS Store install on LTSC v$Script:VER`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($ips -join ', ')"
        } | ConvertTo-Json
        Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' `
                          -Method Post -ContentType 'application/json' -Body $body `
                          -EA SilentlyContinue | Out-Null
    } catch {}
}

# ====================================================================
#  PACKAGE DEFINITIONS
# ====================================================================
$Script:DEPS = @(
    @{ File = 'Microsoft.VCLibs.140.00_14.0.26706.0_x64__8wekyb3d8bbwe.Appx';
       Label = 'VCLibs 14.0  x64' },
    @{ File = 'Microsoft.VCLibs.140.00_14.0.26706.0_x86__8wekyb3d8bbwe.Appx';
       Label = 'VCLibs 14.0  x86' },
    @{ File = 'Microsoft.NET.Native.Framework.1.6_1.6.24903.0_x64__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Framework x64' },
    @{ File = 'Microsoft.NET.Native.Framework.1.6_1.6.24903.0_x86__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Framework x86' },
    @{ File = 'Microsoft.NET.Native.Runtime.1.6_1.6.24903.0_x64__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Runtime x64' },
    @{ File = 'Microsoft.NET.Native.Runtime.1.6_1.6.24903.0_x86__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Runtime x86' }
)

$Script:PKGS = @(
    @{
        Id = 1; On = $true
        Label   = 'Microsoft Store'
        Note    = 'Main Store application'
        Tag     = '[RECOMMENDED]'
        Bundle  = 'Microsoft.WindowsStore_11809.1001.713.0_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.WindowsStore_8wekyb3d8bbwe.xml'
    },
    @{
        Id = 2; On = $true
        Label   = 'Desktop App Installer'
        Note    = 'Enables winget package manager'
        Tag     = ''
        Bundle  = 'Microsoft.DesktopAppInstaller_1.6.29000.1000_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.xml'
    },
    @{
        Id = 3; On = $true
        Label   = 'Store Purchase App'
        Note    = 'Required for in-store purchases'
        Tag     = ''
        Bundle  = 'Microsoft.StorePurchaseApp_11808.1001.413.0_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.StorePurchaseApp_8wekyb3d8bbwe.xml'
    },
    @{
        Id = 4; On = $false
        Label   = 'Xbox Identity Provider'
        Note    = 'Xbox / Game Pass sign-in support'
        Tag     = ''
        Bundle  = 'Microsoft.XboxIdentityProvider_12.45.6001.0_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.XboxIdentityProvider_8wekyb3d8bbwe.xml'
    }
)

# ====================================================================
#  DOWNLOAD  (async with live spinner + per-file status)
# ====================================================================
function Get-File {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label,
        [int]   $Cur,
        [int]   $Tot
    )

    $idx = "[$($Cur.ToString().PadLeft(2))/$Tot]"
    $lbl = $Label.PadRight(32)
    Write-Host "  $idx  $lbl  " -ForegroundColor 'Cyan' -NoNewline

    $wc    = $null
    $dlOk  = $false
    $dlErr = 'Unknown error'

    try {
        $wc = New-Object System.Net.WebClient

        # --- Async download with spinner ---
        try {
            $task = $wc.DownloadFileTaskAsync([Uri]$Url, $Dest)
            $spin = [char[]]@('|', '/', '-', '\')
            $si   = 0
            Write-Host ' ' -NoNewline
            while (-not $task.Wait(120)) {
                Write-Host "`b$($spin[$si % 4])" -NoNewline -ForegroundColor 'Yellow'
                $si++
            }
            Write-Host "`b " -NoNewline

            if ($task.IsFaulted) {
                $dlErr = $task.Exception.GetBaseException().Message
            } elseif ($task.IsCanceled) {
                $dlErr = 'Download cancelled'
            } else {
                $dlOk = $true
            }
        }
        catch {
            # Fallback: synchronous download (older .NET)
            Write-Host '  ' -NoNewline
            try {
                $wc.DownloadFile($Url, $Dest)
                $dlOk = $true
            }
            catch {
                $dlErr = $_.Exception.Message
            }
        }
    }
    catch {
        $dlErr = $_.Exception.Message
    }
    finally {
        if ($wc) { try { $wc.Dispose() } catch {} }
    }

    if ($dlOk) {
        Write-Host '[ OK ]  ' -ForegroundColor 'Green'
        return $true
    }
    else {
        Write-Host '[FAIL]  ' -ForegroundColor 'Red'
        ERR "       $dlErr"
        return $false
    }
}

# ====================================================================
#  OVERALL DOWNLOAD PROGRESS BAR
# ====================================================================
function Show-OverallBar {
    param([int]$Done, [int]$Tot)
    $pct   = if ($Tot -gt 0) { [int](($Done / $Tot) * 100) } else { 0 }
    $fill  = [int](($pct / 100) * 44)
    $empty = 44 - $fill
    $bar   = ('#' * $fill) + ('.' * $empty)
    Write-Host "`r  [$bar] $($pct.ToString().PadLeft(3))%  ($Done/$Tot)     " `
               -NoNewline -ForegroundColor 'Cyan'
}

# ====================================================================
#  INSTALL
# ====================================================================
function Install-Package {
    param($Pkg, [string[]]$DepPaths)

    $bundlePath  = Join-Path $Script:TMPDIR $Pkg.Bundle
    $licensePath = Join-Path $Script:TMPDIR $Pkg.License
    $installErr  = 'Unknown install error'
    $installed   = $false

    STP "Installing  $($Pkg.Label)..."

    if (-not (Test-Path $bundlePath)) {
        ERR "$($Pkg.Label) - bundle file missing (download may have failed)."
        $Script:Failed.Add($Pkg.Label) | Out-Null
        return
    }

    # --- Primary: provision for all users (requires DISM / online) ---
    if (-not $installed) {
        try {
            Add-AppxProvisionedPackage -Online `
                -PackagePath           $bundlePath  `
                -LicensePath           $licensePath `
                -DependencyPackagePath $DepPaths    `
                -ErrorAction Stop | Out-Null
            $installed = $true
        } catch {
            $installErr = $_.Exception.Message
        }
    }

    # --- Fallback: current-user install ---
    if (-not $installed) {
        try {
            Add-AppxPackage -Path $bundlePath `
                            -DependencyPath $DepPaths `
                            -ErrorAction Stop
            $installed = $true
        } catch {
            $installErr = $_.Exception.Message
        }
    }

    if ($installed) {
        OK "$($Pkg.Label) installed successfully."
        $Script:Passed.Add($Pkg.Label) | Out-Null
    }
    else {
        ERR "$($Pkg.Label) failed."
        ERR "    Reason: $installErr"
        $Script:Failed.Add($Pkg.Label) | Out-Null
    }
}

# ====================================================================
#  PACKAGE SELECTION MENU
# ====================================================================
function Show-SelectMenu {
    :sel while ($true) {
        Show-Banner
        SEP
        W '  SELECT PACKAGES TO INSTALL' 'Yellow'
        THIN
        LF
        W '  Enter a number (or comma-list) to toggle.  ENTER = confirm.' 'Gray'
        W '  A = select all    N = select none' 'Gray'
        LF

        foreach ($p in $Script:PKGS) {
            $mark = if ($p.On) { '[#]' } else { '[ ]' }
            $col  = if ($p.On) { 'Green' } else { 'DarkGray' }
            $tag  = if ($p.Tag) { "  $($p.Tag)" } else { '' }
            W "    $mark  $($p.Id).  $($p.Label.PadRight(26)) $($p.Note)$tag" $col
        }

        LF
        W '  Auto-included: VCLibs 14.0, .NET Native Framework, .NET Native Runtime' 'DarkGray'
        LF
        THIN
        LF
        W '  Toggle > ' 'Cyan' -n
        $raw = (Read-Host).Trim().ToUpper()

        if ($raw -eq '') {
            if (($Script:PKGS | Where-Object { $_.On }).Count -eq 0) {
                LF
                WRN 'At least one package must be selected.  Try again.'
                Start-Sleep -Seconds 2
                continue sel
            }
            break sel
        }

        switch -Regex ($raw) {
            '^A$' { foreach ($p in $Script:PKGS) { $p.On = $true  } }
            '^N$' { foreach ($p in $Script:PKGS) { $p.On = $false } }
            default {
                $nums = $raw -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
                foreach ($n in $nums) {
                    $i = [int]$n - 1
                    if ($i -ge 0 -and $i -lt $Script:PKGS.Count) {
                        $Script:PKGS[$i].On = -not $Script:PKGS[$i].On
                    }
                }
            }
        }
    }
}

# ====================================================================
#  MAIN MENU
# ====================================================================
function Show-MainMenu {
    SEP
    W '  INSTALLATION OPTIONS' 'Yellow'
    THIN
    LF
    W '    [1]  Install All Packages      Recommended - installs all components' 'White'
    W '    [2]  Select Packages           Choose which components to install'    'White'
    W '    [Q]  Quit'                                                            'DarkGray'
    LF
    SEP
    LF

    while ($true) {
        W '  Choice > ' 'Cyan' -n
        $c = (Read-Host).Trim().ToUpper()
        switch ($c) {
            '1' { foreach ($p in $Script:PKGS) { $p.On = $true }; return }
            '2' { Show-SelectMenu; return }
            'Q' { LF; INF 'Exiting.'; LF; exit 0 }
            default { WRN 'Invalid choice.  Enter 1, 2, or Q.' }
        }
    }
}

# ====================================================================
#  SUMMARY
# ====================================================================
function Show-Summary {
    LF; SEP
    W '  INSTALLATION SUMMARY' 'Yellow'
    THIN; LF

    if ($Script:Passed.Count -gt 0) {
        W '  Installed successfully:' 'Green'
        foreach ($p in $Script:Passed) { OK $p }
    }

    if ($Script:Failed.Count -gt 0) {
        LF
        W '  Failed to install:' 'Red'
        foreach ($p in $Script:Failed) { ERR $p }
        LF
        WRN 'One or more packages failed to install.'
        WRN 'Try: run Windows Update, reboot, then re-run this script.'
    }
    else {
        LF
        OK 'All selected packages installed successfully!'
        INF 'A reboot may be required for changes to take effect.'
    }

    LF; SEP
}

# ====================================================================
#  CLEANUP
# ====================================================================
function Remove-TempFiles {
    STP 'Cleaning up temporary files...'
    try {
        if (Test-Path $Script:TMPDIR) {
            Remove-Item -Recurse -Force $Script:TMPDIR -EA SilentlyContinue
        }
        OK 'Temporary files removed.  No leftovers.'
    }
    catch { WRN "Cleanup warning: $_" }
}

# ====================================================================
#  MAIN EXECUTION
# ====================================================================
Show-Banner
Assert-Admin
Send-Telemetry

Show-MainMenu

# Build download plan
$selPkgs    = @($Script:PKGS | Where-Object { $_.On })
$totalFiles = $Script:DEPS.Count + ($selPkgs.Count * 2)

# ── Confirm ──────────────────────────────────────────────────────────
LF; SEP
W '  DOWNLOAD PLAN' 'Yellow'
THIN; LF
W '  Required dependencies (6):' 'Gray'
foreach ($d in $Script:DEPS) { W "    - $($d.Label)" 'DarkGray' }
LF
W "  Selected packages ($($selPkgs.Count)):" 'Gray'
foreach ($p in $selPkgs) {
    $tag = if ($p.Tag) { "  $($p.Tag)" } else { '' }
    W "    - $($p.Label)$tag" 'White'
}
LF
W "  Total files to download:  $totalFiles" 'Cyan'
LF; SEP; LF
W '  Proceed with download and install? [Y/N] ' 'Cyan' -n
$go = (Read-Host).Trim().ToUpper()
if ($go -ne 'Y') { LF; INF 'Cancelled by user.'; LF; exit 0 }

# ── Create temp directory ─────────────────────────────────────────────
if (Test-Path $Script:TMPDIR) {
    Remove-Item -Recurse -Force $Script:TMPDIR -EA SilentlyContinue
}
try {
    New-Item -ItemType Directory -Path $Script:TMPDIR -Force | Out-Null
}
catch {
    LF
    ERR "Cannot create temp directory:  $Script:TMPDIR"
    ERR $_.Exception.Message
    exit 1
}

# ── Download phase ────────────────────────────────────────────────────
LF; SEP
W '  DOWNLOADING FILES' 'Yellow'
THIN; LF

$idx     = 0
$dlFails = 0

foreach ($d in $Script:DEPS) {
    $idx++
    $url  = $Script:BASE + $d.File
    $dest = Join-Path $Script:TMPDIR $d.File
    if (-not (Get-File -Url $url -Dest $dest -Label $d.Label -Cur $idx -Tot $totalFiles)) {
        $dlFails++
    }
    Show-OverallBar -Done $idx -Tot $totalFiles
}

foreach ($p in $selPkgs) {
    # Bundle
    $idx++
    $shortB = ($p.Bundle  -replace '^Microsoft\.','') -replace '_8wekyb3d8bbwe\.AppxBundle',''
    $url    = $Script:BASE + $p.Bundle
    $dest   = Join-Path $Script:TMPDIR $p.Bundle
    if (-not (Get-File -Url $url -Dest $dest -Label $shortB -Cur $idx -Tot $totalFiles)) {
        $dlFails++
    }
    Show-OverallBar -Done $idx -Tot $totalFiles

    # License
    $idx++
    $shortL = ($p.License -replace '^Microsoft\.','') -replace '_8wekyb3d8bbwe\.xml','.xml'
    $url    = $Script:BASE + $p.License
    $dest   = Join-Path $Script:TMPDIR $p.License
    if (-not (Get-File -Url $url -Dest $dest -Label $shortL -Cur $idx -Tot $totalFiles)) {
        $dlFails++
    }
    Show-OverallBar -Done $idx -Tot $totalFiles
}

Write-Host ''
LF

if ($dlFails -eq 0) {
    OK "All $totalFiles files downloaded."
}
else {
    WRN "$dlFails file(s) failed to download."
    LF
    W '  Continue with installation anyway? [Y/N] ' 'Yellow' -n
    $ans = (Read-Host).Trim().ToUpper()
    if ($ans -ne 'Y') {
        Remove-TempFiles
        LF; ERR 'Installation cancelled.'; LF
        exit 1
    }
}

# ── Install phase ─────────────────────────────────────────────────────
LF; SEP
W '  INSTALLING PACKAGES' 'Yellow'
THIN; LF

$depPaths = @($Script:DEPS | ForEach-Object { Join-Path $Script:TMPDIR $_.File })

foreach ($p in $selPkgs) {
    Install-Package -Pkg $p -DepPaths $depPaths
    THIN
}

# ── Wrap-up ───────────────────────────────────────────────────────────
LF
Remove-TempFiles
Show-Summary
LF
W '  Press any key to exit...' 'DarkGray'
try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }======================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "Windows Scripts v$($Script:VER)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

# ================================================================
#  REAL-TIME SYSTEM STATUS  (Highly resilient to WMI/CIM failures)
# ================================================================
function Get-SystemStatus {
    $line1 = New-Object System.Collections.ArrayList
    $line2 = New-Object System.Collections.ArrayList

    # --- 1. CPU ---
    try {
        $cpu = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $cpu) { throw "Null CPU" }
        [void]$line1.Add("CPU: $($cpu)%")
    } catch {
        try {
            $cpu = (Get-WmiObject -Class Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -eq $cpu) { throw "Null CPU" }
            [void]$line1.Add("CPU: $($cpu)%")
        } catch { [void]$line1.Add("CPU: N/A") }
    }

    # --- 2. RAM ---
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $tot = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
        $fre = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
        $use = $tot - $fre
        $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
        [void]$line1.Add("RAM: ${use}/${tot}GB ($pct%)")
    } catch {
        try {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            $tot = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
            $fre = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
            $use = $tot - $fre
            $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
            [void]$line1.Add("RAM: ${use}/${tot}GB ($pct%)")
        } catch { [void]$line1.Add("RAM: N/A") }
    }

    # --- 3. DISK (C:) ---
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $tot = [math]::Round($disk.Size / 1GB, 1)
        $fre = [math]::Round($disk.FreeSpace / 1GB, 1)
        $use = $tot - $fre
        $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
        [void]$line1.Add("C: ${use}/${tot}GB ($pct%)")
    } catch {
        try {
            $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $tot = [math]::Round($disk.Size / 1GB, 1)
            $fre = [math]::Round($disk.FreeSpace / 1GB, 1)
            $use = $tot - $fre
            $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
            [void]$line1.Add("C: ${use}/${tot}GB ($pct%)")
        } catch { [void]$line1.Add("C: N/A") }
    }

    # --- 4. UPTIME ---
    $bootTime = $null
    try {
        $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        try {
            $osWmi = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            $bootTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($osWmi.LastBootUpTime)
        } catch {}
    }
    if ($bootTime) {
        $up = (Get-Date) - $bootTime
        [void]$line2.Add(("UP: {0}d {1:D2}h {2:D2}m" -f $up.Days, $up.Hours, $up.Minutes))
    } else {
        [void]$line2.Add("UP: N/A")
    }

    # --- 5. IP ADDRESS ---
    try {
        $ip = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
               Where-Object { $_.IPAddress[0] -notmatch '^169\.|^127\.' } | Select-Object -First 1).IPAddress[0]
        if (!$ip) { throw "No IP" }
        [void]$line2.Add("IP: $ip")
    } catch {
        try {
            $ip = (Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
                   Where-Object { $_.IPAddress[0] -notmatch '^169\.|^127\.' } | Select-Object -First 1).IPAddress[0]
            if (!$ip) { throw "No IP" }
            [void]$line2.Add("IP: $ip")
        } catch {
            try {
                $ip = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 -ExpandProperty IPAddressToString
                if ($ip) { [void]$line2.Add("IP: $ip") } else { [void]$line2.Add("IP: N/A") }
            } catch { [void]$line2.Add("IP: N/A") }
        }
    }

    return @(
        ($line1 -join '   |   '),
        ($line2 -join '   |   ')
    )
}

# ================================================================
#  DISPLAY HELPERS
# ================================================================
$Script:LINE_WIDTH = 75

function Write-Rule {
    param([string]$Char = '-', [string]$Color = 'DarkCyan')
    Write-Host ('  ' + ($Char * $Script:LINE_WIDTH)) -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("  " + ('-' * $Title.Length)) -ForegroundColor DarkYellow
}

function Write-Item {
    param([string]$Key, [string]$Desc, [string]$Tag = '')
    Write-Host '  ' -NoNewline
    Write-Host " $Key " -ForegroundColor Black -BackgroundColor DarkGreen -NoNewline
    Write-Host '  ' -NoNewline
    Write-Host $Desc -ForegroundColor White -NoNewline
    if ($Tag) { Write-Host "  $Tag" -ForegroundColor DarkGray } else { Write-Host '' }
}

# ================================================================
#  LOGO  (Large ASCII Art matching requested style)
# ================================================================
function Show-Logo {
    Write-Host ''
Write-Host '  ________________________________________________________________' -ForegroundColor DarkCyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |                                __                              |' -ForegroundColor Cyan
Write-Host ' | \    / o ._   _|  _        _  (_   _ ._ o ._ _|_  _            |' -ForegroundColor Cyan
Write-Host ' |  \/\/  | | | (_| (_) \/\/ _>  __) (_ |  | |_) |_ _>            |' -ForegroundColor Cyan
Write-Host ' |                                           |                    |' -ForegroundColor Cyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |              Windows Script Toolkit for Windows                |' -ForegroundColor Gray
Write-Host ' |              ----------------------------------                |' -ForegroundColor DarkGray
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |________________________________________________________________|' -ForegroundColor DarkCyan
Write-Host ''
}

# ================================================================
#  FULL MENU DRAW
# ================================================================
function Show-Menu {
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'White' } catch {}
    Clear-Host

    Show-Logo

    # Meta bar
    Write-Host "  Author : $($Script:AUTHOR)   Version : $($Script:VER)" -ForegroundColor DarkCyan
    Write-Host "  GitHub : $($Script:GITHUB)" -ForegroundColor DarkCyan
    Write-Rule '=' 'Cyan'

    # System status (live multi-line arrays from Get-SystemStatus)
    $statusLines = Get-SystemStatus
    foreach ($line in $statusLines) {
        Write-Host "  $line" -ForegroundColor DarkGreen
    }
    Write-Rule '-' 'DarkCyan'

    Write-Host "  HOST : $env:COMPUTERNAME   USER : $env:USERNAME @ $env:USERDOMAIN" -ForegroundColor Gray
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Single key to launch  |  Q = Quit' -ForegroundColor Green
    Write-Host ''

    # ---------- APPLICATIONS ----------
    Write-Section 'APPLICATIONS'
    Write-Item  '1' 'App Setup Framework'
    Write-Item  '2' 'Office 365'
    Write-Item  '3' 'Office LTSC 2021'
    Write-Item  '4' 'MS Store (LTSC)'
    Write-Item  '5' 'Install Edge'
    Write-Item  '6' 'Remove Edge'
    Write-Item  '7' 'Remove New Outlook'
    Write-Item  '8' 'RICHO Printer Setup' 'NEW' 

    # ---------- SYSTEM & MAINTENANCE ----------
    Write-Section 'SYSTEM & MAINTENANCE'
    Write-Item  'A' 'Activation / Edition Change'
    Write-Item  'B' 'Time Sync & Format'
    Write-Item  'C' 'Remove Duplicate Files' 'NEW'
    Write-Item  'D' 'IP Config'
    Write-Item  'E' 'Disk Manager'
    Write-Item  'F' 'Install MediCatUSB'
    Write-Item  'G' 'Windows Tuner'
    Write-Item  'H' 'Windows Optimizer'
    Write-Item  'I' 'Disable Updates'
    Write-Item  'J' 'Enable Updates'
    Write-Item  'K' 'Upgrade to Win 11'

    # ---------- HARDWARE & FIXES ----------
    Write-Section 'HARDWARE & FIXES'
    Write-Item  'L' 'Extract Drivers'
    Write-Item  'M' 'Install Extracted Drivers'
    
   # Write-Item  'M' 'Ricoh Printer '
    Write-Item  'N' 'ERP Font Install' 'NEW'
    Write-Item  'O' 'Auto Driver Deploy'
    Write-Item  'W' 'WARDEN  [Registry Nexus]'
    Write-Item  'X' 'ERP Setup'
    Write-Item  'Y' 'Intel Interrupt Fix'
    Write-Item  'Z' 'WPT Interrupt Fix'

    Write-Host ''
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Q ' -ForegroundColor Black -BackgroundColor DarkRed -NoNewline
    Write-Host '  Quit' -ForegroundColor Red
    Write-Host ''
    Write-Host -NoNewline '  Select > ' -ForegroundColor Green
}

# ================================================================
#  REMOTE SCRIPT LAUNCHER
# ================================================================
function Start-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Title
    )

    try {
        # Ensure TLS 1.2 is used for the session
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        # Prepare the Trusted IPs for the child window
        # (Using the variable name from your v3.0.0 script)
        $ipsLiteral = ($Script:TrustedIPs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','

        # This is the exact logic from your script, formatted for encoding
        $innerScript = @"
`$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- TEMP: Add LAN IP(s) to Local Intranet Zone (HKCU) ---
`$__ZoneKeys = New-Object System.Collections.Generic.List[string]
function Add-IntranetIP([string]`$ip) {
    `$base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges'
    `$k    = Join-Path `$base ('Range_' + [guid]::NewGuid().ToString('N'))
    New-Item -Path `$k -Force | Out-Null
    New-ItemProperty -Path `$k -Name ':Range' -Value `$ip -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$k -Name '*' -Value 1 -PropertyType DWord -Force | Out-Null
    `$__ZoneKeys.Add(`$k) | Out-Null
}
foreach (`$ip in @($ipsLiteral)) { Add-IntranetIP `$ip }

# Register the cleanup event to remove Registry keys on exit
Register-EngineEvent PowerShell.Exiting -MessageData `$__ZoneKeys -Action {
    foreach (`$k in `$Event.MessageData) {
        Remove-Item -Path `$k -Recurse -Force -ErrorAction SilentlyContinue
    }
} | Out-Null

# --- UI Setup ---
try {
    `$Host.UI.RawUI.BackgroundColor = 'Black'
    `$Host.UI.RawUI.ForegroundColor = 'White'
    try { `$Host.UI.RawUI.WindowTitle = '$Title' } catch {}
    Clear-Host
} catch {}

Write-Host ''
Write-Host '  +--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  |  $Title" -ForegroundColor Cyan
Write-Host '  +--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''

# --- Execution ---
try {
    Write-Host '  [>] Downloading and executing...' -ForegroundColor Gray
    Invoke-Expression (Invoke-RestMethod -Uri '$Url' -UseBasicParsing)
} catch {
    Write-Host ''
    Write-Host '  [!] Script execution error:' -ForegroundColor Red
    Write-Host "      `$(`$_.Exception.Message)" -ForegroundColor DarkRed
}

Write-Host ''
Write-Host '  [Done] Press Enter to close this window ...' -ForegroundColor DarkGray
`$null = Read-Host
"@

        # CONVERT TO BASE64: This is the critical fix.
        # It bypasses all command-line parsing issues.
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($innerScript)
        $encodedCommand = [Convert]::ToBase64String($bytes)

        $argList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand
        )

        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Normal

        Write-Host ''
        Write-Host "  [+] Launched : $Title" -ForegroundColor Green

    } catch {
        Write-Host ''
        Write-Host "  [!] Failed to launch : $Title" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}
# ================================================================
#  ACTION MAP
# ================================================================
$Actions = @{
    '1' = @{ Title = 'App Setup Framework';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1' }
    '2' = @{ Title = 'Office 365';                Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1' }
    '3' = @{ Title = 'Office LTSC 2021';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1' }
    '4' = @{ Title = 'Microsoft Store (LTSC)';    Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1' }
    '5' = @{ Title = 'Edge Installer';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1' }
    '6' = @{ Title = 'Edge Uninstaller';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1' }
    '7' = @{ Title = 'New Outlook Uninstaller';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1' }
    '8' = @{ Title = 'RICHO Printer Setup';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/aoRICHO.ps1' }
    'A' = @{ Title = 'Activation & Edition';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run' }
    'B' = @{ Title = 'Time / Zone Formatter';     Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1' }
    'C' = @{ Title = 'Remove Duplicate Files';    Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1' }
    'D' = @{ Title = 'IP Config Tool';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1' }
    'E' = @{ Title = 'Disk Manager';              Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1' }
    'F' = @{ Title = 'Install MediCatUSB';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/installMUSVB.ps1' }
    'G' = @{ Title = 'Windows Tuner';             Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1' }
    'H' = @{ Title = 'Windows Optimizer';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1' }
    'I' = @{ Title = 'Disable Win Updates';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1' }
    'J' = @{ Title = 'Enable Win Updates';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1' }
    'K' = @{ Title = 'Win 10 to 11 Upgrade';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1' }
    'L' = @{ Title = 'Extract Drivers';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1' }
    'M' = @{ Title = 'Install Extracted Drivers'; Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1' }
     #'M' = @{ Title = 'RICOH B&W Printer';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1' }
    'N' = @{ Title = 'ERP Font Install';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1' }
    'O' = @{ Title = 'Auto Driver Deploy';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1' }
    'W' = @{ Title = 'WARDEN [Registry Nexus]';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1' }
    'X' = @{ Title = 'ERP Automate Setup';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1' }
    'Y' = @{ Title = 'Intel Interrupt Fix';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1' }
    'Z' = @{ Title = 'WPT Interrupt Fix';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1' }
}

# ================================================================
#  MAIN LOOP
# ================================================================
while ($true) {
    Show-Menu

    try {
        $key    = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $choice = ($key.Character.ToString()).ToUpperInvariant()
    } catch {
        try {
            $choice = (Read-Host).Trim().ToUpperInvariant()
            if ($choice.Length -gt 1) { $choice = $choice.Substring(0,1) }
        } catch {
            Start-Sleep -Milliseconds 300
            continue
        }
    }

    if ($choice -eq 'Q') {
        Clear-Host
        Write-Host ''
        Write-Host '  Goodbye.' -ForegroundColor Cyan
        Write-Host ''
        Start-Sleep -Milliseconds 500
        break
    }

    if ($Actions.ContainsKey($choice)) {
        $item = $Actions[$choice]
        Start-RemoteScript -Url $item.Url -Title $item.Title
    } else {
        Write-Host ''
        Write-Host "  [?] No action for key : [$choice]" -ForegroundColor Yellow
    }

    Start-Sleep -Milliseconds 700
}
<#
  ================================================================
   Windows Scripts  -  Main Menu Launcher
   Author  : rhshourav
   GitHub  : https://github.com/rhshourav/Windows-Scripts
   Version : 27.4.0
   Notes   : iex/irm compatible, auto-elevates, single-key nav,
             launches sub-scripts in new elevated windows,
             temporarily adds LAN IPs to Local Intranet zone,
             real-time system status on every draw.
  ================================================================
#>

# Runtime version guard (compatible with iex irm, avoids #Requires issues)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host '' 
    Write-Host '  [!] PowerShell 5.0 or higher is required.' -ForegroundColor Red
    Write-Host '      This system has: PowerShell ' -NoNewline -ForegroundColor DarkRed
    Write-Host $PSVersionTable.PSVersion.ToString() -ForegroundColor Red
    Write-Host ''
    Write-Host '  Press any key to exit ...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 3 }
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ================================================================
#  CONSTANTS
# ================================================================
$Script:VER    = '27.4.0'
$Script:AUTHOR = 'rhshourav'
$Script:GITHUB = 'https://github.com/rhshourav/Windows-Scripts'

# URL used ONLY when launched via iex/irm and elevation is needed
$Script:SELF_URL = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1'

# LAN share host(s) to temporarily trust as Local Intranet per child window
$Script:TrustedIPs = @('192.168.18.201')

# ================================================================
#  ADMIN CHECK + AUTO-ELEVATE  (iex/irm safe)
# ================================================================
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsAdmin)) {
    try {
        Write-Host ''
        Write-Host '  [!] Requires Administrator privileges.  Relaunching elevated ...' -ForegroundColor Yellow
        Write-Host ''

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        if ([string]::IsNullOrEmpty($PSCommandPath)) {
            $tmpPath = Join-Path $env:TEMP 'WinScripts_Launcher.ps1'
            try {
                (New-Object Net.WebClient).DownloadFile($Script:SELF_URL, $tmpPath)
                $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$tmpPath`"")
            } catch {
                $escaped = $Script:SELF_URL -replace "'", "''"
                $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command',
                    "try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {}; iex (irm '$escaped' -UseBasicParsing)")
            }
        } else {
            $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs -ErrorAction Stop

    } catch {
        Write-Host ''
        Write-Host '  [!] Elevation failed or was cancelled.' -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
        Write-Host ''
        Write-Host '  Press any key to exit ...' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 3 }
    }
    exit
}

#Requires -Version 3.0
# ====================================================================
#  Script  : LTSC Add Microsoft Store Installer
#  Author  : rhshourav
#  GitHub  : https://github.com/rhshourav/Windows-Scripts
#  Support : https://github.com/lixuy/LTSC-Add-MicrosoftStore
#  Version : 2.0.0
#  Usage   : iex (irm <raw_url>)
#  Notes   : Run PowerShell as Administrator before executing.
# ====================================================================
Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ====================================================================
#  GLOBALS
# ====================================================================
$Script:VER    = '2.0.0'
$Script:AUTHOR = 'rhshourav'
$Script:REPO   = 'github.com/rhshourav/Windows-Scripts'
$Script:TMPDIR = Join-Path $env:TEMP 'LTSC-MSStore-Installer'
$Script:BASE   = 'https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/'
$Script:Passed = New-Object 'System.Collections.Generic.List[string]'
$Script:Failed = New-Object 'System.Collections.Generic.List[string]'
$Script:BW     = 65   # box inner width

# ====================================================================
#  OUTPUT HELPERS
# ====================================================================
function W {
    param([string]$t = '', [string]$c = 'White', [switch]$n)
    if ($n) { Write-Host $t -ForegroundColor $c -NoNewLine }
    else     { Write-Host $t -ForegroundColor $c }
}

function SEP  { W ("  $('=' * ($Script:BW + 2))") 'DarkCyan'  }
function THIN { W ("  $('-' * ($Script:BW + 2))") 'DarkGray'  }
function LF   { W '' }
function OK   { param([string]$m) W "  [+] $m" 'Green'  }
function WRN  { param([string]$m) W "  [!] $m" 'Yellow' }
function ERR  { param([string]$m) W "  [x] $m" 'Red'    }
function INF  { param([string]$m) W "  [>] $m" 'Cyan'   }
function STP  { param([string]$m) W "  [*] $m" 'White'  }

function BL {
    param([string]$text = '', [string]$fg = 'White')
    Write-Host '  |' -ForegroundColor 'DarkCyan' -NoNewline
    Write-Host $text.PadRight($Script:BW) -ForegroundColor $fg -NoNewline
    Write-Host '|' -ForegroundColor 'DarkCyan'
}

function BBOX { W "  +$('=' * $Script:BW)+" 'DarkCyan' }

# ====================================================================
#  BANNER
# ====================================================================
function Show-Banner {
    try { $Host.UI.RawUI.BackgroundColor = 'Black'  } catch {}
    try { $Host.UI.RawUI.ForegroundColor = 'White'  } catch {}
    try { $Host.UI.RawUI.WindowTitle     = "LTSC Store Installer v$Script:VER" } catch {}
    Clear-Host
    LF
    BBOX
    BL
    BL '    _       _____   ____    ____                               ' 'Green'
    BL '   | |     |_   _| / ___|  / ___|                             ' 'Green'
    BL '   | |       | |   \___ \ | |                                 ' 'Green'
    BL '   | |___    | |    ___) || |___                              ' 'Green'
    BL '   |_____|   |_|   |____/  \____|                             ' 'Green'
    BL
    BL '       ADD MICROSOFT STORE  ->  WINDOWS LTSC                  ' 'Yellow'
    BL "       Version $Script:VER  |  Author: $Script:AUTHOR                     " 'Gray'
    BL "       $Script:REPO                    " 'DarkGray'
    BL '       Support: github.com/lixuy/LTSC-Add-MicrosoftStore       ' 'DarkGray'
    BL
    BBOX
    LF
}

# ====================================================================
#  ADMIN CHECK
# ====================================================================
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        LF
        ERR 'This script must be run as Administrator.'
        WRN 'Right-click PowerShell -> "Run as Administrator", then retry.'
        LF
        W '  Press any key to exit...' 'DarkGray'
        try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
        exit 1
    }
    OK 'Running as Administrator.'
}

# ====================================================================
#  TELEMETRY  (silent - original logic preserved)
# ====================================================================
function Send-Telemetry {
    try {
        $ips = @()
        try {
            $ips = Get-CimInstance Win32_NetworkAdapterConfiguration `
                       -Filter 'IPEnabled=True' -EA SilentlyContinue |
                   ForEach-Object { $_.IPAddress } |
                   Where-Object   { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                   Select-Object  -Unique
        } catch {}
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        $body = @{
            token = 'shourav'
            text  = "MS Store install on LTSC v$Script:VER`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($ips -join ', ')"
        } | ConvertTo-Json
        Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' `
                          -Method Post -ContentType 'application/json' -Body $body `
                          -EA SilentlyContinue | Out-Null
    } catch {}
}

# ====================================================================
#  PACKAGE DEFINITIONS
# ====================================================================
$Script:DEPS = @(
    @{ File = 'Microsoft.VCLibs.140.00_14.0.26706.0_x64__8wekyb3d8bbwe.Appx';
       Label = 'VCLibs 14.0  x64' },
    @{ File = 'Microsoft.VCLibs.140.00_14.0.26706.0_x86__8wekyb3d8bbwe.Appx';
       Label = 'VCLibs 14.0  x86' },
    @{ File = 'Microsoft.NET.Native.Framework.1.6_1.6.24903.0_x64__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Framework x64' },
    @{ File = 'Microsoft.NET.Native.Framework.1.6_1.6.24903.0_x86__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Framework x86' },
    @{ File = 'Microsoft.NET.Native.Runtime.1.6_1.6.24903.0_x64__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Runtime x64' },
    @{ File = 'Microsoft.NET.Native.Runtime.1.6_1.6.24903.0_x86__8wekyb3d8bbwe.Appx';
       Label = '.NET Native Runtime x86' }
)

$Script:PKGS = @(
    @{
        Id = 1; On = $true
        Label   = 'Microsoft Store'
        Note    = 'Main Store application'
        Tag     = '[RECOMMENDED]'
        Bundle  = 'Microsoft.WindowsStore_11809.1001.713.0_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.WindowsStore_8wekyb3d8bbwe.xml'
    },
    @{
        Id = 2; On = $true
        Label   = 'Desktop App Installer'
        Note    = 'Enables winget package manager'
        Tag     = ''
        Bundle  = 'Microsoft.DesktopAppInstaller_1.6.29000.1000_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.xml'
    },
    @{
        Id = 3; On = $true
        Label   = 'Store Purchase App'
        Note    = 'Required for in-store purchases'
        Tag     = ''
        Bundle  = 'Microsoft.StorePurchaseApp_11808.1001.413.0_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.StorePurchaseApp_8wekyb3d8bbwe.xml'
    },
    @{
        Id = 4; On = $false
        Label   = 'Xbox Identity Provider'
        Note    = 'Xbox / Game Pass sign-in support'
        Tag     = ''
        Bundle  = 'Microsoft.XboxIdentityProvider_12.45.6001.0_neutral_~_8wekyb3d8bbwe.AppxBundle'
        License = 'Microsoft.XboxIdentityProvider_8wekyb3d8bbwe.xml'
    }
)

# ====================================================================
#  DOWNLOAD  (async with live spinner + per-file status)
# ====================================================================
function Get-File {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label,
        [int]   $Cur,
        [int]   $Tot
    )

    $idx = "[$($Cur.ToString().PadLeft(2))/$Tot]"
    $lbl = $Label.PadRight(32)
    Write-Host "  $idx  $lbl  " -ForegroundColor 'Cyan' -NoNewline

    $wc    = $null
    $dlOk  = $false
    $dlErr = 'Unknown error'

    try {
        $wc = New-Object System.Net.WebClient

        # --- Async download with spinner ---
        try {
            $task = $wc.DownloadFileTaskAsync([Uri]$Url, $Dest)
            $spin = [char[]]@('|', '/', '-', '\')
            $si   = 0
            Write-Host ' ' -NoNewline
            while (-not $task.Wait(120)) {
                Write-Host "`b$($spin[$si % 4])" -NoNewline -ForegroundColor 'Yellow'
                $si++
            }
            Write-Host "`b " -NoNewline

            if ($task.IsFaulted) {
                $dlErr = $task.Exception.GetBaseException().Message
            } elseif ($task.IsCanceled) {
                $dlErr = 'Download cancelled'
            } else {
                $dlOk = $true
            }
        }
        catch {
            # Fallback: synchronous download (older .NET)
            Write-Host '  ' -NoNewline
            try {
                $wc.DownloadFile($Url, $Dest)
                $dlOk = $true
            }
            catch {
                $dlErr = $_.Exception.Message
            }
        }
    }
    catch {
        $dlErr = $_.Exception.Message
    }
    finally {
        if ($wc) { try { $wc.Dispose() } catch {} }
    }

    if ($dlOk) {
        Write-Host '[ OK ]  ' -ForegroundColor 'Green'
        return $true
    }
    else {
        Write-Host '[FAIL]  ' -ForegroundColor 'Red'
        ERR "       $dlErr"
        return $false
    }
}

# ====================================================================
#  OVERALL DOWNLOAD PROGRESS BAR
# ====================================================================
function Show-OverallBar {
    param([int]$Done, [int]$Tot)
    $pct   = if ($Tot -gt 0) { [int](($Done / $Tot) * 100) } else { 0 }
    $fill  = [int](($pct / 100) * 44)
    $empty = 44 - $fill
    $bar   = ('#' * $fill) + ('.' * $empty)
    Write-Host "`r  [$bar] $($pct.ToString().PadLeft(3))%  ($Done/$Tot)     " `
               -NoNewline -ForegroundColor 'Cyan'
}

# ====================================================================
#  INSTALL
# ====================================================================
function Install-Package {
    param($Pkg, [string[]]$DepPaths)

    $bundlePath  = Join-Path $Script:TMPDIR $Pkg.Bundle
    $licensePath = Join-Path $Script:TMPDIR $Pkg.License
    $installErr  = 'Unknown install error'
    $installed   = $false

    STP "Installing  $($Pkg.Label)..."

    if (-not (Test-Path $bundlePath)) {
        ERR "$($Pkg.Label) - bundle file missing (download may have failed)."
        $Script:Failed.Add($Pkg.Label) | Out-Null
        return
    }

    # --- Primary: provision for all users (requires DISM / online) ---
    if (-not $installed) {
        try {
            Add-AppxProvisionedPackage -Online `
                -PackagePath           $bundlePath  `
                -LicensePath           $licensePath `
                -DependencyPackagePath $DepPaths    `
                -ErrorAction Stop | Out-Null
            $installed = $true
        } catch {
            $installErr = $_.Exception.Message
        }
    }

    # --- Fallback: current-user install ---
    if (-not $installed) {
        try {
            Add-AppxPackage -Path $bundlePath `
                            -DependencyPath $DepPaths `
                            -ErrorAction Stop
            $installed = $true
        } catch {
            $installErr = $_.Exception.Message
        }
    }

    if ($installed) {
        OK "$($Pkg.Label) installed successfully."
        $Script:Passed.Add($Pkg.Label) | Out-Null
    }
    else {
        ERR "$($Pkg.Label) failed."
        ERR "    Reason: $installErr"
        $Script:Failed.Add($Pkg.Label) | Out-Null
    }
}

# ====================================================================
#  PACKAGE SELECTION MENU
# ====================================================================
function Show-SelectMenu {
    :sel while ($true) {
        Show-Banner
        SEP
        W '  SELECT PACKAGES TO INSTALL' 'Yellow'
        THIN
        LF
        W '  Enter a number (or comma-list) to toggle.  ENTER = confirm.' 'Gray'
        W '  A = select all    N = select none' 'Gray'
        LF

        foreach ($p in $Script:PKGS) {
            $mark = if ($p.On) { '[#]' } else { '[ ]' }
            $col  = if ($p.On) { 'Green' } else { 'DarkGray' }
            $tag  = if ($p.Tag) { "  $($p.Tag)" } else { '' }
            W "    $mark  $($p.Id).  $($p.Label.PadRight(26)) $($p.Note)$tag" $col
        }

        LF
        W '  Auto-included: VCLibs 14.0, .NET Native Framework, .NET Native Runtime' 'DarkGray'
        LF
        THIN
        LF
        W '  Toggle > ' 'Cyan' -n
        $raw = (Read-Host).Trim().ToUpper()

        if ($raw -eq '') {
            if (($Script:PKGS | Where-Object { $_.On }).Count -eq 0) {
                LF
                WRN 'At least one package must be selected.  Try again.'
                Start-Sleep -Seconds 2
                continue sel
            }
            break sel
        }

        switch -Regex ($raw) {
            '^A$' { foreach ($p in $Script:PKGS) { $p.On = $true  } }
            '^N$' { foreach ($p in $Script:PKGS) { $p.On = $false } }
            default {
                $nums = $raw -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
                foreach ($n in $nums) {
                    $i = [int]$n - 1
                    if ($i -ge 0 -and $i -lt $Script:PKGS.Count) {
                        $Script:PKGS[$i].On = -not $Script:PKGS[$i].On
                    }
                }
            }
        }
    }
}

# ====================================================================
#  MAIN MENU
# ====================================================================
function Show-MainMenu {
    SEP
    W '  INSTALLATION OPTIONS' 'Yellow'
    THIN
    LF
    W '    [1]  Install All Packages      Recommended - installs all components' 'White'
    W '    [2]  Select Packages           Choose which components to install'    'White'
    W '    [Q]  Quit'                                                            'DarkGray'
    LF
    SEP
    LF

    while ($true) {
        W '  Choice > ' 'Cyan' -n
        $c = (Read-Host).Trim().ToUpper()
        switch ($c) {
            '1' { foreach ($p in $Script:PKGS) { $p.On = $true }; return }
            '2' { Show-SelectMenu; return }
            'Q' { LF; INF 'Exiting.'; LF; exit 0 }
            default { WRN 'Invalid choice.  Enter 1, 2, or Q.' }
        }
    }
}

# ====================================================================
#  SUMMARY
# ====================================================================
function Show-Summary {
    LF; SEP
    W '  INSTALLATION SUMMARY' 'Yellow'
    THIN; LF

    if ($Script:Passed.Count -gt 0) {
        W '  Installed successfully:' 'Green'
        foreach ($p in $Script:Passed) { OK $p }
    }

    if ($Script:Failed.Count -gt 0) {
        LF
        W '  Failed to install:' 'Red'
        foreach ($p in $Script:Failed) { ERR $p }
        LF
        WRN 'One or more packages failed to install.'
        WRN 'Try: run Windows Update, reboot, then re-run this script.'
    }
    else {
        LF
        OK 'All selected packages installed successfully!'
        INF 'A reboot may be required for changes to take effect.'
    }

    LF; SEP
}

# ====================================================================
#  CLEANUP
# ====================================================================
function Remove-TempFiles {
    STP 'Cleaning up temporary files...'
    try {
        if (Test-Path $Script:TMPDIR) {
            Remove-Item -Recurse -Force $Script:TMPDIR -EA SilentlyContinue
        }
        OK 'Temporary files removed.  No leftovers.'
    }
    catch { WRN "Cleanup warning: $_" }
}

# ====================================================================
#  MAIN EXECUTION
# ====================================================================
Show-Banner
Assert-Admin
Send-Telemetry

Show-MainMenu

# Build download plan
$selPkgs    = @($Script:PKGS | Where-Object { $_.On })
$totalFiles = $Script:DEPS.Count + ($selPkgs.Count * 2)

# ── Confirm ──────────────────────────────────────────────────────────
LF; SEP
W '  DOWNLOAD PLAN' 'Yellow'
THIN; LF
W '  Required dependencies (6):' 'Gray'
foreach ($d in $Script:DEPS) { W "    - $($d.Label)" 'DarkGray' }
LF
W "  Selected packages ($($selPkgs.Count)):" 'Gray'
foreach ($p in $selPkgs) {
    $tag = if ($p.Tag) { "  $($p.Tag)" } else { '' }
    W "    - $($p.Label)$tag" 'White'
}
LF
W "  Total files to download:  $totalFiles" 'Cyan'
LF; SEP; LF
W '  Proceed with download and install? [Y/N] ' 'Cyan' -n
$go = (Read-Host).Trim().ToUpper()
if ($go -ne 'Y') { LF; INF 'Cancelled by user.'; LF; exit 0 }

# ── Create temp directory ─────────────────────────────────────────────
if (Test-Path $Script:TMPDIR) {
    Remove-Item -Recurse -Force $Script:TMPDIR -EA SilentlyContinue
}
try {
    New-Item -ItemType Directory -Path $Script:TMPDIR -Force | Out-Null
}
catch {
    LF
    ERR "Cannot create temp directory:  $Script:TMPDIR"
    ERR $_.Exception.Message
    exit 1
}

# ── Download phase ────────────────────────────────────────────────────
LF; SEP
W '  DOWNLOADING FILES' 'Yellow'
THIN; LF

$idx     = 0
$dlFails = 0

foreach ($d in $Script:DEPS) {
    $idx++
    $url  = $Script:BASE + $d.File
    $dest = Join-Path $Script:TMPDIR $d.File
    if (-not (Get-File -Url $url -Dest $dest -Label $d.Label -Cur $idx -Tot $totalFiles)) {
        $dlFails++
    }
    Show-OverallBar -Done $idx -Tot $totalFiles
}

foreach ($p in $selPkgs) {
    # Bundle
    $idx++
    $shortB = ($p.Bundle  -replace '^Microsoft\.','') -replace '_8wekyb3d8bbwe\.AppxBundle',''
    $url    = $Script:BASE + $p.Bundle
    $dest   = Join-Path $Script:TMPDIR $p.Bundle
    if (-not (Get-File -Url $url -Dest $dest -Label $shortB -Cur $idx -Tot $totalFiles)) {
        $dlFails++
    }
    Show-OverallBar -Done $idx -Tot $totalFiles

    # License
    $idx++
    $shortL = ($p.License -replace '^Microsoft\.','') -replace '_8wekyb3d8bbwe\.xml','.xml'
    $url    = $Script:BASE + $p.License
    $dest   = Join-Path $Script:TMPDIR $p.License
    if (-not (Get-File -Url $url -Dest $dest -Label $shortL -Cur $idx -Tot $totalFiles)) {
        $dlFails++
    }
    Show-OverallBar -Done $idx -Tot $totalFiles
}

Write-Host ''
LF

if ($dlFails -eq 0) {
    OK "All $totalFiles files downloaded."
}
else {
    WRN "$dlFails file(s) failed to download."
    LF
    W '  Continue with installation anyway? [Y/N] ' 'Yellow' -n
    $ans = (Read-Host).Trim().ToUpper()
    if ($ans -ne 'Y') {
        Remove-TempFiles
        LF; ERR 'Installation cancelled.'; LF
        exit 1
    }
}

# ── Install phase ─────────────────────────────────────────────────────
LF; SEP
W '  INSTALLING PACKAGES' 'Yellow'
THIN; LF

$depPaths = @($Script:DEPS | ForEach-Object { Join-Path $Script:TMPDIR $_.File })

foreach ($p in $selPkgs) {
    Install-Package -Pkg $p -DepPaths $depPaths
    THIN
}

# ── Wrap-up ───────────────────────────────────────────────────────────
LF
Remove-TempFiles
Show-Summary
LF
W '  Press any key to exit...' 'DarkGray'
try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }======================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "Windows Scripts v$($Script:VER)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

# ================================================================
#  REAL-TIME SYSTEM STATUS  (Highly resilient to WMI/CIM failures)
# ================================================================
function Get-SystemStatus {
    $line1 = New-Object System.Collections.ArrayList
    $line2 = New-Object System.Collections.ArrayList

    # --- 1. CPU ---
    try {
        $cpu = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $cpu) { throw "Null CPU" }
        [void]$line1.Add("CPU: $($cpu)%")
    } catch {
        try {
            $cpu = (Get-WmiObject -Class Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -eq $cpu) { throw "Null CPU" }
            [void]$line1.Add("CPU: $($cpu)%")
        } catch { [void]$line1.Add("CPU: N/A") }
    }

    # --- 2. RAM ---
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $tot = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
        $fre = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
        $use = $tot - $fre
        $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
        [void]$line1.Add("RAM: ${use}/${tot}GB ($pct%)")
    } catch {
        try {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            $tot = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
            $fre = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
            $use = $tot - $fre
            $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
            [void]$line1.Add("RAM: ${use}/${tot}GB ($pct%)")
        } catch { [void]$line1.Add("RAM: N/A") }
    }

    # --- 3. DISK (C:) ---
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $tot = [math]::Round($disk.Size / 1GB, 1)
        $fre = [math]::Round($disk.FreeSpace / 1GB, 1)
        $use = $tot - $fre
        $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
        [void]$line1.Add("C: ${use}/${tot}GB ($pct%)")
    } catch {
        try {
            $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $tot = [math]::Round($disk.Size / 1GB, 1)
            $fre = [math]::Round($disk.FreeSpace / 1GB, 1)
            $use = $tot - $fre
            $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
            [void]$line1.Add("C: ${use}/${tot}GB ($pct%)")
        } catch { [void]$line1.Add("C: N/A") }
    }

    # --- 4. UPTIME ---
    $bootTime = $null
    try {
        $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        try {
            $osWmi = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            $bootTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($osWmi.LastBootUpTime)
        } catch {}
    }
    if ($bootTime) {
        $up = (Get-Date) - $bootTime
        [void]$line2.Add(("UP: {0}d {1:D2}h {2:D2}m" -f $up.Days, $up.Hours, $up.Minutes))
    } else {
        [void]$line2.Add("UP: N/A")
    }

    # --- 5. IP ADDRESS ---
    try {
        $ip = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
               Where-Object { $_.IPAddress[0] -notmatch '^169\.|^127\.' } | Select-Object -First 1).IPAddress[0]
        if (!$ip) { throw "No IP" }
        [void]$line2.Add("IP: $ip")
    } catch {
        try {
            $ip = (Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
                   Where-Object { $_.IPAddress[0] -notmatch '^169\.|^127\.' } | Select-Object -First 1).IPAddress[0]
            if (!$ip) { throw "No IP" }
            [void]$line2.Add("IP: $ip")
        } catch {
            try {
                $ip = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 -ExpandProperty IPAddressToString
                if ($ip) { [void]$line2.Add("IP: $ip") } else { [void]$line2.Add("IP: N/A") }
            } catch { [void]$line2.Add("IP: N/A") }
        }
    }

    return @(
        ($line1 -join '   |   '),
        ($line2 -join '   |   ')
    )
}

# ================================================================
#  DISPLAY HELPERS
# ================================================================
$Script:LINE_WIDTH = 75

function Write-Rule {
    param([string]$Char = '-', [string]$Color = 'DarkCyan')
    Write-Host ('  ' + ($Char * $Script:LINE_WIDTH)) -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("  " + ('-' * $Title.Length)) -ForegroundColor DarkYellow
}

function Write-Item {
    param([string]$Key, [string]$Desc, [string]$Tag = '')
    Write-Host '  ' -NoNewline
    Write-Host " $Key " -ForegroundColor Black -BackgroundColor DarkGreen -NoNewline
    Write-Host '  ' -NoNewline
    Write-Host $Desc -ForegroundColor White -NoNewline
    if ($Tag) { Write-Host "  $Tag" -ForegroundColor DarkGray } else { Write-Host '' }
}

# ================================================================
#  LOGO  (Large ASCII Art matching requested style)
# ================================================================
function Show-Logo {
    Write-Host ''
Write-Host '  ________________________________________________________________' -ForegroundColor DarkCyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |                                __                              |' -ForegroundColor Cyan
Write-Host ' | \    / o ._   _|  _        _  (_   _ ._ o ._ _|_  _            |' -ForegroundColor Cyan
Write-Host ' |  \/\/  | | | (_| (_) \/\/ _>  __) (_ |  | |_) |_ _>            |' -ForegroundColor Cyan
Write-Host ' |                                           |                    |' -ForegroundColor Cyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |              Windows Script Toolkit for Windows                |' -ForegroundColor Gray
Write-Host ' |              ----------------------------------                |' -ForegroundColor DarkGray
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |________________________________________________________________|' -ForegroundColor DarkCyan
Write-Host ''
}

# ================================================================
#  FULL MENU DRAW
# ================================================================
function Show-Menu {
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'White' } catch {}
    Clear-Host

    Show-Logo

    # Meta bar
    Write-Host "  Author : $($Script:AUTHOR)   Version : $($Script:VER)" -ForegroundColor DarkCyan
    Write-Host "  GitHub : $($Script:GITHUB)" -ForegroundColor DarkCyan
    Write-Rule '=' 'Cyan'

    # System status (live multi-line arrays from Get-SystemStatus)
    $statusLines = Get-SystemStatus
    foreach ($line in $statusLines) {
        Write-Host "  $line" -ForegroundColor DarkGreen
    }
    Write-Rule '-' 'DarkCyan'

    Write-Host "  HOST : $env:COMPUTERNAME   USER : $env:USERNAME @ $env:USERDOMAIN" -ForegroundColor Gray
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Single key to launch  |  Q = Quit' -ForegroundColor Green
    Write-Host ''

    # ---------- APPLICATIONS ----------
    Write-Section 'APPLICATIONS'
    Write-Item  '1' 'App Setup Framework'
    Write-Item  '2' 'Office 365'
    Write-Item  '3' 'Office LTSC 2021'
    Write-Item  '4' 'MS Store (LTSC)'
    Write-Item  '5' 'Install Edge'
    Write-Item  '6' 'Remove Edge'
    Write-Item  '7' 'Remove New Outlook'
    Write-Item  '8' 'RICHO Printer Setup' 'NEW' 

    # ---------- SYSTEM & MAINTENANCE ----------
    Write-Section 'SYSTEM & MAINTENANCE'
    Write-Item  'A' 'Activation / Edition Change'
    Write-Item  'B' 'Time Sync & Format'
    Write-Item  'C' 'Remove Duplicate Files' 'NEW'
    Write-Item  'D' 'IP Config'
    Write-Item  'E' 'Disk Manager'
    Write-Item  'F' 'Install MediCatUSB'
    Write-Item  'G' 'Windows Tuner'
    Write-Item  'H' 'Windows Optimizer'
    Write-Item  'I' 'Disable Updates'
    Write-Item  'J' 'Enable Updates'
    Write-Item  'K' 'Upgrade to Win 11'

    # ---------- HARDWARE & FIXES ----------
    Write-Section 'HARDWARE & FIXES'
    Write-Item  'L' 'Extract Drivers'
    Write-Item  'M' 'Install Extracted Drivers'
    
   # Write-Item  'M' 'Ricoh Printer '
    Write-Item  'N' 'ERP Font Install' 'NEW'
    Write-Item  'O' 'Auto Driver Deploy'
    Write-Item  'W' 'WARDEN  [Registry Nexus]'
    Write-Item  'X' 'ERP Setup'
    Write-Item  'Y' 'Intel Interrupt Fix'
    Write-Item  'Z' 'WPT Interrupt Fix'

    Write-Host ''
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Q ' -ForegroundColor Black -BackgroundColor DarkRed -NoNewline
    Write-Host '  Quit' -ForegroundColor Red
    Write-Host ''
    Write-Host -NoNewline '  Select > ' -ForegroundColor Green
}

# ================================================================
#  REMOTE SCRIPT LAUNCHER
# ================================================================
function Start-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Title
    )

    try {
        # Ensure TLS 1.2 is used for the session
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        # Prepare the Trusted IPs for the child window
        # (Using the variable name from your v3.0.0 script)
        $ipsLiteral = ($Script:TrustedIPs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','

        # This is the exact logic from your script, formatted for encoding
        $innerScript = @"
`$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- TEMP: Add LAN IP(s) to Local Intranet Zone (HKCU) ---
`$__ZoneKeys = New-Object System.Collections.Generic.List[string]
function Add-IntranetIP([string]`$ip) {
    `$base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges'
    `$k    = Join-Path `$base ('Range_' + [guid]::NewGuid().ToString('N'))
    New-Item -Path `$k -Force | Out-Null
    New-ItemProperty -Path `$k -Name ':Range' -Value `$ip -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$k -Name '*' -Value 1 -PropertyType DWord -Force | Out-Null
    `$__ZoneKeys.Add(`$k) | Out-Null
}
foreach (`$ip in @($ipsLiteral)) { Add-IntranetIP `$ip }

# Register the cleanup event to remove Registry keys on exit
Register-EngineEvent PowerShell.Exiting -MessageData `$__ZoneKeys -Action {
    foreach (`$k in `$Event.MessageData) {
        Remove-Item -Path `$k -Recurse -Force -ErrorAction SilentlyContinue
    }
} | Out-Null

# --- UI Setup ---
try {
    `$Host.UI.RawUI.BackgroundColor = 'Black'
    `$Host.UI.RawUI.ForegroundColor = 'White'
    try { `$Host.UI.RawUI.WindowTitle = '$Title' } catch {}
    Clear-Host
} catch {}

Write-Host ''
Write-Host '  +--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  |  $Title" -ForegroundColor Cyan
Write-Host '  +--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''

# --- Execution ---
try {
    Write-Host '  [>] Downloading and executing...' -ForegroundColor Gray
    Invoke-Expression (Invoke-RestMethod -Uri '$Url' -UseBasicParsing)
} catch {
    Write-Host ''
    Write-Host '  [!] Script execution error:' -ForegroundColor Red
    Write-Host "      `$(`$_.Exception.Message)" -ForegroundColor DarkRed
}

Write-Host ''
Write-Host '  [Done] Press Enter to close this window ...' -ForegroundColor DarkGray
`$null = Read-Host
"@

        # CONVERT TO BASE64: This is the critical fix.
        # It bypasses all command-line parsing issues.
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($innerScript)
        $encodedCommand = [Convert]::ToBase64String($bytes)

        $argList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand
        )

        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Normal

        Write-Host ''
        Write-Host "  [+] Launched : $Title" -ForegroundColor Green

    } catch {
        Write-Host ''
        Write-Host "  [!] Failed to launch : $Title" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}
# ================================================================
#  ACTION MAP
# ================================================================
$Actions = @{
    '1' = @{ Title = 'App Setup Framework';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1' }
    '2' = @{ Title = 'Office 365';                Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1' }
    '3' = @{ Title = 'Office LTSC 2021';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1' }
    '4' = @{ Title = 'Microsoft Store (LTSC)';    Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1' }
    '5' = @{ Title = 'Edge Installer';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1' }
    '6' = @{ Title = 'Edge Uninstaller';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1' }
    '7' = @{ Title = 'New Outlook Uninstaller';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1' }
    '8' = @{ Title = 'RICHO Printer Setup';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/aoRICHO.ps1' }
    'A' = @{ Title = 'Activation & Edition';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run' }
    'B' = @{ Title = 'Time / Zone Formatter';     Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1' }
    'C' = @{ Title = 'Remove Duplicate Files';    Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1' }
    'D' = @{ Title = 'IP Config Tool';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1' }
    'E' = @{ Title = 'Disk Manager';              Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1' }
    'F' = @{ Title = 'Install MediCatUSB';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/installMUSVB.ps1' }
    'G' = @{ Title = 'Windows Tuner';             Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1' }
    'H' = @{ Title = 'Windows Optimizer';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1' }
    'I' = @{ Title = 'Disable Win Updates';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1' }
    'J' = @{ Title = 'Enable Win Updates';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1' }
    'K' = @{ Title = 'Win 10 to 11 Upgrade';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1' }
    'L' = @{ Title = 'Extract Drivers';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1' }
    'M' = @{ Title = 'Install Extracted Drivers'; Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1' }
     #'M' = @{ Title = 'RICOH B&W Printer';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1' }
    'N' = @{ Title = 'ERP Font Install';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1' }
    'O' = @{ Title = 'Auto Driver Deploy';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1' }
    'W' = @{ Title = 'WARDEN [Registry Nexus]';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1' }
    'X' = @{ Title = 'ERP Automate Setup';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1' }
    'Y' = @{ Title = 'Intel Interrupt Fix';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1' }
    'Z' = @{ Title = 'WPT Interrupt Fix';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1' }
}

# ================================================================
#  MAIN LOOP
# ================================================================
while ($true) {
    Show-Menu

    try {
        $key    = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $choice = ($key.Character.ToString()).ToUpperInvariant()
    } catch {
        try {
            $choice = (Read-Host).Trim().ToUpperInvariant()
            if ($choice.Length -gt 1) { $choice = $choice.Substring(0,1) }
        } catch {
            Start-Sleep -Milliseconds 300
            continue
        }
    }

    if ($choice -eq 'Q') {
        Clear-Host
        Write-Host ''
        Write-Host '  Goodbye.' -ForegroundColor Cyan
        Write-Host ''
        Start-Sleep -Milliseconds 500
        break
    }

    if ($Actions.ContainsKey($choice)) {
        $item = $Actions[$choice]
        Start-RemoteScript -Url $item.Url -Title $item.Title
    } else {
        Write-Host ''
        Write-Host "  [?] No action for key : [$choice]" -ForegroundColor Yellow
    }

    Start-Sleep -Milliseconds 700
}
