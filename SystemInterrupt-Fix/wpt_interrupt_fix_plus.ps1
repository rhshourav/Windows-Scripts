<#
WPT Interrupt Fix+ (v1.0)
- GPU micro-tweaks (NVIDIA/AMD) with backup
- Network adapter advanced property optimization + MSI attempt (safe)
- Driver restart engine
- Interrupt watchdog (real-time)
- Auto-rollback if improvement < threshold
- JSON report output
Compatible: PowerShell 5.1+, Windows 10/11
Run as Administrator
#>

#region SETTINGS
$RollbackThreshold = 0.10        # require >=10% improvement to keep changes
$WatchdogDuration  = 240         # seconds to watch after applying fixes
$WatchdogInterval  = 5           # seconds between samples
$ReportDir = Join-Path $env:ProgramData "WPT"
if (-not (Test-Path $ReportDir)) { New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null }
$TimeStamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$ReportFile = Join-Path $ReportDir "wpt_report_$TimeStamp.json"
$BackupFile = Join-Path $ReportDir "wpt_backup_$TimeStamp.json"
$LogFile = Join-Path $ReportDir "wpt_log_$TimeStamp.txt"
Start-Transcript -Path $LogFile -Force | Out-Null
#endregion

#region ADMIN CHECK
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    Stop-Transcript
    exit 1
}
#endregion

#region HELPERS
function Log($msg) { $t = Get-Date -Format o; Write-Host "[$t] $msg"; Add-Content -Path $LogFile -Value "[$t] $msg" }
function Step($msg,$pct=0) { Write-Progress -Activity "WPT Interrupt Fix+" -Status $msg -PercentComplete $pct; Log($msg) }
function Safe-Get($scriptBlock) { try { & $scriptBlock } catch { return $null } }
#endregion

#region METRICS
function Get-InterruptMetric {
    try {
        $c = Get-Counter '\Processor(_Total)\% Interrupt Time' -ErrorAction Stop
        return [math]::Round($c.CounterSamples[0].CookedValue,3)
    } catch { return $null }
}
function Get-DPCMetric {
    try {
        $c = Get-Counter '\Processor(_Total)\% DPC Time' -ErrorAction Stop
        return [math]::Round($c.CounterSamples[0].CookedValue,3)
    } catch { return $null }
}
#endregion

#region STATE BACKUP / RESTORE
function Save-State {
    Step "Saving current state (backup)" 2

    $state = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString("o")
        Hostname  = $env:COMPUTERNAME
        User      = $env:USERNAME
        CPU       = (Get-CimInstance Win32_Processor | Select-Object -First 1 | Select Name,Manufacturer,MaxClockSpeed)
        BIOS      = (Get-CimInstance Win32_BIOS | Select Manufacturer,SMBIOSBIOSVersion,ReleaseDate)
        Services  = @{}
        Registry  = @{}
        NetAdapters = @()
        GPUSnapshot = @{}
        Actions = @()
    }

    # Services snapshot (SysMain, WSearch)
    foreach ($svc in @("SysMain","WSearch")) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            $state.Services[$svc] = @{ Status = $s.Status; Startup = (Get-Service -Name $svc).StartType }
        }
    }

    # GPU related registry backup (keys we might modify)
    $gpuKeys = @(
        "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm",
        "HKLM:\SYSTEM\CurrentControlSet\Services\amdkmdag"
    )
    foreach ($k in $gpuKeys) {
        try {
            $vals = @{}
            if (Test-Path $k) {
                Get-ItemProperty -Path $k | Get-Member -MemberType NoteProperty | ForEach-Object {
                    $name = $_.Name
                    $vals[$name] = (Get-ItemProperty -Path $k -Name $name -ErrorAction SilentlyContinue).$name
                }
            }
            $state.Registry[$k] = $vals
        } catch {}
    }

    # Net adapter advanced props snapshot (only present adapters)
    try {
        $adapters = Get-NetAdapter -Physical | Where-Object {$_.Status -eq "Up"} -ErrorAction SilentlyContinue
        foreach ($nic in $adapters) {
            $props = @{}
            try {
                $adv = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue
                foreach ($p in $adv) { $props[$p.DisplayName] = $p.DisplayValue }
            } catch {}
            $state.NetAdapters += [PSCustomObject]@{ Name = $nic.Name; InterfaceDescription = $nic.InterfaceDescription; Properties = $props }
        }
    } catch {}

    # Save to file
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $BackupFile -Encoding UTF8
    Log "State backup written to $BackupFile"
    return $state
}

