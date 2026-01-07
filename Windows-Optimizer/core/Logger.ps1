<#
.SYNOPSIS
    Core Logger module for Windows Optimizer

.AUTHOR
    Shourav (rhshoruav)

.VERSION
    1.0.0
#>

# -------------------------------
# Create Logs Folder
# -------------------------------
$Global:LogDir = "$PSScriptRoot\..\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

$Global:LogFile = Join-Path $LogDir ("log_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
    Add-Content -Path $Global:LogFile -Value $entry
}
