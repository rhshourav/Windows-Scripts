<#
.SYNOPSIS
    Hardware-Aware optimization profile

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    1.0.0
#>

Write-Host "Applying Hardware-Aware optimizations..." -ForegroundColor Cyan
Write-Log "Applying Hardware-Aware profile"

# Detect CPU cores
$cpuCores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
Write-Log "Detected CPU cores: $cpuCores"

# RAM
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Write-Log "Detected RAM: $ramGB GB"

# Disk type
$disks = Get-PhysicalDisk | Select FriendlyName, MediaType
foreach ($disk in $disks) { Write-Log "Disk: $($disk.FriendlyName), Type: $($disk.MediaType)" }

# Apply safe VisualFX reduction
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Type DWord -Value 2 -Force
Write-Log "VisualFX set to best performance"

# Adjust services based on RAM (low RAM -> disable more background services)
$services = @("MapsBroker","Fax","RetailDemo")
if ($ramGB -lt 8) { $services += "RemoteRegistry","SharedAccess" }

foreach ($svc in $services) {
    try { Get-Service $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled; Write-Log "Service disabled: $svc" }
    catch { Write-Log "Failed to disable $svc: $_" "WARN" }
}

Write-Host "Hardware-Aware optimizations complete." -ForegroundColor Green
Write-Log "Hardware-Aware profile optimization complete"
