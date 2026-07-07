# =========================================
# Windows Performance Tuner - ASCII Safe 
# Fixed: job lookup by Id and job fallback
# =========================================

param(
    [ValidateSet("Optimal","Developer","LowImpact")]
    [string]$Profile = "Optimal"
)

$ErrorActionPreference = "Stop"
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
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

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
        text  = "Windows Tuner v20.4.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
function Show-Banner {
    Clear-Host

    $line = "============================================================"

    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Windows Performance Tuner                               |" -ForegroundColor Cyan
    Write-Host "| Version : v20.4.0                                       |" -ForegroundColor Gray
    Write-Host "| Author  : rhshourav                                     |" -ForegroundColor Gray
    Write-Host "| GitHub  : https://github.com/rhshourav                  |" -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Profile : $($Profile.PadRight(43)) |" -ForegroundColor Yellow
    Write-Host "| Mode    : System Tuning (Admin Required)                |" -ForegroundColor Yellow
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

    $Webhook = "https://cryocore.rhshourav.workers.dev/message"
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

# ==========================================
# WECHAT CLEANUP MODULE (CACHE vs FULL WIPE)
# - Silent skip if nothing found
# - Full wipe roots detected independently (NOT from cache)
# - Menu shows Full Wipe if roots exist
# ==========================================

function Get-FolderSizeBytes($path) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return 0L }
        $sum = 0L
        Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue -File |
            ForEach-Object { $sum += $_.Length }
        return $sum
    } catch { return 0L }
}

function Format-Bytes($bytes) {
    if ($bytes -ge 1TB) { return ("{0:N2} TB" -f ($bytes/1TB)) }
    if ($bytes -ge 1GB) { return ("{0:N2} GB" -f ($bytes/1GB)) }
    if ($bytes -ge 1MB) { return ("{0:N2} MB" -f ($bytes/1MB)) }
    if ($bytes -ge 1KB) { return ("{0:N2} KB" -f ($bytes/1KB)) }
    return ("{0} B" -f $bytes)
}

function Stop-WeChatProcesses {
    $names = @("WeChat","WeChatApp","XWeChat","wechat")
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.CloseMainWindow() | Out-Null } catch {}
        }
    }
    Start-Sleep -Milliseconds 800
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Start-Sleep -Milliseconds 800
}

function Get-WeChatDocCandidatesForUser($userDir) {
    return @(
        (Join-Path $userDir "Documents"),
        (Join-Path $userDir "OneDrive\Documents")
    )
}

function Get-WeChatRootFolders {
    $usersRoot = "C:\Users"
    $wechatRoots = @(
    "WeChat Files",
    "xwechat_files", 
    "WeChat",
    "We",
    "XWeChat",
    "XWe",
    "xwechat"
    )


    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($u in Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue) {
        $docCandidates = Get-WeChatDocCandidatesForUser $u.FullName

        foreach ($docs in $docCandidates) {
            if (-not (Test-Path -LiteralPath $docs)) { continue }

            foreach ($wr in $wechatRoots) {
                $base = Join-Path $docs $wr
                if (Test-Path -LiteralPath $base) { $roots.Add($base) }
            }
        }
    }

    return $roots | Select-Object -Unique
}

function Get-WeChatCacheFolders {
    $cacheRel = @("Cache","Temp","FileStorage\Cache","Video\Cache","Image\Cache")
    $roots = @(Get-WeChatRootFolders)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        # Prefer wxid_* structure when present
        $wxids = Get-ChildItem -LiteralPath $root -Directory -Filter "wxid_*" -ErrorAction SilentlyContinue
        if ($wxids -and $wxids.Count -gt 0) {
            foreach ($w in $wxids) {
                foreach ($c in $cacheRel) {
                    $p = Join-Path $w.FullName $c
                    if (Test-Path -LiteralPath $p) { $out.Add($p) }
                }
            }
        } else {
            # Some variants may keep cache directly under the root
            foreach ($c in $cacheRel) {
                $p = Join-Path $root $c
                if (Test-Path -LiteralPath $p) { $out.Add($p) }
            }
        }
    }

    return $out | Select-Object -Unique
}

function Get-WeChatFullWipeRoots {
    # Full wipe should target the main WeChat containers, regardless of cache presence.
    $roots = @(Get-WeChatRootFolders)

    # Also, if there are wxid_* folders deeper, ensure we include their parent container.
    $derived = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        $derived.Add($r)

        $wxids = Get-ChildItem -LiteralPath $r -Directory -Filter "wxid_*" -ErrorAction SilentlyContinue
        if ($wxids -and $wxids.Count -gt 0) {
            # Parent is already $r, so nothing else required, but keep for completeness
            $derived.Add($r)
        }
    }

    return $derived | Select-Object -Unique
}

