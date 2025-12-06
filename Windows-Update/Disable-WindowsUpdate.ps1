# ============================================================
# Full Windows Update Disable Script (PowerShell)
# Works on Windows 10 / 11
# Requires Administrator Privileges
# Created By rhshourav V1.0 (PS Conversion)
# ============================================================

# =======================
# Check for Administrator
# =======================
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "This script requires administrative privileges."
    Write-Host "Requesting elevation..."
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host ""
Write-Host "============================================="
Write-Host " Disabling Windows Update completely..."
Write-Host "============================================="
Write-Host ""

# =======================
# 1. Stop and Disable Services
# =======================
$services = @(
    "wuauserv",
    "bits",
    "dosvc",
    "WaaSMedicSvc",
    "UsoSvc"
)

foreach ($service in $services) {
    Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
    Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
}

# =======================
# 2. Registry Tweaks
# =======================
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$AUPath = "$WUPath\AU"

New-Item -Path $AUPath -Force | Out-Null

Set-ItemProperty -Path $AUPath -Name NoAutoUpdate -Type DWord -Value 1
Set-ItemProperty -Path $AUPath -Name AUOptions -Type DWord -Value 1

Set-ItemProperty -Path $WUPath -Name DoNotConnectToWindowsUpdateInternetLocations -Type DWord -Value 1
Set-ItemProperty -Path $WUPath -Name DisableOSUpgrade -Type DWord -Value 1
Set-ItemProperty -Path $WUPath -Name ExcludeWUDriversInQualityUpdate -Type DWord -Value 1

# Disable Windows Update Medic Service Repair
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" `
    -Name Start `
    -Type DWord `
    -Value 4

# =======================
# 3. Disable Scheduled Tasks
# =======================
$tasks = @(
    "\Microsoft\Windows\WindowsUpdate\Scheduled Start",
    "\Microsoft\Windows\WindowsUpdate\Automatic App Update",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan",
    "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker",
    "\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask",
    "\Microsoft\Windows\UpdateOrchestrator\Reboot"
)

foreach ($task in $tasks) {
    schtasks /Change /TN $task /Disable 2>$null
}

# =======================
# 4. Firewall Block (Optional – commented)
# =======================
<# 
New-NetFirewallRule `
    -DisplayName "Block Windows Update" `
    -Direction Outbound `
    -Action Block `
    -RemoteAddress "13.107.4.50","13.107.5.50"
#>

Write-Host ""
Write-Host "✅ Windows Update has been disabled from Services, Registry, and Tasks."
Write-Host ""

# =======================
# 5. Ask for Reboot
# =======================
$choice = Read-Host "Do you want to reboot now? (Y/N)"
if ($choice -match "^[Yy]$") {
    Write-Host "Rebooting system..."
    Restart-Computer -Force
} else {
    Write-Host "Skipped reboot. Please restart manually to apply changes."
}

Pause
