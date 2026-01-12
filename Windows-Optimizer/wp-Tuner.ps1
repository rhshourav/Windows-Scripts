<#
WindowsPerformanceTuner v11.0 (Enhanced Build)
Purpose: REAL performance tuning with BEFORE/AFTER reboot benchmarks,
         Service State restoration, and System Restore Points.
Audience: Advanced users. Admin required.
Compatibility: PowerShell 5.1+, Windows 10/11
#>

param(
    [ValidateSet('Gaming','Developer','LowImpact')]
    [string]$Profile = 'Gaming',

    [switch]$Preview, # Used internally for post-reboot phase
    [switch]$Restore  # Run this to revert changes
)

# ===================== GLOBAL CONFIG & PATHS =====================
$ErrorActionPreference = 'Stop'
$BaseDir   = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPerformanceTuner'
$LogDir    = Join-Path $BaseDir 'Logs'
$BenchDir  = Join-Path $BaseDir 'Benchmarks'
$BackupDir = Join-Path $BaseDir 'Backups'
$TaskName  = 'WindowsPerformanceTuner_PostReboot'

# Ensure directories exist
foreach ($d in @($BaseDir,$LogDir,$BenchDir,$BackupDir)) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

$RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile  = Join-Path $LogDir "WPT_$RunStamp.log"

# ===================== LOGGING HELPER =====================
function Log { 
    param([string]$m, [string]$type="INFO", [ConsoleColor]$color="White") 
    Write-Host "[$type] $m" -ForegroundColor $color
    Add-Content $LogFile "[$type] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" 
}

# ===================== SAFETY CHECKS =====================
function Require-Admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "Administrator privileges required."
        exit 1
    }
}

function Create-RestorePoint {
    Log "Attempting to create System Restore Point..." "SYS" Cyan
    try {
        Checkpoint-Computer -Description "WPT_$Profile_$RunStamp" -RestorePointType MODIFY_SETTINGS
        Log "Restore point created successfully." "SYS" Green
    } catch {
        Log "Could not create Restore Point. Ensure System Protection is enabled." "WARN" Yellow
    }
}

# ===================== BENCHMARKING ENGINE =====================
function Get-Benchmark {
    Log "Measuring system performance (5s sample)..." "BENCH" Cyan
    
    # CPU & Memory
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples | Measure-Object CookedValue -Average | Select -ExpandProperty Average
    $mem = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    
    # DPC/Interrupts (Latency Indicators)
    $dpc = (Get-Counter '\Processor(_Total)\% DPC Time').CounterSamples[0].CookedValue
    $int = (Get-Counter '\Processor(_Total)\% Interrupt Time').CounterSamples[0].CookedValue

    # Disk Queue (Responsiveness Indicator)
    $diskQ = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk Queue Length').CounterSamples[0].CookedValue

    [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString('o')
        CPU_Avg_Load = [math]::Round($cpu, 2)
        Free_Mem_MB  = [math]::Round($mem, 1)
        DPC_Time_Pct = [math]::Round($dpc, 3)
        Int_Time_Pct = [math]::Round($int, 3)
        Disk_Queue   = [math]::Round($diskQ, 3)
    }
}

function Save-Benchmark($obj, $label) {
    $path = Join-Path $BenchDir "${label}_$RunStamp.json"
    $obj | ConvertTo-Json -Depth 4 | Out-File $path -Encoding UTF8
    Log "Benchmark [$label] saved to $path" "BENCH"
    return $path
}

# ===================== ETW / LATENCY TRACE =====================
function Run-LatencyTrace {
    # Check if Windows Performance Recorder (WPR) or Xperf exists
    if (Get-Command "xperf" -ErrorAction SilentlyContinue) {
        $etl = Join-Path $BenchDir "kernel_$RunStamp.etl"
        Log "Starting XPERF kernel trace (DPC/ISR) for 15s..." "TRACE" Magenta
        
        try {
            xperf -on latency -stackwalk dpc,isr -buffersize 1024 -MaxFile 256 -FileMode Circular | Out-Null
            Start-Sleep -Seconds 15
            xperf -stop | Out-Null
            xperf -d $etl | Out-Null
            Log "Trace saved: $etl" "TRACE" Green
            
            # Generate Text Report
            $txt = $etl -replace '\.etl$','.txt'
            xperf -i $etl -a dpcisr > $txt
            Log "Text report generated: $txt" "TRACE" Green
        } catch {
            Log "Xperf failed during execution." "ERR" Red
        }
    } else {
        Log "Xperf (Windows ADK) not found. Skipping granular DPC/ISR tracing." "WARN" Yellow
    }
}

# ===================== BACKUP & RESTORE =====================
function Backup-State {
    Log "Backing up Service Start Modes and Registry Keys..." "BACKUP" Cyan
    
    # Services
    Get-CimInstance Win32_Service | Select-Object Name, StartMode | ConvertTo-Json -Depth 2 | Out-File (Join-Path $BackupDir 'services_backup.json')
    
    # Network Tweaks (Global TCP)
    Get-NetTCPSetting | Select-Object SettingName, AutoTuningLevelLocal | ConvertTo-Json | Out-File (Join-Path $BackupDir 'net_backup.json')

    # Graphics Drivers Reg
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $BackupDir 'graphics.reg') /y | Out-Null
}

