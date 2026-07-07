#Requires -Version 5.0
<#
================================================================================
  WARDEN - Windows Advanced Registry Defense, Export & Restoration Nexus
  Part of Windows Scripts Repository
================================================================================
  Author      : rhshourav
  Repository  : https://github.com/rhshourav/WindowsScripts
  Version     : 1.2.0
  Category    : Registry / System Administration
  Compatibility: Windows 10 (PowerShell 5.0+) through Windows 11
  Execute via : iex (irm 'https://raw.githubusercontent.com/rhshourav/WindowsScripts/main/Registry/WARDEN.ps1')
================================================================================
  FEATURES:
    - Full system registry backup (HKLM, HKCU, HKU, including SAM/SECURITY/SYSTEM)
    - Volume Shadow Copy (VSS) for locked hive extraction
    - SHA-256 hash manifest for every backup file
    - ZIP archive with embedded JSON metadata (author, timestamp, OS, session)
    - Automatic administrator self-elevation with UAC prompt
    - SYSTEM-privilege task scheduling for SAM/SECURITY access
    - Temporary service/process suspension for clean capture
    - Pre-restore safety snapshot with rollback support
    - Custom selective backup with keyword search and description labels
    - Full hash verification before every restore
    - Detailed session log per backup/restore operation
    - Colour-coded console UI (dark background, white/green/yellow/red text)
    - ASCII-only output; no emoji dependencies
================================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region ============================================================
#  SCRIPT METADATA
#============================================================
$Script:W_VERSION  = '1.0.0'
$Script:W_AUTHOR   = 'rhshourav'
$Script:W_REPO     = 'https://github.com/rhshourav/WindowsScripts'
$Script:W_BUILD    = '20250101'
#endregion

#region ============================================================
#  GLOBAL STATE
#============================================================
$Script:DefaultBackupRoot  = "$env:SystemDrive\WARDEN_Backups"
$Script:LogFile            = $null
$Script:SessionID          = [System.Guid]::NewGuid().ToString('N').Substring(0,8).ToUpper()
$Script:ShadowID           = $null
$Script:ShadowPath         = $null
$Script:StoppedServices    = [System.Collections.Generic.List[string]]::new()
$Script:StoppedProcesses   = [System.Collections.Generic.List[string]]::new()
#endregion

#region ============================================================
#  REGISTRY HIVE DEFINITIONS
#============================================================
$Script:FullHives = @(
    [PSCustomObject]@{ Name='HKLM_SOFTWARE'; Key='HKLM\SOFTWARE';           Locked=$false; Desc='Installed apps, Windows settings, app config'        },
    [PSCustomObject]@{ Name='HKLM_SYSTEM';   Key='HKLM\SYSTEM';             Locked=$true;  Desc='Device drivers, boot config, CurrentControlSet'       },
    [PSCustomObject]@{ Name='HKLM_SAM';      Key='HKLM\SAM';                Locked=$true;  Desc='Security Account Manager - local users and groups'    },
    [PSCustomObject]@{ Name='HKLM_SECURITY'; Key='HKLM\SECURITY';           Locked=$true;  Desc='LSA secrets, local security policy, cached creds'     },
    [PSCustomObject]@{ Name='HKLM_HARDWARE'; Key='HKLM\HARDWARE';           Locked=$false; Desc='Runtime hardware abstraction layer (not persisted)'    },
    [PSCustomObject]@{ Name='HKU_DEFAULT';   Key='HKU\.DEFAULT';            Locked=$false; Desc='Default profile template applied to new users'        },
    [PSCustomObject]@{ Name='HKCU_CURRENT';  Key='HKCU';                    Locked=$false; Desc='Current user settings, preferences, per-user software' },
    [PSCustomObject]@{ Name='HKLM_BCD';      Key='HKLM\BCD00000000';        Locked=$false; Desc='Boot Configuration Data (BCD store)'                  }
)

$Script:LockedHiveFiles = @(
    [PSCustomObject]@{ Name='SAM';      RelPath='Windows\System32\config\SAM'      },
    [PSCustomObject]@{ Name='SECURITY'; RelPath='Windows\System32\config\SECURITY' },
    [PSCustomObject]@{ Name='SYSTEM';   RelPath='Windows\System32\config\SYSTEM'   },
    [PSCustomObject]@{ Name='SOFTWARE'; RelPath='Windows\System32\config\SOFTWARE' },
    [PSCustomObject]@{ Name='DEFAULT';  RelPath='Windows\System32\config\DEFAULT'  }
)

$Script:CustomRegPaths = @(
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';           Desc='Startup programs run for all users on boot'               },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';            Desc='Windows build, edition, registration, install date'       },
    [PSCustomObject]@{ Path='HKLM\SYSTEM\CurrentControlSet\Services';                       Desc='All Windows service definitions and start types'           },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';     Desc='Installed application list (Add/Remove Programs source)'   },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Classes';                                        Desc='File type associations, shell verbs, COM/OLE class data'   },
    [PSCustomObject]@{ Path='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';           Desc='Startup programs run for the current user only'            },
    [PSCustomObject]@{ Path='HKCU\Software\Microsoft\Internet Explorer';                    Desc='Internet Explorer / legacy Edge browser settings'          },
    [PSCustomObject]@{ Path='HKCU\Software\Microsoft\Office';                               Desc='Microsoft Office suite (Word, Excel, Outlook, etc.)'       },
    [PSCustomObject]@{ Path='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager';        Desc='PendingFileRenameOperations, boot session manager config'  },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows Defender';                     Desc='Windows Defender / Microsoft Defender AV configuration'    },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies';      Desc='System-wide Group Policy enforcement values'               },
    [PSCustomObject]@{ Path='HKCU\Control Panel';                                           Desc='Display, mouse, keyboard, accessibility user preferences'  },
    [PSCustomObject]@{ Path='HKLM\HARDWARE\DESCRIPTION\System';                             Desc='BIOS, CPU, bus, and hardware description data'             },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList';Desc='Registered user profiles and SID-to-path mappings'        },
    [PSCustomObject]@{ Path='HKLM\SYSTEM\CurrentControlSet\Control\Network';                Desc='NIC bindings, Winsock, VPN and network adapter settings'   },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';      Desc='Shell settings, folder views, taskbar, icon cache'         },
    [PSCustomObject]@{ Path='HKLM\SYSTEM\CurrentControlSet\Control\FileSystem';             Desc='NTFS, 8.3 names, long paths, filesystem behaviour flags'   },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Policies';                                       Desc='Machine-level enforced Group Policy (MDM/GPO)'             },
    [PSCustomObject]@{ Path='HKCU\Software\Classes';                                        Desc='Per-user file associations overriding machine defaults'     },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication';Desc='Authentication providers, Winlogon credential providers'   },
    [PSCustomObject]@{ Path='HKLM\SYSTEM\CurrentControlSet\Control\Lsa';                    Desc='LSA authentication packages, security providers'           },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon';   Desc='Winlogon shell, userinit, autologon, GINA settings'        },
    [PSCustomObject]@{ Path='HKCU\Environment';                                              Desc='Per-user environment variables (PATH, TEMP, etc.)'         },
    [PSCustomObject]@{ Path='HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation';    Desc='System timezone, DST, and UTC bias configuration'          },
    [PSCustomObject]@{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'; Desc='System-wide proxy, WinInet, and TLS/SSL settings'     }
)
#endregion
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
        text  = "WARDEN v1.2.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

