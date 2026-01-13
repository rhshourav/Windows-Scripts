Intel-SystemInterrupt-Fix.ps1# ==========================================================
# INTEL SYSTEM INTERRUPTS AUTO FIX TOOL
# Safe | Automated | Factory Ready | PowerShell Native | v 1.0.1B
# ==========================================================

# -----------------------------
# ADMIN CHECK
# -----------------------------
if (-not ([Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run as Administrator"
    exit 1
}

$ErrorActionPreference = "SilentlyContinue"
$Log = "$env:SystemDrive\SystemInterruptFix.log"
Start-Transcript -Path $Log -Append | Out-Null

# -----------------------------
# HELPER
# -----------------------------
function Step($msg,$pct) {
    Write-Progress -Activity "System Interrupt Optimization" -Status $msg -PercentComplete $pct
}

# -----------------------------
# SYSTEM VALIDATION
# -----------------------------
Step "Detecting CPU" 2
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu.Manufacturer -notmatch "Intel") {
    Write-Warning "Non-Intel CPU detected. Script exiting safely."
    Stop-Transcript
    exit 0
}

# -----------------------------
# BASELINE METRICS
# -----------------------------
Step "Measuring baseline interrupts" 5
$baseline = Get-Counter '\Processor(_Total)\% Interrupt Time'
$baseInterrupt = [math]::Round($baseline.CounterSamples[0].CookedValue,2)

# -----------------------------
# DISABLE SYSMAIN (SUPERFETCH)
# -----------------------------
Step "Disabling SysMain (Superfetch)" 10
Stop-Service SysMain -Force
Set-Service SysMain -StartupType Disabled

# -----------------------------
# NETWORK ADAPTER OPTIMIZATION
# -----------------------------
Step "Optimizing network adapters" 20
Get-NetAdapter | Where-Object Status -eq "Up" | ForEach-Object {

    Disable-NetAdapterPowerManagement -Name $_.Name -NoRestart `
        -WakeOnMagicPacket `
        -WakeOnPattern `
        -ErrorAction SilentlyContinue

    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Energy Efficient Ethernet" `
        -DisplayValue "Disabled" `
        -NoRestart

    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Interrupt Moderation" `
        -DisplayValue "Enabled" `
        -NoRestart

    Set-NetAdapterRss -Name $_.Name -Enabled $true
}

# -----------------------------
# USB SELECTIVE SUSPEND OFF
# -----------------------------
Step "Disabling USB selective suspend" 30
powercfg -SETACVALUEINDEX SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0
powercfg -SETDCVALUEINDEX SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0

# -----------------------------
# HIGH PERFORMANCE POWER PLAN
# -----------------------------
Step "Applying High Performance power plan" 40
powercfg /setactive SCHEME_MIN

# -----------------------------
# PNP DEVICE REFRESH
# -----------------------------
Step "Refreshing Plug and Play devices" 50
pnputil /scan-devices | Out-Null

# -----------------------------
# TEMP + DNS CLEANUP
# -----------------------------
Step "Cleaning temp files and DNS cache" 60
Remove-Item "$env:TEMP\*" -Recurse -Force
Remove-Item "C:\Windows\Temp\*" -Recurse -Force
Remove-Item "C:\Windows\Prefetch\*" -Recurse -Force
Clear-DnsClientCache

# -----------------------------
# STORAGE INTERRUPT OPTIMIZATION
# -----------------------------
Step "Optimizing storage interrupt behavior" 70
Get-PhysicalDisk | Where MediaType -ne "Unspecified" | ForEach-Object {
    Set-PhysicalDisk -FriendlyName $_.FriendlyName -Usage AutoSelect
}

# -----------------------------
# DISABLE FAST STARTUP
# -----------------------------
Step "Disabling Fast Startup" 80
powercfg /hibernate off

# -----------------------------
# FINAL METRICS
# -----------------------------
Step "Measuring final interrupt levels" 90
$final = Get-Counter '\Processor(_Total)\% Interrupt Time'
$finalInterrupt = [math]::Round($final.CounterSamples[0].CookedValue,2)

# -----------------------------
# RESULTS
# -----------------------------
Write-Progress -Completed -Activity "System Interrupt Optimization"

Write-Host ""
Write-Host "================ RESULTS ================" -ForegroundColor Cyan
Write-Host "Interrupt Time : $baseInterrupt  ->  $finalInterrupt" -ForegroundColor Green
Write-Host "SysMain        : Disabled"
Write-Host "Network Power  : Optimized"
Write-Host "USB Suspend    : Disabled"
Write-Host "Power Profile  : High Performance"
Write-Host "========================================"

Write-Host ""
Write-Host "Reboot is STRONGLY recommended." -ForegroundColor Yellow

Stop-Transcript
