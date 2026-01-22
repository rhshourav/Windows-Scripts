# ==========================================================
# INTEL SYSTEM INTERRUPTS AUTO FIX TOOL
# Safe | Automated | Factory Ready | PowerShell Native
# Version: 1.0.5 CLEAN (sandbox + encoding aware)
# ==========================================================

# -----------------------------
# ADMIN CHECK
# -----------------------------
$winIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$winPrincipal = New-Object Security.Principal.WindowsPrincipal($winIdentity)
if (-not $winPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this script as Administrator"
    exit 1
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

# -----------------------------
# GLOBALS
# -----------------------------
$ErrorActionPreference = "SilentlyContinue"
$Log = "$env:SystemDrive\SystemInterruptFix.log"
Start-Transcript -Path $Log -Append | Out-Null

function Step($Msg,$Pct) {
    Write-Progress -Activity "System Interrupt Optimization" -Status $Msg -PercentComplete $Pct
}

function Test-PowercfgAvailable {
    & powercfg /? 2>$null
    return ($LASTEXITCODE -eq 0)
}

# -----------------------------
# CPU CHECK
# -----------------------------
Step "Detecting CPU vendor" 5
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu.Manufacturer -notmatch "Intel") {
    Write-Warning "Non-Intel CPU detected. Exiting safely."
    Stop-Transcript
    exit 0
}

# -----------------------------
# INTERRUPT COUNTER (SAFE)
# -----------------------------
Step "Measuring baseline interrupt time" 10
$baseInterrupt = "N/A"
$ctr = Get-Counter '\Processor(_Total)\% Interrupt Time' -ErrorAction SilentlyContinue
if ($ctr -and $ctr.CounterSamples.Count -gt 0) {
    $val = $ctr.CounterSamples[0].CookedValue
    if ($val -gt 0) { $baseInterrupt = [math]::Round($val,2) }
}

# -----------------------------
# SYSMAIN
# -----------------------------
Step "Evaluating SysMain" 20
$hasHDD = Get-PhysicalDisk | Where-Object MediaType -eq "HDD"
if (-not $hasHDD) {
    Stop-Service SysMain -Force
    Set-Service SysMain -StartupType Disabled
}

# -----------------------------
# NETWORK
# -----------------------------
Step "Optimizing network adapters" 35
Get-NetAdapter | Where-Object Status -eq "Up" | ForEach-Object {
    Disable-NetAdapterPowerManagement -Name $_.Name -WakeOnMagicPacket -WakeOnPattern -NoRestart
    if ($_.InterfaceDescription -notmatch "Wireless") {
        Set-NetAdapterRss -Name $_.Name -Enabled $true
    }
}

# -----------------------------
# POWER SETTINGS (SANDBOX SAFE)
# -----------------------------
Step "Applying power optimizations" 55
$PowercfgOK = Test-PowercfgAvailable
if ($PowercfgOK) {
    powercfg -SETACVALUEINDEX SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0 | Out-Null
    powercfg -SETDCVALUEINDEX SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0 | Out-Null
    powercfg /setactive SCHEME_MIN | Out-Null
} else {
    Write-Warning "powercfg is restricted in this environment. Power optimizations skipped."
}

# -----------------------------
# CLEANUP
# -----------------------------
Step "Cleaning temp files" 75
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Clear-DnsClientCache | Out-Null

# -----------------------------
# FINAL INTERRUPTS
# -----------------------------
Step "Measuring final interrupt time" 90
$finalInterrupt = "N/A"
$ctr = Get-Counter '\Processor(_Total)\% Interrupt Time' -ErrorAction SilentlyContinue
if ($ctr -and $ctr.CounterSamples.Count -gt 0) {
    $val = $ctr.CounterSamples[0].CookedValue
    if ($val -gt 0) { $finalInterrupt = [math]::Round($val,2) }
}

Write-Progress -Completed -Activity "System Interrupt Optimization"

# -----------------------------
# RESULTS
# -----------------------------
Write-Host ""
Write-Host "============= RESULTS =============" -ForegroundColor Cyan
Write-Host ("Interrupt Time : {0} -> {1}" -f $baseInterrupt, $finalInterrupt)
Write-Host "SysMain        : Adaptive"
Write-Host "NIC Power      : Optimized"
Write-Host "USB Suspend    : Applied if supported"
Write-Host "Power Profile  : High Performance if supported"
Write-Host "==================================="

Write-Host ""
Write-Host "Reboot recommended." -ForegroundColor Yellow

Stop-Transcript
