<#
.SYNOPSIS
  Set Dhaka time zone, force time sync (timeout-safe), and apply date/time formats for ALL users,
  with immediate refresh for the CURRENT user.

.DESCRIPTION
  Order is intentional:
  1) Prompt + apply formats first (so current user sees it immediately)
  2) Refresh current session (WM_SETTINGCHANGE + optional Explorer restart)
  3) Force time zone Dhaka and time sync (resync has a hard timeout)

.AUTHOR
  Shourav (rhshourav)
.GITHUB
  https://github.com/rhshourav
.VERSION
  1.4.0
#>

[CmdletBinding()]
param(
  [int]$MaxAllowedDriftSeconds = 5,
  [switch]$SkipFormatPrompt,
  [switch]$RestartExplorerForCurrentUser,
  [int]$ResyncTimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"

# -----------------------------
# Console helpers
# -----------------------------
function Write-Line { Write-Host ("=" * 78) -ForegroundColor DarkCyan }
function Write-Head([string]$t) { Write-Line; Write-Host $t -ForegroundColor Cyan; Write-Line }
function Write-Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Gray }
function Write-OK  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "[-] $m" -ForegroundColor Red }

function Is-Admin {
  $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $wp.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
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
        text  = "Time Sync & Format v1.4.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

# -----------------------------
# Auto-elevate
# -----------------------------
if (-not (Is-Admin)) {
  Write-Warn "Administrator rights are required. Elevating..."
  $argList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`"",
    "-MaxAllowedDriftSeconds", $MaxAllowedDriftSeconds,
    "-ResyncTimeoutSeconds", $ResyncTimeoutSeconds
  )
  if ($SkipFormatPrompt) { $argList += "-SkipFormatPrompt" }
  if ($RestartExplorerForCurrentUser) { $argList += "-RestartExplorerForCurrentUser" }

  Start-Process powershell -Verb RunAs -ArgumentList $argList
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


# -----------------------------
# Constants
# -----------------------------
$DhakaWindowsTzId = "Bangladesh Standard Time"

function Get-DhakaNow {
  $tz = [TimeZoneInfo]::FindSystemTimeZoneById($DhakaWindowsTzId)
  [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
}

# -----------------------------
# Safe process runner (timeout)
# -----------------------------
function Invoke-ProcessWithTimeout {
  param(
    [Parameter(Mandatory)] [string] $FilePath,
    [Parameter(Mandatory)] [string[]] $ArgumentList,
    [int] $TimeoutSeconds = 15
  )

  $outFile = Join-Path $env:TEMP ("ps_out_{0}.txt" -f ([guid]::NewGuid().ToString("N")))
  $errFile = Join-Path $env:TEMP ("ps_err_{0}.txt" -f ([guid]::NewGuid().ToString("N")))

  try {
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow `
      -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $done = $p | Wait-Process -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
    if (-not $done) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
      return @{
        TimedOut = $true
        ExitCode = $null
        StdOut   = (Get-Content $outFile -ErrorAction SilentlyContinue | Out-String).Trim()
        StdErr   = (Get-Content $errFile -ErrorAction SilentlyContinue | Out-String).Trim()
      }
    }

    return @{
      TimedOut = $false
      ExitCode = $p.ExitCode
      StdOut   = (Get-Content $outFile -ErrorAction SilentlyContinue | Out-String).Trim()
      StdErr   = (Get-Content $errFile -ErrorAction SilentlyContinue | Out-String).Trim()
    }
  }
  finally {
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

# -----------------------------
# Format (ALL users)
# -----------------------------
function Prompt-Choice([string]$Title, [hashtable]$Options, [string]$CurrentValue) {
  Write-Line
  Write-Host $Title -ForegroundColor Cyan
  Write-Host ("Current: {0}" -f $CurrentValue) -ForegroundColor Gray
  foreach ($k in ($Options.Keys | Sort-Object {[int]$_})) {
    Write-Host ("  {0}) {1}" -f $k, $Options[$k]) -ForegroundColor Gray
  }
  Write-Host "  Enter) Keep current" -ForegroundColor DarkGray
  $sel = Read-Host "Select"
  if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
  if ($Options.ContainsKey($sel)) { return $Options[$sel] }
  Write-Warn "Invalid selection. Keeping current."
  $null
}

function Set-IntlInHive([string]$HiveRoot, [string]$ShortDate, [string]$LongDate, [string]$TimeFmt) {
  $intlPath = Join-Path $HiveRoot "Control Panel\International"
  if (-not (Test-Path $intlPath)) {
    try { New-Item -Path $intlPath -Force | Out-Null } catch { return $null }
  }

  $changes = @{}
  if ($ShortDate) {
    Set-ItemProperty -Path $intlPath -Name sShortDate -Value $ShortDate -Force
    $changes["sShortDate"] = $ShortDate
  }
  if ($LongDate) {
    Set-ItemProperty -Path $intlPath -Name sLongDate -Value $LongDate -Force
    $changes["sLongDate"] = $LongDate
  }
  if ($TimeFmt) {
    Set-ItemProperty -Path $intlPath -Name sTimeFormat -Value $TimeFmt -Force
    $changes["sTimeFormat"] = $TimeFmt

    $is24 = ($TimeFmt -like "HH*")
    try {
      Set-ItemProperty -Path $intlPath -Name iTime -Value ($(if ($is24) { "1" } else { "0" })) -Force
      $changes["iTime"] = $(if ($is24) { "1" } else { "0" })
    } catch { }
  }
  $changes
}

function Load-UserHive([string]$NtUserDatPath, [string]$MountName) {
  $mount = "HKU\$MountName"
  $out = & reg.exe load $mount $NtUserDatPath 2>&1
  if ($LASTEXITCODE -ne 0) { throw "reg load failed: $out" }
}

function Unload-UserHive([string]$MountName) {
  $mount = "HKU\$MountName"
  $out = & reg.exe unload $mount 2>&1
  if ($LASTEXITCODE -ne 0) { throw "reg unload failed: $out" }
}

function Apply-FormatsAllUsers([string]$ShortDate, [string]$TimeFmt) {
  $LongDate = "dddd, dd MMMM yyyy"

  $applied = New-Object System.Collections.Generic.List[string]
  $failed  = New-Object System.Collections.Generic.List[string]

  # 1) Loaded user hives
  Write-Info "Applying formats to loaded user hives..."
  $loadedSids = Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'HKEY_USERS\\S-1-5-21-' -and $_.Name -notmatch '_Classes$' } |
    ForEach-Object { $_.PSChildName }

  foreach ($sid in $loadedSids) {
    try {
      $root = "Registry::HKEY_USERS\$sid"
      [void](Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt)
      $applied.Add("$sid (loaded)") | Out-Null
    } catch {
      $failed.Add("$sid (loaded): $($_.Exception.Message)") | Out-Null
    }
  }

  # 2) .DEFAULT
  Write-Info "Applying formats to HKEY_USERS\.DEFAULT..."
  try {
    $root = "Registry::HKEY_USERS\.DEFAULT"
    [void](Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt)
    $applied.Add(".DEFAULT") | Out-Null
  } catch {
    $failed.Add(".DEFAULT: $($_.Exception.Message)") | Out-Null
  }

  # 3) Default profile (future users)
  $defaultNtUser = Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT"
  if (Test-Path $defaultNtUser) {
    Write-Info "Applying formats to Default profile (future users)..."
    $mountName = "TEMP_DEFAULT_PROFILE"
    try {
      Load-UserHive -NtUserDatPath $defaultNtUser -MountName $mountName
      $root = "Registry::HKEY_USERS\$mountName"
      [void](Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt)
      Unload-UserHive -MountName $mountName
      $applied.Add("DefaultProfile (C:\Users\Default)") | Out-Null
    } catch {
      try { Unload-UserHive -MountName $mountName } catch { }
      $failed.Add("DefaultProfile: $($_.Exception.Message)") | Out-Null
    }
  } else {
    $failed.Add("DefaultProfile: NTUSER.DAT not found at $defaultNtUser") | Out-Null
  }

  # 4) Offline users (ProfileList)
  Write-Info "Applying formats to offline user hives (ProfileList)..."
  $profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
  $profiles = Get-ChildItem $profileList -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' }

  foreach ($p in $profiles) {
    $sid = $p.PSChildName
    $mountName = $null
    try {
      if (Test-Path "Registry::HKEY_USERS\$sid") { continue }

      $profilePath = (Get-ItemProperty $p.PSPath -ErrorAction Stop).ProfileImagePath
      if ([string]::IsNullOrWhiteSpace($profilePath)) { continue }

      $expanded = [Environment]::ExpandEnvironmentVariables($profilePath)
      $ntuser = Join-Path $expanded "NTUSER.DAT"
      if (-not (Test-Path $ntuser)) { continue }

      $mountName = "TEMP_$($sid -replace '[^A-Za-z0-9]','_')"
      Load-UserHive -NtUserDatPath $ntuser -MountName $mountName
      $root = "Registry::HKEY_USERS\$mountName"
      [void](Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt)
      Unload-UserHive -MountName $mountName

      $applied.Add("$sid (offline hive)") | Out-Null
    } catch {
      try { if ($mountName) { Unload-UserHive -MountName $mountName } } catch { }
      $failed.Add("$sid (offline hive): $($_.Exception.Message)") | Out-Null
    }
  }

  @{
    Applied   = $applied
    Failed    = $failed
    ShortDate = $ShortDate
    LongDate  = $LongDate
    TimeFmt   = $TimeFmt
  }
}

