# =========================================
# Windows Performance Tuner - ASCII Safe v14.3
# Fixed: job lookup by Id and job fallback
# =========================================

param(
    [ValidateSet("Gaming","Developer","LowImpact")]
    [string]$Profile = "Gaming"
)

$ErrorActionPreference = "Stop"

# ---------- ADMIN CHECK ----------
function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host "Run PowerShell as Administrator." -ForegroundColor Red
        Pause
        exit
    }
}
Require-Admin

# ---------- UI ----------
function Line { Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan }
function Title($t) {
    Line
    Write-Host ("| " + $t.PadRight(52) + " |") -ForegroundColor Yellow
    Line
}
function Info($k,$v) {
    Write-Host ("| {0,-10}: {1,-38} |" -f $k,$v) -ForegroundColor Gray
}
function ProgressBar($label,$pct,$start) {
    $elapsed = (Get-Date) - $start
    $eta = if ($pct -gt 0) {
        [TimeSpan]::FromSeconds(([math]::Max(0,$elapsed.TotalSeconds) / $pct) * (100 - $pct))
    } else { "??" }

    $blocks = [math]::Floor($pct/4)
    $bar = ("#" * $blocks).PadRight(25,".")
    Write-Host ("| {0,-50} |" -f $label) -ForegroundColor Cyan
    Write-Host ("| [{0}] {1,3}% ETA {2,-8} |" -f $bar,$pct,$eta) -ForegroundColor Green
}
function Show-Banner {
    Clear-Host

    $line = "============================================================"

    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Windows Performance Tuner                               |" -ForegroundColor Cyan
    Write-Host "| Version : v18.1.S                                       |" -ForegroundColor Gray
    Write-Host "| Author  : rhshourav                                     |" -ForegroundColor Gray
    Write-Host "| GitHub  : https://github.com/rhshourav                  |" -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Profile : $($Profile.PadRight(43)) |" -ForegroundColor Yellow
    Write-Host "| Mode    : Real System Tuning (Admin Required)           |" -ForegroundColor Yellow
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ""
}

Show-Banner
# ---------- SYSTEM INFO ----------
Title "SYSTEM CONFIGURATION"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ram = Get-CimInstance Win32_ComputerSystem
$gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1

Info "CPU"    $cpu.Name
Info "Cores" "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"
Info "Clock" "$($cpu.MaxClockSpeed) MHz"
Info "RAM"   ("{0:N1} GB" -f ($ram.TotalPhysicalMemory/1GB))
Info "GPU"   $gpu.Name
Info "Driver" $gpu.DriverVersion
Line




# ---------- SYSTEM CLEANUP (WITH PROGRESS BAR + DNS) ----------
# ---------- SYSTEM CLEANUP (CUSTOM ASCII PROGRESS) ----------
function Invoke-SystemCleanup {

    Title "SYSTEM CLEANUP"

    $tasks = @(
        @{ Name="Windows Update Cache"; Path="C:\Windows\SoftwareDistribution\Download\*"; Service="wuauserv" },
        @{ Name="Windows Temp";        Path="C:\Windows\Temp\*" },
        @{ Name="User Temp";           Path="$env:TEMP\*" },
        @{ Name="Prefetch";            Path="C:\Windows\Prefetch\*" },
        @{ Name="DNS Cache";            Action="DNS" }
    )

    $start = Get-Date
    $index = 0
    $total = $tasks.Count

    foreach ($t in $tasks) {
        $index++
        $pct = [math]::Round(($index / $total) * 100)

        ProgressBar "Cleaning: $($t.Name)" $pct $start
        Start-Sleep -Milliseconds 300

        try {
            if ($t.Service) {
                Stop-Service $t.Service -Force -ErrorAction SilentlyContinue
            }

            if ($t.Path -and (Test-Path $t.Path)) {
                Remove-Item $t.Path -Recurse -Force -ErrorAction SilentlyContinue
            }

            if ($t.Action -eq "DNS") {
                Clear-DnsClientCache
            }

            if ($t.Service) {
                Start-Service $t.Service -ErrorAction SilentlyContinue
            }
        }
        catch {
            # silently continue
        }

        try {
            [Console]::SetCursorPosition(0,[Console]::CursorTop - 2)
        } catch {}
    }

    ProgressBar "System cleanup complete" 100 $start
    Line
}


# ---------- BENCHMARK ----------
function Benchmark {
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples |
           Measure-Object CookedValue -Average | Select-Object -ExpandProperty Average
    $mem = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    $dpc = (Get-Counter '\Processor(_Total)\% DPC Time').CounterSamples[0].CookedValue
    $disk = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk Queue Length').CounterSamples[0].CookedValue

    [PSCustomObject]@{
        CPU_Load    = [math]::Round($cpu,2)
        Free_Mem_MB = [math]::Round($mem,0)
        DPC_Latency = [math]::Round($dpc,3)
        Disk_Queue  = [math]::Round($disk,3)
    }
}

