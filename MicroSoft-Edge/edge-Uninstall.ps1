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
        text  = "MS EDGE Uninstaller v$($ScriptVersion)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQULuYZb+TIJwhPQHKhPXc/P1i8
# FD+gghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBSphUKzIKgFmNHFiq8SNYlx4TxBqTANBgkq
# hkiG9w0BAQEFAASCAQB09+6EU/YzY/HSFZu0BUeK1PM/+ji/QNks2lPc7I2wtmoH
# 6+givakxi6Aiz6ypTEwLZ1pbGAIidx3rLbXNUVkQytxbOLxLmvjuo9gufosdfYVG
# TxtXY3LmrnkoWX2RSqBVhToy25YgzMzpz55Nrh9y/U5yBx1u5/JihEbI7rZv2HYx
# gjgkHFSThCjth0yefrzkjBT9DeCeceJ6nBA/TQFk9QqzOUZmRNyimBZ9lKuOlwsP
# 1oNYePMbb0oJ143eLLNp/5t5lHvdqYkOJ45wZ2U05KzQvOc4C9SJTRnw8dorhClU
# +NtWsQWf77v2bPuMpfQ+gP2cas2pTbP3Z6NEgdJBoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0N1owLwYJKoZIhvcNAQkEMSIEINupBtHPSPhCkPdP
# +3HYNiA0irvGAmuHfYrV9QehfZtTMA0GCSqGSIb3DQEBAQUABIICABtkU9HF9jsi
# HYZBAtAsfhn3iW/IIQmzYiae5eI6evmJrWTq5nOX/87nSi9zxkVW9FAyQ9qP28l1
# J4HN3ia1uUAT7+RpniDLzFCQ0L1kKrRwMKuULq6okvN52mTZZU8faZOMHCfcyp30
# KLa57rJ77YOTCm6SiSLtFESXk6+wX7V49u3HLWWVRDsFbj7TmXt8QeSpWql1MmVL
# H0Jm78nrPgg+E4wizGmqd9gX6xtvg0m2973P95Av55LrEUbrCUK9ap4QMsbHMF8H
# 4AmvH8+zX4x0nLA6tGZv+3FIqnNLJR6veEcubnVBKqeWd3j6Gmz1JBiCOck4mAgG
# z3QZ/F9aSIDow/c1cErPOnmlg2aCrGWVzlFxCkwx8fATTPdG0tZUXfxiORWJKQIH
# d2Eg8xppL7YfNveRpncpLTqK+aprN9sosd/fefE3CVxy8xRgnAFKSxN4xQ6qZgPd
# fe4BSj1lRykEV2FHdzDqfHZb6QXOFq36HxqIw2rxM2ajLbKbmdaIx4u7/gZccHEV
# GKdXIjDyZ9Fm2mmy8IpakFPtmh3Hon36NibLAglGlX3KHrKPlSpYz6QSPL/2gxr+
# 1AvLlX4bdiM6MOCDbW61+I45//Qbrkpz0ap7SG004/94ResJPN141JYdTMw5yjNs
# fINpiMxO4rRlM0s0alS13d/dFwZmXOss
# SIG # End signature block