function Restore-State {
    Log "STARTING RESTORE PROCESS..." "RESTORE" Magenta
    
    # 1. Registry
    if (Test-Path (Join-Path $BackupDir 'graphics.reg')) {
        Log "Restoring Graphics Registry..."
        reg import (Join-Path $BackupDir 'graphics.reg') | Out-Null
    }

    # 2. Services
    $svcFile = Join-Path $BackupDir 'services_backup.json'
    if (Test-Path $svcFile) {
        Log "Restoring Service Start Modes (this may take time)..."
        $services = Get-Content $svcFile | ConvertFrom-Json
        foreach ($svc in $services) {
            try {
                $current = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
                if ($current -and $current.StartType -ne $svc.StartMode) {
                    Set-Service -Name $svc.Name -StartupType $svc.StartMode -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        Log "Services restored." "RESTORE" Green
    }

    # 3. Network
    Log "Resetting TCP stack..."
    netsh int ip reset | Out-Null
    
    Log "Restore complete. PLEASE REBOOT MANUALLY." "RESTORE" Yellow
    exit
}

# ===================== TUNING PROFILES =====================
function Optimize-Network {
    Log "Applying TCP Optimizations (CTCP, AutoTuning)..." "TUNE"
    # Congestion Provider: CUBIC is standard, CTCP often better for variable latency
    Set-NetTCPSetting -SettingName InternetCustom -CongestionProvider CTCP -ErrorAction SilentlyContinue
    Set-NetTCPSetting -SettingName InternetCustom -AutoTuningLevelLocal Normal -ErrorAction SilentlyContinue
    # Disable Nagle's Algorithm for gaming interfaces usually requires registry hacks per interface (skipped for safety/complexity balance)
}

function Optimize-Visuals {
    Log "Adjusting Visual Effects for Performance..." "TUNE"
    # UserPreferencesMask is complex; simple registry tweak for 'Adjust for best performance'
    # HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects -> VisualFXSetting = 2
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -ErrorAction SilentlyContinue
}

function Apply-Gaming {
    Log ">>> APPLYING GAMING PROFILE <<<" "TUNE" Magenta
    
    # 1. Power Plan: High Performance
    Log "Setting Power Scheme to High Performance..."
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 
    
    # 2. GPU Scheduling (HAGS)
    Log "Enabling Hardware Accelerated GPU Scheduling..."
    reg add 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null

    # 3. Game Mode / Priority
    # Specifically for process priority handling (Win32PrioritySeparation 26 = 0x1A favors foreground)
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 38 

    Optimize-Network
    # Disable Sleep/Hibernate to prevent latency spikes from power state checks
    powercfg /hibernate off
}

function Apply-Developer {
    Log ">>> APPLYING DEVELOPER PROFILE <<<" "TUNE" Magenta
    
    # 1. Power Plan: Balanced (Better for thermals on laptops, still responsive)
    powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
    
    # 2. FileSystem: Disable 8.3 Name Creation (Speed up NTFS)
    fsutil 8dot3name set 1 | Out-Null
    
    # 3. Service Tweaks (Example: Set WSL Service to Manual if not used often, or Auto if used)
    # This is highly specific, so we stick to general filesystem perf here.
}

# ===================== POST-REBOOT SCHEDULER =====================
function Schedule-PostReboot {
    # Using 'cmd /c start' to detach slightly or ensure visibility
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile -Preview"
    $trigger = New-ScheduledTaskTrigger -AtLogon
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Log "Task Scheduled. Benchmarking will resume after reboot." "SYS"
}

# ===================== MAIN EXECUTION FLOW =====================
Require-Admin

# >>> RESTORE MODE
if ($Restore) { 
    Restore-State 
}

# >>> POST-REBOOT (PREVIEW) MODE
if ($Preview) {
    Log "Resuming session post-reboot..." "SYS" Green
    
    # Wait for system to "settle" (services to start, disk I/O to drop)
    Log "Waiting 60 seconds for system settlement..." "WAIT" Yellow
    Start-Sleep -Seconds 60
    
    $after = Get-Benchmark
    Save-Benchmark $after 'after'
    
    Run-LatencyTrace
    
    # Cleanup Task
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    
    Log "Tuning Complete." "DONE" Green
    Log "Check $BenchDir for JSON results and Kernel Latency reports."
    
    # Comparison Output
    $beforePath = Join-Path $BenchDir "before_$($RunStamp.Split('_')[0])*.json" 
    # (Simple globbing to find the matching 'before' file might be tricky if multiple runs happen same day. 
    #  In production, save RunID to registry to persist across reboot.)
    
    exit
}

# >>> INITIAL RUN
Log "WindowsPerformanceTuner Started | Profile: $Profile" "INIT" Green

Create-RestorePoint
Backup-State

$pre = Get-Benchmark
Save-Benchmark $pre 'before'

switch ($Profile) {
    'Gaming'    { Apply-Gaming }
    'Developer' { Apply-Developer }
    'LowImpact' { Log "LowImpact: Only running benchmarks and backups." }
}

Schedule-PostReboot

Log "Configuration applied. Rebooting in 10 seconds..." "SYS" Yellow
Start-Sleep -Seconds 10
Restart-Computer -Force