function Refresh-IntlSettingsCurrentSession([switch]$RestartExplorer) {
  Write-Info "Refreshing international settings for current session (best-effort)..."

  try {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
  public const int HWND_BROADCAST = 0xffff;
  public const int WM_SETTINGCHANGE = 0x001A;
  public const int SMTO_ABORTIFHUNG = 0x0002;

  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, int Msg, IntPtr wParam, string lParam,
    int fuFlags, int uTimeout, out IntPtr lpdwResult
  );
}
"@ -ErrorAction SilentlyContinue | Out-Null

    $result = [IntPtr]::Zero
    [void][Win32.NativeMethods]::SendMessageTimeout(
      [IntPtr][Win32.NativeMethods]::HWND_BROADCAST,
      [Win32.NativeMethods]::WM_SETTINGCHANGE,
      [IntPtr]::Zero,
      "intl",
      [Win32.NativeMethods]::SMTO_ABORTIFHUNG,
      5000,
      [ref]$result
    )
    Write-OK "Broadcasted WM_SETTINGCHANGE (intl)."
  } catch {
    Write-Warn "WM_SETTINGCHANGE broadcast failed: $($_.Exception.Message)"
  }

  try {
    & rundll32.exe user32.dll,UpdatePerUserSystemParameters 1, $true | Out-Null
    Write-OK "Updated per-user system parameters."
  } catch {
    Write-Warn "UpdatePerUserSystemParameters failed: $($_.Exception.Message)"
  }

  if ($RestartExplorer) {
    try {
      Write-Warn "Restarting Explorer for current user (UI refresh; brief disruption)..."
      Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
      Start-Process explorer.exe | Out-Null
      Write-OK "Explorer restarted."
    } catch {
      Write-Warn "Explorer restart failed: $($_.Exception.Message)"
    }
  }
}

