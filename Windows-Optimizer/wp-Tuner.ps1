<#
WindowsPerformanceTuner v13.0
Purpose: REAL tuning with Visual Progress Bars, Auto-Comparison Reports,
         and Safety Pauses.
Audience: Advanced users. Admin required.
Compatibility: PowerShell 5.1+, Windows 10/11
#>

param(
    [ValidateSet('Gaming','Developer','LowImpact')]
    [string]$Profile = 'Gaming',

    [switch]$Preview, # Internal: Post-reboot phase
    [switch]$Restore, # Run to revert changes
    [switch]$SkipCleanup # Use this to skip file deletion
)

# ===================== CONFIGURATION =====================
$ErrorActionPreference = 'Stop'
$BaseDir   = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPerformanceTuner'
$LogDir    = Join-Path $BaseDir 'Logs'
$BenchDir  = Join-Path $BaseDir 'Benchmarks'
$BackupDir = Join-Path $BaseDir 'Backups'
$TaskName  = 'WindowsPerformanceTuner_PostReboot'

# Create Directories
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

# ===================== VISUAL CLEANUP MODULE =====================
function Invoke-SystemCleanup {
    Log "Initializing Deep Cleanup..." "CLEAN" Cyan
    
    $tasks = @(
        @{ Name="Windows Update Cache"; Path="C:\Windows\SoftwareDistribution\Download\*"; Svc="wuauserv" },
        @{ Name="System Temp";          Path="C:\Windows\Temp\*" },
        @{ Name="User Temp";            Path="$env:TEMP\*" },
        @{ Name="Prefetch";             Path="C:\Windows\Prefetch\*" },
        @{ Name="DNS Cache";            Action={ Clear-DnsClientCache } }
    )

    $total = $tasks.Count
    $i = 0

    foreach ($task in $tasks) {
        $i++
        $percent = [math]::Round(($i / $total) * 100)
        
        # UPDATE PROGRESS BAR
        Write-Progress -Activity "Deep Cleaning System" -Status "Processing: $($task.Name)" -PercentComplete $percent
        
        try {
            # Stop Service if needed
            if ($task.Svc) { 
                Stop-Service -Name $task.Svc -Force -ErrorAction SilentlyContinue 
                Start-Sleep -Milliseconds 500
            }

            # Delete Files
            if ($task.Path) {
                # We use SilentlyContinue to ignore locked files (normal behavior)
                Remove-Item -Path $task.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            # Execute ScriptBlock
            if ($task.Action) {
                & $task.Action
            }

            # Restart Service
            if ($task.Svc) { 
                Start-Service -Name $task.Svc -ErrorAction SilentlyContinue 
            }
            
            Start-Sleep -Milliseconds 300 # Artifical delay so user sees the bar
            Log "Cleaned: $($task.Name)" "CLEAN" Green

        } catch {
            Log "Failed to clean $($task.Name)" "WARN" Yellow
        }
    }
    
    Write-Progress -Activity "Deep Cleaning System" -Completed
}

# ===================== BENCHMARKING ENGINE =====================
function Get-Benchmark {
    Write-Progress -Activity "Benchmarking" -Status "Sampling System Metrics (5s)..." -PercentComplete 0
    
    $cpuData  = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5)
    $mem      = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    $dpc      = (Get-Counter '\Processor(_Total)\% DPC Time').CounterSamples[0].CookedValue
    $diskQ    = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk Queue Length').CounterSamples[0].CookedValue
    
    $cpuAvg = ($cpuData.CounterSamples | Measure-Object CookedValue -Average).Average
    
    Write-Progress -Activity "Benchmarking" -Completed

    [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString('o')
        CPU_Load     = [math]::Round($cpuAvg, 2)
        Free_Mem_MB  = [math]::Round($mem, 1)
        DPC_Latency  = [math]::Round($dpc, 3)
        Disk_Queue   = [math]::Round($diskQ, 3)
    }
}

function Save-Benchmark($obj, $label) {
    # If this is the "After" benchmark, we don't use the timestamp so we can easily find it later
    if ($label -eq 'after') {
        $path = Join-Path $BenchDir "bench_after.json"
    } else {
        $path = Join-Path $BenchDir "bench_before.json"
    }
    $obj | ConvertTo-Json -Depth 4 | Out-File $path -Encoding UTF8
    return $path
}

