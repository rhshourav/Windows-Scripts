<#
============================================
 Windows Optimizer
============================================
 Version : 2.5.0
 Author  : Shourav
 GitHub  : https://github.com/rhshourav
============================================
#>

# ==========================================================
# Auto Elevate
# ==========================================================
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    Start-Process powershell `
        "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/Windows-Optimizer.ps1 | iex`"" `
        -Verb RunAs
    exit
}

# ==========================================================
# Paths
# ==========================================================
$Root = Join-Path $env:TEMP "WindowsOptimizer"
$LogDir = Join-Path $Root "logs"
$SnapDir = Join-Path $Root "snapshots"

New-Item -ItemType Directory -Force -Path $Root,$LogDir,$SnapDir | Out-Null
$LogFile = Join-Path $LogDir "optimizer.log"

# ==========================================================
# Logging
# ==========================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] $Level="INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content $LogFile $line

    switch ($Level) {
        "INFO"  { Write-Host $line -ForegroundColor Green }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
    }
}

# ==========================================================
# Telemetry
# ==========================================================
function Show-TelemetryNotice {
    Write-Host ""
    Write-Host "Telemetry is ENABLED by default." -ForegroundColor Cyan
    Write-Host "Data collected:" -ForegroundColor Cyan
    Write-Host "- Username, Computer Name, Profile Applied"
    Write-Host "- No files, no browsing data, no credentials"
    Write-Host ""
}

function Send-Telemetry {
    param([string]$Profile)
    try {
        $body = @{
            token = "shourav"
            text  = "Windows Optimizer`nProfile: $Profile`nUser: $env:USERNAME`nPC: $env:COMPUTERNAME"
        } | ConvertTo-Json

        Invoke-RestMethod `
            -Uri "https://cryocore.rhshourav02.workers.dev/message" `
            -Method POST `
            -ContentType "application/json" `
            -Body $body | Out-Null
    } catch {
        Write-Log "Telemetry send failed" "WARN"
    }
}

# ==========================================================
# Snapshot
# ==========================================================
function Save-Snapshot {
    $file = Join-Path $SnapDir "snapshot-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
    Get-Service | Select Name,Status,StartType | Out-File $file
    Write-Log "Snapshot saved: $file"
}

function Restore-Snapshot {
    Write-Host "Snapshot restore is a placeholder." -ForegroundColor Cyan
    Write-Log "Restore requested (not fully implemented)" "WARN"
}

# ==========================================================
# Optimization Profiles
# ==========================================================
function Level1-Balanced {
    Write-Log "Applying Level 1 - Balanced"
    Set-ItemProperty `
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
        VisualFXSetting 1
}

function Level2-Performance {
    Write-Log "Applying Level 2 - Performance"
    $services = "SysMain","DiagTrack","XblGameSave"
    foreach ($s in $services) {
        try {
            Stop-Service $s -Force -ErrorAction SilentlyContinue
            Set-Service $s -StartupType Disabled
            Write-Log "Disabled service: $s"
        } catch {}
    }
}

function Level3-Aggressive {
    Write-Log "Applying Level 3 - Aggressive"
    $services = "SysMain","DiagTrack","XblGameSave","PrintSpooler","WSearch"
    foreach ($s in $services) {
        try {
            Stop-Service $s -Force -ErrorAction SilentlyContinue
            Set-Service $s -StartupType Disabled
            Write-Log "Aggressively disabled: $s"
        } catch {}
    }
}

function Gaming-Profile {
    Write-Log "Applying Gaming Profile"
    powercfg /setactive SCHEME_MIN
    Set-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" `
        NetworkThrottlingIndex -Value 0xffffffff
}

function Hardware-Aware {
    Write-Log "Applying Hardware-Aware Optimization"
    $cpu = (Get-CimInstance Win32_Processor).Name
    Write-Log "Detected CPU: $cpu"
    powercfg /setactive SCHEME_MIN
}

# ==========================================================
# UI
# ==========================================================
Clear-Host
Write-Host "============================================"
Write-Host " Windows Optimizer"
Write-Host " Version : 2.5.0"
Write-Host " Author  : Shourav"
Write-Host "============================================"

Show-TelemetryNotice
Save-Snapshot

Write-Host ""
Write-Host "1. Level 1 - Balanced"
Write-Host "2. Level 2 - Performance"
Write-Host "3. Level 3 - Aggressive"
Write-Host "4. Gaming"
Write-Host "5. Hardware-Aware"
Write-Host "6. Restore Snapshot"
Write-Host ""

$choice = Read-Host "Select option"

switch ($choice) {
    "1" { Level1-Balanced; Send-Telemetry "Level 1 - Balanced" }
    "2" { Level2-Performance; Send-Telemetry "Level 2 - Performance" }
    "3" { Level3-Aggressive; Send-Telemetry "Level 3 - Aggressive" }
    "4" { Gaming-Profile; Send-Telemetry "Gaming" }
    "5" { Hardware-Aware; Send-Telemetry "Hardware-Aware" }
    "6" { Restore-Snapshot }
    default { Write-Log "Invalid selection" "WARN" }
}

Write-Log "Execution complete"
