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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUclEMp+HWt0aoQrRNCaXK3bN+
# FHSgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBR+irx5xVsEGDUgOVrCRIlPnGpuLjANBgkq
# hkiG9w0BAQEFAASCAQCi8AvmMDA01mEXz0HIRjNUy23/9Rm8g0uOcEJOXSi27i2c
# geqetvBQiFIgKgxE3e4XEZgHpny/z4Wh8TKpvHgGSN7IoQBwRUa05TQBmgT0MAOn
# qAFpugV80JcypINWPXu/A6V33+P1yyN/w9yLm85DnlgoFNtUlETmBqWERb03RYM8
# c1sGwVMVWS7re0SH9LboyN1mGFP4VmKFBCDqdTPpSKJrRMBAzw+9AYM5cyotzmn4
# dba5xCeiP8/BTfuEMgq6WTFGWpUzUj0nQDiPuCQ4aEBWkVwxeLXtcaEPvKbb+Oow
# bdTG2deKkBcaDsO6mm0GtjmvNUQscF9GrX2ZdmuJoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0N1owLwYJKoZIhvcNAQkEMSIEIN0w0/gB0j8mG9M7
# q3ZptZOt7zATO9ungOEl7wOVEEICMA0GCSqGSIb3DQEBAQUABIICAHTmbRP22hpb
# Anh8MduIFlm1QKC3Z1SRRCz2dCQmqlAv+ABZYSIAyv+fi7nkoxWh+MBIjP3VzOlR
# OYZDTTZxH3gT0ZjCXcTu9cAfwWokLDJb+v/xc0GQ4w+2gKIcWlUuYGvt7ype/vN4
# fw3O3vdOr0tQJRH9WD9iGukIRPia5QAjv0XYUuAytftZAsfOaeii8SGfmyKXFUDr
# Ixsv82JEEo4BOIz54taHtqRA0BQn+GtZfpVlUFLaCuSKNizkoeHI6W1oE4TUrImn
# zDFsZ0fehOE1h4EElvxNGKpQ57XLQxkmjp2gska/PU373jamwRQIKbZ1BRlXrJbO
# Lvn91FJh+MytgiaBwt19dAU7fEMbSulRhKE8OJSiSmXdwShXKb3g4ORiMZTExWxz
# x2NWnvFp75t71nAeZ/nqsZ74QG17kPxDizpJ1N3q3FE/Ge72MpXAvtAh6lIVhwFH
# bEwr2fsnHNSuEuxZ5NxkJadpSCgqU6uHoKaXev/6tmpcca3nuSXmx5GB2TF8mmk4
# DIzWk3IWUVA4v/4IYs2A/qu+8cgB/2GEHg6TvQL3TQ+CRkKUPx7DIzQhr8ayfjP9
# hmdN5789CX4BR7ysaiBL9medOOjXpTv9rlOHZ/DWefbHiiWJFrzmhYvEYjYAfQP5
# b6mQyi8vFJYn2YSnDne+POj1lDifSWcC
# SIG # End signature block
