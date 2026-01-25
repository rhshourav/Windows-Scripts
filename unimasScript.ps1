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
 _   _       _                     
| | | |_ __ (_)_ __ ___   __ _ ___ 
| | | | '_ \| | '_ ` _ \ / _` / __|
| |_| | | | | | | | | | | (_| \__ \
 \___/|_| |_|_|_| |_| |_|\__,_|___/

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
    Write-Host "Author: rhshourav | GitHub: Windows-Scripts | Version: 1.4.0" -ForegroundColor DarkCyan
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
    Write-Host "  6) MS Edge Uninstaller"
    Write-Host "  7) MS Edge Installer"
    Write-Host ""
    Write-Host "ERP Auto Setup:" -ForegroundColor Yellow
    Write-Host "  8) ERP Setup"
    Write-Host "  9) ERP Font Setup"
    Write-Host ""
    Write-Host "Time & IP Setup:" -ForegroundColor Yellow
    Write-Host " A) Time Sync & Format For All Users"
    Write-Host " B) IP Config"
    Write-Host ""
    Write-Host "Printer Setup:" -ForegroundColor Yellow
    Write-Host "  C) RICHO B&W"
    Write-Host "  D) RICHO Color"
    Write-Host ""
    Write-Host "Other:" -ForegroundColor Yellow
    Write-Host "  E) Active & Change Edition"
    Write-Host "  F) Extract Drivers"
    Write-Host "  G) Install Extracted Drivers"
    Write-Host "  H) Fix Windows Photo Invalid Registry Value"
    Write-Host ""
    Write-Host "Windows Optimization:" -ForegroundColor Yellow
    Write-Host "  I) Windows Tuner"
    Write-Host "  J) Windows Optimizer"
    Write-Host ""
    Write-Host "Windows Update:" -ForegroundColor Yellow
    Write-Host "  K) Disable Windows Update"
    Write-Host "  L) Enable Windows Update"
    Write-Host "  M) Upgrade Windows 10 to 11"
    Write-Host ""
    Write-Host "Windows System Interrupt Fix:" -ForegroundColor Yellow
    Write-Host "  N) Intel System Interrupt Fix"
    Write-Host "  O) WPT Interrupt Fix"
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
    '6' = @{ Title="MS Edge Uninstaller"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1"}
    '7' = @{ Title="MS Edge Installer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1"}

    '8' = @{ Title="ERP Setup"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1" }
    '9' = @{ Title="ERP Font Setup"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1" }

    'A' = @{ Title="Time Sync & Format For All Users"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1" }
    'B' = @{ Title="IP Config"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1"}

    'C' = @{ Title="RICHO B&W"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1" }
    'D' = @{ Title="RICHO Color"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addColorRICHO.ps1" }

    'E' = @{ Title="Active & Change Edition"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run" }
    'F' = @{Title="Extract Drivers"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1"}
    'G' = @{Title="Install Extracted Drivers"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1"}
    'H' = @{Title="Fix Windows Photo Invalid Registry Value"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Photo-Invalid-Reg-Value/winPhotoInvalidRegFix.ps1"}

    'I' = @{ Title="Windows Tuner"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1" }
    'J' = @{ Title="Windows Optimizer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1" }

    'K' = @{ Title="Disable Windows Update"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1" }
    'L' = @{ Title="Enable Windows Update"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1" }
    'M' = @{ Title="Upgrade Windows 10 to 11"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1" }

    'N' = @{ Title="Intel System Interrupt Fix"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1" }
    'O' = @{ Title="WPT Interrupt Fix"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1" }
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
