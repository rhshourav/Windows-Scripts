<#
  Windows-Scripts | Remove Microsoft Edge (Best-Effort) - Interactive Remover
  Supports: Windows 10 19H1 (1903) -> Windows 11 current | PowerShell 5.1+
  Author : Shourav
  GitHub : https://github.com/rhshourav
  Version: 1.3.1

  NOTES:
  - WebView2 is NOT touched unless explicitly selected from the menu.
  - On some newer Windows builds, Edge may be retained/restored by servicing/updates.
  - Script is best-effort and prioritizes stability by default.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# -----------------------------
# Script Metadata (Windows-Scripts)
# -----------------------------
$ScriptName    = "Remove Edge - Interactive Remover"
$ScriptVersion = "1.3.1"
$ScriptAuthor  = "Shourav"
$ScriptGitHub  = "github.com/rhshourav"
$ScriptPack    = "Windows-Scripts"

# Banner mode:
#   "ASCII"   -> safe on all consoles (default, recommended)
#   "UNICODE" -> only if your console/font can render block chars
$BannerMode = "ASCII"

# -----------------------------
# Theme / UI
# -----------------------------
$C_OK    = "Green"
$C_WARN  = "Yellow"
$C_ERR   = "Red"
$C_INFO  = "Cyan"
$C_DIM   = "DarkGray"
$C_MAIN  = "White"

function Set-ConsoleTheme {
    try {
        $raw = $Host.UI.RawUI
        $raw.BackgroundColor = "Black"
        $raw.ForegroundColor = "Gray"
        $raw.WindowTitle = $ScriptName
        Clear-Host
    } catch {}

    # Best-effort for Unicode; harmless even if BannerMode is ASCII.
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
}

function Write-Section([string]$t) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor $C_DIM
    Write-Host $t -ForegroundColor $C_INFO
    Write-Host ("=" * 78) -ForegroundColor $C_DIM
}

# No "press enter" pauses.
function Pause-Brief([int]$Seconds = 2) {
    Start-Sleep -Seconds $Seconds
}

function Write-Banner {
    Write-Host ""

    if ($BannerMode -eq "UNICODE") {
        # Only enable if you know your console can render it cleanly.
        Write-Host "██████╗ ███████╗███╗   ███╗ ██████╗ ██╗   ██╗███████╗" -ForegroundColor $C_INFO
        Write-Host "██╔══██╗██╔════╝████╗ ████║██╔═══██╗██║   ██║██╔════╝" -ForegroundColor $C_INFO
        Write-Host "██████╔╝█████╗  ██╔████╔██║██║   ██║██║   ██║█████╗  " -ForegroundColor $C_INFO
        Write-Host "██╔══██╗██╔══╝  ██║╚██╔╝██║██║   ██║╚██╗ ██╔╝██╔══╝  " -ForegroundColor $C_INFO
        Write-Host "██║  ██║███████╗██║ ╚═╝ ██║╚██████╔╝ ╚████╔╝ ███████╗" -ForegroundColor $C_INFO
        Write-Host "╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝   ╚═══╝  ╚══════╝" -ForegroundColor $C_INFO
    } else {
        # ASCII banner (safe everywhere)
        Write-Host "==============================================================================" -ForegroundColor $C_INFO
        Write-Host "  REMOVE MICROSOFT EDGE - INTERACTIVE REMOVER"                                  -ForegroundColor $C_INFO
        Write-Host "==============================================================================" -ForegroundColor $C_INFO
    }

    Write-Host ("{0} | v{1}" -f $ScriptName, $ScriptVersion) -ForegroundColor $C_MAIN
    Write-Host ("Author: {0} | GitHub: {1}" -f $ScriptAuthor, $ScriptGitHub) -ForegroundColor $C_DIM
    Write-Host ("Package: {0}" -f $ScriptPack) -ForegroundColor $C_DIM
    Write-Host "Microsoft Edge removal (best-effort) | WebView2 avoided by default" -ForegroundColor $C_DIM
    Write-Host ""
}

