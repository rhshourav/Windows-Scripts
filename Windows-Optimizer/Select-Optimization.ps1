<#
.SYNOPSIS
    Windows Optimizer – Main Selector

.AUTHOR
    Shourav (rhshoruav)

.VERSION
    1.0.0
#>

# -------------------------------
# Metadata
# -------------------------------
$ScriptVersion = "1.0.0"
$AuthorName    = "MD Shourav Hossain"
$GitHubUser    = "rhshoruav"
$ProjectName   = "Windows Optimizer"

# -------------------------------
# Admin Check
# -------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Exit 1
}

# -------------------------------
# Resolve Root Path
# -------------------------------
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# -------------------------------
# Load Core Modules
# -------------------------------
. "$Root\core\Logger.ps1"
. "$Root\core\Snapshot.ps1"
. "$Root\core\Telemetry.ps1"

# -------------------------------
# Banner
# -------------------------------
function Show-Banner {
    Clear-Host
    Write-Host "============================================"
    Write-Host " $ProjectName"
    Write-Host "============================================"
    Write-Host " Version : $ScriptVersion"
    Write-Host " Author  : $AuthorName"
    Write-Host " GitHub  : https://github.com/$GitHubUser"
    Write-Host "============================================"
    Write-Host ""
}

Show-Banner
Write-Log "Started $ProjectName v$ScriptVersion by $AuthorName"

# -------------------------------
# Snapshot
# -------------------------------
try {
    Save-Snapshot
}
catch {
    Write-Log "Snapshot failed: $_" "ERROR"
    Write-Host "Snapshot failed. Aborting to prevent irreversible changes." -ForegroundColor Red
    Exit 1
}

# -------------------------------
# Telemetry Notice
# -------------------------------
Show-TelemetryNotice

# -------------------------------
# Menu
# -------------------------------
Write-Host "Select Optimization Profile:"
Write-Host ""
Write-Host "1. Level 1 – Balanced"
Write-Host "2. Level 2 – Performance"
Write-Host "3. Level 3 – Aggressive"
Write-Host "4. Gaming"
Write-Host "5. Hardware-Aware"
Write-Host "6. Restore from Snapshot"
Write-Host ""

$choice = Read-Host "Enter your choice"

switch ($choice) {
    "1" {
        . "$Root\profiles\Level1-Balanced.ps1"
        Send-Telemetry -ProfileName "Level 1 – Balanced"
    }
    "2" {
        . "$Root\profiles\Level2-Performance.ps1"
        Send-Telemetry -ProfileName "Level 2 – Performance"
    }
    "3" {
        . "$Root\profiles\Level3-Aggressive.ps1"
        Send-Telemetry -ProfileName "Level 3 – Aggressive"
    }
    "4" {
        . "$Root\profiles\Gaming.ps1"
        Send-Telemetry -ProfileName "Gaming"
    }
    "5" {
        . "$Root\profiles\Hardware-Aware.ps1"
        Send-Telemetry -ProfileName "Hardware-Aware"
    }
    "6" {
        . "$Root\core\Restore.ps1"
    }
    default {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        Write-Log "Invalid menu selection: $choice" "WARN"
    }
}

Write-Log "Execution completed"