function Invoke-WeChatCleanup {

    $cacheFolders = @(Get-WeChatCacheFolders)
    $fullRoots    = @(Get-WeChatFullWipeRoots)
    $ThresholdBytes = 100MB


    # SILENT SKIP
    if ((-not $cacheFolders -or $cacheFolders.Count -eq 0) -and
        (-not $fullRoots   -or $fullRoots.Count   -eq 0)) {
        return
    }

    Title "WECHAT CLEANUP ANALYSIS"

    # Size calculations
    $cacheSize = 0L
    foreach ($p in $cacheFolders) { $cacheSize += (Get-FolderSizeBytes $p) }

    $fullSize = 0L
    foreach ($p in $fullRoots) { $fullSize += (Get-FolderSizeBytes $p) }


    $cachePretty = Format-Bytes $cacheSize
    $fullPretty  = Format-Bytes $fullSize

    Write-Host ("| Cache wipe can clean: {0,-30} |" -f $cachePretty) -ForegroundColor Cyan
    Write-Host ("| Full wipe can clean : {0,-30} |" -f $fullPretty)  -ForegroundColor Cyan
    Line
    Write-Host ""
    # ---------- THRESHOLD CHECK (100 MB) ----------
    if ($cacheSize -lt $ThresholdBytes -and $fullSize -lt $ThresholdBytes) {
        return   # silent skip, nothing worth cleaning
    }
    # MENU (PS 5.1 safe)
    $choiceList = New-Object System.Collections.Generic.List[System.Management.Automation.Host.ChoiceDescription]

    # Offer FULL WIPE if roots exist (even if size shows 0 B due to locks/access)
    if ($fullRoots -and $fullRoots.Count -gt 0) {
        $choiceList.Add(
            (New-Object System.Management.Automation.Host.ChoiceDescription -ArgumentList @(
                "&Full Wipe",
                ("Delete ALL WeChat folders (" + $fullPretty + ")")
            ))
        )
    }

    # Offer CACHE WIPE only if cache paths exist
    if ($cacheFolders -and $cacheFolders.Count -gt 0) {
        $choiceList.Add(
            (New-Object System.Management.Automation.Host.ChoiceDescription -ArgumentList @(
                "&Cache Wipe",
                ("Delete ONLY cache/temp (" + $cachePretty + ")")
            ))
        )
    }

    $choiceList.Add(
        (New-Object System.Management.Automation.Host.ChoiceDescription -ArgumentList @(
            "&Cancel",
            "Do nothing"
        ))
    )

    $choices = $choiceList.ToArray()
    $selection = $Host.UI.PromptForChoice(
        "WeChat Cleanup Mode",
        "Select what you want to delete:",
        $choices,
        $choices.Length - 1
    )

    $picked = $choices[$selection].Label.Replace("&","")
    if ($picked -eq "Cancel") { return }

    # Determine targets
    $mode = ""
    $targets = @()

    if ($picked -eq "Full Wipe") {
        $mode = "FULL"
        $targets = $fullRoots
    }
    elseif ($picked -eq "Cache Wipe") {
        $mode = "CACHE"
        $targets = $cacheFolders
    }
    else {
        return
    }

    if (-not $targets -or $targets.Count -eq 0) {
        Write-Host "| Nothing to delete for selected mode                    |" -ForegroundColor Yellow
        Line
        return
    }

    Title ("WECHAT " + $mode + " WIPE")
    Write-Host "| Closing WeChat                                         |" -ForegroundColor Yellow
    try { Stop-WeChatProcesses } catch { try { Add-Failure "WeChat close failed" } catch {} }
    Line

    $start = Get-Date
    $i = 0
    $n = $targets.Count

    foreach ($p in $targets) {
        $i++
        $pct = [math]::Round(($i / $n) * 100)
        $label = "Deleting: " + (Split-Path $p -Leaf)
        ProgressBar $label $pct $start

        try {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            try { Add-Failure ("WeChat delete failed: " + $p) } catch {}
        }

        try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
    }

    ProgressBar ("WeChat " + $mode + " wipe complete") 100 $start
    Line
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
function Get-CounterSafe($path, $sampleInterval = 1, $maxSamples = 3) {
    try {
        $r = Get-Counter $path -SampleInterval $sampleInterval -MaxSamples $maxSamples -ErrorAction Stop
        if ($r -and $r.CounterSamples -and $r.CounterSamples.Count -gt 0) {
            return $r.CounterSamples | Select-Object -ExpandProperty CookedValue
        }
        return $null
    } catch {
        return $null
    }
}

function Benchmark {

    # CPU Load
    $cpuVals = Get-CounterSafe '\Processor(_Total)\% Processor Time' 1 5
    $cpuLoad = $null
    if ($cpuVals) {
        $cpuLoad = [math]::Round((($cpuVals | Measure-Object -Average).Average), 2)
    } else {
        # Fallback via CIM
        try {
            $cpuLoad = [math]::Round((Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty LoadPercentage), 2)
        } catch {
            $cpuLoad = "N/A"
        }
    }

    # Free Mem (MB)
    $memVal = Get-CounterSafe '\Memory\Available MBytes' 1 1
    $freeMem = $null
    if ($memVal) {
        $freeMem = [math]::Round($memVal[0], 0)
    } else {
        # Fallback via CIM (FreePhysicalMemory is KB)
        try {
            $freeMem = [math]::Round(((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024), 0)
        } catch {
            $freeMem = "N/A"
        }
    }

    # DPC Time (may not exist)
    $dpcVal = Get-CounterSafe '\Processor(_Total)\% DPC Time' 1 1
    $dpc = if ($dpcVal) { [math]::Round($dpcVal[0], 3) } else { "N/A" }

    # Disk Queue (may not exist)
    $dqVal = Get-CounterSafe '\PhysicalDisk(_Total)\Avg. Disk Queue Length' 1 1
    $dq = if ($dqVal) { [math]::Round($dqVal[0], 3) } else { "N/A" }

    [PSCustomObject]@{
        CPU_Load    = $cpuLoad
        Free_Mem_MB = $freeMem
        DPC_Latency = $dpc
        Disk_Queue  = $dq
    }
}

$before = Benchmark
Invoke-SystemCleanup
Invoke-WeChatCleanup
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


# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU8a5LTMJbYS2WzmJEw/ypsLVk
# nwCgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQ0txFeVUagrg0F8wauLvHuCWOoFzANBgkq
# hkiG9w0BAQEFAASCAQBLajDZB87l/44CJlOi3hoiYk71v78ZO/dJApWDSDVm+ram
# pPfYd+YykZOz3elKlgGc3YUlVE9BPyNTRXzzj8EbovpH1dgjRPwzN0bPChtZKgNW
# /2Cm6d+2YxezqUzu7LPyHFq4E2sRjhQewj9FXue1NxSbNUzLmDMltlH994KXjAr9
# Ys0cKZp9ps8p5lSSSKXAE7ievNp6zadN0uMmILLc/HziAIhex9918CnscDR6CODH
# 1f3kYu7gm8cS+OdrQsfWIiQsfzEq+iTQpwtzzXFmktUhb4XnkXD4LsOcft2tio3B
# 2NKXSABqLSmiul5YzwXjUL8Ehh1wj+26+C86KfG/oYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ1NVowLwYJKoZIhvcNAQkEMSIEIOUyENdHvpdNYEbZ
# /ym5pQvW5KDSbo63212dZqAs4yQDMA0GCSqGSIb3DQEBAQUABIICAIWzq/B1wNrY
# 3D6AlrXqAdSCbOJoCZAf53v3cT86WjwBpR2numZUsh1eSHcmDdHFQA1Pe9jY/r+P
# iYiCvb5575FYi2uancFuB5HdvcB6GLUTvgKXFKTtywu4tng3DD10k+INBBNrZywH
# PP4XJaf8ZKUMTjSKvqahbU6tHj8I7Wsl+73O3jQvatzmGAA0cD6uyEBeiSZXw56B
# Q1urVyZZ7dBsREMshxDzL9vyFgDYwRFAHMTZb/YqORWLIsIVMh1xpjEifca/U/PV
# +YGkMWgRgAA7RDQbCtfSVHfynUfeOi1j68TotdI33ikDoak0bOd5ZZtqOI/XnKth
# Qtect2FGFXBHMkTWmDpTJKuzPl+tLiC6h9b0Btt29IfDp3hgzG/eZIaWn0VTzf0r
# +XlFNS7916W1NobThj2C+3baPS2CWg2RN/qaT7JERb1yBrykxp1tRsZ12fp8VyWl
# wBjBLsh2sKf0xrt3dDgCy0JAickofOYtcPnRejXHcan3ajOLRA3GF4keZSKAdsWc
# QWDWhgPymm8Jh894AXHfXQkAMbEVipJyfVT0sUMXH2WUbUHqzZHJgO3vNSjpfz6I
# VQOe74HSzfNeAiweUYr7K+ZV69Mia5OvhzAm9kP+Ql4sb4deCEQoKoeHKn3pvH7H
# L9dU9OYGOR9QZRr0VmH+pA1tYNNrc6ps
# SIG # End signature block