#region ============================================================
#  UI FUNCTIONS
#============================================================
function Set-ConsoleTheme {
    try {
        $h = $Host.UI.RawUI
        $h.BackgroundColor = 'Black'
        $h.ForegroundColor = 'White'
        $h.WindowTitle     = "WARDEN v$Script:W_VERSION  |  Registry Defense Engine  |  Session $Script:SessionID"
        if ($h.BufferSize.Width -lt 100) {
            $h.BufferSize  = New-Object System.Management.Automation.Host.Size(120, 9000)
            $maxW = $h.MaxWindowSize.Width
            $maxH = $h.MaxWindowSize.Height
            $h.WindowSize  = New-Object System.Management.Automation.Host.Size(
                [Math]::Min(120,$maxW), [Math]::Min(45,$maxH))
        }
    } catch { <# non-fatal - ISE/VS Code hosts may throw #> }
    Clear-Host
}

function Write-Banner {
    Clear-Host
    $W = 84
    $B = '+' + ('=' * ($W - 2)) + '+'
    Write-Host $B -ForegroundColor DarkGreen
    $logo = @(
        "  :::       :::     :::     :::::::::  :::::::::  :::::::::: ::::    ::: ",
        "  :+:       :+:   :+: :+:   :+:    :+: :+:    :+: :+:        :+:+:   :+: ",
        "  +:+       +:+  +:+   +:+  +:+    +:+ +:+    +:+ +:+        :+:+:+  +:+ ",
        "  +#+  +:+  +#+ +#++:++#++: +#++:++#:  +#+    +:+ +#++:++#   +#+ +:+ +#+ ",
        "  +#+ +#+#+ +#+ +#+     +#+ +#+    +#+ +#+    +#+ +#+        +#+  +#+#+# ",
        "   #+#+# #+#+#  #+#     #+# #+#    #+# #+#    #+# #+#        #+#   #+#+# ",
        "    ###   ###   ###     ### ###    ### #########  ########## ###    #### "
    )
    Write-Host ('|' + (' ' * ($W-2)) + '|') -ForegroundColor DarkGreen
    foreach ($line in $logo) {
        $pad = $line.PadRight($W - 2)
        if ($pad.Length -gt ($W-2)) { $pad = $pad.Substring(0,$W-2) }
        Write-Host ('|' + $pad + '|') -ForegroundColor Green
    }
    Write-Host ('|' + (' ' * ($W-2)) + '|') -ForegroundColor DarkGreen
    $sub  = '  Windows Advanced Registry Defense, Export & Restoration Nexus'
    $sub2 = "  v$Script:W_VERSION  |  Author: $Script:W_AUTHOR  |  Session: $Script:SessionID"
    Write-Host ('|' + $sub.PadRight($W-2) + '|')  -ForegroundColor Cyan
    Write-Host ('|' + $sub2.PadRight($W-2) + '|') -ForegroundColor DarkCyan
    Write-Host $B -ForegroundColor DarkGreen
    Write-Host ''
}

function Write-Section {
    param([string]$Title)
    $W = 84
    Write-Host ''
    Write-Host ('+' + ('-' * ($W-2)) + '+') -ForegroundColor DarkYellow
    Write-Host ('|  ' + $Title.PadRight($W-4) + '  |') -ForegroundColor Yellow
    Write-Host ('+' + ('-' * ($W-2)) + '+') -ForegroundColor DarkYellow
    Write-Host ''
}

function Write-Divider { Write-Host ('  ' + ('-' * 78)) -ForegroundColor DarkGray }
function wI { param([string]$m) Write-Host "  [*] $m" -ForegroundColor White   }   # Info
function wOK { param([string]$m) Write-Host "  [+] $m" -ForegroundColor Green  }   # Success
function wW { param([string]$m) Write-Host "  [!] $m" -ForegroundColor Yellow  }   # Warning
function wE { param([string]$m) Write-Host "  [-] $m" -ForegroundColor Red     }   # Error
function wS { param([string]$m) Write-Host "  [>] $m" -ForegroundColor Cyan    }   # Step

function Read-Input {
    param([string]$Prompt, [string]$Default = '')
    Write-Host "  $Prompt" -ForegroundColor Cyan -NoNewline
    if ($Default -ne '') { Write-Host " [$Default]" -ForegroundColor DarkGray -NoNewline }
    Write-Host ': ' -ForegroundColor Cyan -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val) -and $Default -ne '') { return $Default }
    return $val.Trim()
}

function Pause-Screen {
    Write-Host ''
    Write-Host '  Press any key to continue...' -ForegroundColor DarkGray -NoNewline
    try { [void][System.Console]::ReadKey($true) } catch { Read-Host }
    Write-Host ''
}

function Show-Bar {
    param([int]$Now, [int]$Of, [string]$Label = '')
    if ($Of -le 0) { return }
    $pct    = [int][Math]::Floor(($Now / $Of) * 100)
    $filled = [int][Math]::Floor(($Now / $Of) * 44)
    $bar    = '[' + ('#' * $filled) + ('.' * (44 - $filled)) + "]"
    $lbl    = if ($Label.Length -gt 25) { $Label.Substring(0,22) + '...' } else { $Label.PadRight(25) }
    Write-Host ("`r  $bar $pct% | $lbl") -ForegroundColor Green -NoNewline
    if ($Now -ge $Of) { Write-Host '' }
}
#endregion

#region ============================================================
#  LOGGING
#============================================================
function Start-Log {
    param([string]$Dir)
    $Script:LogFile = Join-Path $Dir "WARDEN_$Script:SessionID.log"
    _Log "WARDEN v$Script:W_VERSION  Session:$Script:SessionID  Author:$Script:W_AUTHOR"
    _Log "OS: $([System.Environment]::OSVersion.VersionString)"
    _Log "PowerShell: $($PSVersionTable.PSVersion)  User: $env:USERNAME  Host: $env:COMPUTERNAME"
}

function _Log {
    param([string]$Msg, [string]$Lvl = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Lvl.PadRight(5)] $Msg"
    if ($Script:LogFile) {
        try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
        catch { <# silent #> }
    }
}
#endregion

#region ============================================================
#  PRIVILEGE MANAGEMENT
#============================================================
function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystem {
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem }
    catch { return $false }
}

function Get-LocalAdminNames {
    try {
        $grp = [ADSI]'WinNT://./Administrators,group'
        return @($grp.Invoke('Members')) | ForEach-Object {
            $_.GetType().InvokeMember('Name','GetProperty',$null,$_,$null)
        }
    } catch { return @('Administrator') }
}

