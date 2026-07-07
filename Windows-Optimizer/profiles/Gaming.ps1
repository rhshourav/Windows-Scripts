<#
.SYNOPSIS
    Gaming optimization profile

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    1.0.0
#>

Write-Host "Applying Gaming optimizations..." -ForegroundColor Cyan
Write-Log "Applying Gaming profile"

# Disable Game DVR
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Type DWord -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Type DWord -Value 0 -Force
Write-Log "GameDVR disabled"

# Disable minor background services
$services = @("MapsBroker","Fax","RetailDemo")
foreach ($svc in $services) {
    try { Get-Service $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled; Write-Log "Service disabled: $svc" }
    catch { Write-Log "Failed to disable $svc: $_" "WARN" }
}

# VisualFX performance
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Type DWord -Value 2 -Force
Write-Log "VisualFX set to best performance"

Write-Host "Gaming optimizations complete." -ForegroundColor Green
Write-Log "Gaming profile optimization complete"
