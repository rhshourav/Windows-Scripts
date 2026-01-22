<#
  Windows Scripts - Main Menu Launcher
  Author : rhshourav
  GitHub : https://github.com/rhshourav/Windows-Scripts
  Notes  : Auto-elevates once, menu uses single key press (no Enter),
           launches selected remote scripts in NEW elevated PowerShell windows.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Auto-elevate (once)
# -----------------------------
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsAdmin)) {
    Write-Host "[!] Not running as Administrator. Relaunching elevated..." -ForegroundColor Yellow
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    Start-Process -FilePath "powershell.exe" -ArgumentList $args -Verb RunAs | Out-Null
    exit
}

# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

function Show-Logo {
    Write-Host @"
__        ___           _                     ____            _       _       
\ \      / (_)_ __   __| | _____      _____  / ___|  ___ _ __(_)_ __ | |_ ___ 
 \ \ /\ / /| | '_ \ / _` |/ _ \ \ /\ / / __| \___ \ / __| '__| | '_ \| __/ __|
  \ V  V / | | | | | (_| | (_) \ V  V /\__ \  ___) | (__| |  | | |_) | |_\__ \
   \_/\_/  |_|_| |_|\__,_|\___/ \_/\_/ |___/ |____/ \___|_|  |_| .__/ \__|___/
                                                                |_|            

"@ -ForegroundColor Cyan
}


function Write-Header {
    Clear-Host
try {
        $Host.UI.RawUI.BackgroundColor = 'Black'
        $Host.UI.RawUI.ForegroundColor = 'White'
    } catch {}
    Clear-Host

    Show-Logo
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "                    Windows Scripts (Menu)" -ForegroundColor Cyan
    Write-Host "Author: rhshourav | GitHub: Windows-Scripts | Version: 1.3.0" -ForegroundColor DarkCyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Press a key (no Enter).  Q = Quit" -ForegroundColor Green
    Write-Host ""
}

function Show-Menu {
    Write-Header
    Write-Host "App Setup:" -ForegroundColor Yellow
    Write-Host "  1) App Setup"
    Write-Host "  2) Office 365 Install"
    Write-Host "  3) Office LTSC 2021 Install"
    Write-Host "  4) Microsoft Store For LTSC"
    Write-Host "  5) New Outlook Uninstaller"
    Write-Host ""
    Write-Host "ERP Auto Setup:" -ForegroundColor Yellow
    Write-Host "  6) ERP Setup"
    Write-Host "  7) ERP Font Setup"
    Write-Host ""
    Write-Host "Time Setup:" -ForegroundColor Yellow
    Write-Host " 8) Time Sync & Format For All Users"
    Write-Host ""
    Write-Host "Printer Setup:" -ForegroundColor Yellow
    Write-Host "  9) RICHO B&W"
    Write-Host "  A) RICHO Color"
    Write-Host ""
    Write-Host "Other:" -ForegroundColor Yellow
    Write-Host "  B) Active & Change Edition"
    Write-Host ""
    Write-Host "Windows Optimization:" -ForegroundColor Yellow
    Write-Host "  C) Windows Tuner"
    Write-Host "  D) Windows Optimizer"
    Write-Host ""
    Write-Host "Windows Update:" -ForegroundColor Yellow
    Write-Host "  E) Disable Windows Update"
    Write-Host "  F) Enable Windows Update"
    Write-Host "  G) Upgrade Windows 10 to 11"
    Write-Host ""
    Write-Host "Windows System Interrupt Fix:" -ForegroundColor Yellow
    Write-Host "  H) Intel System Interrupt Fix"
    Write-Host "  I) WPT Interrupt Fix"
    Write-Host ""
    Write-Host "  Q) Quit" -ForegroundColor Red
    Write-Host ""
    Write-Host -NoNewline "Select: " -ForegroundColor Green
}

# -----------------------------
# Remote launcher (new elevated window)
# -----------------------------
function Start-RemoteScriptInNewAdminWindow {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Title
    )

    try {
        # Use TLS 1.2 on older Win10 builds
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        $cmd = @"
`$ErrorActionPreference='Stop';
try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {}
Write-Host '=== $Title ===' -ForegroundColor Cyan;
iex (irm '$Url' -UseBasicParsing);
"@

        $argList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-NoExit",
            "-Command", $cmd
        )

        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList | Out-Null
        Write-Host "`n[+] Launched: $Title" -ForegroundColor Green
    }
    catch {
        Write-Host "`n[!] Failed to launch: $Title" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

# -----------------------------
# Menu map (easy to extend)
# -----------------------------
$Actions = @{
    '1' = @{ Title="App Setup"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1" }
    '2' = @{ Title="Office 365 Install"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1" }
    '3' = @{ Title="Office LTSC 2021 Install"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1" }
    '4' = @{ Title="Microsoft Store For LTSC"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1" }
    '5' = @{ Title="New Outlook Uninstaller"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1" }

    '6' = @{ Title="ERP Setup"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1" }
    '7' = @{ Title="ERP Font Setup"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1" }

    '8' = @{ Title="Time Sync & Format For All Users"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1"

    '9' = @{ Title="RICHO B&W"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1" }
    'A' = @{ Title="RICHO Color"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addColorRICHO.ps1" }

    'B' = @{ Title="Active & Change Edition"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run" }

    'C' = @{ Title="Windows Tuner"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1" }
    'D' = @{ Title="Windows Optimizer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1" }

    'E' = @{ Title="Disable Windows Update"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1" }
    'F' = @{ Title="Enable Windows Update"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1" }
    'G' = @{ Title="Upgrade Windows 10 to 11"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1" }

    'H' = @{ Title="Intel System Interrupt Fix"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1" }
    'I' = @{ Title="WPT Interrupt Fix"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1" }
}

# -----------------------------
# Main loop
# -----------------------------
while ($true) {
    Show-Menu

    $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    $choice = ($k.Character.ToString()).ToUpperInvariant()

    if ($choice -eq 'Q') { break }

    if ($Actions.ContainsKey($choice)) {
        $item = $Actions[$choice]
        Start-RemoteScriptInNewAdminWindow -Url $item.Url -Title $item.Title
    }
    else {
        Write-Host "`n[!] Invalid selection: $choice" -ForegroundColor Yellow
    }

    Start-Sleep -Milliseconds 700
}
