# ============================================
# Windows Optimizer
# Version : 3.1.0
# Author  : Shourav
# GitHub  : https://github.com/rhshourav
# ============================================

# -------------------------
# GLOBAL PATHS
# -------------------------
$BaseDir = "$env:TEMP\WindowsOptimizer"
$LogDir  = "$BaseDir\logs"
$SnapDir = "$BaseDir\snapshots"
$LogFile = "$LogDir\optimizer.log"

New-Item -ItemType Directory -Force -Path $LogDir, $SnapDir | Out-Null

# -------------------------
# LOGGING
# -------------------------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogFile -Value $line

    switch ($Level) {
        "INFO"   { Write-Host $line -ForegroundColor Cyan }
        "ACTION" { Write-Host $line -ForegroundColor Green }
        "WARN"   { Write-Host $line -ForegroundColor Yellow }
        "ERROR"  { Write-Host $line -ForegroundColor Red }
        default  { Write-Host $line }
    }
}

# -------------------------
# ADMIN CHECK
# -------------------------
# -------------------------
# ADMIN CHECK (IRM | IEX SAFE)
# -------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {

    Write-Host ""
    Write-Host "Administrator privileges are required." -ForegroundColor Yellow
    Write-Host "The script will now relaunch with elevation." -ForegroundColor Yellow
    Write-Host ""

    $TempDir = "$env:TEMP\WindowsOptimizer"
    $ScriptPath = "$TempDir\Windows-Optimizer.ps1"
    $ScriptUrl  = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/Windows-Optimizer.ps1"

    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $ScriptPath -UseBasicParsing
    }
    catch {
        Write-Host "Failed to download script. Aborting." -ForegroundColor Red
        exit 1
    }

    Start-Process powershell `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
        -Verb RunAs

    Write-Host "Elevated instance launched. You may close this window." -ForegroundColor Green
    exit
}

Write-Log "Windows Optimizer started" "INFO"

# -------------------------
# SNAPSHOT
# -------------------------
function Save-Snapshot {
    $file = "$SnapDir\snapshot-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
    Get-Service | Select Name, Status, StartType | Out-File $file
    Write-Log "System snapshot saved: $file" "ACTION"
}

Save-Snapshot

# -------------------------
# TELEMETRY NOTICE
# -------------------------
function Show-TelemetryNotice {
    Write-Host ""
    Write-Host "Telemetry is ENABLED." -ForegroundColor Yellow
    Write-Host "Collected: Username, Computer Name, Selected Profile." -ForegroundColor Yellow
    Write-Host "Purpose: Usage analytics and script improvement." -ForegroundColor Yellow
    Write-Host ""
}

Show-TelemetryNotice

# -------------------------
# OPTIMIZATION PROFILES
# -------------------------
function Level1_Balanced {
    Write-Log "Applying Level 1 - Balanced optimizations" "ACTION"
    Set-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
        -Name "ShowSyncProviderNotifications" -Value 0 -Force
}

function Level2_Performance {
    Write-Log "Applying Level 2 - Performance optimizations" "ACTION"
    Stop-Service "SysMain" -Force -ErrorAction SilentlyContinue
    Set-Service "SysMain" -StartupType Disabled
}

function Level3_Aggressive {
    Write-Log "Applying Level 3 - Aggressive optimizations" "ACTION"
    Stop-Service "DiagTrack" -Force -ErrorAction SilentlyContinue
    Set-Service "DiagTrack" -StartupType Disabled
}

function Gaming_Profile {
    Write-Log "Applying Gaming optimizations" "ACTION"
    powercfg -setactive SCHEME_MIN
}

function Hardware_Aware {
    Write-Log "Applying Hardware-Aware optimizations" "ACTION"
    powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
}

# -------------------------
# BLOATWARE REMOVAL
# -------------------------
function Remove-Bloatware {
    Write-Log "Removing optional Microsoft bloatware" "ACTION"

    $apps = @(
        "Microsoft.XboxApp",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Microsoft.BingNews",
        "Microsoft.GetHelp",
        "Microsoft.MicrosoftSolitaireCollection"
    )

    foreach ($app in $apps) {
        Get-AppxPackage -Name $app -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
        Write-Log "Removed $app" "INFO"
    }
}

# -------------------------
# MENU
# -------------------------
Write-Host ""
Write-Host "Select Optimization Profile:"
Write-Host "1. Level 1 - Balanced"
Write-Host "2. Level 2 - Performance"
Write-Host "3. Level 3 - Aggressive"
Write-Host "4. Gaming"
Write-Host "5. Hardware-Aware"
Write-Host "6. Remove Bloatware Only"
Write-Host ""

$choice = Read-Host "Enter choice"

switch ($choice) {
    "1" { Level1_Balanced }
    "2" { Level2_Performance }
    "3" { Level3_Aggressive }
    "4" { Gaming_Profile }
    "5" { Hardware_Aware }
    "6" { Remove-Bloatware }
    default { Write-Log "Invalid selection" "ERROR" }
}

Write-Log "Execution completed" "INFO"