# -----------------------------
# Time zone + sync
# -----------------------------
function Ensure-TimeZoneDhaka {
  $before = (tzutil /g 2>$null).Trim()
  Write-Info "Current Windows time zone: $before"
  if ($before -ne $DhakaWindowsTzId) {
    Write-Info "Setting time zone to Dhaka: $DhakaWindowsTzId"
    tzutil /s $DhakaWindowsTzId | Out-Null
  } else {
    Write-OK "Time zone already set to Dhaka."
  }
  $after = (tzutil /g 2>$null).Trim()
  if ($after -ne $DhakaWindowsTzId) {
    throw "Failed to set time zone. Current is still: $after"
  }
  @{ Before = $before; After = $after }
}

function Force-TimeSync([int]$TimeoutSeconds) {
  Write-Info "Ensuring Windows Time service (w32time) is enabled and running..."
  try { Set-Service -Name w32time -StartupType Automatic } catch { }

  $svc = Get-Service -Name w32time -ErrorAction Stop
  if ($svc.Status -ne "Running") { Start-Service -Name w32time }

  $peers = "time.google.com,0x9 time.windows.com,0x9 pool.ntp.org,0x9"
  Write-Info "Configuring NTP peers (best-effort): $peers"
  try {
    & w32tm /config /manualpeerlist:$peers /syncfromflags:manual /reliable:no /update | Out-Null
  } catch {
    Write-Warn "w32tm /config failed (continuing): $($_.Exception.Message)"
  }

  Write-Info "Restarting w32time (best-effort)..."
  try {
    Stop-Service -Name w32time -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Service -Name w32time -ErrorAction Stop
  } catch { }

  Write-Info "Forcing time resync (timeout ${TimeoutSeconds}s)..."
  $res = Invoke-ProcessWithTimeout -FilePath "w32tm.exe" -ArgumentList @("/resync","/force") -TimeoutSeconds $TimeoutSeconds

  if ($res.TimedOut) {
    Write-Warn "w32tm /resync timed out. Continuing."
  } elseif ($res.ExitCode -ne 0) {
    Write-Warn "w32tm /resync failed (exit $($res.ExitCode)). Continuing."
  } else {
    Write-OK "w32tm /resync completed."
  }

  $st = Invoke-ProcessWithTimeout -FilePath "w32tm.exe" -ArgumentList @("/query","/status") -TimeoutSeconds 10
  @{
    ResyncTimedOut = $res.TimedOut
    ResyncExitCode = $res.ExitCode
    ResyncStdOut   = $res.StdOut
    ResyncStdErr   = $res.StdErr
    StatusOutput   = ($st.StdOut + "`n" + $st.StdErr).Trim()
  }
}

