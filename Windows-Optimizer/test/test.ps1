# Aggressive Windows Optimization Script (PowerShell)
# Designed for interactive use (e.g. via iwr ... | iex). Requires admin.

function Check-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) { Write-Host 'ERROR: Please run as Administrator.' -ForegroundColor Red; Exit 1 }
}

function Create-RestorePoint {
    Write-Host 'Creating system restore point...'
    try {
        $rpName = "WinOpt Restore - $(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
        Checkpoint-Computer -Description $rpName -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Host "Restore point created: $rpName" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to create restore point: $_"
    }
}

function Backup-Services {
    Write-Host 'Backing up current services...'
    $file = "$env:TEMP\ServicesBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Get-Service | Select Name, Status, StartType | Export-Csv -Path $file -NoTypeInformation
    Write-Host "Services backed up to $file" -ForegroundColor Green
}

function Backup-ScheduledTasks {
    Write-Host 'Backing up current scheduled tasks...'
    $backupPath = "$env:TEMP\TasksBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    $tasks = Get-ScheduledTask
    foreach ($task in $tasks) {
        try {
            $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            $taskName = ($task.TaskName -replace '[\\/:\*\?"<>|]','_')
            $path = Join-Path $backupPath ($task.TaskPath.TrimStart('\'))
            if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
            Out-File -FilePath (Join-Path $path "$taskName.xml") -InputObject $xml -Encoding ASCII
        } catch { }
    }
    Write-Host "Scheduled tasks backed up to $backupPath" -ForegroundColor Green
}

function Rollback-ToRestorePoint {
    Write-Host 'Attempting rollback to last restore point...'
    $rp = Get-WmiObject -Class Win32_RestorePoint |
           Sort-Object SequenceNumber -Descending | Select-Object -First 1
    if ($rp) {
        Write-Host "Restoring to: $($rp.Description)..."
        $systemRestore = Get-WmiObject -Class Win32_SystemRestore
        $systemRestore.Restore($rp.SequenceNumber) | Out-Null
        Write-Host "Rollback initiated." -ForegroundColor Yellow
    } else {
        Write-Warning 'No restore point found to roll back to.'
    }
}

function Disable-WindowsDefender {
    param([Switch]$Force)
    Write-Host 'Disabling Windows Defender components...'
    # Turn off real-time monitoring
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    # Apply policy to disable Defender
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
        -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host 'Windows Defender disabled (policy set).' -ForegroundColor Yellow
}

function Disable-WindowsUpdate {
    Write-Host 'Disabling Windows Update service...'
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled
    Write-Host 'Windows Update service disabled.' -ForegroundColor Yellow
}

function Disable-SearchIndexing {
    Write-Host 'Disabling Windows Search indexing service...'
    Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
    Set-Service -Name WSearch -StartupType Disabled
    Write-Host 'Windows Search indexing disabled.' -ForegroundColor Yellow
}

function Disable-CortanaWebSearch {
    Write-Host 'Disabling Cortana and web search...'
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
        -Name 'AllowCortana' -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
        -Name 'ConnectedSearchUseWeb' -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Host 'Cortana/web search disabled via policy.' -ForegroundColor Yellow
}

function Remove-BuiltInApps {
    Write-Host 'Removing built-in Windows Store apps...'
    $apps = Get-AppxPackage -AllUsers
    foreach ($app in $apps) {
        try { Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        catch { }
    }
    $prov = Get-AppxProvisionedPackage -Online
    foreach ($pkg in $prov) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue }
        catch { }
    }
    Write-Host 'AppX packages removed.' -ForegroundColor Yellow
}

function Optimize-Gaming {
    Write-Host 'Applying Gaming optimization profile...'
    # Disable Superfetch (SysMain) for gaming
    Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
    Set-Service -Name SysMain -StartupType Disabled
    # Adjust GPU scheduling (set HwSchMode=2 in registry)
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' `
        -Name 'HwSchMode' -Value 2 -Type DWord -Force
    Write-Host 'Gaming tweaks applied: SysMain disabled, GPU scheduling set to 2.' -ForegroundColor Green
}

function Optimize-LowEnd {
    Write-Host 'Applying Low-End optimization profile...'
    Disable-SearchIndexing
    # Disable telemetry collection via registry
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
        -Name 'AllowTelemetry' -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Host 'Telemetry disabled.' -ForegroundColor Yellow
    # Stop additional low-priority services
    $svcs = @('DiagTrack','WMPNetworkSvc','MapsBroker','lfsvc')
    foreach ($svc in $svcs) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled
    }
    Write-Host 'Low-End profile applied.' -ForegroundColor Green
}

function Optimize-Developer {
    Write-Host 'Applying Developer/Workstation profile...'
    # Disable UI animations (set visual effects to best performance)
    $perfKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    New-Item -Path $perfKey -Force | Out-Null
    Set-ItemProperty -Path $perfKey -Name 'VisualFXSetting' -Value 2 -Type DWord -Force
    Write-Host 'Developer tweaks applied: animations off, responsiveness maximized.' -ForegroundColor Green
}

function Optimize-Minimal {
    Write-Host 'Applying Debloated Minimal OS profile...'
    Disable-CortanaWebSearch
    Remove-BuiltInApps
    Write-Host 'Minimal OS tweaks applied.' -ForegroundColor Green
}

# Main interactive menu
Clear-Host
Check-Admin
Start-Transcript -Path "$env:TEMP\WinOpt_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" | Out-Null
Write-Host "=== Windows Optimization Script ===" -ForegroundColor Cyan
Write-Host "Select a profile to apply:"
Write-Host " 1) Gaming Performance"
Write-Host " 2) Low-End System Optimization"
Write-Host " 3) Developer/Workstation Profile"
Write-Host " 4) Debloated Minimal OS"
Write-Host " 5) Custom Aggressive (All tweaks)"
Write-Host " Q) Quit"
do {
    $choice = Read-Host 'Enter choice [1-5, Q]'
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
            # All aggressive tweaks (with confirmations)
            if ((Read-Host "Apply all tweaks (DISABLE Defender, Update, Search, etc)? [Y/N]").ToUpper() -eq 'Y') {
                Create-RestorePoint; Backup-Services; Backup-ScheduledTasks
                Disable-WindowsDefender
                Disable-WindowsUpdate
                Disable-SearchIndexing
                Disable-CortanaWebSearch
                Remove-BuiltInApps
                Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
                Set-Service -Name SysMain -StartupType Disabled
                Write-Host 'All aggressive changes applied.' -ForegroundColor Magenta
            } else {
                Write-Host 'Aborting aggressive changes.' -ForegroundColor Yellow
            }
        }
        'Q' {
            Write-Host 'Exiting. Use System Restore to undo any changes if needed.' -ForegroundColor Cyan
            break
        }
        Default {
            Write-Host 'Invalid selection.' -ForegroundColor Red
        }
    }
} while ($choice -ne 'Q')
Stop-Transcript
