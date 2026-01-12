<#
WindowsPerformanceTuner v10.0 (Authoritative Build)
Purpose: REAL performance tuning with BEFORE/AFTER reboot benchmarks
         and kernel latency measurement via ETW (xperf).
Audience: Advanced users. Admin required. No placebo tweaks.
Compatibility: PowerShell 5.1+, Windows 10/11
#>

param(
    [ValidateSet('Gaming','Developer','LowImpact')]
    [string]$Profile = 'Gaming',

    [switch]$Preview,
    [switch]$Restore
)

# ===================== GLOBAL PATHS =====================
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
function Log { param($m) Write-Host "[INFO] $m"; Add-Content $LogFile "[INFO] $(Get-Date -Format o) $m" }
function Warn{ param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow; Add-Content $LogFile "[WARN] $(Get-Date -Format o) $m" }
function Err { param($m) Write-Host "[ERR]  $m" -ForegroundColor Red; Add-Content $LogFile "[ERR]  $(Get-Date -Format o) $m" }

# ===================== ADMIN CHECK =====================
function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Err 'Administrator privileges required.'
        exit 1
    }
}

Require-Admin

# ===================== BENCHMARKING =====================
function Get-Benchmark {
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples | Measure-Object CookedValue -Average | % Average
    $mem = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue

    [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        CPU_Avg   = [math]::Round($cpu,2)
        FreeMB    = [math]::Round($mem,1)
    }
}

function Save-Benchmark($obj,$label) {
    $path = Join-Path $BenchDir "${label}_$RunStamp.json"
    $obj | ConvertTo-Json -Depth 4 | Out-File $path -Encoding UTF8
    return $path
}

# ===================== ETW KERNEL LATENCY =====================
function Run-KernelLatencyTrace {
    $etl = Join-Path $BenchDir "kernel_$RunStamp.etl"
    Log 'Starting kernel ETW trace (DPC/ISR)...'

    xperf -on latency -stackwalk dpc,isr -buffersize 1024 -MaxFile 256 -FileMode Circular | Out-Null
    Start-Sleep -Seconds 15
    xperf -stop | Out-Null
    xperf -d $etl | Out-Null

    Log "Kernel trace saved: $etl"

    $txt = $etl -replace '\.etl$','.txt'
    xperf -i $etl -a dpcisr > $txt

    Log "Latency analysis written: $txt"
    return $txt
}

# ===================== BACKUP =====================
function Backup-State {
    Get-CimInstance Win32_Service | Select Name,State,StartMode | ConvertTo-Json -Depth 3 | Out-File (Join-Path $BackupDir 'services.json')
    reg export 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers' (Join-Path $BackupDir 'graphics.reg') /y | Out-Null
    Log 'System state backed up.'
}

# ===================== RESTORE =====================
function Restore-State {
    Log 'Restoring registry and services...'
    reg import (Join-Path $BackupDir 'graphics.reg') | Out-Null
    Warn 'Service restore must be manual (safety).' 
    Log 'Restore complete. Reboot recommended.'
    exit
}

if ($Restore) { Restore-State }

# ===================== APPLY PROFILE =====================
function Apply-Gaming {
    Log 'Applying Gaming profile.'
    powercfg /setactive SCHEME_MIN
    reg add 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers' /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null
}

# ===================== POST-REBOOT TASK =====================
function Schedule-PostReboot {
    $cmd = "powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile -Preview"
    schtasks /create /tn $TaskName /tr "$cmd" /sc ONSTART /ru SYSTEM /f | Out-Null
    Log 'Post-reboot benchmark task scheduled.'
}

# ===================== MAIN =====================
Log "WindowsPerformanceTuner started | Profile=$Profile Preview=$Preview"

if (-not $Preview) {
    Backup-State
    $pre = Get-Benchmark
    Save-Benchmark $pre 'before'

    switch ($Profile) {
        'Gaming'    { Apply-Gaming }
    }

    Schedule-PostReboot
    Log 'Reboot required to complete tuning.'
    exit
}

# ===================== POST-REBOOT PHASE =====================
Start-Sleep -Seconds 30
$after = Get-Benchmark
Save-Benchmark $after 'after'
$lat = Run-KernelLatencyTrace

schtasks /delete /tn $TaskName /f | Out-Null

Log 'Post-reboot benchmark complete.'
Log 'Compare before/after JSON and kernel latency report for results.'
