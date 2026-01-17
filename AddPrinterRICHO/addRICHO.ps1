<#
.SYNOPSIS
  RICOH network printer auto-installer (full rebuild):
  - Downloads driver files individually from GitHub raw (parallel via BITS)
  - FORCEFULLY removes printers, ports, drivers (and optionally driver-store packages)
  - Installs driver from oemsetup.inf
  - Creates LPR port with byte counting
  - Adds printer

.AUTHOR
  Shourav (rhshourav)

.VERSION
  1.5.0

.NOTES
  - Windows PowerShell 5.1 compatible
  - WARNING:
    * If you enable force cleanup, it will remove ANY printer using the target port(s).
    * Driver store purge can remove other packages if you choose broad matching.
#>

[CmdletBinding()]
param(
  # Driver source
  [string]$BaseRawUrl      = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/main/RPrint_driver",
  [string]$LocalDriverDir  = "C:\Drivers\RPrint_driver",

  # Printer settings
  [string]$PrinterIP       = "192.168.18.245",
  [string]$PrinterName     = "RICHO",

  # You have used BOTH styles; keep both for forced cleanup.
  [string]$PortName        = "IP_192.168.18.245",
  [string]$AltPortName     = "192.168.18.245",

  [string]$LprQueue        = "lp",

  # REQUIRED for deterministic installs (no guessing)
  [Parameter(Mandatory=$true)]
  [string]$DriverName,

  # Optional additional drivers to remove during cleanup (exact names)
  [string[]]$RemoveDriverNames = @(),

  # Parallel downloads
  [ValidateRange(1,24)]
  [int]$DownloadThreads    = 8,

  # Cleanup behavior
  [switch]$ForceFullCleanup,

  # Also attempt to purge printer driver packages from Driver Store (pnputil) for the specified driver names.
  [switch]$PurgeDriverStore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- DRIVER FILE LIST ----------
$DriverFiles = @(
  "mfricr64.dl_",
  "oemsetup.dsc",
  "oemsetup.inf",
  "rd067d64.dl_",
  "rica67.cat",
  "rica67cb.dl_",
  "rica67cd.dl_",
  "rica67cd.psz",
  "rica67cf.cfz",
  "rica67ch.chm",
  "rica67ci.dl_",
  "rica67cj.dl_",
  "rica67cl.ini",
  "rica67ct.dl_",
  "rica67cz.dlz",
  "rica67gl.dl_",
  "rica67gr.dl_",
  "rica67lm.dl_",
  "rica67tl.ex_",
  "rica67ug.dl_",
  "rica67ug.miz",
  "rica67ui.dl_",
  "rica67ui.irj",
  "rica67ui.rcf",
  "rica67ui.rdj",
  "rica67ur.dl_",
  "ricdb64.dl_"
)

# ---------- BANNER ----------
function Show-Banner {
  param([string]$Title,[string]$Version,[string]$Author)
  $line = ("=" * 70)
  Write-Host $line -ForegroundColor DarkCyan
  Write-Host ("  {0}" -f $Title) -ForegroundColor Cyan
  Write-Host ("  Version: {0}    Author: {1}" -f $Version, $Author) -ForegroundColor DarkGray
  Write-Host $line -ForegroundColor DarkCyan
}

# ---------- LOG ----------
function Log {
  param([string]$Message, [ValidateSet("Info","Warn","Error")] [string]$Level="Info")
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $prefix = "[$ts]"
  if ($Level -eq "Info")  { Write-Host "$prefix $Message" }
  if ($Level -eq "Warn")  { Write-Host "$prefix $Message" -ForegroundColor Yellow }
  if ($Level -eq "Error") { Write-Host "$prefix $Message" -ForegroundColor Red }
}

# ---------- INLINE PROGRESS ----------
$script:LastBarText = ""
$script:BarLine = $null

function New-BarLine { Write-Host ""; $script:BarLine = [Console]::CursorTop - 1 }

function Render-Bar {
  param(
    [ValidateRange(0,100)][int]$Percent,
    [string]$Phase,
    [string]$Detail = "",
    [ValidateSet("Good","Warn","Fail")] [string]$Mood = "Good"
  )
  $width  = 28
  $filled = [int]([Math]::Round(($Percent/100) * $width))
  if ($filled -gt $width) { $filled = $width }
  if ($filled -lt 0) { $filled = 0 }

  $bar = ("#" * $filled) + ("-" * ($width - $filled))
  if ($Detail.Length -gt 60) { $Detail = $Detail.Substring(0,57) + "..." }
  $text = ("[{0}] {1,3}%  {2,-12} {3}" -f $bar, $Percent, $Phase, $Detail).TrimEnd()
  if ($text -eq $script:LastBarText) { return }
  $script:LastBarText = $text

  $fg = "Green"
  if ($Mood -eq "Warn") { $fg = "Yellow" }
  if ($Mood -eq "Fail") { $fg = "Red" }

  $curLeft = [Console]::CursorLeft
  $curTop  = [Console]::CursorTop

  [Console]::SetCursorPosition(0, $script:BarLine)
  Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
  [Console]::SetCursorPosition(0, $script:BarLine)
  Write-Host $text -ForegroundColor $fg -NoNewline

  [Console]::SetCursorPosition($curLeft, $curTop)
}

function Finish-Bar {
  param([string]$Final="Completed",[ValidateSet("Good","Fail")] [string]$Mood="Good")
  $finalMood = "Good"; if ($Mood -eq "Fail") { $finalMood = "Fail" }
  Render-Bar -Percent 100 -Phase "Complete" -Detail $Final -Mood $finalMood
  Write-Host ""
}

# ---------- RETRY ----------
function Retry {
  param(
    [scriptblock]$Action,
    [int]$Times = 6,
    [int]$DelaySeconds = 2,
    [string]$What = "operation"
  )
  for ($i = 1; $i -le $Times; $i++) {
    try { return & $Action }
    catch {
      if ($i -eq $Times) { throw }
      Log ("Retry {0}/{1} failed for {2}: {3}" -f $i, $Times, $What, $_.Exception.Message) -Level "Warn"
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

# ---------- ADMIN CHECK ----------
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script as Administrator."
  }
}

# ---------- SPOOLER HARD RESET ----------
function Stop-SpoolerHard {
  try { Stop-Service Spooler -Force -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Seconds 2
  Get-Process spoolsv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}
function Start-Spooler { Start-Service Spooler -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
function Clear-SpoolFiles {
  $dir = Join-Path $env:WINDIR "System32\spool\PRINTERS"
  if (Test-Path $dir) {
    Get-ChildItem $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

# ---------- PRINTER / PORT / DRIVER CLEANUP ----------
function Remove-PrinterByNameIfExists {
  param([string]$Name)
  $p = Get-Printer -Name $Name -ErrorAction SilentlyContinue
  if ($p) {
    Log "Removing printer: $Name" -Level "Warn"
    Retry -What ("Remove-Printer {0}" -f $Name) -Action { Remove-Printer -Name $Name -ErrorAction Stop }
  }
}

function Remove-PrintersUsingPort {
  param([string]$Port)
  $printers = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -eq $Port })
  if ($printers.Count -gt 0) {
    Log ("Found {0} printer(s) using port '{1}'. Removing them..." -f $printers.Count, $Port) -Level "Warn"
    foreach ($p in $printers) {
      Log ("Removing printer bound to port: {0}" -f $p.Name) -Level "Warn"
      Retry -What ("Remove-Printer {0}" -f $p.Name) -Action { Remove-Printer -Name $p.Name -ErrorAction Stop }
    }
  }
}

function Remove-PortForce {
  param([string]$Name)
  $port = Get-PrinterPort -Name $Name -ErrorAction SilentlyContinue
  if ($port) {
    Log "Removing port: $Name" -Level "Warn"

    Remove-PrintersUsingPort -Port $Name

    Stop-SpoolerHard
    Clear-SpoolFiles
    Start-Spooler

    Retry -What ("Remove-PrinterPort {0}" -f $Name) -Action { Remove-PrinterPort -Name $Name -ErrorAction Stop }
  }
}

function Remove-PrinterDriverIfExists {
  param([string]$Name)
  $drv = Get-PrinterDriver -Name $Name -ErrorAction SilentlyContinue
  if ($drv) {
    Log "Removing printer driver: $Name" -Level "Warn"
    Retry -What ("Remove-PrinterDriver {0}" -f $Name) -Action { Remove-PrinterDriver -Name $Name -ErrorAction Stop }
  }
}

# Best-effort Driver Store purge: find oem*.inf entries that look like printer drivers and contain keywords.
function Get-PnpUtilDriverTable {
  $raw = cmd.exe /c "pnputil /enum-drivers"
  $lines = $raw | Out-String | Select-String -Pattern "Published Name|Original Name|Provider Name|Class Name|Driver Package Provider" -AllMatches
  # Parse blocks in a simple way: split by blank line in the original output
  $text = ($raw | Out-String)
  $blocks = $text -split "(\r?\n){2,}"
  $items = @()

  foreach ($b in $blocks) {
    if ($b -notmatch "Published Name") { continue }
    $pub = ($b | Select-String -Pattern "Published Name\s*:\s*(.+)" -AllMatches).Matches.Value
    $pubName = $null
    if ($b -match "Published Name\s*:\s*(.+)") { $pubName = $Matches[1].Trim() }

    $provider = $null
    if ($b -match "Driver Package Provider\s*:\s*(.+)") { $provider = $Matches[1].Trim() }
    elseif ($b -match "Provider Name\s*:\s*(.+)") { $provider = $Matches[1].Trim() }

    $class = $null
    if ($b -match "Class Name\s*:\s*(.+)") { $class = $Matches[1].Trim() }

    $orig = $null
    if ($b -match "Original Name\s*:\s*(.+)") { $orig = $Matches[1].Trim() }

    if ($pubName) {
      $items += [pscustomobject]@{
        PublishedName = $pubName
        Provider      = $provider
        ClassName     = $class
        OriginalName  = $orig
        Block         = $b
      }
    }
  }
  return $items
}

function Purge-DriverStoreForNames {
  param([string[]]$Names)

  $targets = @($Names | Where-Object { $_ -and $_.Trim().Length -gt 0 })
  if ($targets.Count -eq 0) { return }

  Log "Driver Store purge enabled. Enumerating driver store..." -Level "Warn"
  $tbl = @(Get-PnpUtilDriverTable)

  foreach ($n in $targets) {
    # heuristic: match PublishedName entries where provider mentions RICOH or block contains the driver name string
    $matches = @(
      $tbl | Where-Object {
        ($_.ClassName -eq "Printer") -and (
          ($_.Provider -match "RICOH") -or
          ($_.Block -match [regex]::Escape($n))
        )
      }
    )

    if ($matches.Count -eq 0) {
      Log "No driver-store entries matched for: $n (skipping)" -Level "Warn"
      continue
    }

    foreach ($m in $matches) {
      Log ("Purging driver store package: {0} (Provider={1}, Original={2})" -f $m.PublishedName, $m.Provider, $m.OriginalName) -Level "Warn"
      # Best-effort. /force is used because you explicitly asked "forcefully".
      try {
        cmd.exe /c ("pnputil /delete-driver {0} /uninstall /force" -f $m.PublishedName) | Out-Null
      } catch {
        Log ("pnputil purge failed for {0}: {1}" -f $m.PublishedName, $_.Exception.Message) -Level "Warn"
      }
    }
  }
}

# ---------- BITS DOWNLOAD (PARALLEL) ----------
function Ensure-Bits {
  $svc = Get-Service -Name BITS -ErrorAction SilentlyContinue
  if (-not $svc) { throw "BITS service not found." }
  if ($svc.Status -ne "Running") { Start-Service BITS -ErrorAction SilentlyContinue; Start-Sleep 1 }
}

function Get-RicohBitsJobs { param([string]$Prefix) Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like ($Prefix + "*") } }
function Remove-RicohBitsJobs { param([string]$Prefix) foreach ($j in @(Get-RicohBitsJobs -Prefix $Prefix)) { try { Remove-BitsTransfer -BitsJob $j -Confirm:$false -ErrorAction SilentlyContinue } catch {} } }

function Download-DriverFilesParallel {
  param([string]$BaseUrl,[string]$DestDir,[string[]]$Files,[int]$Threads)

  Ensure-Bits
  New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

  $prefix = "RicohDrv-" + ([Guid]::NewGuid().ToString("N")) + "-"
  $total = $Files.Count

  for ($i=0; $i -lt $Files.Count; $i += $Threads) {
    $batch = $Files[$i..([Math]::Min($i+$Threads-1, $Files.Count-1))]

    foreach ($f in $batch) {
      $src  = $BaseUrl + "/" + $f
      $dest = Join-Path $DestDir $f

      if (Test-Path $dest) {
        $fi = Get-Item $dest -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 0) { continue }
      }

      Start-BitsTransfer -Source $src -Destination $dest -Asynchronous -DisplayName ($prefix + $f) -ErrorAction Stop | Out-Null
    }

    while ($true) {
      $jobs = @()
      foreach ($f in $batch) {
        $j = (Get-RicohBitsJobs -Prefix ($prefix + $f) | Select-Object -First 1)
        if ($j) { $jobs += $j }
      }

      $err = @($jobs | Where-Object JobState -eq "Error")
      if ($err.Count -gt 0) {
        foreach ($e in $err) {
          $msg = $e.ErrorDescription
          try { Remove-BitsTransfer -BitsJob $e -Confirm:$false -ErrorAction SilentlyContinue } catch {}
          throw "BITS download failed: $msg"
        }
      }

      foreach ($t in @($jobs | Where-Object JobState -eq "Transferred")) {
        Complete-BitsTransfer -BitsJob $t -ErrorAction SilentlyContinue
      }

      $done = 0
      foreach ($f in $Files) {
        $path = Join-Path $DestDir $f
        if (Test-Path $path) {
          $fi = Get-Item $path -ErrorAction SilentlyContinue
          if ($fi -and $fi.Length -gt 0) { $done++ }
        }
      }

      $pct = if ($total -gt 0) { [int](($done / $total) * 100) } else { 100 }
      $overall = [Math]::Min(35, [int]([Math]::Round(($pct/100) * 35)))
      Render-Bar -Percent $overall -Phase "Download" -Detail ("{0}/{1}" -f $done, $total) -Mood "Good"

      $active = @($jobs | Where-Object { $_.JobState -in @("Queued","Connecting","Transferring") })
      if ($active.Count -eq 0) { break }

      Start-Sleep -Milliseconds 300
    }
  }

  foreach ($f in $Files) {
    $dest = Join-Path $DestDir $f
    if (!(Test-Path $dest)) { throw "Missing downloaded file: $f" }
    $fi = Get-Item $dest -ErrorAction SilentlyContinue
    if (-not $fi -or $fi.Length -le 0) { throw "Downloaded file is empty: $f" }
  }

  Remove-RicohBitsJobs -Prefix $prefix
}

# -------------------- MAIN --------------------
Show-Banner -Title "RICOH Network Printer Auto-Installer (Full Rebuild)" -Version "1.5.0" -Author "Shourav (rhshourav)"
New-BarLine

try {
  Assert-Admin

  Render-Bar -Percent 1 -Phase "Init" -Detail "Starting" -Mood "Good"
  Log "Starting installer v1.5.0"
  Log ("Target: IP={0}, PrinterName={1}, Port={2}, AltPort={3}, Queue={4}" -f $PrinterIP, $PrinterName, $PortName, $AltPortName, $LprQueue)
  Log "DriverName (install): $DriverName"
  if ($RemoveDriverNames.Count -gt 0) { Log ("Additional drivers to remove: {0}" -f ($RemoveDriverNames -join ", ")) -Level "Warn" }
  Log ("ForceFullCleanup={0}, PurgeDriverStore={1}" -f $ForceFullCleanup.IsPresent, $PurgeDriverStore.IsPresent) -Level "Warn"

  # Phase 1: Download
  Render-Bar -Percent 5 -Phase "Init" -Detail "Preparing downloads" -Mood "Good"
  Download-DriverFilesParallel -BaseUrl $BaseRawUrl -DestDir $LocalDriverDir -Files $DriverFiles -Threads $DownloadThreads
  Render-Bar -Percent 35 -Phase "Download" -Detail "Done" -Mood "Good"

  # Phase 2: FORCE CLEANUP
  Render-Bar -Percent 40 -Phase "Cleanup" -Detail "Reset spooler" -Mood "Warn"
  Stop-SpoolerHard
  Clear-SpoolFiles
  Start-Spooler

  Render-Bar -Percent 45 -Phase "Cleanup" -Detail "Remove printers" -Mood "Warn"
  # Always remove the target name
  Remove-PrinterByNameIfExists -Name $PrinterName

  if ($ForceFullCleanup) {
    # Also remove any printers using either port name
    Remove-PrintersUsingPort -Port $PortName
    if ($AltPortName -and $AltPortName -ne $PortName) {
      Remove-PrintersUsingPort -Port $AltPortName
    }
  }

  Render-Bar -Percent 52 -Phase "Cleanup" -Detail "Reset spooler" -Mood "Warn"
  Stop-SpoolerHard
  Clear-SpoolFiles
  Start-Spooler

  Render-Bar -Percent 58 -Phase "Cleanup" -Detail "Remove ports" -Mood "Warn"
  # Remove ports if present; if not, fine
  try { Remove-PortForce -Name $PortName } catch { Log ("Port remove failed (will continue): {0}" -f $_.Exception.Message) -Level "Warn" }
  if ($AltPortName -and $AltPortName -ne $PortName) {
    try { Remove-PortForce -Name $AltPortName } catch { Log ("Alt port remove failed (will continue): {0}" -f $_.Exception.Message) -Level "Warn" }
  }

  Render-Bar -Percent 62 -Phase "Cleanup" -Detail "Remove drivers" -Mood "Warn"
  # Remove requested old drivers + the install driver (if you truly want full rebuild)
  $driversToRemove = @()
  $driversToRemove += $DriverName
  $driversToRemove += $RemoveDriverNames
  $driversToRemove = @($driversToRemove | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique)

  foreach ($dn in $driversToRemove) {
    try { Remove-PrinterDriverIfExists -Name $dn } catch { Log ("Driver remove failed (may be in use): {0}" -f $_.Exception.Message) -Level "Warn" }
  }

  if ($PurgeDriverStore) {
    Render-Bar -Percent 66 -Phase "Cleanup" -Detail "Purge driver store" -Mood "Warn"
    Purge-DriverStoreForNames -Names $driversToRemove
  }

  Render-Bar -Percent 70 -Phase "Cleanup" -Detail "Done" -Mood "Good"

  # Phase 3: Install driver
  Render-Bar -Percent 74 -Phase "Driver" -Detail "pnputil install" -Mood "Good"
  $infPath = Join-Path $LocalDriverDir "oemsetup.inf"
  if (!(Test-Path $infPath)) { throw "oemsetup.inf not found in $LocalDriverDir" }

  Retry -What "pnputil /add-driver" -Action {
    cmd.exe /c ("pnputil /add-driver `"{0}`" /install" -f $infPath) | Out-Null
  }
  Start-Sleep -Seconds 2
  Render-Bar -Percent 80 -Phase "Driver" -Detail "Installed" -Mood "Good"

  # Phase 4: Create port
  Render-Bar -Percent 86 -Phase "Port" -Detail "Creating LPR port" -Mood "Good"
  Retry -What "Add-PrinterPort" -Action {
    Add-PrinterPort -Name $PortName -LprHostAddress $PrinterIP -LprQueueName $LprQueue -LprByteCounting
  }

  # Phase 5: Add printer
  Render-Bar -Percent 92 -Phase "Printer" -Detail "Adding printer" -Mood "Good"
  Retry -What "Add-Printer" -Action {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
  }

  # Verify
  Render-Bar -Percent 98 -Phase "Verify" -Detail "Checking" -Mood "Good"
  $p = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
  if (!$p) { throw "Install failed: printer not found after creation." }

  Finish-Bar -Final "Completed" -Mood "Good"
  Log ("SUCCESS: Installed '{0}' (Driver={1}, Port={2}, IP={3})" -f $p.Name, $p.DriverName, $p.PortName, $PrinterIP)

} catch {
  Finish-Bar -Final "Failed" -Mood "Fail"
  Log ("FAILED: {0}" -f $_.Exception.Message) -Level "Error"
  throw
}
