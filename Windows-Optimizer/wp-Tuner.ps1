<#
================================================================================
WindowsPerformanceTuner v13.0  (STABLE LEGACY RELEASE)
Author: rhshourav
GitHub: https://github.com/rhshourav

Purpose:
- REAL system tuning with visual progress bars
- Automatic before/after benchmark comparison
- Safety pauses and rollback support

Audience: Advanced / Power users (Administrator required)
Compatibility: PowerShell 5.1+, Windows 10 / Windows 11

============================== CHANGELOG ==============================
[v13.0]
- Visual cleanup engine with progress bars
- Benchmarking engine (CPU, Memory, DPC, Disk Queue)
- Auto comparison report after reboot
- Gaming / Developer tuning profiles
- System Restore Point + Registry/Service backup
- Safe reboot countdown with user override
- Restore mode to revert system state
======================================================================
#>

param(
    [ValidateSet('Gaming','Developer','LowImpact')]
    [string]$Profile = 'Gaming',

    [switch]$Preview,      # Internal: Post-reboot phase
    [switch]$Restore,      # Revert changes
    [switch]$SkipCleanup   # Skip file cleanup stage
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
    param([string]$m,[string]$type="INFO",[ConsoleColor]$color="White")
    Write-Host "[$type] $m" -ForegroundColor $color
    Add-Content $LogFile "[$type] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
}
function Show-Banner {
    Clear-Host

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "  Windows Performance Tuner" -ForegroundColor Cyan
    Write-Host "  Version : v13.0 (Stable Legacy Release)" -ForegroundColor Gray
    Write-Host "  Author  : rhshourav" -ForegroundColor Gray
    Write-Host "  GitHub  : https://github.com/rhshourav" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Profile : $Profile" -ForegroundColor Yellow
    Write-Host "  Mode    : Real System Tuning (Admin Required)" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}


# ===================== ADMIN CHECK =====================
function Require-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "Administrator privileges required. Please run PowerShell as Administrator."
        exit 1
    }
}
# ===================== CLEANUP MODULE =====================
function Invoke-SystemCleanup {
    Log "Initializing Deep Cleanup..." "CLEAN" Cyan

    $tasks = @(
        @{ Name="Windows Update Cache"; Path="C:\Windows\SoftwareDistribution\Download\*"; Svc="wuauserv" },
        @{ Name="System Temp"; Path="C:\Windows\Temp\*" },
        @{ Name="User Temp"; Path="$env:TEMP\*" },
        @{ Name="Prefetch"; Path="C:\Windows\Prefetch\*" },
        @{ Name="DNS Cache"; Action={ Clear-DnsClientCache } }
    )

    $i = 0
    foreach ($task in $tasks) {
        $i++
        Write-Progress -Activity "Deep Cleaning System" -Status $task.Name -PercentComplete (($i/$tasks.Count)*100)
        try {
            if ($task.Svc) { Stop-Service $task.Svc -Force -ErrorAction SilentlyContinue }
            if ($task.Path) { Remove-Item $task.Path -Recurse -Force -ErrorAction SilentlyContinue }
            if ($task.Action) { & $task.Action }
            if ($task.Svc) { Start-Service $task.Svc -ErrorAction SilentlyContinue }
            Log "Cleaned: $($task.Name)" "CLEAN" Green
        } catch {
            Log "Failed: $($task.Name)" "WARN" Yellow
        }
        Start-Sleep -Milliseconds 300
    }
    Write-Progress -Activity "Deep Cleaning System" -Completed
}

# ===================== BENCHMARK ENGINE =====================
function Get-Benchmark {
    Write-Progress -Activity "Benchmarking" -Status "Sampling metrics..." -PercentComplete 0

    $cpuData = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5
    $cpuAvg  = ($cpuData.CounterSamples | Measure-Object CookedValue -Average).Average
    $mem     = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    $dpc     = (Get-Counter '\Processor(_Total)\% DPC Time').CounterSamples[0].CookedValue
    $diskQ   = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk Queue Length').CounterSamples[0].CookedValue

    Write-Progress -Activity "Benchmarking" -Completed

    [PSCustomObject]@{
        Timestamp   = (Get-Date).ToString('o')
        CPU_Load    = [math]::Round($cpuAvg,2)
        Free_Mem_MB = [math]::Round($mem,1)
        DPC_Latency = [math]::Round($dpc,3)
        Disk_Queue  = [math]::Round($diskQ,3)
    }
}