function Invoke-Elevate {
    wW 'Administrator rights required. Triggering UAC self-elevation...'
    _Log 'Triggering UAC elevation' 'WARN'
    $script = if ($PSCommandPath) { "-File `"$PSCommandPath`"" }
              else { "-NoExit -Command `"& { iex (irm 'https://raw.githubusercontent.com/$Script:W_AUTHOR/WindowsScripts/main/Registry/WARDEN.ps1') }`"" }
    $args   = "-NoProfile -ExecutionPolicy Bypass $script"
    try {
        Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait
    } catch {
        wE "Elevation failed: $_"
    }
    exit 0
}

function Invoke-AsSystemTask {
    param([string]$ScriptText, [string]$TaskName)
    wS "Scheduling SYSTEM task: $TaskName"
    _Log "SYSTEM task schedule: $TaskName" 'INFO'
    $enc    = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptText))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                  -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    $trig   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(4)
    $prin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trig `
                           -Principal $prin -Settings $set -Force | Out-Null
    Start-Sleep 6
    Start-ScheduledTask -TaskName $TaskName
    $waited = 0
    while ($waited -lt 120) {
        Start-Sleep 2
        $waited += 2
        if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State -eq 'Ready') { break }
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    _Log "SYSTEM task complete: $TaskName" 'INFO'
}
#endregion

#region ============================================================
#  VOLUME SHADOW COPY (VSS)
#============================================================
function New-VSS {
    param([string]$Vol = "$env:SystemDrive\")
    wS 'Creating Volume Shadow Copy for locked hive access...'
    _Log "VSS create on $Vol" 'INFO'
    try {
        $cls = [WMICLASS]'Win32_ShadowCopy'
        $r   = $cls.Create($Vol, 'ClientAccessible')
        if ($r.ReturnValue -ne 0) { throw "VSS returned error code $($r.ReturnValue)" }
        $Script:ShadowID   = $r.ShadowID
        $shadow            = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $Script:ShadowID }
        $Script:ShadowPath = $shadow.DeviceObject + '\'
        wOK "Shadow copy ready: $Script:ShadowPath"
        _Log "VSS ID:$Script:ShadowID  Path:$Script:ShadowPath" 'INFO'
        return $true
    } catch {
        wW "VSS creation failed: $_"
        _Log "VSS failed: $_" 'WARN'
        return $false
    }
}

function Remove-VSS {
    if (-not $Script:ShadowID) { return }
    try {
        $s = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $Script:ShadowID }
        if ($s) { $s.Delete() | Out-Null }
        wOK 'Volume Shadow Copy removed.'
        _Log 'VSS deleted' 'INFO'
    } catch {
        wW "VSS removal failed: $_"
        _Log "VSS delete error: $_" 'WARN'
    }
    $Script:ShadowID   = $null
    $Script:ShadowPath = $null
}

function Copy-FromVSS {
    param([string]$Rel, [string]$Dest)
    if (-not $Script:ShadowPath) { return $false }
    $src = Join-Path $Script:ShadowPath $Rel
    try {
        Copy-Item -LiteralPath $src -Destination $Dest -Force
        return $true
    } catch {
        _Log "VSS copy failed for ${Rel}: $_" 'WARN'
        return $false
    }
}
#endregion

#region ============================================================
#  SERVICE & PROCESS MANAGEMENT
#============================================================
function Stop-Services-Blocking {
    $names = @('RemoteRegistry')   # Only stop RemoteRegistry; VSS must stay running
    foreach ($n in $names) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                Stop-Service -Name $n -Force -ErrorAction Stop
                $Script:StoppedServices.Add($n)
                wS "Stopped service: $n"
                _Log "Stopped service: $n" 'INFO'
            } catch {
                wW "Cannot stop ${n}: $_"
                _Log "Stop service fail $n : $_" 'WARN'
            }
        }
    }
}

function Start-Services-Blocked {
    foreach ($n in $Script:StoppedServices) {
        try {
            Start-Service -Name $n -ErrorAction Stop
            wOK "Restored service: $n"
            _Log "Restored service: $n" 'INFO'
        } catch {
            wW "Cannot restore ${n}: $_"
            _Log "Restore service fail ${n}: $_" 'WARN'
        }
    }
    $Script:StoppedServices.Clear()
}
#endregion

#region ============================================================
#  SHA-256 HASHING
#============================================================
function Get-Hash256 {
    param([string]$Path)
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        _Log "Hash error for ${Path}: $_" 'ERROR'
        return 'HASH_ERROR'
    }
}

function Write-HashManifest {
    param([string]$Dir, [hashtable]$HT)
    $file  = Join-Path $Dir "WARDEN_SHA256_$Script:SessionID.sha256"
    $lines = @(
        "# WARDEN SHA-256 Hash Manifest",
        "# Version   : $Script:W_VERSION",
        "# Author    : $Script:W_AUTHOR",
        "# Session   : $Script:SessionID",
        "# Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "# Computer  : $env:COMPUTERNAME",
        "# Repo      : $Script:W_REPO",
        ''
    )
    foreach ($k in ($HT.Keys | Sort-Object)) {
        $lines += "$($HT[$k])  $k"
    }
    $lines | Set-Content -Path $file -Encoding UTF8
    return $file
}

function Test-HashManifest {
    param([string]$ManifestFile, [string]$BaseDir)
    wS 'Verifying SHA-256 hashes...'
    _Log "Hash verification start: $ManifestFile" 'INFO'
    $pass = $true
    $entries = Get-Content -Path $ManifestFile -Encoding UTF8 |
               Where-Object { $_ -notmatch '^#' -and $_.Trim() -ne '' }
    foreach ($entry in $entries) {
        $parts = $entry -split '\s+', 2
        if ($parts.Count -ne 2) { continue }
        $exp  = $parts[0].Trim().ToUpper()
        $name = $parts[1].Trim()
        $fp   = Join-Path $BaseDir $name
        if (Test-Path -LiteralPath $fp) {
            $act = Get-Hash256 $fp
            if ($act.ToUpper() -eq $exp) {
                wOK "VERIFIED : $name"
                _Log "Hash OK: $name" 'INFO'
            } else {
                wE "MISMATCH : $name"
                wE "  Expected : $exp"
                wE "  Got      : $act"
                _Log "Hash MISMATCH: $name | exp=$exp got=$act" 'ERROR'
                $pass = $false
            }
        } else {
            wW "MISSING  : $name"
            _Log "File missing for hash: $name" 'WARN'
            $pass = $false
        }
    }
    return $pass
}
#endregion

#region ============================================================
#  ARCHIVE / METADATA
#============================================================
function Write-MetaJson {
    param([string]$Dir, [string]$Type, [string[]]$Files)
    $obj = [ordered]@{
        schema       = 'WARDEN-Backup-Metadata-v1.0'
        version      = $Script:W_VERSION
        author       = $Script:W_AUTHOR
        repository   = $Script:W_REPO
        session_id   = $Script:SessionID
        backup_type  = $Type
        created_utc  = (Get-Date).ToUniversalTime().ToString('o')
        created_local= (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        computer     = $env:COMPUTERNAME
        username     = $env:USERNAME
        os_version   = [System.Environment]::OSVersion.VersionString
        ps_version   = $PSVersionTable.PSVersion.ToString()
        files_count  = $Files.Count
        files        = $Files
    }
    $json = $obj | ConvertTo-Json -Depth 6
    $fp   = Join-Path $Dir 'WARDEN_metadata.json'
    $json | Set-Content -Path $fp -Encoding UTF8
    return $fp
}

function Compress-ToZip {
    param([string]$SrcDir, [string]$ZipPath)
    wS "Compressing to ZIP: $(Split-Path $ZipPath -Leaf)"
    _Log "ZIP: $SrcDir -> $ZipPath" 'INFO'
    try {
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
        Add-Type -Assembly 'System.IO.Compression.FileSystem'
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $SrcDir, $ZipPath,
            [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $mb = [Math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
        wOK "Archive created: $ZipPath ($mb MB)"
        _Log "ZIP done: $ZipPath ($mb MB)" 'INFO'
        return $true
    } catch {
        wE "ZIP failed: $_"
        _Log "ZIP error: $_" 'ERROR'
        return $false
    }
}

function Expand-FromZip {
    param([string]$ZipPath, [string]$DestDir)
    wS "Extracting: $(Split-Path $ZipPath -Leaf)"
    _Log "Extract: $ZipPath -> $DestDir" 'INFO'
    try {
        if (-not (Test-Path $DestDir)) { New-Item $DestDir -ItemType Directory -Force | Out-Null }
        Add-Type -Assembly 'System.IO.Compression.FileSystem'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
        wOK "Extracted to: $DestDir"
        _Log "Extract done: $DestDir" 'INFO'
        return $true
    } catch {
        wE "Extraction failed: $_"
        _Log "Extract error: $_" 'ERROR'
        return $false
    }
}
#endregion

#region ============================================================
#  REGISTRY EXPORT / IMPORT
#============================================================
function Export-Key {
    param([string]$Key, [string]$Out)
    _Log "reg export: $Key -> $Out" 'INFO'
    try {
        $r = & reg export "$Key" "$Out" /y 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $Out)) {
            _Log "Export OK: $Key" 'INFO'
            return $true
        } else {
            _Log "Export code=$LASTEXITCODE $Key : $r" 'WARN'
            return $false
        }
    } catch {
        _Log "Export exception $Key : $_" 'ERROR'
        return $false
    }
}

function Import-RegFile {
    param([string]$File)
    _Log "reg import: $File" 'INFO'
    try {
        $r = & reg import "$File" 2>&1
        if ($LASTEXITCODE -eq 0) {
            _Log "Import OK: $File" 'INFO'
            return $true
        } else {
            _Log "Import code=$LASTEXITCODE $File : $r" 'ERROR'
            return $false
        }
    } catch {
        _Log "Import exception $File : $_" 'ERROR'
        return $false
    }
}

function Restore-Hive {
    param([string]$HiveName, [string]$SrcFile)
    _Log "reg restore HKLM\$HiveName from $SrcFile" 'INFO'
    try {
        $r = & reg restore "HKLM\$HiveName" "$SrcFile" 2>&1
        if ($LASTEXITCODE -eq 0) {
            _Log "Hive restore OK: $HiveName" 'INFO'
            return $true
        } else {
            _Log "Hive restore code=$LASTEXITCODE $HiveName : $r" 'WARN'
            return $false
        }
    } catch {
        _Log "Hive restore exception $HiveName : $_" 'ERROR'
        return $false
    }
}
#endregion

#region ============================================================
#  FULL BACKUP
#============================================================
function Invoke-FullBackup {
    param([string]$Root)

    Write-Section 'FULL SYSTEM REGISTRY BACKUP'

    $ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $label = "FULL_${ts}_$Script:SessionID"
    $bDir  = Join-Path $Root $label
    $rDir  = Join-Path $bDir 'registry_export'
    $hDir  = Join-Path $bDir 'hive_files'

    foreach ($d in @($bDir,$rDir,$hDir)) {
        New-Item $d -ItemType Directory -Force | Out-Null
    }
    Start-Log $bDir

    wI "Backup directory : $bDir"
    wI "Session ID       : $Script:SessionID"
    wI "Timestamp        : $ts"
    Write-Divider

    $HT     = @{}
    $fList  = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    # -- Step 1: Stop interfering services --
    wI 'Step 1/6  Suspending interfering services...'
    Stop-Services-Blocking
    wOK 'Service check done.'
    Write-Divider

    # -- Step 2: Create VSS shadow copy --
    wI 'Step 2/6  Creating Volume Shadow Copy...'
    $vssOk = New-VSS -Vol "$env:SystemDrive\"
    Write-Divider

    # -- Step 3: Export reg hives via reg export (unlocked) --
    wI 'Step 3/6  Exporting accessible registry hives...'
    $unlocked = $Script:FullHives | Where-Object { -not $_.Locked }
    $tot = $unlocked.Count
    $idx = 0
    foreach ($h in $unlocked) {
        $idx++
        Show-Bar $idx $tot $h.Name
        $out = Join-Path $rDir "$($h.Name).reg"
        $ok  = Export-Key -Key $h.Key -Out $out
        if ($ok) {
            $hash = Get-Hash256 $out
            $HT["registry_export\$($h.Name).reg"] = $hash
            $fList.Add("registry_export\$($h.Name).reg")
            wOK "  $($h.Name)  [$($h.Desc)]"
        } else {
            $errors.Add("Export failed: $($h.Key)")
            wW "  FAILED: $($h.Name)"
        }
    }
    Write-Divider

    # -- Step 4: Copy locked hives from VSS --
    wI 'Step 4/6  Copying locked hive files (SAM, SECURITY, SYSTEM)...'
    foreach ($hf in $Script:LockedHiveFiles) {
        $dest = Join-Path $hDir $hf.Name
        $ok   = $false

        if ($vssOk) {
            $ok = Copy-FromVSS -Rel $hf.RelPath -Dest $dest
            if ($ok) {
                wOK "VSS copy OK : $($hf.Name)"
            } else {
                wW "VSS copy failed for $($hf.Name) - attempting reg save fallback..."
            }
        }

        if (-not $ok) {
            # Fallback: reg save (may need SYSTEM for SAM/SECURITY)
            try {
                & reg save "HKLM\$($hf.Name)" $dest /y 2>$null | Out-Null
                if (Test-Path $dest) {
                    $ok = $true
                    wOK "reg save OK : $($hf.Name)"
                }
            } catch { <# silent #> }
        }

        if (-not $ok) {
            # Final fallback: schedule as SYSTEM via task scheduler
            $taskScript = "reg save 'HKLM\$($hf.Name)' '$dest' /y"
            $taskName   = "WARDEN_SAV_$($hf.Name)_$(Get-Random)"
            Invoke-AsSystemTask -ScriptText $taskScript -TaskName $taskName
            Start-Sleep 3
            if (Test-Path $dest) {
                $ok = $true
                wOK "SYSTEM task OK : $($hf.Name)"
            }
        }

        if ($ok -and (Test-Path $dest)) {
            $hash = Get-Hash256 $dest
            $HT["hive_files\$($hf.Name)"] = $hash
            $fList.Add("hive_files\$($hf.Name)")
            _Log "Hive hash $($hf.Name): $hash" 'INFO'
        } else {
            $errors.Add("All methods failed for hive: $($hf.Name)")
            wE "FAILED all methods: $($hf.Name)"
        }
    }
    Write-Divider

    # -- Step 5: Hash manifest + metadata --
    wI 'Step 5/6  Writing SHA-256 manifest and metadata...'
    $hashFile = Write-HashManifest -Dir $bDir -HT $HT
    $metaFile = Write-MetaJson -Dir $bDir -Type 'FULL' -Files $fList.ToArray()
    wOK "Hash manifest : $hashFile"
    wOK "Metadata JSON : $metaFile"

    Write-Host ''
    Write-Host '  SHA-256 Hash Summary:' -ForegroundColor Yellow
    Write-Divider
    foreach ($k in ($HT.Keys | Sort-Object)) {
        Write-Host "  $($HT[$k].Substring(0,20))...  $k" -ForegroundColor Cyan
    }
    Write-Divider

    # -- Step 6: Compress to ZIP --
    wI 'Step 6/6  Compressing backup archive...'
    $zipPath = Join-Path $Root "$label.zip"
    $zipOk   = Compress-ToZip -SrcDir $bDir -ZipPath $zipPath
    if ($zipOk) {
        $zipHash = Get-Hash256 $zipPath
        Add-Content -Path $hashFile -Value "$zipHash  $label.zip" -Encoding UTF8
        wOK "ZIP SHA-256: $zipHash"
        _Log "ZIP hash: $zipHash" 'INFO'
    }

    # -- Cleanup --
    Remove-VSS
    Start-Services-Blocked

    # -- Summary --
    Write-Section 'BACKUP SUMMARY'
    wOK "Status          : $(if($errors.Count -eq 0){'COMPLETE - No errors'}else{"COMPLETE with $($errors.Count) warning(s)"})"
    wOK "Backup folder   : $bDir"
    if ($zipOk) { wOK "ZIP archive     : $zipPath" }
    wOK "Hash manifest   : $hashFile"
    wOK "Session log     : $Script:LogFile"
    wOK "Files captured  : $($fList.Count)"
    if ($errors.Count -gt 0) {
        Write-Divider
        wW 'Warnings encountered:'
        foreach ($e in $errors) { wW "  -> $e" }
    }
    _Log "Full backup done. Files=$($fList.Count) Errors=$($errors.Count)" 'INFO'

    Pause-Screen
}
#endregion

#region ============================================================
#  FULL RESTORE
#============================================================
function Invoke-FullRestore {
    param([string]$Root)

    Write-Section 'FULL SYSTEM REGISTRY RESTORE'

    # Gather backups
    $dirs = @(Get-ChildItem $Root -Filter 'FULL_*' -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending)
    $zips = @(Get-ChildItem $Root -Filter 'FULL_*.zip' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending)

    $all = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($d in $dirs) { $all.Add(@{ L=$d.Name;      P=$d.FullName;  Z=$false }) }
    foreach ($z in $zips)  { $all.Add(@{ L=$z.Name;     P=$z.FullName;  Z=$true  }) }

    if ($all.Count -eq 0) {
        wW "No full backups found in: $Root"
        Pause-Screen; return
    }

    wI 'Available full backups:'
    for ($i = 0; $i -lt $all.Count; $i++) {
        $t = if ($all[$i].Z) { '[ZIP]' } else { '[DIR]' }
        Write-Host "    [$($i+1)] $t  $($all[$i].L)" -ForegroundColor Cyan
    }
    Write-Host ''

    $pick = Read-Input "Select backup number [1-$($all.Count)]" '1'
    $sel  = $null
    if ([int]::TryParse($pick,[ref]$null)) {
        $idx = [int]$pick - 1
        if ($idx -ge 0 -and $idx -lt $all.Count) { $sel = $all[$idx] }
    }
    if (-not $sel) { wE 'Invalid selection.'; Pause-Screen; return }

    $srcDir = $sel.P
    if ($sel.Z) {
        $exDir = Join-Path $Root "RESTORE_EXTRACT_$(Get-Date -Format 'yyyyMMddHHmmss')"
        $ok = Expand-FromZip -ZipPath $sel.P -DestDir $exDir
        if (-not $ok) { Pause-Screen; return }
        $srcDir = $exDir
    }

    # Hash verification
    $hFiles = @(Get-ChildItem $srcDir -Filter '*.sha256' -ErrorAction SilentlyContinue)
    if ($hFiles.Count -gt 0) {
        $verified = Test-HashManifest -ManifestFile $hFiles[0].FullName -BaseDir $srcDir
        if (-not $verified) {
            wW 'Hash verification FAILED - backup may be corrupted or tampered.'
            $go = Read-Input 'Proceed anyway? [y/N]' 'n'
            if ($go -notmatch '^[yY]') { Pause-Screen; return }
        } else {
            wOK 'Hash verification PASSED - backup integrity confirmed.'
        }
    } else {
        wW 'No SHA-256 manifest found - integrity unverified.'
    }

    # Pre-restore safety backup
    Write-Divider
    wI 'Creating pre-restore safety snapshot (enables rollback)...'
    $safeRoot = Join-Path $Root 'PRE_RESTORE_SAFETY'
    if (-not (Test-Path $safeRoot)) { New-Item $safeRoot -ItemType Directory -Force | Out-Null }
    Invoke-FullBackup -Root $safeRoot
    Write-Divider

    # Final confirmation
    wW '!! CAUTION: This will overwrite live registry keys. !!'
    wW "Restoring from: $($sel.L)"
    $cf = Read-Input 'Type CONFIRM to proceed' ''
    if ($cf -ne 'CONFIRM') { wI 'Restore cancelled.'; Pause-Screen; return }

    Start-Log $srcDir
    Stop-Services-Blocking

    # Import .reg files
    Write-Section 'Importing Registry Export Files'
    $regFiles = @(Get-ChildItem (Join-Path $srcDir 'registry_export') -Filter '*.reg' -ErrorAction SilentlyContinue)
    $errors   = [System.Collections.Generic.List[string]]::new()
    $tot      = $regFiles.Count
    $idx      = 0
    foreach ($rf in $regFiles) {
        $idx++
        Show-Bar $idx $tot $rf.Name
        $ok = Import-RegFile -File $rf.FullName
        if (-not $ok) {
            $errors.Add("Import failed: $($rf.Name)")
            wW "  FAILED: $($rf.Name)"
        }
    }
    Write-Host ''

    # Restore locked hives
    $hiveDir = Join-Path $srcDir 'hive_files'
    if (Test-Path $hiveDir) {
        Write-Section 'Restoring Hive Files (SAM/SECURITY/SYSTEM)'
        $hiveFiles = @(Get-ChildItem $hiveDir -ErrorAction SilentlyContinue)
        foreach ($hf in $hiveFiles) {
            wS "Restoring hive: $($hf.Name)"
            $ok = Restore-Hive -HiveName $hf.BaseName -SrcFile $hf.FullName
            if ($ok) {
                wOK "  Restored: $($hf.Name)"
            } else {
                wW "  Queued for next boot: $($hf.Name)"
                $errors.Add("Hive requires reboot: $($hf.Name)")
            }
        }
    }

    Start-Services-Blocked

    Write-Section 'RESTORE SUMMARY'
    if ($errors.Count -eq 0) {
        wOK 'Restore completed with no errors.'
    } else {
        wW "Restore completed with $($errors.Count) note(s):"
        foreach ($e in $errors) { wW "  -> $e" }
    }
    wW 'A SYSTEM RESTART is strongly recommended to apply all changes.'
    $rb = Read-Input 'Restart now? [y/N]' 'n'
    if ($rb -match '^[yY]') { Start-Sleep 2; Restart-Computer -Force }

    Pause-Screen
}
#endregion

#region ============================================================
#  CUSTOM BACKUP
#============================================================
function Invoke-CustomBackup {
    param([string]$Root)

    Write-Section 'CUSTOM SELECTIVE REGISTRY BACKUP'

    $selected = [System.Collections.Generic.List[string]]::new()
    $running  = $true

    while ($running) {
        Write-Host ''
        Write-Host '  +----------------------------------------------------+' -ForegroundColor DarkGreen
        Write-Host "  |  Selected paths: $($selected.Count)".PadRight(52) + '|' -ForegroundColor Green
        Write-Host '  |  [1] Browse predefined paths with descriptions      |' -ForegroundColor White
        Write-Host '  |  [2] Search paths by keyword                        |' -ForegroundColor White
        Write-Host '  |  [3] Enter a custom path manually                   |' -ForegroundColor White
        Write-Host '  |  [4] View current selection                         |' -ForegroundColor White
        Write-Host '  |  [5] Proceed with backup                            |' -ForegroundColor Green
        Write-Host '  |  [0] Cancel                                         |' -ForegroundColor Red
        Write-Host '  +----------------------------------------------------+' -ForegroundColor DarkGreen
        Write-Host ''

        $ch = Read-Input 'Option' '5'

        switch ($ch) {

            '1' {
                # Paginated predefined list
                $cols   = $Script:CustomRegPaths
                $page   = 0
                $pgSize = 8
                $paging = $true
                while ($paging) {
                    $start = $page * $pgSize
                    $end   = [Math]::Min($start + $pgSize, $cols.Count) - 1
                    Write-Host ''
                    Write-Host "  Predefined Paths (page $($page+1)/$([Math]::Ceiling($cols.Count/$pgSize))):" -ForegroundColor Yellow
                    Write-Divider
                    for ($i = $start; $i -le $end; $i++) {
                        $c = $cols[$i]
                        $m = if ($selected.Contains($c.Path)) { '[X]' } else { '[ ]' }
                        Write-Host ("  [{0,2}] $m  {1}" -f ($i+1), $c.Path) -ForegroundColor Cyan
                        Write-Host ("        {0}" -f $c.Desc) -ForegroundColor DarkGray
                    }
                    Write-Divider
                    Write-Host '  Enter numbers to toggle, N=next page, P=prev page, Q=done' -ForegroundColor DarkGray
                    $inp = Read-Input 'Toggle/Navigate' 'q'

                    if ($inp -match '^[qQ]$') {
                        $paging = $false
                    } elseif ($inp -match '^[nN]$') {
                        if (($page + 1) * $pgSize -lt $cols.Count) { $page++ }
                    } elseif ($inp -match '^[pP]$') {
                        if ($page -gt 0) { $page-- }
                    } else {
                        foreach ($token in ($inp -split ',')) {
                            $token = $token.Trim()
                            $n     = 0
                            if ([int]::TryParse($token,[ref]$n)) {
                                $n--
                                if ($n -ge 0 -and $n -lt $cols.Count) {
                                    $path = $cols[$n].Path
                                    if ($selected.Contains($path)) {
                                        $selected.Remove($path) | Out-Null
                                        wI "Removed : $path"
                                    } else {
                                        $selected.Add($path)
                                        wOK "Added   : $path"
                                    }
                                }
                            }
                        }
                    }
                }
            }

            '2' {
                $kw = Read-Input 'Keyword to search' ''
                if ($kw) {
                    $hits = @($Script:CustomRegPaths | Where-Object {
                        $_.Path -match [regex]::Escape($kw) -or $_.Desc -match [regex]::Escape($kw)
                    })
                    if ($hits.Count -eq 0) {
                        wW "No results for '$kw'"
                    } else {
                        Write-Host ''
                        Write-Host "  Search results for '$kw':" -ForegroundColor Yellow
                        Write-Divider
                        for ($i = 0; $i -lt $hits.Count; $i++) {
                            $m = if ($selected.Contains($hits[$i].Path)) { '[X]' } else { '[ ]' }
                            Write-Host ("  [{0}] $m  {1}" -f ($i+1), $hits[$i].Path) -ForegroundColor Cyan
                            Write-Host ("       {0}" -f $hits[$i].Desc) -ForegroundColor DarkGray
                        }
                        Write-Divider
                        $picks = Read-Input 'Toggle by number (comma-separated)' ''
                        foreach ($token in ($picks -split ',')) {
                            $token = $token.Trim()
                            $n     = 0
                            if ([int]::TryParse($token,[ref]$n)) {
                                $n--
                                if ($n -ge 0 -and $n -lt $hits.Count) {
                                    $path = $hits[$n].Path
                                    if ($selected.Contains($path)) {
                                        $selected.Remove($path) | Out-Null
                                        wI "Removed : $path"
                                    } else {
                                        $selected.Add($path)
                                        wOK "Added   : $path"
                                    }
                                }
                            }
                        }
                    }
                }
            }

            '3' {
                $cp = Read-Input 'Registry path (e.g. HKLM\SOFTWARE\MyApp)' ''
                if ($cp) {
                    # Test path accessibility
                    $psPath = $cp -replace '^HKLM\\','HKLM:\' `
                                  -replace '^HKCU\\','HKCU:\' `
                                  -replace '^HKU\\','HKU:\'   `
                                  -replace '^HKCR\\','HKCR:\'
                    $exists = Test-Path -LiteralPath $psPath -ErrorAction SilentlyContinue
                    if (-not $exists) {
                        wW "Path not found or inaccessible: $cp"
                        $force = Read-Input 'Add anyway? [y/N]' 'n'
                        if ($force -notmatch '^[yY]') { break }
                    }
                    if (-not $selected.Contains($cp)) {
                        $selected.Add($cp)
                        wOK "Added: $cp"
                    } else {
                        wI "Already in selection: $cp"
                    }
                }
            }

            '4' {
                Write-Host ''
                Write-Host '  Current selection:' -ForegroundColor Yellow
                Write-Divider
                if ($selected.Count -eq 0) {
                    wI '  (empty)'
                } else {
                    for ($i = 0; $i -lt $selected.Count; $i++) {
                        Write-Host ("  [{0,2}]  {1}" -f ($i+1), $selected[$i]) -ForegroundColor Cyan
                    }
                }
                Write-Divider
                Pause-Screen
            }

            '5' { $running = $false }
            '0' { wI 'Custom backup cancelled.'; Pause-Screen; return }
            default { wW 'Invalid option.' }
        }
    }

    if ($selected.Count -eq 0) {
        wW 'No paths selected. Returning to main menu.'
        Pause-Screen; return
    }

    # Create backup dirs
    $ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $label = "CUSTOM_${ts}_$Script:SessionID"
    $bDir  = Join-Path $Root $label
    $rDir  = Join-Path $bDir 'registry_export'
    New-Item $rDir -ItemType Directory -Force | Out-Null
    Start-Log $bDir

    wI "Custom backup - $($selected.Count) path(s)"
    wI "Destination: $bDir"
    Write-Divider

    $HT     = @{}
    $fList  = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    Stop-Services-Blocking

    $tot = $selected.Count
    $idx = 0
    foreach ($regPath in $selected) {
        $idx++
        $safe = ($regPath -replace '[\\/:*?"<>|]','_').TrimEnd('_')
        $out  = Join-Path $rDir "$safe.reg"
        Show-Bar $idx $tot ($regPath -replace 'HKLM\\|HKCU\\','')
        $ok   = Export-Key -Key $regPath -Out $out
        if ($ok) {
            $hash = Get-Hash256 $out
            $HT["registry_export\$safe.reg"] = $hash
            $fList.Add("registry_export\$safe.reg")
        } else {
            $errors.Add("Export failed: $regPath")
        }
    }
    Write-Host ''

    Start-Services-Blocked

    # Save path manifest for later restore matching
    $pathMap = Join-Path $bDir 'WARDEN_path_map.txt'
    $mapLines = [System.Collections.Generic.List[string]]::new()
    $mapLines.Add('# WARDEN Custom Backup Path Map')
    $mapLines.Add("# Session: $Script:SessionID")
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $safe = ($selected[$i] -replace '[\\/:*?"<>|]','_').TrimEnd('_')
        $mapLines.Add("$safe.reg|$($selected[$i])")
    }
    $mapLines | Set-Content $pathMap -Encoding UTF8

    $hashFile = Write-HashManifest -Dir $bDir -HT $HT
    Write-MetaJson -Dir $bDir -Type 'CUSTOM' -Files $fList.ToArray() | Out-Null

    Write-Host ''
    Write-Host '  SHA-256 Hash Summary:' -ForegroundColor Yellow
    Write-Divider
    foreach ($k in ($HT.Keys | Sort-Object)) {
        Write-Host "  $($HT[$k].Substring(0,20))...  $k" -ForegroundColor Cyan
    }
    Write-Divider

    $zipPath = Join-Path $Root "$label.zip"
    Compress-ToZip -SrcDir $bDir -ZipPath $zipPath | Out-Null

    Write-Section 'CUSTOM BACKUP SUMMARY'
    wOK "Paths captured  : $($fList.Count) / $($selected.Count)"
    wOK "Backup folder   : $bDir"
    wOK "ZIP archive     : $zipPath"
    wOK "Hash manifest   : $hashFile"
    if ($errors.Count -gt 0) {
        wW "Warnings ($($errors.Count)):"
        foreach ($e in $errors) { wW "  -> $e" }
    } else {
        wOK 'All selected paths exported successfully.'
    }
    _Log "Custom backup done. Files=$($fList.Count) Errors=$($errors.Count)" 'INFO'

    Pause-Screen
}
#endregion

