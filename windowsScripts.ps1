<#
  Windows Scripts - Main Menu Launcher
  Author : rhshourav
  GitHub : https://github.com/rhshourav/Windows-Scripts
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Auto-elevate
# -----------------------------
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsAdmin)) {
    Write-Host "[!] Not running as Administrator. Relaunching..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# -----------------------------
# UI Elements
# -----------------------------
function Show-Logo {
    Clear-Host
    Write-Host @"
 __        ___                 _                ____            _   _       
 \ \      / (_)_ __   __| | _____      _____  / ___|  ___ _ __(_)_ __ | |_ ___ 
  \ \ /\ / /| | '_ \ / _` |/ _ \ \ /\ / / __| \___ \ / __| '__| | '_ \| __/ __|
   \ V  V / | | | | | (_| | (_) \ V  V /\__ \  ___) | (__| |  | | |_) | |_\__ \
    \_/\_/  |_|_| |_|\__,_|\___/ \_/\_/ |___/ |____/ \___|_|  |_| .__/ \__|___/
                                                                |_|            
"@ -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n--- $Title ---" -ForegroundColor Yellow
}

function Write-Item {
    param([string]$Key, [string]$Description)
    Write-Host "  $Key) " -NoNewline -ForegroundColor Green
    Write-Host $Description
}

# -----------------------------
# Remote launcher
# -----------------------------
function Start-RemoteScript {
    param([string]$Url, [string]$Title)
    try {
        $cmd = "`$ErrorActionPreference='Stop'; Write-Host '=== $Title ===' -ForegroundColor Cyan; iex (irm '$Url' -UseBasicParsing);"
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-Command", $cmd)
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList | Out-Null
        Write-Host "`n[+] Launched: $Title" -ForegroundColor Green
    } catch {
        Write-Host "`n[!] Error launching $Title" -ForegroundColor Red
    }
}

# -----------------------------
# Action Mapping
# -----------------------------
$Actions = @{
    # App Setup
    '1' = @{ Title="App Setup Framework"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1" }
    '2' = @{ Title="Office 365 Install"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1" }
    '3' = @{ Title="Office LTSC 2021"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1" }
    '4' = @{ Title="Microsoft Store (LTSC)"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1" }
    '5' = @{ Title="Edge Installer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1"}
    
    # Uninstalls
    '6' = @{ Title="Edge Uninstaller"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1"}
    '7' = @{ Title="New Outlook Uninstaller"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1" }
    
    # System Tools
    'A' = @{ Title="Activation & Edition"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run" }
    'B' = @{ Title="Time/Zone Formatter"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1" }
    'C' = @{ Title="IP Config Tool"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1"}
    'D' = @{ Title="Disk Manager"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1" }
    'E' = @{ Title="Install MediCatUSB"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/Run-MediCat.ps1" }

    # Maintenance & Optimization
    'F' = @{ Title="Windows Tuner"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1" }
    'G' = @{ Title="Windows Optimizer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1" }
    'H' = @{ Title="Disable Win Update"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1" }
    'I' = @{ Title="Enable Win Update"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1" }
    'J' = @{ Title="Win 10 to 11 Upgrade"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1" }

    # Drivers & Printer
    'K' = @{ Title="Extract Drivers"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1"}
    'L' = @{ Title="Install Extracted Drivers"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1"}
    'M' = @{ Title="RICOH B&W Printer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1" }
    'N' = @{ Title="RICOH Color Printer"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addColorRICHO.ps1" }
    
    # Fixes
    'X' = @{ Title="ERP Automate Setup"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1" }
    'Y' = @{ Title="Intel Interrupt Fix"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1" }
    'Z' = @{ Title="WPT Interrupt Fix"; Url="https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1" }
}

# -----------------------------
# Main Loop
# -----------------------------
while ($true) {
    Show-Logo
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   rhshourav Windows-Scripts Launcher | Version 1.5.0" -ForegroundColor DarkCyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Write-Section "APPLICATIONS"
    Write-Item "1" "App Setup Framework"
    Write-Item "2" "Office 365"
    Write-Item "3" "Office LTSC 2021"
    Write-Item "4" "MS Store (LTSC)"
    Write-Item "5" "Install Edge"
    Write-Item "6" "Remove Edge"
    Write-Item "7" "Remove New Outlook"

    Write-Section "SYSTEM & MAINTENANCE"
    Write-Item "A" "Activation / Edition Change"
    Write-Item "B" "Time Sync & Format"
    Write-Item "C" "IP Config"
    Write-Item "D" "Disk Manager"
    Write-Item "E" "Install MediCatUSB (New)"
    Write-Item "F" "Windows Tuner"
    Write-Item "G" "Windows Optimizer"
    Write-Item "H" "Disable Updates"
    Write-Item "I" "Enable Updates"
    Write-Item "J" "Upgrade to Win 11"

    Write-Section "HARDWARE & FIXES"
    Write-Item "K" "Extract Drivers"
    Write-Item "L" "Install Drivers"
    Write-Item "M" "Ricoh B&W"
    Write-Item "N" "Ricoh Color"
    Write-Item "X" "ERP Setup"
    Write-Item "Y" "Intel Interrupt Fix"
    Write-Item "Z" "WPT Interrupt Fix"

    Write-Host "`n  Q) Quit" -ForegroundColor Red
    Write-Host -NoNewline "`nSelect an option: " -ForegroundColor Green

    $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    $choice = ($k.Character.ToString()).ToUpperInvariant()

    if ($choice -eq 'Q') { break }

    if ($Actions.ContainsKey($choice)) {
        $item = $Actions[$choice]
        Start-RemoteScript -Url $item.Url -Title $item.Title
    } else {
        Write-Host "`n[!] Invalid: $choice" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}
