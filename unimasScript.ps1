<#
  Windows Scripts - Main Menu Launcher
  Author : rhshourav
  GitHub : https://github.com/rhshourav/Windows-Scripts
  Notes  : Auto-elevates once, menu uses single key press (no Enter),
           launches selected remote scripts in NEW PowerShell windows.

           Integrated: TEMP "Open File - Security Warning" mitigation for UNC EXEs
           from \\192.168.18.201\it\... by temporarily adding the IP to
           Local Intranet zone for the lifetime of each launched window.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Configure: LAN host(s) to treat as Local Intranet (TEMP per launched window)
# -----------------------------
$TrustedIntranetIPs = @(
  '192.168.18.201'
)

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
function Write-Section {
    param([string]$Title)
    Write-Host "`n--- $Title ---" -ForegroundColor Yellow
}

function Write-Item {
    param([string]$Key, [string]$Description)
    Write-Host "  $Key) " -NoNewline -ForegroundColor Green
    Write-Host $Description
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
    Write-Host "Author: rhshourav | GitHub: Windows-Scripts | Version: 1.5.1" -ForegroundColor DarkCyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Press a key (no Enter).  Q = Quit" -ForegroundColor Green
    Write-Host ""
}

function Show-Menu {
     Write-Header
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
    Write-Host ""
    Write-Host "  Q) Quit" -ForegroundColor Red
    Write-Host ""
    Write-Host -NoNewline "Select: " -ForegroundColor Green
}

# -----------------------------
# Remote launcher (new window) + TEMP intranet trust for LAN share
# -----------------------------
function Start-RemoteScriptInNewAdminWindow {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Title
    )

    try {
        # Use TLS 1.2 on older Win10 builds
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        # Build a literal array for the child window (e.g. '192.168.18.201','x.x.x.x')
        $ipsLiteral = ($TrustedIntranetIPs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','

        $cmd = @"
`$ErrorActionPreference='Stop';

# ===== TEMP: Add LAN IP(s) to Local Intranet Zone (HKCU) for this window lifetime =====
`$__TempZoneKeys = New-Object System.Collections.Generic.List[string]

function Add-IntranetIp([string]`$ip) {
  `$base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges'
  `$k = Join-Path `$base ('Range_' + [guid]::NewGuid().ToString('N'))
  New-Item -Path `$k -Force | Out-Null
  New-ItemProperty -Path `$k -Name ':Range' -Value `$ip -PropertyType String -Force | Out-Null
  New-ItemProperty -Path `$k -Name '*'      -Value 1   -PropertyType DWord  -Force | Out-Null  # 1 = Local intranet
  [void]`$__TempZoneKeys.Add(`$k)
}

foreach(`$ip in @($ipsLiteral)) { Add-IntranetIp `$ip }

Register-EngineEvent PowerShell.Exiting -MessageData @(`$__TempZoneKeys) -Action {
  foreach(`$k in `$Event.MessageData) {
    Remove-Item -Path `$k -Recurse -Force -ErrorAction SilentlyContinue
  }
} | Out-Null
# =====================================================================================

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

        # You already elevated the menu once. Don’t trigger UAC again per selection.
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList | Out-Null

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