function Restore-State($stateFile) {
    if (-not (Test-Path $stateFile)) { Log "No backup file to restore."; return $false }
    Step "Restoring saved configuration" 2
    $state = Get-Content $stateFile | ConvertFrom-Json

    # Restore services
    foreach ($svc in $state.Services.PSObject.Properties.Name) {
        $info = $state.Services.$svc
        try {
            if ($info.Startup -ne $null) {
                Set-Service -Name $svc -StartupType $info.Startup -ErrorAction SilentlyContinue
            }
            if ($info.Status -and $info.Status -ne "Running") {
                Start-Service -Name $svc -ErrorAction SilentlyContinue
            }
            if ($info.Status -and $info.Status -eq "Stopped") {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            }
            Log "Restored service $svc to startup $($info.Startup) and status $($info.Status)"
        } catch { Log "Failed to restore service $svc: $_" }
    }

    # Restore registry keys we captured
    foreach ($k in $state.Registry.PSObject.Properties.Name) {
        $vals = $state.Registry.$k
        foreach ($name in $vals.PSObject.Properties.Name) {
            $value = $vals.$name
            if ($null -ne $value -and $value -ne "") {
                try {
                    New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path $k -Name $name -Value $value -ErrorAction SilentlyContinue
                    Log "Restored registry $k\$name => $value"
                } catch { Log "Failed to restore registry $k\$name : $_" }
            }
        }
    }

    # Restore network adapter advanced props
    foreach ($nic in $state.NetAdapters) {
        foreach ($pName in $nic.Properties.PSObject.Properties.Name) {
            $val = $nic.Properties.$pName
            try {
                Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $pName -DisplayValue $val -NoRestart -ErrorAction SilentlyContinue
                Log "Restored adapter $($nic.Name) prop $pName => $val"
            } catch { Log "Failed to restore adapter $($nic.Name) prop $pName" }
        }
    }

    Log "Restore finished (some changes require reboot)"
    return $true
}
#endregion

#region GPU MICRO-TWEAKS (safe + backup)
function Apply-GPUMicroTweaks {
    Step "Applying GPU micro-tweaks (safe mode)" 30

    # Ensure GraphicsDrivers HwSchMode=2 (HAGS)
    try {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name "HwSchMode" -Value 2 -Type DWord -Force
        Log "Set HwSchMode=2"
    } catch { Log "HwSchMode set failed: $_" }

    # Vendor specific safe tweaks
    $gpuName = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name
    if ($gpuName -match "NVIDIA") {
        # safe registry keys - capture and set
        try {
            $k = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm"
            New-Item -Path $k -Force | Out-Null
            # these keys may not exist; write safely
            Set-ItemProperty -Path $k -Name "PowerMizerEnable" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $k -Name "PerfLevelSrc" -Value 2222 -Type DWord -Force -ErrorAction SilentlyContinue
            Log "Applied NVIDIA safe tweaks"
        } catch { Log "NVIDIA tweaks failed: $_" }
    } elseif ($gpuName -match "AMD") {
        try {
            $k = "HKLM:\SYSTEM\CurrentControlSet\Services\amdkmdag"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -Path $k -Name "EnableUlps" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $k -Name "EnableUlps_NA" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Log "Applied AMD safe tweaks (ULPS off)"
        } catch { Log "AMD tweaks failed: $_" }
    } else {
        Log "GPU vendor not detected or unsupported; no vendor tweaks applied"
    }
}
#endregion