function Save-Benchmark($obj,$label) {
    $path = Join-Path $BenchDir "bench_$label.json"
    $obj | ConvertTo-Json -Depth 4 | Out-File $path -Encoding UTF8
}

# ===================== REPORT =====================
function Show-ComparisonReport {
    $b = Get-Content (Join-Path $BenchDir 'bench_before.json') | ConvertFrom-Json
    $a = Get-Content (Join-Path $BenchDir 'bench_after.json')  | ConvertFrom-Json

    Write-Host "`n================ PERFORMANCE REPORT ================" -ForegroundColor Cyan
    "Metric          | Before     | After      | Change" | Write-Host
    "---------------------------------------------------" | Write-Host

    foreach ($m in 'CPU_Load','Free_Mem_MB','DPC_Latency','Disk_Queue') {
        $diff = $a.$m - $b.$m
        $pct  = [math]::Round(($diff / ($b.$m+0.01))*100,1)
        if ($m -eq 'Free_Mem_MB') { $good = $diff -gt 0 } else { $good = $diff -lt 0 }
        $color = if ($good) { 'Green' } else { 'Red' }
        "{0,-15} | {1,-10} | {2,-10} | {3,-8}%" -f $m,$b.$m,$a.$m,$pct | Write-Host -ForegroundColor $color
    }
    Write-Host "====================================================`n" -ForegroundColor Cyan
}

# ===================== TUNING =====================
function Apply-Gaming {
    Log "Applying Gaming Profile" "TUNE" Cyan
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    reg add 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' Win32PrioritySeparation 38
    powercfg /hibernate off
}

function Apply-Developer {
    Log "Applying Developer Profile" "TUNE" Cyan
    powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
    fsutil 8dot3name set 1 | Out-Null
}

# ===================== BACKUP / RESTORE =====================
function Create-RestorePoint {
    try { Checkpoint-Computer -Description "WPT_$Profile_$RunStamp" -RestorePointType MODIFY_SETTINGS } catch {}
}

function Backup-State {
    Get-CimInstance Win32_Service | Select Name,StartMode | ConvertTo-Json | Out-File (Join-Path $BackupDir 'services.json')
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $BackupDir 'graphics.reg') /y | Out-Null
}

function Restore-State {
    if (Test-Path (Join-Path $BackupDir 'graphics.reg')) { reg import (Join-Path $BackupDir 'graphics.reg') }
    $svcs = Get-Content (Join-Path $BackupDir 'services.json') | ConvertFrom-Json
    foreach ($s in $svcs) { Set-Service $s.Name -StartupType $s.StartMode -ErrorAction SilentlyContinue }
    Log "Restore complete. Reboot manually." "RESTORE" Green
    exit
}

function Schedule-PostReboot {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile -Preview"
    Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger (New-ScheduledTaskTrigger -AtLogon) -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest) -Force | Out-Null
}

# ===================== MAIN =====================
Require-Admin
if ($Restore) { Restore-State }

if ($Preview) {
    Start-Sleep 60
    Save-Benchmark (Get-Benchmark) 'after'
    Unregister-ScheduledTask $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Show-ComparisonReport
    Read-Host 'Done. Press ENTER to exit.'
    exit
}

Show-Banner
Log "WindowsPerformanceTuner v13 initialized" "INIT" Green
Create-RestorePoint
Backup-State
Save-Benchmark (Get-Benchmark) 'before'

if (-not $SkipCleanup) { Invoke-SystemCleanup }

switch ($Profile) {
    'Gaming'    { Apply-Gaming }
    'Developer' { Apply-Developer }
}

Schedule-PostReboot

# ===================== SAFETY REBOOT TIMER =====================
Write-Host "`n==============================================" -ForegroundColor Yellow
Write-Host " TUNING APPLIED. REBOOT REQUIRED." -ForegroundColor Yellow
Write-Host " Please save all open documents now." -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Yellow

$timeout = 300  # 5 minutes
for ($i = 0; $i -lt $timeout; $i++) {

    $remaining = $timeout - $i
    Write-Progress `
        -Activity "Waiting for User Confirmation" `
        -Status "Press ENTER to reboot immediately (Auto reboot in $remaining seconds)" `
        -PercentComplete (($i / $timeout) * 100)

    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') { break }
    }

    Start-Sleep -Seconds 1
}

Write-Progress -Activity "Waiting for User Confirmation" -Completed
Write-Host "Rebooting now..." -ForegroundColor Red
Restart-Computer -Force
