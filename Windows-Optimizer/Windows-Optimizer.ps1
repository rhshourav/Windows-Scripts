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
    Write-Info 'Backing up current services...'
    try {
        $file = Join-Path $SvcBackupDir "Services_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        Get-Service | Select Name, Status, StartType |
            Export-Csv -Path $file -NoTypeInformation -Force
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

        Write-Warn "Selected restore point:"
        Write-Warn " $($rp.Description)"

        $confirm = Read-Host "Type 'YES' to restore system"
        if ($confirm -ne 'YES') {
            Write-Info "Rollback aborted."
            return
        }

        $result = Invoke-SystemRestore -SequenceNumber $rp.SequenceNumber

        if ($result.ReturnValue -eq 0) {
            Write-Succ "System Restore initiated. Reboot will occur."
        } else {
            Write-Err "Restore failed with code: $($result.ReturnValue)"
        }
    }
    catch {
        Write-Err "Rollback failed: $($_.Exception.Message)"
    }
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
        [string]$CsvFile
    )

    if (-not (Test-Path $CsvFile)) {
        Write-Err "Service backup file not found."
        return
    }

    $services = Import-Csv $CsvFile
    foreach ($svc in $services) {
        try {
            Set-Service -Name $svc.Name -StartupType $svc.StartType -ErrorAction SilentlyContinue
            if ($svc.Status -eq 'Running') {
                Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warn "Failed restoring service: $($svc.Name)"
        }
    }

    Write-Succ "Service restore completed."
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

    Get-ChildItem $BackupPath -Filter *.xml -Recurse | ForEach-Object {
        try {
            Register-ScheduledTask `
                -TaskName $_.BaseName `
                -Xml (Get-Content $_.FullName -Raw) `
                -Force
        } catch {
            Write-Warn "Failed restoring task: $($_.Name)"
        }
    }

    Write-Succ "Scheduled task restore completed."
}

#endregion
#region compare Banchmark
function Compare-Benchmark {
    param ($Current)

    $history = Get-ChildItem $BenchDir -Filter "Benchmark_*.json" -ErrorAction SilentlyContinue

    if ($history.Count -eq 0) {
        $Current | ConvertTo-Json | Out-File "$BenchDir\Benchmark_Last.json"
        Write-Host "[INFO] No previous benchmark found. Baseline saved." -ForegroundColor Yellow
        return
    }

    $previous = Get-Content "$BenchDir\Benchmark_Last.json" | ConvertFrom-Json

    Write-Host "`n[COMPARISON] Previous vs Current:" -ForegroundColor Cyan

    $comparison = @(
    [PSCustomObject]@{ Metric="CPU";      Before=$previous.CPU;      After=$Current.CPU }
    [PSCustomObject]@{ Metric="Memory";   Before=$previous.Memory;   After=$Current.Memory }
    [PSCustomObject]@{ Metric="Graphics"; Before=$previous.Graphics; After=$Current.Graphics }
    [PSCustomObject]@{ Metric="Gaming";   Before=$previous.Gaming;   After=$Current.Gaming }
    [PSCustomObject]@{
        Metric="Disk"
        Before="$($previous.Disk) ($($previous.DiskType))"
        After="$($Current.Disk) ($($Current.DiskType))"
    }
)

$comparison | Format-Table -AutoSize
$comparison | Out-File $Global:CompareFile -Append


    $Current | ConvertTo-Json | Out-File "$BenchDir\Benchmark_Last.json"
}

#endregion
#region WinSAT Score
function Get-WinSATScore {
    $xmlPath = Get-ChildItem "$env:WinDir\Performance\WinSAT\DataStore" `
        -Filter "*Formal*.xml" |
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
    $BenchFile = Join-Path $BenchDir "Benchmark_$timestamp.txt"

    Write-Host "`n[ACTION] Running Windows System Assessment (WinSAT)" -ForegroundColor Cyan
    Write-Host "[INFO] Output file: $BenchFile" -ForegroundColor DarkGray
    Write-Host "[ACTION] This may take several minutes..." -ForegroundColor Yellow

    winsat formal | Tee-Object -FilePath $BenchFile

    Write-Host "[SUCCESS] Benchmark completed." -ForegroundColor Green
    Write-Host "[INFO] Raw output saved to:" -ForegroundColor Cyan
    Write-Host " $BenchFile`n"

    $current = Get-WinSATScore
    $current | Add-Member Profile $Global:ActiveProfile -Force

    Show-BenchmarkResults $current
    Compare-Benchmark $current }

#endregion

#region Tweaks (each function prints status)
function Disable-WindowsDefender {
    param([Switch]$Force)
    Write-Info 'Disabling Windows Defender components (policy & realtime)...'
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Succ 'Windows Defender disabled via policy (if present).'
    } catch {
        Write-Warn "Unable to fully disable Defender with cmdlets: $_"
    }
}

function Disable-WindowsUpdate {
    Write-Info 'Stopping and disabling Windows Update (wuauserv)...'
    try { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
    Write-Succ 'Windows Update service stopped/disabled (if present).'
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
Write-Host "=== Windows Optimization Script v7.0.b ===" -ForegroundColor Cyan
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
