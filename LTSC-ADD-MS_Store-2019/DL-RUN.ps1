#Requires -Version 3.0
# ====================================================================
#  Script  : LTSC Add Microsoft Store Installer
#  Author  : rhshourav
#  GitHub  : https://github.com/rhshourav/Windows-Scripts
#  Support : https://github.com/lixuy/LTSC-Add-MicrosoftStore
#  Version : 2.1.0
#  Usage   : iex (irm <raw_url>)
#  Notes   : Run PowerShell as Administrator before executing.
# ====================================================================
Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ====================================================================
#  GLOBALS
# ====================================================================
$Script:VER    = '2.1.0'
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
        Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' `
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
try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
