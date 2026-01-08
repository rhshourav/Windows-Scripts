<#
Author: rhshourav
Version: 7.0.b
GitHub: https://github.com/rhshourav
Notes: Requires Administrator. Tested for PowerShell 5.1 and PowerShell 7.x compatibility.
#>

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
    Write-Info 'Creating system restore point...'
    try {
        $rpName = "WinOpt Restore - $(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
        Checkpoint-Computer -Description $rpName -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Succ "Restore point created: $rpName"
    } catch {
        Write-Warn "Failed to create restore point: $_"
    }
}

function Backup-Services {
    Write-Info 'Backing up current services...'
    try {
        $file = "$env:TEMP\ServicesBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        Get-Service | Select Name, Status, StartType | Export-Csv -Path $file -NoTypeInformation -Force
        Write-Succ "Services backed up to $file"
    } catch {
        Write-Warn "Failed to backup services: $_"
    }
}

function Backup-ScheduledTasks {
    Write-Info 'Backing up scheduled tasks...'
    try {
        $backupPath = "$env:TEMP\TasksBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            try {
                $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
                $taskName = ($task.TaskName -replace '[\\/:\*\?"<>|]','_')
                $path = Join-Path $backupPath ($task.TaskPath.TrimStart('\'))
                if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
                Out-File -FilePath (Join-Path $path "$taskName.xml") -InputObject $xml -Encoding ASCII -Force
            } catch { Write-Warn "Skipping task $($task.TaskName): $_" }
        }
        Write-Succ "Scheduled tasks backed up to $backupPath"
    } catch {
        Write-Warn "Failed to backup tasks: $_"
    }
}

function Rollback-ToRestorePoint {
    Write-Info 'Locating latest restore point...'
    try {
        $rp = Get-WmiObject -Class Win32_RestorePoint -ErrorAction SilentlyContinue |
              Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($rp) {
            Write-Warn "About to restore to: $($rp.Description) (Seq: $($rp.SequenceNumber)). This will initiate system restore and may reboot."
            $confirm = Read-Host "Proceed with rollback? Type 'YES' to continue"
            if ($confirm -ne 'YES') { Write-Info 'Rollback aborted by user.'; return }
            $systemRestore = Get-WmiObject -Class Win32_SystemRestore
            $res = $systemRestore.Restore($rp.SequenceNumber)
            Write-Succ "Restore command issued. Return: $res. System will handle the actual restore process."
        } else {
            Write-Warn 'No restore point found to roll back to.'
        }
    } catch {
        Write-Err "Restore failed: $_"
    }
}
#endregion

#region Benchmarks
function Run-Benchmark {
    Write-Info 'Running Windows Experience Index (WinSAT formal). This can take several minutes...'
    try {
        if (Get-Command winsat -ErrorAction SilentlyContinue) {
            winsat formal | Out-Null
            $score = Get-WmiObject -Class Win32_WinSAT -ErrorAction SilentlyContinue
            if ($score) {
                Write-Host "Benchmark results (higher = better):"
                Write-Host "  CPU:    $($score.CPUScore)"
                Write-Host "  Memory: $($score.MemoryScore)"
                Write-Host "  Graphics (DX9): $($score.GraphicsScore)"
                Write-Host "  D3D:    $($score.D3DScore)"
                Write-Host "  Disk:   $($score.DiskScore)"
                $logFile = "$env:TEMP\WinOpt_Benchmark_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                $score | Select CPUScore,MemoryScore,GraphicsScore,D3DScore,DiskScore | Export-Csv -Path $logFile -NoTypeInformation
                Write-Succ "Benchmark complete. Results saved to $logFile"
            } else {
                Write-Warn "WinSAT ran but no Win32_WinSAT object found."
            }
        } else {
            Write-Warn "winsat command not found on this system."
        }
    } catch {
        Write-Err "Benchmark failed: $_"
    }
}
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
$transcriptFile = "$env:TEMP\WinOpt_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile | Out-Null

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
            Create-RestorePoint; Backup-Services; Backup-ScheduledTasks
            Optimize-Gaming
        }
        '2' {
            Create-RestorePoint; Backup-Services; Backup-ScheduledTasks
            Optimize-LowEnd
        }
        '3' {
            Create-RestorePoint; Backup-Services; Backup-ScheduledTasks
            Optimize-Developer
        }
        '4' {
            Create-RestorePoint; Backup-Services; Backup-ScheduledTasks
            Optimize-Minimal
        }
        '5' {
            $yn = Read-Host "Apply all aggressive tweaks (DISABLE Defender, Update, Search, etc)? [Y/N]"
            if ($yn.ToUpper() -eq 'Y') {
                Create-RestorePoint; Backup-Services; Backup-ScheduledTasks
                Disable-WindowsDefender
                Disable-WindowsUpdate
                Disable-SearchIndexing
                Disable-CortanaWebSearch
                Remove-BuiltInApps
                try { Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue } catch {}
                try { Set-Service -Name SysMain -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
                Write-Succ 'All aggressive changes applied.'
            } else {
                Write-Info 'Aborting aggressive changes.'
            }
        }
        '6' {
            Optimize-Eternal
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
Write-Host "Log saved to: $transcriptFile" -ForegroundColor Green
#endregion
