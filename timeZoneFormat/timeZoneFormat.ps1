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
  1.3.0
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

  $peers = "time.windows.com,0x9 pool.ntp.org,0x9"
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
Write-Head "Dhaka TZ + Sync + ALL-Users Formats (Formats First) | v1.3.0 | rhshourav"

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
