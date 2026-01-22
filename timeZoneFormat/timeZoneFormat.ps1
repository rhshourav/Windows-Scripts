<#
.SYNOPSIS
  Force set Windows time zone to Dhaka, force time sync, validate vs Dhaka time,
  and apply chosen date/time display formats to ALL users (existing + future).

.DESCRIPTION
  - Sets time zone to "Bangladesh Standard Time" (Dhaka)
  - Forces w32time service and resync (best-effort; domain policy may override)
  - Validates local time vs computed Dhaka time within threshold
  - Prompts once for date + time format and applies to:
      * All loaded user hives (HKEY_USERS\<SID>)
      * All profile hives by loading each NTUSER.DAT (unloaded users)
      * C:\Users\Default\NTUSER.DAT (future users)
      * HKEY_USERS\.DEFAULT (system/logon context)

.AUTHOR
  Shourav (rhshourav)
.GITHUB
  https://github.com/rhshourav
.VERSION
  1.1.0
#>

[CmdletBinding()]
param(
  [int]$MaxAllowedDriftSeconds = 5,
  [switch]$SkipFormatPrompt
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
    "-NoProfile"
    "-ExecutionPolicy", "Bypass"
    "-File", "`"$PSCommandPath`""
    "-MaxAllowedDriftSeconds", $MaxAllowedDriftSeconds
  )
  if ($SkipFormatPrompt) { $argList += "-SkipFormatPrompt" }
  Start-Process powershell -Verb RunAs -ArgumentList $argList
  exit
}

# -----------------------------
# Core constants
# -----------------------------
$DhakaWindowsTzId = "Bangladesh Standard Time"

function Get-DhakaNow {
  $tz = [TimeZoneInfo]::FindSystemTimeZoneById($DhakaWindowsTzId)
  [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
}

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

function Force-TimeSync {
  Write-Info "Ensuring Windows Time service (w32time) is enabled and running..."
  try { Set-Service -Name w32time -StartupType Automatic } catch { }

  $svc = Get-Service -Name w32time -ErrorAction Stop
  if ($svc.Status -ne "Running") { Start-Service -Name w32time }

  # Best-effort peers; domain may override and that's normal.
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

  Write-Info "Forcing time resync..."
  $resyncOut = ""
  try { $resyncOut = (& w32tm /resync /force 2>&1 | Out-String).Trim() } catch { $resyncOut = $_.Exception.Message }

  $statusOut = ""
  try { $statusOut = (& w32tm /query /status 2>&1 | Out-String).Trim() } catch { }

  @{ ResyncOutput = $resyncOut; StatusOutput = $statusOut }
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
# Format (ALL users) helpers
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
  # HiveRoot examples:
  #  - Registry::HKEY_USERS\S-1-5-21-...\Control Panel\International
  #  - Registry::HKEY_USERS\.DEFAULT\Control Panel\International
  $intlPath = Join-Path $HiveRoot "Control Panel\International"

  if (-not (Test-Path $intlPath)) {
    # Some system hives may not have it yet; create if needed
    try { New-Item -Path $intlPath -Force | Out-Null } catch { return $false }
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

  # Return changes for reporting
  return $changes
}

function Load-UserHive([string]$NtUserDatPath, [string]$MountName) {
  # MountName will appear under HKU\<MountName>
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
  # Long date: keep it readable and consistent
  $LongDate = "dddd, dd MMMM yyyy"

  $applied = New-Object System.Collections.Generic.List[string]
  $failed  = New-Object System.Collections.Generic.List[string]

  # 1) Apply to all already-loaded user hives
  Write-Info "Applying formats to loaded user hives..."
  $loadedSids = Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -match 'HKEY_USERS\\S-1-5-21-' -and $_.Name -notmatch '_Classes$'
    } |
    ForEach-Object { ($_).PSChildName }

  foreach ($sid in $loadedSids) {
    try {
      $root = "Registry::HKEY_USERS\$sid"
      $changes = Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt
      $applied.Add("$sid (loaded)") | Out-Null
    } catch {
      $failed.Add("$sid (loaded): $($_.Exception.Message)") | Out-Null
    }
  }

  # 2) Apply to .DEFAULT (system/logon context)
  Write-Info "Applying formats to HKEY_USERS\.DEFAULT..."
  try {
    $root = "Registry::HKEY_USERS\.DEFAULT"
    [void](Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt)
    $applied.Add(".DEFAULT") | Out-Null
  } catch {
    $failed.Add(".DEFAULT: $($_.Exception.Message)") | Out-Null
  }

  # 3) Apply to Default user profile (future users): C:\Users\Default\NTUSER.DAT
  $defaultNtUser = Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT"
  if (Test-Path $defaultNtUser) {
    Write-Info "Applying formats to Default profile (future users)..."
    $mountName = "TEMP_DEFAULT_PROFILE"
    try {
      # Load, apply, unload
      Load-UserHive -NtUserDatPath $defaultNtUser -MountName $mountName
      $root = "Registry::HKEY_USERS\$mountName"
      [void](Set-IntlInHive -HiveRoot $root -ShortDate $ShortDate -LongDate $LongDate -TimeFmt $TimeFmt)
      Unload-UserHive -MountName $mountName
      $applied.Add("DefaultProfile (C:\Users\Default)") | Out-Null
    } catch {
      # Attempt unload if partially loaded
      try { Unload-UserHive -MountName $mountName } catch { }
      $failed.Add("DefaultProfile: $($_.Exception.Message)") | Out-Null
    }
  } else {
    $failed.Add("DefaultProfile: NTUSER.DAT not found at $defaultNtUser") | Out-Null
  }

  # 4) Apply to ALL user profiles by loading their NTUSER.DAT (for users not currently logged in)
  Write-Info "Applying formats to all user profiles (loading NTUSER.DAT where needed)..."
  $profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
  $profiles = Get-ChildItem $profileList -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' }

  foreach ($p in $profiles) {
    $sid = $p.PSChildName
    try {
      # If already loaded, we already did it. Skip.
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
      # Try unload if something went wrong mid-way
      try {
        if ($mountName) { Unload-UserHive -MountName $mountName }
      } catch { }
      $failed.Add("$sid (offline hive): $($_.Exception.Message)") | Out-Null
    }
  }

  return @{
    Applied = $applied
    Failed  = $failed
    ShortDate = $ShortDate
    LongDate  = $LongDate
    TimeFmt   = $TimeFmt
  }
}

# -----------------------------
# Run
# -----------------------------
Write-Head "Dhaka Time Zone + Forced Time Sync + ALL-Users Formats | v1.1.0 | rhshourav"

$tzResult = Ensure-TimeZoneDhaka

$syncResult = Force-TimeSync
if ($syncResult.ResyncOutput) {
  if ($syncResult.ResyncOutput -match "completed|success|sent|resync") {
    Write-OK "Resync output: $($syncResult.ResyncOutput)"
  } else {
    Write-Warn "Resync output: $($syncResult.ResyncOutput)"
  }
}

$match = Test-DhakaTimeMatch -ThresholdSeconds $MaxAllowedDriftSeconds
Write-Info ("Local time : {0:yyyy-MM-dd HH:mm:ss.fff}" -f $match.LocalNow)
Write-Info ("Dhaka time : {0:yyyy-MM-dd HH:mm:ss.fff}" -f $match.DhakaNow)
if ($match.IsMatch) {
  Write-OK ("Time matches Dhaka within {0}s (drift: {1}s)." -f $match.Threshold, $match.DriftSeconds)
} else {
  Write-Warn ("Time does NOT match Dhaka within {0}s (drift: {1}s). Domain policy or blocked NTP can prevent correction." -f $match.Threshold, $match.DriftSeconds)
}

$formatsResult = $null
if (-not $SkipFormatPrompt) {
  # Get current formats from current user as "Current" reference
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

  $newShortDate = Prompt-Choice -Title "Select Short Date format (will apply to ALL users)" -Options $dateOptions -CurrentValue $curShort
  $newTimeFmt   = Prompt-Choice -Title "Select Time format (will apply to ALL users)"       -Options $timeOptions -CurrentValue $curTime

  if ($newShortDate -or $newTimeFmt) {
    # If user keeps one, preserve current for that one (fallback to a safe default if null)
    if (-not $newShortDate) { $newShortDate = $(if ($curShort) { $curShort } else { "dd-MM-yyyy" }) }
    if (-not $newTimeFmt)   { $newTimeFmt   = $(if ($curTime)  { $curTime }  else { "HH:mm:ss" }) }

    Write-Info "Applying chosen formats to ALL users..."
    $formatsResult = Apply-FormatsAllUsers -ShortDate $newShortDate -TimeFmt $newTimeFmt

    Write-OK "Formats applied. Note: users may need to sign out/in for some apps to reflect changes."
  } else {
    Write-Info "No format changes selected."
  }
} else {
  Write-Info "Format prompt skipped."
}

Write-Head "Summary"
Write-Host ("Time zone: {0} -> {1}" -f $tzResult.Before, $tzResult.After) -ForegroundColor Gray
Write-Host ("Drift vs Dhaka: {0}s (threshold {1}s) => {2}" -f $match.DriftSeconds, $match.Threshold, $(if ($match.IsMatch) {"OK"} else {"WARN"})) -ForegroundColor Gray

if ($formatsResult) {
  Write-Host ("Formats: ShortDate={0} | LongDate={1} | TimeFormat={2}" -f $formatsResult.ShortDate, $formatsResult.LongDate, $formatsResult.TimeFmt) -ForegroundColor Gray
  Write-Host ("Applied to: {0}" -f $formatsResult.Applied.Count) -ForegroundColor Gray
  if ($formatsResult.Failed.Count -gt 0) {
    Write-Warn ("Failed: {0}" -f $formatsResult.Failed.Count)
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
