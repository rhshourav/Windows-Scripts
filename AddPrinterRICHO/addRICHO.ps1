<#
.SYNOPSIS
  RICOH Network Printer Auto-Installer (ZIP driver source) - Hardened for 0x00000704

.AUTHOR
  Shourav (rhshourav)

.VERSION
  1.8.1

.DESCRIPTION
  Fixes:
  - Uses standard TCP/IP port name: IP_<ip>
  - Verifies ports via Win32_TCPIPPrinterPort (CIM/WMI) instead of parsing prnport output
  - prnport.vbs calls fail loud with exit code + stderr
  - Wait loop after creating port to avoid spooler race
#>

[CmdletBinding()]
param(
  [string]$ZipUrl = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/RPrint_driver/r_print_driver.zip",
  [string]$LocalDriverDir = "C:\Drivers\RPrint_driver",

  [string]$PrinterName = "RICHO",

  [string]$PrinterIP = "192.168.18.245",
  [string]$LprQueue  = "secure",

  # IMPORTANT: Use standard port naming
  [string]$PortName    = "",

  [string]$DriverName  = "RICOH MP 2555 PCL 6",

  [switch]$ForceFullCleanup,
  [switch]$RemoveDriver
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------- UI / LOG ----------------
function Show-Banner {
  param([string]$Title,[string]$Version,[string]$Author)
  $line = ("=" * 70)
  Write-Host $line -ForegroundColor DarkCyan
  Write-Host ("  {0}" -f $Title) -ForegroundColor Cyan
  Write-Host ("  Version: {0}    Author: {1}" -f $Version, $Author) -ForegroundColor DarkGray
  Write-Host $line -ForegroundColor DarkCyan
}

function Log {
  param([string]$Message, [ValidateSet("Info","Warn","Error")] [string]$Level="Info")
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $prefix = "[$ts]"
  if ($Level -eq "Info")  { Write-Host "$prefix $Message" }
  if ($Level -eq "Warn")  { Write-Host "$prefix $Message" -ForegroundColor Yellow }
  if ($Level -eq "Error") { Write-Host "$prefix $Message" -ForegroundColor Red }
}

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

# ---------------- SYSTEM ----------------
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script as Administrator."
  }
}

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