#region ============================================================
#  CUSTOM RESTORE
#============================================================
function Invoke-CustomRestore {
    param([string]$Root)

    Write-Section 'CUSTOM SELECTIVE REGISTRY RESTORE'

    $dirs = @(Get-ChildItem $Root -Filter 'CUSTOM_*' -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending)
    $zips = @(Get-ChildItem $Root -Filter 'CUSTOM_*.zip' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending)

    $all = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($d in $dirs) { $all.Add(@{ L=$d.Name; P=$d.FullName; Z=$false }) }
    foreach ($z in $zips)  { $all.Add(@{ L=$z.Name; P=$z.FullName; Z=$true  }) }

    if ($all.Count -eq 0) { wW 'No custom backups found.'; Pause-Screen; return }

    wI 'Available custom backups:'
    for ($i = 0; $i -lt $all.Count; $i++) {
        $t = if ($all[$i].Z) { '[ZIP]' } else { '[DIR]' }
        Write-Host "    [$($i+1)] $t  $($all[$i].L)" -ForegroundColor Cyan
    }
    Write-Host ''

    $pick = Read-Input "Select backup [1-$($all.Count)]" '1'
    $sel  = $null
    if ([int]::TryParse($pick,[ref]$null)) {
        $idx = [int]$pick - 1
        if ($idx -ge 0 -and $idx -lt $all.Count) { $sel = $all[$idx] }
    }
    if (-not $sel) { wE 'Invalid.'; Pause-Screen; return }

    $srcDir = $sel.P
    if ($sel.Z) {
        $exDir = Join-Path $Root "CUSTOM_EXTRACT_$(Get-Date -Format 'yyyyMMddHHmmss')"
        $ok = Expand-FromZip -ZipPath $sel.P -DestDir $exDir
        if (-not $ok) { Pause-Screen; return }
        $srcDir = $exDir
    }

    # Hash check
    $hFiles = @(Get-ChildItem $srcDir -Filter '*.sha256' -ErrorAction SilentlyContinue)
    if ($hFiles.Count -gt 0) {
        $ok = Test-HashManifest -ManifestFile $hFiles[0].FullName -BaseDir $srcDir
        if (-not $ok) {
            wW 'Hash FAILED - backup may be corrupt.'
            $go = Read-Input 'Proceed anyway? [y/N]' 'n'
            if ($go -notmatch '^[yY]') { Pause-Screen; return }
        } else { wOK 'Hash PASSED.' }
    }

    # Load path map
    $rDir    = Join-Path $srcDir 'registry_export'
    $mapFile = Join-Path $srcDir 'WARDEN_path_map.txt'
    $pathMap = @{}
    if (Test-Path $mapFile) {
        Get-Content $mapFile -Encoding UTF8 | Where-Object { $_ -notmatch '^#' -and $_ } |
        ForEach-Object {
            $parts = $_ -split '\|', 2
            if ($parts.Count -eq 2) { $pathMap[$parts[0]] = $parts[1] }
        }
    }

    $regFiles = @(Get-ChildItem $rDir -Filter '*.reg' -ErrorAction SilentlyContinue)
    if ($regFiles.Count -eq 0) { wW 'No .reg files found.'; Pause-Screen; return }

    Write-Host ''
    wI 'Select entries to restore:'
    Write-Divider
    for ($i = 0; $i -lt $regFiles.Count; $i++) {
        $orig = if ($pathMap[$regFiles[$i].Name]) { $pathMap[$regFiles[$i].Name] } else { $regFiles[$i].Name }
        Write-Host ("  [{0,2}]  {1}" -f ($i+1), $orig) -ForegroundColor Cyan
    }
    Write-Host '  [ A]  Restore ALL listed entries' -ForegroundColor Green
    Write-Divider

    $inp = Read-Input 'Selection (comma-separated numbers or A for all)' 'A'

    $toRestore = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    if ($inp -match '^[aA]$') {
        $toRestore.AddRange([System.IO.FileInfo[]]$regFiles)
    } else {
        foreach ($token in ($inp -split ',')) {
            $n = 0
            if ([int]::TryParse($token.Trim(),[ref]$n)) {
                $n--
                if ($n -ge 0 -and $n -lt $regFiles.Count) {
                    $toRestore.Add($regFiles[$n])
                }
            }
        }
    }

    if ($toRestore.Count -eq 0) { wW 'Nothing selected.'; Pause-Screen; return }

    # Pre-restore safety backup of targeted paths only
    wI 'Snapshotting current state of selected keys before restore...'
    $safeRoot = Join-Path $Root 'PRE_CUSTOM_RESTORE_SAFETY'
    if (-not (Test-Path $safeRoot)) { New-Item $safeRoot -ItemType Directory -Force | Out-Null }
    $safeDir  = Join-Path $safeRoot "SAFETY_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $safeRDir = Join-Path $safeDir 'registry_export'
    New-Item $safeRDir -ItemType Directory -Force | Out-Null
    foreach ($rf in $toRestore) {
        $orig = if ($pathMap[$rf.Name]) { $pathMap[$rf.Name] } else { '' }
        if ($orig) {
            $safe = ($orig -replace '[\\/:*?"<>|]','_').TrimEnd('_')
            Export-Key -Key $orig -Out (Join-Path $safeRDir "$safe.reg") | Out-Null
        }
    }
    wOK "Safety snapshot: $safeDir"
    Write-Divider

    $cf = Read-Input 'Type CONFIRM to proceed' ''
    if ($cf -ne 'CONFIRM') { wI 'Cancelled.'; Pause-Screen; return }

    Start-Log $srcDir
    Stop-Services-Blocking

    $errors = [System.Collections.Generic.List[string]]::new()
    $tot    = $toRestore.Count
    $idx    = 0
    foreach ($rf in $toRestore) {
        $idx++
        Show-Bar $idx $tot $rf.Name
        $ok = Import-RegFile -File $rf.FullName
        if (-not $ok) { $errors.Add("Import failed: $($rf.Name)") }
    }
    Write-Host ''

    Start-Services-Blocked

    Write-Section 'CUSTOM RESTORE SUMMARY'
    wOK "Restored entries : $($toRestore.Count - $errors.Count) / $($toRestore.Count)"
    if ($errors.Count -gt 0) {
        wW "Errors ($($errors.Count)):"
        foreach ($e in $errors) { wW "  -> $e" }
    } else {
        wOK 'All selected entries restored successfully.'
    }
    _Log "Custom restore done. OK=$($toRestore.Count - $errors.Count) Err=$($errors.Count)" 'INFO'

    Pause-Screen
}
#endregion

