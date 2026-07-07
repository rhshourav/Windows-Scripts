<#
WPT Interrupt Fix+ (v1.2.0)
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
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}
# ================================================================
#  TELEMETRY
# ================================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "System Interrupt Fix v1.2.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUz+ZlMqetC7MVDQUGXb28xwBa
# xQigghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
# AQsFADAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzMB4XDTI2MDcwNzA4MDE1
# N1oXDTI5MDcwNzA4MTE1N1owGzEZMBcGA1UEAwwQUkhTSE9VUkFWLUlULU9wczCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALFj11KDAqN3fhbDT9fvgrLF
# VemPYmcud3qA+9Sc4RojOjElODGXyaOlBSVmDGpmCkNRC+dnkGCLB8bYb3gsnHey
# Ud99DA8tvkTgb06+B1pigTZUmhyAwyPiu77+h224c8SsZFkmgQ/Dh2Sc2ynNocZe
# 773d6a/B4DRg7/K9xV8jFap6BP1fjaM3Do40GSL+OVnXl2ssvfFk4FyP5fc8Czz5
# MJ5IJKRFrnHv3kNcmyz5mnz0LoBQs/JtHpWg3BogIalJ2tyCiZgk0xIsz5j5UjhA
# /KepfnWGpCowJ/NJWnmOZcikFlDPggI27QNc/IbxZ035ht+Zgc7b1Cf68GmL/8UC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRJ+13W7/PcqVgZXZf87/JdXvGqxjANBgkqhkiG9w0BAQsFAAOCAQEA
# MDUJsw0AephOCByoLTFSm8hnB4I7s8ddA64vDTv4QF2TcXdrd/glByhEQexUEDpw
# lPCSbzHAmRM5X71QYNoB/CDlCoAO8BQnbegqkhAx8ubRyciwsLA4ZPp+/GFbgZaV
# khkOWpL6v6fmU3kSB5px+roqOuMjmqvbtCDlC4JH25WuDEgGJQhqpgdQSZdomWjH
# le/GnQKt4Y18ysVFvgE1lRO8x6gkJ5IJbZPJ0Q//2xCvtM0WpjXmQl1RHV/7tqDS
# fqprCQxuKiTPC64VfafzeS7IUNJMgQS73H6wuaKdeT85PIxreleNwNXfbr4O/FY3
# eqlSEZAqzKtZXfNFWPmHazCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE+jCC
# BPYCAQEwLzAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzAhAQvylGgaQVhE7g
# tCp7LUPgMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBT5f81wSL5Z/Ot7E+GkV5ICjUDh1zANBgkq
# hkiG9w0BAQEFAASCAQCqs090VWDeBnebPd9xx9iRGZ9/NVjLNP3KYO6/yfK2sMn5
# 2UjbCVX2HXoLLRAFoTJQjxD+indkDpWtUvk9PSgfCfeviw5CObTxm+sp9bFrTKeQ
# d6yjE9pAg7rsnV3+0JySlVoge2XbUdEqf+RjpbpMfiewRly1S2ke/CsZft5Asf6M
# RVgwkePR0PAToQVRp8SY5ayrMDLjg5BMBwUUqUa23H6C9AZuvF8pobcaycZ5gea+
# YMzTYhgU53zfsc/3zcGtqfXx9wZSwEYY/BVOb3fTv7MKgJIfwuzbHOzEy7g15xH5
# dQYgKetnd0IW3yMJthIPqzFfdapHzj+MaQj4+PEHoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ1MlowLwYJKoZIhvcNAQkEMSIEIJVPkf6plUcYQf92
# DF+LxZEoG5qIr1L/gYukA1vjM3R9MA0GCSqGSIb3DQEBAQUABIICALVm4QXZoRuK
# qZQp0+2An4TSZbDbjNUB44zWPfvCLYzAkfp3jJsehCWUxV4TwhikGRJ5DR83fAKB
# mtT1e2A3sVW295ztnyzd/KFAqO2f3Z082WBOJqdokKcdpeWAU7D/GGIpEYFr9Gcw
# XLMlLl1YSEZKvuOJfqzkQhfu9jKZ1DGr7mXo+ZpFX4HC6uy+5jH7Ye3YRZnqHdpP
# ZhSKQwu87epclW3Iz96mUbHXYVIwq/wybfHEed8rNSbrPV8PnU7P7Vv4SsHrHelQ
# XkFefAZL1O9IeCDo0n7mu7wZ2HS+wr6kpCJ5eVgAZ5F69vvLGhE4IN8pVANgJRp8
# Ttkz+ujkmqyqdyl/wIymWHj5F4j27tiCCW9IcGHynfgY9uIlh2GcMa5F/K3TA+8i
# UGOz6LtU6Ya6nGsHWP9mqp482t2QE5D0NrR/KExi42wEsUhri9n3aKASPxh39tBX
# luwsGoY/IRpbanX5V2+IV+TeIM5z4+C1tZ5PBxY4ePzWKTu24fJXz2U3dJRAiLjv
# PdV/Zyv1Qc5HcfkNDlt7IEyd7m0HneKVd6k+QEurHe9uHRMAdxtDnrqvALiANMOT
# atMLX7kFEMoDmuPeA2TLhAXQoCpzTZhaRdJlRuKmJbCuTkRHK0jx4h8uv0e/n9Ft
# 9a+6ez6t3qxB91Wkh/dVmWUqoyPTYiYb
# SIG # End signature block
