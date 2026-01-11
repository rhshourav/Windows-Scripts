<#
Author: rhshourav
Version: 9.0.b
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



#region Utilities & Checks
function Check-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'ERROR: Please run as Administrator.' -ForegroundColor Red
        Exit 1
    }
}

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
    # Try modern Storage module first
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop
        if ($pd) {
            # If multiple disks, prefer system disk by simple heuristic (MediaType first)
            $media = ($pd | Select-Object -First 1).MediaType
            return ($media -ne $null) ? $media.ToString() : 'Unknown'
        }
    } catch { }

    # Fallback: WMI - look for 'SSD' or 'Solid State' in model or media type
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
Write-Host "=== Windows Optimization Script v9.0.b ===" -ForegroundColor Cyan
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