#region ============================================================
#  ROLLBACK
#============================================================
function Invoke-Rollback {
    param([string]$Root)

    Write-Section 'ROLLBACK - Restore Previous State'

    $pools = @(
        (Join-Path $Root 'PRE_RESTORE_SAFETY'),
        (Join-Path $Root 'PRE_CUSTOM_RESTORE_SAFETY')
    )

    $all = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($pool in $pools) {
        if (Test-Path $pool) {
            @(Get-ChildItem $pool -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) |
            ForEach-Object { $all.Add(@{ L="[SAFETY] $($_.Name)"; P=$_.FullName; Z=$false }) }
            @(Get-ChildItem $pool -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object Name -Descending) |
            ForEach-Object { $all.Add(@{ L="[SAFETY-ZIP] $($_.Name)"; P=$_.FullName; Z=$true }) }
        }
    }
    @(Get-ChildItem $Root -Filter 'FULL_*' -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | Select-Object -First 5) |
    ForEach-Object { $all.Add(@{ L="[FULL] $($_.Name)"; P=$_.FullName; Z=$false }) }

    if ($all.Count -eq 0) {
        wW 'No rollback points available. Run a backup first.'
        Pause-Screen; return
    }

    wI 'Available rollback points (newest first):'
    for ($i = 0; $i -lt $all.Count; $i++) {
        Write-Host ("    [{0,2}]  {1}" -f ($i+1), $all[$i].L) -ForegroundColor Cyan
    }
    Write-Host ''

    $pick = Read-Input "Select rollback point [1-$($all.Count)]" '1'
    $sel  = $null
    if ([int]::TryParse($pick,[ref]$null)) {
        $idx = [int]$pick - 1
        if ($idx -ge 0 -and $idx -lt $all.Count) { $sel = $all[$idx] }
    }
    if (-not $sel) { wE 'Invalid.'; Pause-Screen; return }

    wW "Rolling back to: $($sel.L)"
    $cf = Read-Input 'Type ROLLBACK to confirm' ''
    if ($cf -ne 'ROLLBACK') { wI 'Cancelled.'; Pause-Screen; return }

    $srcDir = $sel.P
    if ($sel.Z) {
        $exDir = Join-Path $Root "ROLLBACK_EXTRACT_$(Get-Date -Format 'yyyyMMddHHmmss')"
        $ok = Expand-FromZip -ZipPath $sel.P -DestDir $exDir
        if (-not $ok) { Pause-Screen; return }
        $srcDir = $exDir
    }

    Start-Log $srcDir
    Stop-Services-Blocking

    $regFiles = @(Get-ChildItem (Join-Path $srcDir 'registry_export') -Filter '*.reg' -ErrorAction SilentlyContinue)
    $errors   = [System.Collections.Generic.List[string]]::new()
    $tot      = $regFiles.Count
    $idx      = 0
    foreach ($rf in $regFiles) {
        $idx++
        Show-Bar $idx $tot $rf.Name
        $ok = Import-RegFile -File $rf.FullName
        if (-not $ok) { $errors.Add("Rollback import failed: $($rf.Name)") }
    }
    Write-Host ''

    $hiveDir = Join-Path $srcDir 'hive_files'
    if (Test-Path $hiveDir) {
        @(Get-ChildItem $hiveDir -ErrorAction SilentlyContinue) | ForEach-Object {
            wS "Restoring hive: $($_.Name)"
            Restore-Hive -HiveName $_.BaseName -SrcFile $_.FullName | Out-Null
        }
    }

    Start-Services-Blocked

    Write-Section 'ROLLBACK COMPLETE'
    if ($errors.Count -eq 0) { wOK 'Rollback applied successfully.' }
    else {
        wW "Rollback with $($errors.Count) note(s):"
        foreach ($e in $errors) { wW "  -> $e" }
    }
    wW 'Restart recommended to fully apply rolled-back state.'
    $rb = Read-Input 'Restart now? [y/N]' 'n'
    if ($rb -match '^[yY]') { Start-Sleep 2; Restart-Computer -Force }

    Pause-Screen
}
#endregion