# -----------------------------
# Privilege
# -----------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Elevate-Self {
    if (Test-Admin) { return }

    Set-ConsoleTheme
    Write-Banner
    Write-Host "[!] Not running as Administrator. Relaunching elevated..." -ForegroundColor $C_WARN

    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList | Out-Null
    exit
}

# -----------------------------
# Core Helpers
# -----------------------------
function Stop-ProcSafe([string[]]$Names) {
    foreach ($n in $Names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Disable-ServiceSafe([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}
        try { Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
    }
}

function Disable-TasksLike([string]$Pattern) {
    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $Pattern }
        foreach ($t in $tasks) {
            try { Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    } catch {}
}

function Get-HighestSetupExe([string[]]$AppRoots) {
    $setups = New-Object System.Collections.Generic.List[object]

    foreach ($root in $AppRoots) {
        if (-not (Test-Path $root)) { continue }
        try {
            $verDirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+)+' }

            foreach ($v in $verDirs) {
                $setup = Join-Path $v.FullName "Installer\setup.exe"
                if (Test-Path $setup) {
                    $setups.Add([pscustomobject]@{ Version=$v.Name; Path=$setup })
                }
            }
        } catch {}
    }

    if ($setups.Count -eq 0) { return $null }

    $sorted = $setups | Sort-Object -Property @{
        Expression = { try { [version]$_.Version } catch { [version]"0.0.0.0" } }
    } -Descending

    return $sorted[0].Path
}

function Run-Exe([string]$FilePath, [string]$Args, [string]$Label) {
    Write-Host "-> $Label" -ForegroundColor $C_MAIN
    Write-Host "   $FilePath $Args" -ForegroundColor $C_DIM
    $p = Start-Process -FilePath $FilePath -ArgumentList $Args -Wait -PassThru -WindowStyle Hidden
    Write-Host "   ExitCode: $($p.ExitCode)" -ForegroundColor $C_DIM
    return $p.ExitCode
}

function Takeown-And-Delete([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Write-Host "-> Deleting (aggressive): $Path" -ForegroundColor $C_WARN
    & takeown.exe /F $Path /R /D Y | Out-Null
    & icacls.exe $Path /grant Administrators:F /T /C | Out-Null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-WinGetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    return $cmd.Source
}

# Always returns an ARRAY (prevents .Count errors)
function Verify-EdgePresence {
    $paths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    return @($paths | Where-Object { Test-Path $_ })
}

# -----------------------------
# Operations
# -----------------------------
function Disable-EdgeUpdate {
    Write-Section "Disable Edge Update (services + scheduled tasks)"
    Stop-ProcSafe @("MicrosoftEdgeUpdate", "edgeupdate", "edgeupdatem")

    Disable-ServiceSafe "edgeupdate"
    Disable-ServiceSafe "edgeupdatem"
    Disable-ServiceSafe "MicrosoftEdgeElevationService"

    Disable-TasksLike "MicrosoftEdgeUpdateTaskMachineCore"
    Disable-TasksLike "MicrosoftEdgeUpdateTaskMachineUA"
    Disable-TasksLike "MicrosoftEdgeUpdateTaskMachine*"
    Disable-TasksLike "MicrosoftEdgeUpdate*"

    Write-Host "[+] Edge Update services/tasks disabled (best-effort)." -ForegroundColor $C_OK
}

function Uninstall-Edge {
    param([switch]$TryWingetFirst = $true)

    Write-Section "Uninstall Microsoft Edge (best-effort)"
    Stop-ProcSafe @("msedge", "msedgewebview2", "MicrosoftEdgeUpdate", "edgeupdate", "edgeupdatem")

    if ($TryWingetFirst) {
        $winget = Get-WinGetPath
        if ($null -ne $winget) {
            Write-Host "-> winget detected. Attempting uninstall..." -ForegroundColor $C_MAIN
            try {
                & $winget uninstall -e --id Microsoft.Edge --silent --force --disable-interactivity --accept-source-agreements | Out-Null
                Write-Host "[+] winget uninstall attempted." -ForegroundColor $C_OK
            } catch {
                Write-Host "[!] winget uninstall failed: $($_.Exception.Message)" -ForegroundColor $C_WARN
            }
        } else {
            Write-Host "-> winget not found. Skipping winget uninstall." -ForegroundColor $C_DIM
        }
    }

    $edgeSetup = Get-HighestSetupExe @(
        "C:\Program Files (x86)\Microsoft\Edge\Application",
        "C:\Program Files\Microsoft\Edge\Application",
        (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\Application")
    )

    if ($null -eq $edgeSetup) {
        Write-Host "[!] Could not locate Edge setup.exe in standard locations." -ForegroundColor $C_WARN
        return
    }

    try { Run-Exe $edgeSetup "--uninstall --system-level --verbose-logging --force-uninstall" "Edge uninstall (system-level)" | Out-Null } catch {}
    try { Run-Exe $edgeSetup "--uninstall --user-level  --verbose-logging --force-uninstall" "Edge uninstall (user-level)"  | Out-Null } catch {}

    $still = Verify-EdgePresence
    if (@($still).Count -eq 0) {
        Write-Host "[+] Edge executable not found in standard Program Files paths." -ForegroundColor $C_OK
    } else {
        Write-Host "[!] Edge still appears present at:" -ForegroundColor $C_WARN
        @($still) | ForEach-Object { Write-Host "    $_" -ForegroundColor $C_WARN }
        Write-Host "    Note: On some builds, removal is OS-enforced and Edge may persist/return." -ForegroundColor $C_DIM
    }
}

function Uninstall-WebView2 {
    Write-Section "Remove WebView2 Runtime (HIGH RISK)"
    Write-Host "[!] This can break apps (Office add-ins, Teams components, widgets, embedded sign-in)." -ForegroundColor $C_WARN
    $confirm = Read-Host "Type EXACTLY 'REMOVE' to proceed, or press ENTER to cancel"
    if ($confirm -ne "REMOVE") {
        Write-Host "-> Cancelled WebView2 removal." -ForegroundColor $C_DIM
        return
    }

    Stop-ProcSafe @("msedgewebview2", "MicrosoftEdgeUpdate", "edgeupdate", "edgeupdatem")

    $winget = Get-WinGetPath
    if ($null -ne $winget) {
        try {
            & $winget uninstall -e --id Microsoft.EdgeWebView2Runtime --silent --force --disable-interactivity --accept-source-agreements | Out-Null
            Write-Host "[+] winget WebView2 uninstall attempted." -ForegroundColor $C_OK
        } catch {
            Write-Host "[!] winget WebView2 uninstall failed: $($_.Exception.Message)" -ForegroundColor $C_WARN
        }
    } else {
        Write-Host "-> winget not found. Skipping winget WebView2 uninstall." -ForegroundColor $C_DIM
    }

    $wvSetup = Get-HighestSetupExe @(
        "C:\Program Files (x86)\Microsoft\EdgeWebView\Application",
        "C:\Program Files\Microsoft\EdgeWebView\Application"
    )

    if ($null -ne $wvSetup) {
        try {
            Run-Exe $wvSetup "--uninstall --msedgewebview --system-level --verbose-logging --force-uninstall" "WebView2 uninstall (system-level)" | Out-Null
        } catch {}
    } else {
        Write-Host "[!] WebView2 setup.exe not found in standard locations." -ForegroundColor $C_WARN
    }

    Write-Host "[+] WebView2 removal step completed (best-effort)." -ForegroundColor $C_OK
}

function Aggressive-Cleanup {
    param([switch]$IncludeWebView2 = $false)

    Write-Section "Aggressive cleanup (take ownership + delete leftovers)"
    Write-Host "[!] This may interfere with servicing / future updates on some systems." -ForegroundColor $C_WARN
    $ok = Read-Host "Proceed? (Y/N)"
    if ($ok -notin @("Y","y")) {
        Write-Host "-> Aggressive cleanup cancelled." -ForegroundColor $C_DIM
        return
    }

    Stop-ProcSafe @("msedge", "msedgewebview2", "MicrosoftEdgeUpdate", "edgeupdate", "edgeupdatem")

    $paths = @(
        "C:\Program Files (x86)\Microsoft\Edge",
        "C:\Program Files\Microsoft\Edge",
        "C:\Program Files (x86)\Microsoft\EdgeUpdate",
        "C:\Program Files\Microsoft\EdgeUpdate",
        (Join-Path $env:LOCALAPPDATA "Microsoft\Edge"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeUpdate")
    )

    if ($IncludeWebView2) {
        $paths += @(
            "C:\Program Files (x86)\Microsoft\EdgeWebView",
            "C:\Program Files\Microsoft\EdgeWebView"
        )
    }

    foreach ($p in $paths) {
        if (Test-Path $p) { Takeown-And-Delete $p }
    }

    Write-Host "[+] Cleanup completed (best-effort)." -ForegroundColor $C_OK
}

# -----------------------------
# Main
# -----------------------------
Elevate-Self
Set-ConsoleTheme

$log = Join-Path $env:TEMP ("RemoveEdge_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
try { Start-Transcript -Path $log | Out-Null } catch {}

try {
    while ($true) {
        Set-ConsoleTheme
        Write-Banner
        Write-Host ("Log: {0}" -f $log) -ForegroundColor $C_DIM
        Write-Host ""

        Write-Host "  [1] Recommended: Disable Edge Update + Remove Edge (NO WebView2)" -ForegroundColor $C_MAIN
        Write-Host "  [2] Remove Edge only" -ForegroundColor $C_MAIN
        Write-Host "  [3] Disable Edge Update only (services/tasks)" -ForegroundColor $C_MAIN
        Write-Host "  [4] Aggressive cleanup leftovers (NO WebView2)" -ForegroundColor $C_MAIN
        Write-Host "  [5] Full: Disable Update + Remove Edge + Aggressive cleanup (NO WebView2)" -ForegroundColor $C_MAIN
        Write-Host "  [6] OPTIONAL: Remove WebView2 Runtime (HIGH RISK)" -ForegroundColor $C_WARN
        Write-Host "  [7] Exit" -ForegroundColor $C_MAIN
        Write-Host ""

        $choice = Read-Host "Select an option (1-7)"

        switch ($choice) {
            "1" { Disable-EdgeUpdate; Uninstall-Edge -TryWingetFirst:$true; Pause-Brief 2 }
            "2" { Uninstall-Edge -TryWingetFirst:$true; Pause-Brief 2 }
            "3" { Disable-EdgeUpdate; Pause-Brief 2 }
            "4" { Aggressive-Cleanup -IncludeWebView2:$false; Pause-Brief 2 }
            "5" { Disable-EdgeUpdate; Uninstall-Edge -TryWingetFirst:$true; Aggressive-Cleanup -IncludeWebView2:$false; Pause-Brief 2 }
            "6" { Uninstall-WebView2; Pause-Brief 2 }
            "7" { break }
            default { Write-Host "[!] Invalid option." -ForegroundColor $C_WARN; Start-Sleep -Seconds 1 }
        }
    }

    Write-Section "Final verification"
    $still = Verify-EdgePresence
    if (@($still).Count -eq 0) {
        Write-Host "[+] Edge executable not found in standard Program Files paths." -ForegroundColor $C_OK
    } else {
        Write-Host "[!] Edge still present at:" -ForegroundColor $C_WARN
        @($still) | ForEach-Object { Write-Host "    $_" -ForegroundColor $C_WARN }
        Write-Host "    Some Windows builds restore or retain Edge as a platform component." -ForegroundColor $C_DIM
    }

    Write-Host ""
    Write-Host ("Log saved at: {0}" -f $log) -ForegroundColor $C_DIM

    # Auto-exit shortly after final status (no keypress required)
    Start-Sleep -Seconds 3
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
