<#
================================================================================
WindowsPerformanceTuner v16.0
Author: rhshourav
GitHub: https://github.com/rhshourav
Purpose: Network Latency Boost, GPU Optimization, and System Health.
================================================================================
#>

param(
    [ValidateSet('Gaming','Developer','LowImpact')]
    [string]$Profile = 'Gaming',
    [switch]$Preview, 
    [switch]$Restore
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

# ===================== NETWORK LATENCY BOOST =====================
function Optimize-Network {
    Log "Applying Network Latency Boost (Lower Ping)..." "NET" Cyan
    
    # 1. Disable Network Throttling (Prioritizes Games over Background traffic)
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NetworkThrottlingIndex" /t REG_DWORD /d 0xFFFFFFFF /f | Out-Null

    # 2. TCP Optimizations
    netsh int tcp set global autotuninglevel=normal
    netsh int tcp set global scalingstate=enabled
    netsh int tcp set global timestamps=disabled
    netsh int tcp set global netdma=enabled
    netsh int tcp set global dca=enabled
    netsh int tcp set global ecncapability=disabled
    
    # 3. Gaming-Specific TCP (Nagle's Algorithm / TCPNoDelay)
    $Interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    foreach ($Interface in $Interfaces) {
        reg add $Interface.PsPath /v "TcpAckFrequency" /t REG_DWORD /d 1 /f | Out-Null
        reg add $Interface.PsPath /v "TCPNoDelay" /t REG_DWORD /d 1 /f | Out-Null
    }

    Log "Network optimizations applied. TCP NoDelay enabled." "NET" Green
}

# ===================== GPU OPTIMIZATION =====================
function Optimize-GPU {
    Log "Detecting & Optimizing GPU..." "GPU" Cyan
    $gpus = Get-CimInstance Win32_VideoController
    foreach ($gpu in $gpus) {
        Log "Found: $($gpu.Name)" "GPU" Green
        reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v "HwSchMode" /t REG_DWORD /d 2 /f | Out-Null
        reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v "VarRefreshRate" /t REG_DWORD /d 1 /f | Out-Null
        
        if ($gpu.Name -like "*NVIDIA*") {
            reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Power" /v "PowerModel" /t REG_DWORD /d 1 /f | Out-Null
        }
    }
}

# ===================== SYSTEM HEALTH (SFC / DISM) =====================
function Invoke-SystemHealth {
    Log "Running Health Checks (DISM & SFC)..." "HEALTH" Magenta
    dism.exe /online /cleanup-image /restorehealth | Out-Null
    sfc /scannow | Out-Null
    Log "Health checks finished." "HEALTH" Green
}

# ===================== CLEANUP (VISUAL) =====================
function Invoke-SystemCleanup {
    Log "Starting Visual Cleanup..." "CLEAN" Cyan
    $tasks = @(
        @{ Name="Update Cache"; Path="C:\Windows\SoftwareDistribution\Download\*"; Svc="wuauserv" },
        @{ Name="Temp Files"; Path="C:\Windows\Temp\*"; Path2="$env:TEMP\*" },
        @{ Name="Prefetch"; Path="C:\Windows\Prefetch\*" },
        @{ Name="DNS Cache"; Action={ Clear-DnsClientCache } }
    )
    $i = 0
    foreach ($task in $tasks) {
        $i++
        Write-Progress -Activity "Cleaning" -Status "Processing: $($task.Name)" -PercentComplete (($i / $tasks.Count) * 100)
        if ($task.Svc) { Stop-Service $task.Svc -Force -ErrorAction SilentlyContinue }
        if ($task.Path) { Remove-Item $task.Path -Recurse -Force -ErrorAction SilentlyContinue }
        if ($task.Path2) { Remove-Item $task.Path2 -Recurse -Force -ErrorAction SilentlyContinue }
        if ($task.Action) { & $task.Action }
        if ($task.Svc) { Start-Service $task.Svc -ErrorAction SilentlyContinue }
    }
}

# ===================== BENCHMARKING =====================
function Get-Benchmark {
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples | Measure-Object CookedValue -Average | Select -ExpandProperty Average
    $mem = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    $dpc = (Get-Counter '\Processor(_Total)\% DPC Time').CounterSamples[0].CookedValue
    $gpuName = (Get-CimInstance Win32_VideoController).Name -join ", "

    [PSCustomObject]@{ 
        GPU = $gpuName; 
        CPU_Load = [math]::Round($cpu,2); 
        Free_Mem_MB = [math]::Round($mem,1); 
        DPC_Latency = [math]::Round($dpc,3) 
    }
}

# ===================== MAIN EXECUTION =====================
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { 
    Write-Error "Please run as Administrator!" 
    exit 
}

if ($Preview) {
    Log "Resuming after reboot..." "INIT" Green
    Start-Sleep -Seconds 45
    Get-Benchmark | ConvertTo-Json | Out-File (Join-Path $BenchDir "bench_after.json")
    
    $b = Get-Content (Join-Path $BenchDir "bench_before.json") | ConvertFrom-Json
    $a = Get-Content (Join-Path $BenchDir "bench_after.json") | ConvertFrom-Json
    
    Write-Host "`n================================================" -ForegroundColor Cyan
    Write-Host " PERFORMANCE TUNING REPORT | rhshourav" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "GPU: $($a.GPU)" -ForegroundColor Yellow
    "{0,-15} | {1,-10} | {2,-10} | {3,-10}" -f "Metric", "Before", "After", "Change" | Write-Host
    
    $metrics = @("CPU_Load", "Free_Mem_MB", "DPC_Latency")
    foreach ($m in $metrics) {
        $diff = $a.$m - $b.$m
        $pct = [math]::Round(($diff / ($b.$m + 0.01)) * 100, 1)
        
        # FIXED IF/ELSE FOR POWERSHELL 5.1 COMPATIBILITY
        if ($m -eq "Free_Mem_MB") {
            if ($diff -gt 0) { $color = "Green" } else { $color = "Red" }
        } else {
            if ($diff -lt 0) { $color = "Green" } else { $color = "Red" }
        }
        
        "{0,-15} | {1,-10} | {2,-10} | {3,-10}" -f $m, $b.$m, $a.$m, "$pct%" | Write-Host -ForegroundColor $color
    }
    
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Read-Host "`nTuning Complete. Press ENTER to close."
    exit
}

Clear-Host
Log "WindowsPerformanceTuner v16 | rhshourav" "INIT" Magenta
Log "GitHub: github.com/rhshourav" "INIT" Magenta

Get-Benchmark | ConvertTo-Json | Out-File (Join-Path $BenchDir "bench_before.json")

Invoke-SystemHealth
Invoke-SystemCleanup
Optimize-GPU
Optimize-Network
Update-Disk | Out-Null

# Schedule Post-Reboot
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Profile $Profile -Preview"
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogon) -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest) -Force | Out-Null

Write-Host "`nPAUSED: Save your work. Press ENTER to reboot." -ForegroundColor Yellow
Read-Host
Restart-Computer -Force