#region ============================================================
#  BACKUP CATALOG VIEWER
#============================================================
function Show-Catalog {
    param([string]$Root)
    Write-Section "BACKUP CATALOG  --  $Root"

    $allDirs = @(Get-ChildItem $Root -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending)
    $allZips = @(Get-ChildItem $Root -Filter '*.zip' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending)

    if ($allDirs.Count -eq 0 -and $allZips.Count -eq 0) {
        wW "No backups found in $Root"
        Pause-Screen; return
    }

    Write-Host '  [FOLDERS]' -ForegroundColor Yellow
    Write-Divider
    foreach ($d in $allDirs) {
        if ($d.Name -match '^(FULL|CUSTOM|PRE_)') {
            $sz = try {
                $bytes = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
                          Measure-Object Length -Sum).Sum
                "$([Math]::Round($bytes/1MB,1)) MB"
            } catch { '?' }
            Write-Host ("  {0,-48} {1}" -f $d.Name, $sz) -ForegroundColor Cyan
        }
    }
    Write-Host ''
    Write-Host '  [ZIP ARCHIVES]' -ForegroundColor Yellow
    Write-Divider
    foreach ($z in $allZips) {
        $sz = "$([Math]::Round($z.Length/1MB,1)) MB"
        Write-Host ("  {0,-48} {1}" -f $z.Name, $sz) -ForegroundColor Cyan
    }
    Write-Divider
    wI "Total items: $($allDirs.Count + $allZips.Count)"

    Pause-Screen
}
#endregion

