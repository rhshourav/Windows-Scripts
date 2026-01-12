<#
WindowsPerformanceTuner v12.0
Purpose: REAL performance tuning, System Cleanup, Service Restoration,
         and Latency Benchmarking (DPC/ISR).
Audience: Advanced users. Admin required.
Compatibility: PowerShell 5.1+, Windows 10/11
#>

param(
    [ValidateSet('Gaming','Developer','LowImpact')]
    [string]$Profile = 'Gaming',

    [switch]$Preview, # Internal: Post-reboot phase
    [switch]$Restore, # Run to revert changes
    [switch]$SkipCleanup # Use this if you want to skip file deletion
)

# ===================== CONFIGURATION =====================
$ErrorActionPreference = 'Stop'
$BaseDir   = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPerformanceTuner'
$LogDir    = Join-Path $BaseDir 'Logs'
$BenchDir  = Join-Path $BaseDir 'Benchmarks'
$BackupDir = Join-Path $BaseDir 'Backups'
$TaskName  = 'WindowsPerformanceTuner_PostReboot'

foreach ($d in @($BaseDir,$LogDir,$BenchDir,$BackupDir)) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

$RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile  = Join-Path $LogDir "WPT_$RunStamp.log"

# ===================== LOGGING =====================
function Log { 
    param([string]$m, [string]$type="INFO", [ConsoleColor]$color="White") 
    Write-Host "[$type] $m" -ForegroundColor $color
    Add-Content $LogFile "[$type] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" 
}

# ===================== ADMIN CHECK =====================
function Require-Admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "Administrator privileges required. Please run as Admin."
        exit 1
    }
}

# ===================== CLEANUP MODULE =====================
function Invoke-SystemCleanup {
    Log ">>> STARTING SYSTEM CLEANUP <<<" "CLEAN" Magenta

    # 1. Windows Update Cache (SoftwareDistribution)
    Log "Cleaning Windows Update Cache..." "CLEAN"
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    } catch {
        Log "Could not clear Update cache (Service may be locked)." "WARN" Yellow
    }

    # 2. Flush DNS
    Log "Flushing DNS Resolver Cache..." "CLEAN"
    Clear-DnsClientCache | Out-Null

    # 3. Temp, User Temp, and Prefetch
    # Note: We use SilentlyContinue because many temp files are currently in use by running apps.
    $targets = @(
        "C:\Windows\Temp\*",
        "$env:TEMP\*",
        "C:\Windows\Prefetch\*"
    )

    foreach ($path in $targets) {
        Log "Sweeping: $path" "CLEAN"
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    Log "Cleanup Complete." "CLEAN" Green
}

# ===================== BENCHMARKING =====================
function Get-Benchmark {
    Log "Measuring system performance (5s sample)..." "BENCH" Cyan
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples | Measure-Object CookedValue -Average | Select -ExpandProperty Average
    $mem = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    $dpc = (Get-Counter '\Processor(_Total)\% DPC Time').CounterSamples[0].CookedValue
    $diskQ = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk Queue Length').CounterSamples[0].CookedValue

    [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString('o')
        CPU_Avg_Load = [math]::Round($cpu, 2)
        Free_Mem_MB  = [math]::Round($mem, 1)
        DPC_Time_Pct = [math]::Round($dpc, 3)
        Disk_Queue   = [math]::Round($diskQ, 3)
    }
}

function Save-Benchmark($obj, $label) {
    $path = Join-Path $BenchDir "${label}_$RunStamp.json"
    $obj | ConvertTo-Json -Depth 4 | Out-File $path -Encoding UTF8
    return $path
}

# ===================== BACKUP & RESTORE =====================
function Create-RestorePoint {
    Log "Creating System Restore Point..." "SYS" Cyan
    try {
        Checkpoint-Computer -Description "WPT_$Profile_$RunStamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log "Restore point created." "SYS" Green
    } catch {
        Log "Restore Point creation failed (System Protection might be disabled)." "WARN" Yellow
    }
}

function Backup-State {
    Log "Backing up Service States..." "BACKUP"
    Get-CimInstance Win32_Service | Select-Object Name, StartMode | ConvertTo-Json | Out-File (Join-Path $BackupDir 'services_backup.json')
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $BackupDir 'graphics.reg') /y | Out-Null
}

function Restore-State {
    Log ">>> RESTORING SYSTEM STATE <<<" "RESTORE" Magenta
    
    if (Test-Path (Join-Path $BackupDir 'graphics.reg')) {
        reg import (Join-Path $BackupDir 'graphics.reg') | Out-Null
    }

    $svcFile = Join-Path $BackupDir 'services_backup.json'
    if (Test-Path $svcFile) {
        Log "Restoring Services..."
        $services = Get-Content $svcFile | ConvertFrom-Json
        foreach ($svc in $services) {
            try {
                Set-Service -Name $svc.Name -StartupType $svc.StartMode -ErrorAction SilentlyContinue
            } catch {}
        }
    }
    Log "Restore Complete. Please reboot manually." "RESTORE" Green
    exit
}

# ===================== TUNING LOGIC =====================
function Apply-Gaming {
    Log "Applying Gaming Profile..." "TUNE"
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c # High Perf
    reg add 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null # HAGS
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 38 
    powercfg /hibernate off
}

function Apply-Developer {
    Log "Applying Developer Profile..." "TUNE"
    powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e # Balanced
    fsutil 8dot3name set 1 | Out-Null
}

# ===================== SCHEDULER =====================
function Schedule-PostReboot {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile -Preview"
    $trigger = New-ScheduledTaskTrigger -AtLogon
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

# ===================== MAIN EXECUTION =====================
Require-Admin

if ($Restore) { Restore-State }

# --- POST REBOOT PHASE ---
if ($Preview) {
    Log "Waiting 60s for system settlement..." "WAIT" Yellow
    Start-Sleep -Seconds 60
    
    $after = Get-Benchmark
    Save-Benchmark $after 'after'
    
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Log "Tuning Complete. Check Logs." "DONE" Green
    exit
}

# --- INITIAL PHASE ---
Log "WindowsPerformanceTuner v12 | Profile: $Profile" "INIT" Green
Create-RestorePoint
Backup-State

$pre = Get-Benchmark
Save-Benchmark $pre 'before'

if (-not $SkipCleanup) { Invoke-SystemCleanup }

switch ($Profile) {
    'Gaming'    { Apply-Gaming }
    'Developer' { Apply-Developer }
}

Schedule-PostReboot

# --- SAFETY PAUSE ---
Write-Host "`n==============================================" -ForegroundColor Yellow
Write-Host " TUNING COMPLETE. REBOOT REQUIRED." -ForegroundColor Yellow
Write-Host " Please save all your open documents now." -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Yellow
Write-Host "Press [ENTER] to Reboot now..." -NoNewline
Read-Host
Write-Host "Rebooting..." -ForegroundColor Red
Restart-Computer -Force
