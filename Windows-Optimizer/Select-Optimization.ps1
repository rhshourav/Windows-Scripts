<#
.SYNOPSIS
    Windows Optimizer Orchestrator (Lazy-Loading, IRM/IEX ready, Auto-Elevate)

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    2.3.0
#>

# -------------------------------
# Directories
# -------------------------------
$ScriptRoot  = Join-Path $env:TEMP "WindowsOptimizer"
$CoreDir     = Join-Path $ScriptRoot "core"
$ProfilesDir = Join-Path $ScriptRoot "profiles"
$LogsDir     = Join-Path $ScriptRoot "logs"
$SnapDir     = Join-Path $ScriptRoot "snapshots"

# Ensure directories exist
$null = New-Item -ItemType Directory -Force -Path $ScriptRoot,$CoreDir,$ProfilesDir,$LogsDir,$SnapDir

$ScriptFile = Join-Path $ScriptRoot "Select-Optimization.ps1"

# -------------------------------
# Auto-elevate to Administrator
# -------------------------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "Restarting script as Administrator..." -ForegroundColor Yellow
    if ($MyInvocation.ScriptName -eq "") {
        # Running via IRM/IEX: download self
        Invoke-RestMethod "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/Select-Optimization.ps1" -UseBasicParsing | Set-Content $ScriptFile
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptFile`""
    $psi.Verb = "runas"
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Failed to elevate." -ForegroundColor Red }
    Exit
}

# -------------------------------
# Metadata
# -------------------------------
$ScriptVersion = "2.3.0"
$AuthorName    = "Shourav"
$GitHubUser    = "rhshoruav"
$ProjectName   = "Windows Optimizer"

# -------------------------------
# Core Module Loader
# -------------------------------
function Load-CoreModule {
    param([string]$ModuleName)
    $file = Join-Path $CoreDir $ModuleName
    if (-not (Test-Path $file)) {
        try {
            Invoke-RestMethod "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/core/$ModuleName" -UseBasicParsing | Set-Content $file
        } catch {
            Write-Host "Failed to download $ModuleName. Check network or GitHub URL." -ForegroundColor Red
            Exit 1
        }
    }
    try { . $file } catch { Write-Host "Failed to load $ModuleName" -ForegroundColor Red; Exit 1 }
}

# -------------------------------
# Profile Loader
# -------------------------------
function Load-Profile {
    param([string]$ProfileName)
    $file = Join-Path $ProfilesDir $ProfileName
    if (-not (Test-Path $file)) {
        try {
            Invoke-RestMethod "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/profiles/$ProfileName" -UseBasicParsing | Set-Content $file
        } catch {
            Write-Host "Failed to download profile $ProfileName" -ForegroundColor Red
            Exit 1
        }
    }
    try { . $file } catch { Write-Host "Failed to load profile $ProfileName" -ForegroundColor Red; Exit 1 }
}

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

# -------------------------------
# Load Core Modules in Safe Order
# -------------------------------
Load-CoreModule "Logger.ps1"           # Write-Log available
Load-CoreModule "Telemetry.ps1"        # Show-TelemetryNotice / Send-Telemetry
Load-CoreModule "Snapshot.ps1"         # Save-Snapshot / Restore-Snapshot

# -------------------------------
# Initial Logging & Snapshot
# -------------------------------
Write-Log "Windows Optimizer started"

try { Save-Snapshot } catch { Write-Log "Snapshot failed: $_" "ERROR"; Exit 1 }

Show-TelemetryNotice

# -------------------------------
# Menu
# -------------------------------
Write-Host "Select Optimization Profile:"
Write-Host ""
Write-Host "1. Level 1 - Balanced"
Write-Host "2. Level 2 - Performance"
Write-Host "3. Level 3 - Aggressive"
Write-Host "4. Gaming"
Write-Host "5. Hardware-Aware"
Write-Host "6. Restore from Snapshot"
Write-Host ""

$choice = Read-Host "Enter your choice"

switch ($choice) {
    "1" {
        Load-Profile "Level1-Balanced.ps1"
        Send-Telemetry -ProfileName "Level 1 - Balanced"
    }
    "2" {
        Load-Profile "Level2-Performance.ps1"
        Send-Telemetry -ProfileName "Level 2 - Performance"
    }
    "3" {
        Load-Profile "Level3-Aggressive.ps1"
        Send-Telemetry -ProfileName "Level 3 - Aggressive"
    }
    "4" {
        Load-Profile "Gaming.ps1"
        Send-Telemetry -ProfileName "Gaming"
    }
    "5" {
        Load-Profile "Hardware-Aware.ps1"
        Send-Telemetry -ProfileName "Hardware-Aware"
    }
    "6" {
        Load-CoreModule "Restore.ps1"
        Restore-Snapshot
    }
    default {
        Write-Host "Invalid selection." -ForegroundColor Yellow
        Write-Log "Invalid menu selection: $choice" "WARN"
    }
}

Write-Log "Execution completed"
