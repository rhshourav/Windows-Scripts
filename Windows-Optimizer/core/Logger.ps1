<#
.SYNOPSIS
    Core Logger module for Windows Optimizer

.AUTHOR
    Shourav (rhshoruav)

.VERSION
    1.1.0
#>

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp][$Level] $Message"

    # Output to console
    switch ($Level) {
        "INFO" { Write-Host $logLine -ForegroundColor Green }
        "WARN" { Write-Host $logLine -ForegroundColor Yellow }
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
    }

    # Output to log file
    $logFile = Join-Path $env:TEMP "WindowsOptimizer\logs\WindowsOptimizer.log"
    Add-Content -Path $logFile -Value $logLine
}