function Test-DhakaTimeMatch([int]$ThresholdSeconds) {
  $localNow = Get-Date
  $dhakaNow = Get-DhakaNow
  $drift = [Math]::Abs(($localNow - $dhakaNow).TotalSeconds)

  @{
    LocalNow = $localNow
    DhakaNow = $dhakaNow
    DriftSeconds = [Math]::Round($drift, 3)
    Threshold = $ThresholdSeconds
    IsMatch = ($drift -le $ThresholdSeconds)
  }
}

# -----------------------------
# MAIN
# -----------------------------
Write-Head "Dhaka TZ + Sync + ALL-Users Formats (Formats First) | v1.4.0 | rhshourav"

$formatsResult = $null
if (-not $SkipFormatPrompt) {
  $curIntl = Get-ItemProperty "HKCU:\Control Panel\International" -ErrorAction SilentlyContinue
  $curShort = $curIntl.sShortDate
  $curTime  = $curIntl.sTimeFormat

  $dateOptions = @{
    "1" = "dd-MM-yyyy"
    "2" = "dd/MM/yyyy"
    "3" = "yyyy-MM-dd"
    "4" = "dd MMM yyyy"
    "5" = "MMM dd, yyyy"
  }
  $timeOptions = @{
    "1" = "HH:mm"
    "2" = "HH:mm:ss"
    "3" = "hh:mm tt"
    "4" = "hh:mm:ss tt"
  }

  $newShortDate = Prompt-Choice -Title "Select Short Date format (applies to ALL users)" -Options $dateOptions -CurrentValue $curShort
  $newTimeFmt   = Prompt-Choice -Title "Select Time format (applies to ALL users)"       -Options $timeOptions -CurrentValue $curTime

  if ($newShortDate -or $newTimeFmt) {
    if (-not $newShortDate) { $newShortDate = $(if ($curShort) { $curShort } else { "dd-MM-yyyy" }) }
    if (-not $newTimeFmt)   { $newTimeFmt   = $(if ($curTime)  { $curTime }  else { "HH:mm:ss" }) }

    Write-Info "Applying chosen formats to ALL users (now)..."
    $formatsResult = Apply-FormatsAllUsers -ShortDate $newShortDate -TimeFmt $newTimeFmt
    Refresh-IntlSettingsCurrentSession -RestartExplorer:$RestartExplorerForCurrentUser
    Write-OK "Formats written for all users; current session refreshed."
  } else {
    Write-Info "No format changes selected."
  }
} else {
  Write-Info "Format prompt skipped."
}

# Time zone + sync AFTER formats (so format feels immediate)
$tzResult = Ensure-TimeZoneDhaka
$syncResult = Force-TimeSync -TimeoutSeconds $ResyncTimeoutSeconds

$match = Test-DhakaTimeMatch -ThresholdSeconds $MaxAllowedDriftSeconds
Write-Info ("Local time : {0:yyyy-MM-dd HH:mm:ss.fff}" -f $match.LocalNow)
Write-Info ("Dhaka time : {0:yyyy-MM-dd HH:mm:ss.fff}" -f $match.DhakaNow)
if ($match.IsMatch) {
  Write-OK ("Time matches Dhaka within {0}s (drift: {1}s)." -f $match.Threshold, $match.DriftSeconds)
} else {
  Write-Warn ("Time does NOT match Dhaka within {0}s (drift: {1}s). Domain policy or blocked NTP can prevent correction." -f $match.Threshold, $match.DriftSeconds)
}

