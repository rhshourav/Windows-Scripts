<#
.SYNOPSIS
    Level 3 – Aggressive optimization profile

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    1.0.0
#>

Write-Host "Applying Level 3 – Aggressive optimizations..." -ForegroundColor Cyan
Write-Log "Applying Level 3 – Aggressive"

# VisualFX
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
                 -Name "VisualFXSetting" -Type DWord -Value 2 -Force
Write-Log "VisualFX set to best performance"

# Disable search indexing
Stop-Service WSearch -Force
Set-Service WSearch -StartupType Disabled
Write-Log "Search indexing disabled"

# Disable telemetry
$TelemetryServices = @("DiagTrack","dmwappushservice")
foreach ($svc in $TelemetryServices) {
    try {
        Get-Service $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled
        Write-Log "Telemetry service disabled: $svc"
    }
    catch { Write-Log "Failed to disable telemetry service $svc: $_" "WARN" }
}

# Disable background services
$services = @("MapsBroker","Fax","RetailDemo","RemoteRegistry","SharedAccess","WerSvc")
foreach ($svc in $services) {
    try {
        Get-Service $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled
        Write-Log "Service disabled: $svc"
    }
    catch { Write-Log "Failed to disable $svc: $_" "WARN" }
}

# Disable Windows Game DVR
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Type DWord -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Type DWord -Value 0 -Force
Write-Log "GameDVR disabled"

Write-Host "Level 3 – Aggressive complete." -ForegroundColor Green
Write-Log "Level 3 – Aggressive optimization complete"
