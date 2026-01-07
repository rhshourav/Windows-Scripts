<#
============================================
 Windows Optimizer
============================================
 Version : 2.6.0
 Author  : Shourav
 GitHub  : https://github.com/rhshourav
============================================
#>

# ==========================================================
# Admin Check (NO INSTANT EXIT)
# ==========================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Clear-Host
    Write-Host "Administrator privileges are REQUIRED." -ForegroundColor Red
    Write-Host ""
    Write-Host "The optimizer needs admin rights to:"
    Write-Host "- Disable services"
    Write-Host "- Modify system registry"
    Write-Host "- Remove bloatware"
    Write-Host ""
    Write-Host "Press ENTER to relaunch as Administrator..."
    Read-Host

    Start-Process powershell `
        "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/Windows-Optimizer.ps1 | iex`"" `
        -Verb RunAs

    Write-Host "Relaunching... You may close this window."
    Start-Sleep 3
    exit
}

# ==========================================================
# Paths
# ==========================================================
$Root    = Join-Path $env:TEMP "WindowsOptimizer"
$LogDir  = Join-Path $Root "logs"
$SnapDir = Join-Path $Root "snapshots"

New-Item -ItemType Directory -Force -Path $Root,$LogDir,$SnapDir | Out-Null
$LogFile = Join-Path $LogDir "optimizer.log"

# ==========================================================
# Logging
# ==========================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","ACTION","WARN","ERROR")] $Level="INFO"
    )
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"

    Add-Content $LogFile $line

    switch ($Level) {
        "INFO"   { Write-Host $line -ForegroundColor Cyan }
        "ACTION" { Write-Host $line -ForegroundColor Green }
        "WARN"   { Write-Host $line -ForegroundColor Yellow }
        "ERROR"  { Write-Host $line -ForegroundColor Red }
    }
}

# ==========================================================
# Telemetry (Transparent)
# ==========================================================
function Show-TelemetryNotice {
    Write-Host ""
    Write-Host "Telemetry is ENABLED by default." -ForegroundColor Cyan
    Write-Host "Data collected:"
    Write-Host "- Username"
    Write-Host "- Computer name"
    Write-Host "- Selected optimization profile"
    Write-Host ""
}

function Send-Telemetry {
    param([string]$Profile)
    Write-Log "Sending telemetry for profile: $Profile" "INFO"
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
        Write-Log "Telemetry failed to send" "WARN"
    }
}

# ==========================================================
# Snapshot
# ==========================================================
function Save-Snapshot {
    $file = Join-Path $SnapDir "snapshot-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
    Write-Log "Saving system snapshot..." "ACTION"
    Get-Service | Select Name,Status,StartType | Out-File $file
    Write-Log "Snapshot saved: $file" "INFO"
}

# ==========================================================
# Bloatware Removal
# ==========================================================
function Remove-Bloatware {
    Write-Log "Starting bloatware removal" "ACTION"

    $apps = @(
        "Microsoft.Xbox*",
        "Microsoft.GetHelp",
        "Microsoft.Getstarted",
        "Microsoft.People",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.BingNews",
        "Microsoft.BingWeather",
        "Microsoft.WindowsFeedbackHub"
    )

    foreach ($app in $apps) {
        Write-Log "Removing package: $app" "ACTION"
        Get-AppxPackage -Name $app -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
    }

    Write-Log "Bloatware removal completed" "INFO"
}

# ==========================================================
# Optimization Profiles
# ==========================================================
function Level1-Balanced {
    Write-Log "Applying Level 1 - Balanced" "ACTI
