
<#
.SYNOPSIS
    Level 2 – Performance optimization profile

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    1.0.0
#>

Write-Host "Applying Level 2 – Performance optimizations..." -ForegroundColor Cyan
Write-Log "Applying Level 2 – Performance"

# VisualFX
try {
    Set-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
        -Name "VisualFXSetting" -Type DWord -Value 2 -Force
    Write-Log "Visual effects set to best performance"
}
catch { Write-Log "Failed to set VisualFX: $_" "WARN" }

# Disable search indexing (big performance gain)
try {
    Stop-Service WSearch -Force
    Set-Service WSearch -StartupType Disabled
    Write-Log "Search indexing service disabled"
}
catch { Write-Log "Failed to disable WSearch: $_" "WARN" }

# Disable more background services
$services = @("MapsBroker","Fax","RetailDemo","RemoteRegistry","WerSvc")
foreach ($svc in $services) {
    try {
        Get-Service $svc -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled
        Write-Log "Service disabled: $svc"
    }
    catch { Write-Log "Failed to disable $svc: $_" "WARN" }
}

Write-Host "Level 2 – Performance complete." -ForegroundColor Green
Write-Log "Level 2 – Performance optimization complete"
