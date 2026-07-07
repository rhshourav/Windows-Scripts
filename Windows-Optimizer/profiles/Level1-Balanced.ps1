
<#
.SYNOPSIS
    Level 1 – Balanced optimization profile

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    1.0.0
#>

Write-Host "Applying Level 1 – Balanced optimizations..." -ForegroundColor Cyan
Write-Log "Applying Level 1 – Balanced"

# Set Visual Effects to best performance
try {
    Set-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
        -Name "VisualFXSetting" -Type DWord -Value 2 -Force
    Write-Log "Visual effects set to best performance"
}
catch { Write-Log "Failed to set VisualFX: $_" "WARN" }

# Disable minor unnecessary services
$services = @("MapsBroker","Fax","RetailDemo")
foreach ($svc in $services) {
    try {
        Get-Service $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled
        Write-Log "Service disabled: $svc"
    }
    catch { Write-Log "Failed to disable $svc: $_" "WARN" }
}

Write-Host "Level 1 – Balanced complete." -ForegroundColor Green
Write-Log "Level 1 – Balanced optimization complete"