# ---------------- PRINTUI ----------------
function PrintUI-DeletePrinter {
  param([string]$Name)
  cmd.exe /c ("rundll32 printui.dll,PrintUIEntry /dl /n `"{0}`" /q" -f $Name) | Out-Null
}

function PrintUI-DeleteDriver {
  param([string]$ModelName)
  cmd.exe /c ("rundll32 printui.dll,PrintUIEntry /dd /m `"{0}`" /q" -f $ModelName) | Out-Null
}

function PrintUI-InstallDriverFromInf {
  param([string]$InfPath, [string]$ModelName)
  cmd.exe /c ("rundll32 printui.dll,PrintUIEntry /ia /m `"{0}`" /f `"{1}`"" -f $ModelName, $InfPath) | Out-Null
}

function PrintUI-InstallPrinter {
  param([string]$PrinterName,[string]$PortName,[string]$DriverName,[string]$InfPath)
  cmd.exe /c ("rundll32 printui.dll,PrintUIEntry /if /b `"{0}`" /r `"{1}`" /m `"{2}`" /f `"{3}`"" -f $PrinterName,$PortName,$DriverName,$InfPath) | Out-Null
}

# ---------------- PRNPORT + PORT VERIFY (HARDENED) ----------------
function Get-PrnPortVbs {
  $candidates = @(
    (Join-Path $env:WINDIR "System32\Printing_Admin_Scripts\en-US\prnport.vbs"),
    (Join-Path $env:WINDIR "System32\Printing_Admin_Scripts\prnport.vbs")
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  throw "prnport.vbs not found on this system."
}

function Port-Exists {
  param([string]$Name)
  try {
    $filter = "Name='{0}'" -f $Name.Replace("'","''")
    $p = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter $filter -ErrorAction Stop
    return [bool]$p
  } catch {
    return $false
  }
}

function Ensure-LprPort {
  param(
    [string]$PortName,
    [string]$IP,
    [string]$Queue
  )

  $vbs = Get-PrnPortVbs

  # Prefer explicit double-spool enable switch (-2e). If this build doesn't support it,
  # we retry without the -2* flag.
  $cmd1 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue -2e"
  $out1 = cmd.exe /c $cmd1 2>&1

  if ($LASTEXITCODE -eq 0) { return }

  # Retry without -2e (some variants are picky)
  $cmd2 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue"
  $out2 = cmd.exe /c $cmd2 2>&1

  if ($LASTEXITCODE -ne 0) {
    throw "prnport.vbs failed.`nAttempt1: $cmd1`n$out1`nAttempt2: $cmd2`n$out2"
  }
}


function Delete-PortBestEffort {
  param([string]$PortName)
  $vbs = Get-PrnPortVbs
  $cmd = "cscript //nologo `"$vbs`" -d -s localhost -r `"$PortName`""
  $null = cmd.exe /c $cmd 2>&1
}


function Wait-Port {
  param([string]$Name,[int]$Seconds = 15)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while (-not (Port-Exists -Name $Name)) {
    if (Get-Date -gt $deadline) { return $false }
    Start-Sleep -Milliseconds 500
  }
  return $true
}

# ---------------- ZIP DOWNLOAD + EXTRACT ----------------
function Ensure-Bits {
  $svc = Get-Service -Name BITS -ErrorAction SilentlyContinue
  if (-not $svc) { throw "BITS service not found." }
  if ($svc.Status -ne "Running") { Start-Service BITS -ErrorAction SilentlyContinue; Start-Sleep 1 }
}

function Download-ZipWithBits {
  param([string]$Url,[string]$OutFile)

  Ensure-Bits
  if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

  $job = Start-BitsTransfer -Source $Url -Destination $OutFile -Asynchronous -DisplayName "RicohDrvZip" -ErrorAction Stop

  while ($true) {
    if ($job.JobState -eq "Error") {
      $msg = $job.ErrorDescription
      try { Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue } catch {}
      throw "BITS download failed: $msg"
    }

    if ($job.JobState -eq "Transferred") {
      Complete-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
      break
    }

    $pct = 0
    if ($job.BytesTotal -gt 0) {
      $pct = [int](($job.BytesTransferred / $job.BytesTotal) * 100)
    }

    $overall = 5 + [int](($pct/100) * 20)
    Render-Bar -Percent $overall -Phase "Download" -Detail ("{0}%" -f $pct) -Mood "Good"

    Start-Sleep -Milliseconds 200
    $job = Get-BitsTransfer -AllUsers | Where-Object { $_.DisplayName -eq "RicohDrvZip" } | Select-Object -First 1
    if (-not $job) {
      if (Test-Path $OutFile) { break }
      throw "BITS job vanished unexpectedly and ZIP not found."
    }
  }
}

function Extract-DriverZip {
  param([string]$ZipPath,[string]$DestDir)

  New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

  Get-ChildItem -Path $DestDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

  Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force

  $dirs = @(Get-ChildItem -Path $DestDir -Directory -ErrorAction SilentlyContinue)
  if ($dirs.Count -eq 1) {
    $nested = $dirs[0].FullName
    $maybeInf = Join-Path $nested "oemsetup.inf"
    if (Test-Path $maybeInf) {
      Get-ChildItem -Path $nested -Force | Move-Item -Destination $DestDir -Force
      Remove-Item -Path $nested -Recurse -Force
    }
  }

  $inf = Join-Path $DestDir "oemsetup.inf"
  $cat = Join-Path $DestDir "rica67.cat"
  if (!(Test-Path $inf)) { throw "Missing oemsetup.inf after extraction." }
  if (!(Test-Path $cat)) { throw "Missing rica67.cat after extraction." }

  return $inf
}

# ---------------- MAIN ----------------
Show-Banner -Title "RICOH Network Printer Auto-Installer (ZIP Driver Source) - Hardened" -Version "1.8.1" -Author "Shourav (rhshourav)"
New-BarLine

try {
  Assert-Admin

  if ([string]::IsNullOrWhiteSpace($PortName)) {
    $PortName = "IP_{0}" -f $PrinterIP
  }

  Render-Bar -Percent 1 -Phase "Init" -Detail "Starting" -Mood "Good"

  Log ("Target: IP={0}, PrinterName={1}, Port={2}, Queue={3}" -f $PrinterIP,$PrinterName,$PortName,$LprQueue)
  Log ("DriverName: {0}" -f $DriverName)
  Log ("ZIP: {0}" -f $ZipUrl)
  Log ("Local driver dir: {0}" -f $LocalDriverDir)
  Log ("ForceFullCleanup={0}, RemoveDriver={1}" -f $ForceFullCleanup.IsPresent, $RemoveDriver.IsPresent) -Level "Warn"

  Render-Bar -Percent 5 -Phase "Download" -Detail "Starting" -Mood "Good"
  $zipPath = Join-Path $env:TEMP "r_print_driver.zip"
  Download-ZipWithBits -Url $ZipUrl -OutFile $zipPath

  Render-Bar -Percent 25 -Phase "Extract" -Detail "Unpacking" -Mood "Good"
  try { Unblock-File -Path $zipPath -ErrorAction SilentlyContinue } catch {}
  $infPath = Extract-DriverZip -ZipPath $zipPath -DestDir $LocalDriverDir
  Render-Bar -Percent 35 -Phase "Extract" -Detail "Done" -Mood "Good"

  Render-Bar -Percent 40 -Phase "Cleanup" -Detail "Reset spooler" -Mood "Warn"
  Stop-SpoolerHard; Clear-SpoolFiles; Start-Spooler

  Render-Bar -Percent 48 -Phase "Cleanup" -Detail ("Remove {0} (if exists)" -f $PrinterName) -Mood "Warn"
  PrintUI-DeletePrinter -Name $PrinterName

  if ($ForceFullCleanup) {
    Render-Bar -Percent 55 -Phase "Cleanup" -Detail "Remove ports (best-effort)" -Mood "Warn"
    try { Delete-PortBestEffort -PortName $PortName } catch {}
  }

  if ($RemoveDriver) {
    Render-Bar -Percent 58 -Phase "Cleanup" -Detail "Remove driver (best-effort)" -Mood "Warn"
    try { PrintUI-DeleteDriver -ModelName $DriverName } catch {}
  }

  Render-Bar -Percent 60 -Phase "Cleanup" -Detail "Done" -Mood "Good"

  Render-Bar -Percent 72 -Phase "Driver" -Detail "Register driver" -Mood "Good"
  PrintUI-InstallDriverFromInf -InfPath $infPath -ModelName $DriverName

  Render-Bar -Percent 85 -Phase "Port" -Detail "Create LPR port" -Mood "Good"

  # Delete stale then create
  try { Delete-PortBestEffort -PortName $PortName } catch {}
  Ensure-LprPort -PortName $PortName -IP $PrinterIP -Queue $LprQueue

  # Wait until spooler registers it
  if (-not (Wait-Port -Name $PortName -Seconds 15)) {
    # Provide quick diagnostics
    $ports = Get-CimInstance Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue |
      Select-Object -First 30 Name,HostAddress,Protocol,PortNumber
    throw "LPR port '$PortName' was not registered in time. Existing ports sample: $($ports | Out-String)"
  }

  Render-Bar -Percent 95 -Phase "Printer" -Detail "Install printer" -Mood "Good"
  PrintUI-InstallPrinter -PrinterName $PrinterName -PortName $PortName -DriverName $DriverName -InfPath $infPath

  Finish-Bar -Final "Completed" -Mood "Good"
  Log ("SUCCESS: Installed '{0}' using '{1}' on port '{2}'" -f $PrinterName,$DriverName,$PortName)

} catch {
  Finish-Bar -Final "Failed" -Mood "Fail"
  Log ("FAILED: {0}" -f $_.Exception.Message) -Level "Error"
  throw
}