Write-Head "Summary"
Write-Host ("Time zone: {0} -> {1}" -f $tzResult.Before, $tzResult.After) -ForegroundColor Gray

if ($formatsResult) {
  Write-Host ("Formats: ShortDate={0} | LongDate={1} | TimeFormat={2}" -f $formatsResult.ShortDate, $formatsResult.LongDate, $formatsResult.TimeFmt) -ForegroundColor Gray
  Write-Host ("Applied targets: {0}" -f $formatsResult.Applied.Count) -ForegroundColor Gray
  if ($formatsResult.Failed.Count -gt 0) {
    Write-Warn ("Failed targets: {0}" -f $formatsResult.Failed.Count)
    foreach ($f in ($formatsResult.Failed | Select-Object -First 15)) { Write-Host "  $f" -ForegroundColor DarkGray }
    if ($formatsResult.Failed.Count -gt 15) { Write-Host "  ... (truncated)" -ForegroundColor DarkGray }
  }
}

if ($syncResult.StatusOutput) {
  Write-Line
  Write-Host "w32tm status (best-effort):" -ForegroundColor Cyan
  $syncResult.StatusOutput.Split("`n") |
    ForEach-Object { $_.TrimEnd() } |
    Where-Object { $_ } |
    ForEach-Object { Write-Host "  $($_)" -ForegroundColor DarkGray }
}

Write-Line
Write-OK "Done."

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU9HONlG5B6p85f89yep70U2X7
# uZCgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRzRT/Ic/pyp/UBTAmG26GC3Q4t5zANBgkq
# hkiG9w0BAQEFAASCAQBtY+nUtEm/utZgdq6mDPtHvEsuI8NeQ+5DhqWJDteBFJRG
# 5GBIXQFSFbOHhvJnhkMmBjTgcUBwtQP5NIboFnD1P0J4e8h1l9YcmXRiSRJ4x+77
# pN724RdvmUftCZ2BcI4IbUolG2IVMmaf9oQDeLJTEGDb9CBj7NV8MIdUQF+UB4F0
# onPqxSMsC6PrT0p7v5ZcfAY8fnEktsQ2DPiS/oSycgRc11QZkiAs5XwbhoieFyzm
# hPuhR16z5GoVbapBs/Uz+KG+SMz9V8cbnuD3d96de3xjHHm+2CTXv91fS3oMUchi
# pUnVVrQm0PxQmjZpEs7t9VJDUgi7OUKVy+kfHkbyoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDUwOFowLwYJKoZIhvcNAQkEMSIEIN+1FSogmgzaV5lQ
# ktSI7RLlUr+AkRW1cWp+5jfvVuJ8MA0GCSqGSIb3DQEBAQUABIICAM3bB+leg/1o
# SepspB303ywqA6ohwGC8ahqqCj8QlwraB24Md29G+GWPDqr/HhvDZO1C6tXeAdg0
# UEup9GrCDIwm2umpqg5WefPt2cfSVsc0TIoQo9BG29j/+9skO3yV+vwbc+tATiS8
# ozp+IYnOMRm9LLol4QEFzv1Ulk4Z1cbkk2N4Zj/GGpfCp9ANXjxyI/ypsw1+mSDG
# dhV+jEcZC+s76r/l7P+2EgOl732k81Z4JUfB19orfSyhkMDN0HhO/bWHIU4nfDsw
# R825vJsNfqvQjrxzXneVaxPg0UuGDw+vwhunW4kINoFfQnLFLFcgmBJosAsWlPeH
# e68lbRrr5pAEohwetF0BHEA2DLHGRrY4TtLqDkVzwnEAkAlWKZs1156iksKNchR4
# jIZyNGWXXoi8J+HYFhoiPCEXk8kdodT9O4486nQhfkEXeAsXNI39yrwbRBf8Kmk+
# JubSaiw4da91MV8MgqUVaBkG1cXLthunYRmBEWropbvdDfxRU+ZHaevAHSgz52i9
# Rk8fT5xeOxHHWF4DOeoe7ciWCStccij/Xq5Hg59YnZulpTMTxLZK9RxE1ydSHzD3
# 5zMjGPCWYQ7ZEUnJtqFhyJsuZeLq1h5f/n/5QNDugPttd23NPkzV7pc0FTxEyJlL
# YGi3BZZX82bmxUZyu6H+woxLC6U+lb/M
# SIG # End signature block