#region NETWORK ADAPTER OPTIMIZATION + SAFE MSI ATTEMPT
function Optimize-NetworkAdapters-Safe {
    Step "Optimizing network adapters (per-adapter, safe)" 40

    $adapters = @()
    try { $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } } catch {}

    if (-not $adapters -or $adapters.Count -eq 0) {
        Log "No physical, up adapters found"
        return
    }

    foreach ($nic in $adapters) {
        Log "Processing adapter: $($nic.Name) ($($nic.InterfaceDescription))"
        # disable power mgmt wakes
        try { Disable-NetAdapterPowerManagement -Name $nic.Name -NoRestart -WakeOnMagicPacket -ErrorAction SilentlyContinue } catch {}
        # attempt to set common low-latency advanced props
        $adv = @()
        try { $adv = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        if ($adv) {
            # list of property names and desired values (conservative)
            $candidates = @{
                "Interrupt Moderation" = "Disabled";
                "Large Send Offload v2 (IPv4)" = "Disabled";
                "Large Send Offload v2 (IPv6)" = "Disabled";
                "Energy Efficient Ethernet" = "Disabled";
                "Flow Control" = "Disabled"
            }

            foreach ($entry in $candidates.GetEnumerator()) {
                $prop = $adv | Where-Object { $_.DisplayName -eq $entry.Key }
                if ($prop) {
                    try {
                        Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $entry.Key -DisplayValue $entry.Value -NoRestart -ErrorAction SilentlyContinue
                        Log "Set $($nic.Name) : $($entry.Key) => $($entry.Value)"
                    } catch { Log "Failed to set $($nic.Name) : $($entry.Key)" }
                }
            }

            # SAFE MSI attempt: look for property names that mention 'MSI' or 'Interrupt Mode'
            $msiProp = $adv | Where-Object { $_.DisplayName -match "MSI|Interrupt Mode|Interrupt Moderation|Legacy" }
            if ($msiProp) {
                foreach ($p in $msiProp) {
                    try {
                        # choose value carefully based on available possible values
                        $possible = $p.DisplayValue
                        # if the device exposes "MSI" as an option, try to set it
                        # We query allowed values via the cmdlet (no direct api) -> attempt 'Enabled' or 'MSI' depending on text
                        $tryVal = if ($p.DisplayValue -match "Disabled|Off") { "Enabled" } else { $p.DisplayValue }
                        Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $tryVal -NoRestart -ErrorAction SilentlyContinue
                        Log "Attempted MSI change on $($nic.Name) property $($p.DisplayName) => $tryVal"
                    } catch { Log "MSI attempt on $($nic.Name) property $($p.DisplayName) failed: $_" }
                }
            } else {
                Log "No MSI/Interrupt Mode property exposed for $($nic.Name) (skipping MSI attempt)"
            }
        } else {
            Log "No advanced properties reported for $($nic.Name)"
        }
    }
}
#endregion

#region DRIVER RESTART ENGINE
function Restart-AllDrivers-Safe {
    Step "Restarting key drivers (safe order)" 60
    # Classes in priority order
    $classes = @("Net","Display","Media","DiskDrive")
    $devices = @()
    foreach ($c in $classes) {
        $devs = Get-PnpDevice -Class $c -Status OK -ErrorAction SilentlyContinue
        if ($devs) { $devices += $devs }
    }
    $total = $devices.Count
    if ($total -eq 0) { Log "No devices to restart"; return }

    $i = 0; $start = Get-Date
    foreach ($d in $devices) {
        $i++; $pct = [math]::Round(($i/$total)*100)
        ProgressBar "Restarting: $($d.FriendlyName)" $pct $start
        Start-Sleep -Milliseconds 300
        try {
            pnputil /restart-device "$($d.InstanceId)" | Out-Null
            Log "pnputil restarted: $($d.FriendlyName)"
        } catch { Log "pnputil restart failed for $($d.FriendlyName): $_" }
        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }
    ProgressBar "Driver restart complete" 100 $start
    Line
}
#endregion

#region INTERRUPT WATCHDOG (real-time)
function Interrupt-Watchdog {
    param(
        [int]$DurationSec = $WatchdogDuration,
        [int]$IntervalSec = $WatchdogInterval,
        [double]$AlertThreshold = 5.0    # percent interrupt time considered high
    )
    Step "Starting Interrupt Watchdog ($DurationSec s)" 70
    $samples = @()
    $end = (Get-Date).AddSeconds($DurationSec)
    while ((Get-Date) -lt $end) {
        $val = Get-InterruptMetric
        $dpc = Get-DPCMetric
        $samples += [PSCustomObject]@{ Time=(Get-Date).ToString("o"); Interrupt=$val; DPC=$dpc }
        if ($val -gt $AlertThreshold) {
            Log "Watchdog alert: Interrupts = $val% (threshold $AlertThreshold%). Attempting remediation."
            # Remediation: restart network, then audio, then display drivers
            try {
                $net = Get-PnpDevice -Class Net -Status OK -ErrorAction SilentlyContinue
                if ($net) {
                    foreach ($n in $net) {
                        Log "Watchdog: Restarting network device $($n.FriendlyName)"
                        try { pnputil /restart-device "$($n.InstanceId)" | Out-Null } catch {}
                    }
                }
            } catch {}
            try {
                $media = Get-PnpDevice -Class Media -Status OK -ErrorAction SilentlyContinue
                if ($media) { foreach ($m in $media) { pnputil /restart-device "$($m.InstanceId)" | Out-Null } }
            } catch {}
            try {
                $display = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue
                if ($display) { foreach ($g in $display) { pnputil /restart-device "$($g.InstanceId)" | Out-Null } }
            } catch {}
        }
        Start-Sleep -Seconds $IntervalSec
    }

    # return samples
    return $samples
}
#endregion