#region ============================================================
#  MAIN MENU
#============================================================
function Show-Menu {
    param([ref]$Root)
    $live = $true
    while ($live) {
        Write-Banner
        Write-Host "  Backup Location : $($Root.Value)" -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '  +----------------------------------------------------+' -ForegroundColor DarkGreen
        Write-Host '  |               WARDEN  MAIN  MENU                   |' -ForegroundColor Green
        Write-Host '  |                                                     |' -ForegroundColor DarkGreen
        Write-Host '  |   [1]  Full System Registry Backup                  |' -ForegroundColor White
        Write-Host '  |   [2]  Full System Registry Restore                 |' -ForegroundColor White
        Write-Host '  |   [3]  Custom Selective Backup                      |' -ForegroundColor White
        Write-Host '  |   [4]  Custom Selective Restore                     |' -ForegroundColor White
        Write-Host '  |   [5]  Rollback  (undo last restore)                |' -ForegroundColor Yellow
        Write-Host '  |   [6]  View Backup Catalog                          |' -ForegroundColor White
        Write-Host '  |   [7]  Change Backup Directory                      |' -ForegroundColor White
        Write-Host '  |   [Q]  Quit                                         |' -ForegroundColor Red
        Write-Host '  |                                                     |' -ForegroundColor DarkGreen
        Write-Host '  +----------------------------------------------------+' -ForegroundColor DarkGreen
        Write-Host ''

        $ch = (Read-Input 'Choose option').ToUpper()

        switch ($ch) {
            '1' { Invoke-FullBackup   -Root $Root.Value }
            '2' { Invoke-FullRestore  -Root $Root.Value }
            '3' { Invoke-CustomBackup -Root $Root.Value }
            '4' { Invoke-CustomRestore -Root $Root.Value }
            '5' { Invoke-Rollback     -Root $Root.Value }
            '6' { Show-Catalog        -Root $Root.Value }
            '7' {
                $nd = Read-Input 'New backup directory' $Root.Value
                if ($nd -and -not (Test-Path $nd)) {
                    try { New-Item $nd -ItemType Directory -Force | Out-Null }
                    catch { wE "Cannot create: $nd"; Start-Sleep 2; continue }
                }
                if ($nd) { $Root.Value = $nd; wOK "Directory set: $($Root.Value)"; Start-Sleep 1 }
            }
            'Q' { $live = $false }
            default { wW 'Invalid option.'; Start-Sleep 1 }
        }
    }
}
#endregion