$before = Benchmark
Invoke-SystemCleanup

# ---------- DISM (job with fallback) ----------
Title "SYSTEM REPAIR - DISM"
$start = Get-Date
$dismJob = $null
$useJob = $true

try {
    $dismJob = Start-Job -ScriptBlock { DISM /Online /Cleanup-Image /RestoreHealth } -ErrorAction Stop
} catch {
    # Start-Job failed (environment restriction); fallback to synchronous
    $useJob = $false
}

$p = 0
if ($useJob -and $dismJob) {
    while ($true) {
        try {
            $state = (Get-Job -Id $dismJob.Id -ErrorAction Stop).State
        } catch {
            # Job disappeared or not found; break out
            break
        }
        if ($state -ne "Running") { break }
        ProgressBar "DISM RestoreHealth" $p $start
        Start-Sleep 1
        $p = [math]::Min(99,$p+4)
        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }
    ProgressBar "DISM RestoreHealth" 100 $start
    try { Receive-Job -Id $dismJob.Id -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Remove-Job -Id $dismJob.Id -ErrorAction SilentlyContinue } catch {}
} else {
    # Synchronous fallback
    ProgressBar "DISM RestoreHealth (sync)" 10 $start
    DISM /Online /Cleanup-Image /RestoreHealth
    ProgressBar "DISM RestoreHealth (sync)" 100 $start
}
Line

# ---------- SFC (job with fallback) ----------
Title "SYSTEM REPAIR - SFC"
$start = Get-Date
$sfcJob = $null
$useJob = $true

try {
    $sfcJob = Start-Job -ScriptBlock { sfc /scannow } -ErrorAction Stop
} catch {
    $useJob = $false
}

$p = 0
if ($useJob -and $sfcJob) {
    while ($true) {
        try {
            $state = (Get-Job -Id $sfcJob.Id -ErrorAction Stop).State
        } catch {
            break
        }
        if ($state -ne "Running") { break }
        ProgressBar "SFC Scan" $p $start
        Start-Sleep 1
        $p = [math]::Min(99,$p+3)
        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }
    ProgressBar "SFC Scan" 100 $start
    try { Receive-Job -Id $sfcJob.Id -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Remove-Job -Id $sfcJob.Id -ErrorAction SilentlyContinue } catch {}
} else {
    ProgressBar "SFC Scan (sync)" 10 $start
    sfc /scannow
    ProgressBar "SFC Scan (sync)" 100 $start
}
Line

# ---------- NETWORK (NO DNS) ----------
Title "NETWORK OPTIMIZATION"
try { netsh interface tcp set global autotuninglevel=normal | Out-Null } catch {}
try { netsh interface tcp set global rss=enabled | Out-Null } catch {}
try { netsh interface tcp set global chimney=disabled | Out-Null } catch {}
Write-Host "| Network stack optimized (DNS unchanged)             |" -ForegroundColor Green
Line

# ---------- GPU ----------
Title "GPU OPTIMIZATION"
try {
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null
} catch {}
if ($gpu.Name -match "NVIDIA") {
    Write-Host "| NVIDIA detected - set 'Prefer maximum performance' in vendor control panel |" -ForegroundColor Green
} elseif ($gpu.Name -match "AMD") {
    Write-Host "| AMD detected - use Radeon performance profile |" -ForegroundColor Green
} else {
    Write-Host "| Intel or unknown GPU detected |" -ForegroundColor Green
}
Line

# ---------- DRIVER REFRESH ----------
Title "DRIVER REFRESH"
try { pnputil /scan-devices | Out-Null } catch {}
Write-Host "| Plug and Play rescan attempted                       |" -ForegroundColor Green
Line

# ---------- POWER PROFILE ----------
Title "POWER PROFILE"
if ($Profile -eq "Gaming") {
    try { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c } catch {}
    Write-Host "| Gaming power profile applied                          |" -ForegroundColor Green
} elseif ($Profile -eq "Developer") {
    try { powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e } catch {}
    Write-Host "| Developer power profile applied                       |" -ForegroundColor Green
} else {
    Write-Host "| LowImpact profile selected                             |" -ForegroundColor Green
}
Line

# ---------- FINAL BENCH ----------
$after = Benchmark

Title "PERFORMANCE COMPARISON"
foreach ($p in $before.PSObject.Properties.Name) {
    "{0,-15} : {1,8} -> {2,8}" -f $p,$before.$p,$after.$p | Write-Host -ForegroundColor Cyan
}
Line
Write-Host "NOTE: Full performance improvement occurs after reboot." -ForegroundColor Yellow

# ---------- SAFE REBOOT ----------
for ($i=30; $i -gt 0; $i--) {
    Write-Host "Rebooting in $i seconds... Press CTRL+C to cancel" -ForegroundColor Red
    Start-Sleep 1
}
Restart-Computer -Force