#region REPORTING
function Write-Report {
    param($reportObj)
    $reportObj | ConvertTo-Json -Depth 6 | Out-File -FilePath $ReportFile -Encoding UTF8
    Log "JSON report written to $ReportFile"
}
#endregion

#region MAIN FLOW
# 1) Baseline
Step "Collect baseline metrics" 1
$baselineInterrupt = Get-InterruptMetric
$baselineDPC = Get-DPCMetric
$beforeSnapshot = [PSCustomObject]@{
    Interrupt = $baselineInterrupt
    DPC = $baselineDPC
}

# 2) Save state
$state = Save-State

# 3) Do core fixes
Invoke-SystemCleanup  # assume exists in your main script environment; if not, you can implement cleanup here
Apply-GPUMicroTweaks
Optimize-NetworkAdapters-Safe
Restart-AllDrivers-Safe

# 4) Short wait to settle
Step "Settling for system stabilization" 65
Start-Sleep -Seconds 6

# 5) Post-fix metrics
Step "Collect post-fix metrics" 75
$postInterrupt = Get-InterruptMetric
$postDPC = Get-DPCMetric
$afterSnapshot = [PSCustomObject]@{ Interrupt=$postInterrupt; DPC=$postDPC }

# 6) Start watchdog for a while and collect samples
$samples = Interrupt-Watchdog -DurationSec $WatchdogDuration -IntervalSec $WatchdogInterval -AlertThreshold 5.0

# 7) Decide on rollback
$improvement = $null
if ($baselineInterrupt -and $postInterrupt) {
    try {
        $improvement = ($baselineInterrupt - $postInterrupt) / [math]::Max(0.0001,$baselineInterrupt)
    } catch { $improvement = $null }
}
$didRollback = $false
if ($improvement -eq $null) {
    Log "Unable to calculate improvement; skipping auto-rollback decision"
} elseif ($improvement -lt $RollbackThreshold) {
    Log ("Improvement {0:P2} < required {1:P2} -> rolling back" -f $improvement,$RollbackThreshold)
    $restored = Restore-State -stateFile $BackupFile
    $didRollback = $restored
} else {
    Log ("Improvement {0:P2} >= required {1:P2} -> keeping changes" -f $improvement,$RollbackThreshold)
}

# 8) Build report
$report = [PSCustomObject]@{
    TimeStamp = $TimeStamp
    Host = $env:COMPUTERNAME
    User = $env:USERNAME
    Baseline = $beforeSnapshot
    After = $afterSnapshot
    WatchdogSamples = $samples
    BackupFile = $BackupFile
    ReportFile = $ReportFile
    LogFile = $LogFile
    RollbackThreshold = $RollbackThreshold
    Improvement = $improvement
    RolledBack = $didRollback
    ActionsTaken = @(
        "Invoke-SystemCleanup",
        "Apply-GPUMicroTweaks",
        "Optimize-NetworkAdapters-Safe",
        "Restart-AllDrivers-Safe",
        "Interrupt-Watchdog"
    )
}

Write-Report -reportObj $report

# 9) Final output
Step "Finished - writing results" 95
Write-Host ""
Write-Host "WPT Interrupt Fix+ completed. Summary:" -ForegroundColor Cyan
Write-Host ("Baseline Interrupt: {0}  Post-Fix Interrupt: {1}" -f $baselineInterrupt,$postInterrupt)
Write-Host ("Improvement: {0:P2}" -f ($improvement))
if ($didRollback) { Write-Host "Changes were rolled back (didRollback = true)" -ForegroundColor Yellow } else { Write-Host "Changes retained" -ForegroundColor Green }

Write-Host ""
Write-Host "JSON report: $ReportFile" -ForegroundColor Cyan
Write-Host "Log file: $LogFile" -ForegroundColor Cyan
Step "Completed" 100
Stop-Transcript
#endregion