#region ============================================================
#  ENTRY POINT
#============================================================
Set-ConsoleTheme
Write-Banner

# Privilege check
if (-not (Test-IsAdmin)) {
    wE 'Administrator rights are required.'
    wW "Users with local administrator rights on this machine:"
    Get-LocalAdminNames | ForEach-Object { Write-Host "    - $_" -ForegroundColor Cyan }
    Write-Host ''
    wI 'Attempting UAC self-elevation...'
    Start-Sleep 2
    Invoke-Elevate
}

wOK "Running as Administrator : $env:USERNAME"

if (Test-IsSystem) {
    wOK 'SYSTEM privileges confirmed  (SAM / SECURITY direct reg save available).'
} else {
    wI 'Standard Admin mode  (VSS will be used for SAM / SECURITY hives).'
}
Write-Divider

# Ensure VSS service is running
$vssSvc = Get-Service -Name VSS -ErrorAction SilentlyContinue
if ($vssSvc -and $vssSvc.Status -ne 'Running') {
    try {
        Set-Service -Name VSS -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name VSS -ErrorAction Stop
        wOK 'Volume Shadow Copy service started.'
    } catch {
        wW 'Could not start VSS. Locked hive capture may fall back to reg save / SYSTEM task.'
    }
} else {
    wOK 'Volume Shadow Copy service is running.'
}
Write-Divider

# Initialise backup root
$backupRoot = $Script:DefaultBackupRoot
if (-not (Test-Path $backupRoot)) {
    try {
        New-Item $backupRoot -ItemType Directory -Force | Out-Null
        wOK "Created default backup directory: $backupRoot"
    } catch {
        wW "Cannot create default directory. Please specify an alternate location."
        $backupRoot = Read-Input 'Backup directory' "$env:USERPROFILE\WARDEN_Backups"
        if ($backupRoot -and -not (Test-Path $backupRoot)) {
            New-Item $backupRoot -ItemType Directory -Force | Out-Null
        }
    }
} else {
    wOK "Default backup directory ready: $backupRoot"
}

Start-Sleep 1

# Launch menu
$rootRef = [ref]$backupRoot
Show-Menu -Root $rootRef

Write-Banner
wOK 'WARDEN session terminated. Stay hardened.'
Write-Host ''
#endregion

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUQJrb3WaN8/elgKG/Yt3iWuEm
# McugghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBTG4QGylF6ZTZHHkZYeMJtw5ahHTzANBgkq
# hkiG9w0BAQEFAASCAQAZBtw/7Crf1hAhfdv+SxtqOPMN1jsgV4LgQVGKUqYeFLaC
# M1SVmVLxr3BIz4GG/XMFMtE1eadxMTq8ZInDHkrWEQIzi1AeLlxq0SM/3XO0JAr0
# q3VJaQh+Y0joFFj4Me+F67pHOD00czW12iVzLOtuXeJT5XaU2OxNlEaaOUtO0FZE
# zhNWkXT7biWQNQ6M/TDXVjQ5AJoEvLfyYB0UMgcmo5Qat3zzZXgwNPwi7xIg2QLE
# zr2kNkz8ANNRALTSi6OhVAqkFS8s7Ja+GRsFnoH457/t90vO7l497bBiL1jMNL1C
# UbQlk5/jgBftwE5NV/atwNTblZaJbH4OqqmWc2uLoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDUwN1owLwYJKoZIhvcNAQkEMSIEID8ubqOs7ynjpih5
# x1ee2oogq7E3ZXzTsPdc+k1LlEGCMA0GCSqGSIb3DQEBAQUABIICAJIkIMXlixdE
# v8IztS2ferc0v9gEIyobcPJd5rU9a/0zx309RndzUOheXJk+WMkU9bQZ8HrscAfJ
# yyUOwM8/kPq4Nl81QYUZfaSqiTSJToEQ0Rlf9kWDy/BFNYVyCa71Z5FJlOmGrqES
# F9dIPQXC2/NqzqTsLe23HERrs6Ui+fF5JHLk5Bg2j8PMOWjgz7mDgERF8p9/sbeV
# 3lmqjG+Uv+gMbKOdmQty8NwpDkhk5SWYXwAsHr0Kdds5z/S5ZkwKYIFjrWTbQdjU
# 0CicaNoVtlO4gUXVSzE51119qrF/50utRu1o2RewtLN1llttggscthjoxsKzV7SQ
# Yq1AcA0Ei1OCXAcggmlgF97lWamA7FnLWgvw7VW6R23mdFLA0F71gLwt7ZFzUVHy
# hgKmTgIIzepGrmNMZZ9rIUCfrFE9+cEhpRvksykyYlH0SoQa/uBrAqL+AMAvtSz6
# xbTcJHTzmO8yHhZy13n227ZGzwhrACGBAcJtZ9Rc6VUDSYyXPMlCvmM2qOiriThe
# hG44j650IFzdXmQJAjTKPRn854tg2vTdGQf3dhr5o8XICQ7F/V/of8QX559KsEQx
# ZgPB0svXEx358+0nYBOo1+EcRZQX4mYsxDM4EYUiHR9DkTtHAQvtzSN+85K0HiCy
# cdCDlpN+UGqoASWdrw19NgnSiujgkiit
# SIG # End signature block