# ===================== COMPARISON REPORT =====================
function Show-ComparisonReport {
    $beforePath = Join-Path $BenchDir "bench_before.json"
    $afterPath  = Join-Path $BenchDir "bench_after.json"

    if ((Test-Path $beforePath) -and (Test-Path $afterPath)) {
        $b = Get-Content $beforePath | ConvertFrom-Json
        $a = Get-Content $afterPath | ConvertFrom-Json

        Write-Host "`n=================================================" -ForegroundColor Cyan
        Write-Host "     PERFORMANCE IMPROVEMENT REPORT" -ForegroundColor Cyan
        Write-Host "=================================================" -ForegroundColor Cyan
        
        # Table Header
        "{0,-15} | {1,-10} | {2,-10} | {3,-10}" -f "Metric", "Before", "After", "Change" | Write-Host -ForegroundColor Gray
        Write-Host "-------------------------------------------------" -ForegroundColor Gray

        # Helper to calc diff
        $metrics = @("CPU_Load", "Free_Mem_MB", "DPC_Latency", "Disk_Queue")
        
        foreach ($m in $metrics) {
            $valB = $b.$m
            $valA = $a.$m
            
            if ($valB -eq 0) { $valB = 0.01 } # Prevent div/0

            $diff = $valA - $valB
            $pct  = [math]::Round(($diff / $valB) * 100, 1)
            
            # Color Logic: 
            # For Memory: Higher is GREEN. For CPU/Latency: Lower is GREEN.
            $color = "White"
            if ($m -eq "Free_Mem_MB") {
                if ($diff -gt 0) { $color = "Green"; $sign = "+" } else { $color = "Red"; $sign = "" }
            } else {
                if ($diff -lt 0) { $color = "Green"; $sign = "" } else { $color = "Red"; $sign = "+" }
            }

            "{0,-15} | {1,-10} | {2,-10} | {3,-10}" -f $m, $valB, $valA, "$sign$pct%" | Write-Host -ForegroundColor $color
        }
        Write-Host "=================================================`n" -ForegroundColor Cyan
    } else {
        Log "Could not find benchmark files to compare." "WARN" Yellow
    }
}

# ===================== TUNING LOGIC =====================
function Apply-Gaming {
    Log "Applying Gaming Profile..." "TUNE"
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 
    reg add 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null 
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 38 
    powercfg /hibernate off
}

function Apply-Developer {
    Log "Applying Developer Profile..." "TUNE"
    powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
    fsutil 8dot3name set 1 | Out-Null
}

function Create-RestorePoint {
    Log "Creating System Restore Point..." "SYS" Cyan
    try {
        Checkpoint-Computer -Description "WPT_$Profile_$RunStamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log "Restore point created." "SYS" Green
    } catch {
        Log "Restore Point failed (System Protection disabled?)." "WARN" Yellow
    }
}

function Backup-State {
    Log "Backing up Service States..." "BACKUP"
    Get-CimInstance Win32_Service | Select-Object Name, StartMode | ConvertTo-Json | Out-File (Join-Path $BackupDir 'services_backup.json')
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $BackupDir 'graphics.reg') /y | Out-Null
}

function Restore-State {
    Log ">>> RESTORING SYSTEM STATE <<<" "RESTORE" Magenta
    if (Test-Path (Join-Path $BackupDir 'graphics.reg')) { reg import (Join-Path $BackupDir 'graphics.reg') | Out-Null }
    $svcFile = Join-Path $BackupDir 'services_backup.json'
    if (Test-Path $svcFile) {
        $services = Get-Content $svcFile | ConvertFrom-Json
        foreach ($svc in $services) { try { Set-Service -Name $svc.Name -StartupType $svc.StartMode -ErrorAction SilentlyContinue } catch {} }
    }
    Log "Restore Complete. Reboot manually." "RESTORE" Green
    exit
}

function Schedule-PostReboot {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile -Preview"
    $trigger = New-ScheduledTaskTrigger -AtLogon
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

# ===================== MAIN EXECUTION =====================
Require-Admin

if ($Restore) { Restore-State }

# --- POST REBOOT PHASE (PREVIEW) ---
if ($Preview) {
    Log "Waiting 60s for system settlement..." "WAIT" Yellow
    Start-Sleep -Seconds 60
    
    $after = Get-Benchmark
    Save-Benchmark $after 'after'
    
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    
    # DISPLAY THE COMPARISON TABLE
    Show-ComparisonReport
    
    Log "Tuning Complete. Press Enter to exit." "DONE" Green
    Read-Host
    exit
}

# --- INITIAL PHASE ---
Clear-Host
Log "WindowsPerformanceTuner v13 | Profile: $Profile" "INIT" Green
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
Write-Host " TUNING APPLIED. REBOOT REQUIRED." -ForegroundColor Yellow
Write-Host " Please save all your open documents now." -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Yellow

$timeout = 300 # 5 minutes timeout
for ($i = 0; $i -lt $timeout; $i++) {
    Write-Progress -Activity "Waiting for User Confirmation" -Status "Press ENTER to Reboot immediately (Auto-reboot in $($timeout - $i)s)" -PercentComplete (($i / $timeout) * 100)
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') { break }
    }
    Start-Sleep -Seconds 1
}
Write-Progress -Activity "Waiting for User Confirmation" -Completed

Write-Host "Rebooting..." -ForegroundColor Red
Restart-Computer -Force
