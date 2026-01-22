<#
.SYNOPSIS
  RICOH Color Printer Auto-Installer (ZIP driver source) - Hardened

.AUTHOR
  Shourav (rhshourav)

.VERSION
  1.0.0

.DESCRIPTION
  - Downloads driver ZIP from GitHub raw URL
  - Extracts to local driver directory
  - Installs/registers driver via PrintUIEntry (/ia)
  - Creates LPR TCP/IP port via prnport.vbs (correct -2e usage)
  - Verifies port via Win32_TCPIPPrinterPort (CIM)
  - Installs printer via PrintUIEntry (/if)
  - Avoids Get-Printer / Add-Printer cmdlets
#>

[CmdletBinding()]
param(
  # ZIP source (raw)
  [string]$ZipUrl = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/RPrint_driver/SCP2000_PCL.zip",

  # Local cache/extract dir
  [string]$LocalDriverDir = "C:\Drivers\SCP2000_PCL",

  # Target printer name
  [string]$PrinterName = "Secure-Color-Printer",

  # Target IP + LPR queue
  [string]$PrinterIP = "192.168.18.245",
  [string]$LprQueue  = "secure",

  # Port config (standard naming)
  [string]$PortName = "LPR_192.168.18.245",

  # Driver model name MUST match INF model string exactly
  [string]$DriverName  = "RICOH IM C2000 PCL 6",

  # Cleanup behavior
  [switch]$ForceFullCleanup,

  # Best-effort: attempt to remove the driver name too (can fail if in use)
  [switch]$RemoveDriver
)
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

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

# ---------------- PRNPORT + PORT VERIFY ----------------
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
  } catch { return $false }
}

function Delete-PortBestEffort {
  param([string]$PortName)
  $vbs = Get-PrnPortVbs
  $cmd = "cscript //nologo `"$vbs`" -d -s localhost -r `"$PortName`""
  $null = cmd.exe /c $cmd 2>&1
}

function Ensure-LprPort {
  param([string]$PortName,[string]$IP,[string]$Queue)

  $vbs = Get-PrnPortVbs

  # Attempt with -2e (enable double spool), retry without it if this build is picky
  $cmd1 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue -2e"
  $out1 = cmd.exe /c $cmd1 2>&1
  if ($LASTEXITCODE -eq 0) { return }

  $cmd2 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue"
  $out2 = cmd.exe /c $cmd2 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "prnport.vbs failed.`nAttempt1: $cmd1`n$out1`nAttempt2: $cmd2`n$out2"
  }
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

function Test-IsZipFile {
  param([string]$Path)
  try {
    if (-not (Test-Path $Path)) { return $false }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      if ($fs.Length -lt 4) { return $false }
      $b = New-Object byte[] 2
      $null = $fs.Read($b, 0, 2)
      # ZIP files start with "PK" (0x50 0x4B)
      return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)
    } finally {
      $fs.Dispose()
    }
  } catch { return $false }
}

function Download-ZipWithBits {
  param([string]$Url,[string]$OutFile)

  $parent = Split-Path -Parent $OutFile
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

  if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

  $bitsOk = $false
  try {
    Ensure-Bits
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
      Start-Sleep -Milliseconds 200
      $job = Get-BitsTransfer -AllUsers | Where-Object { $_.DisplayName -eq "RicohDrvZip" } | Select-Object -First 1
      if (-not $job) { break }
    }

    if (Test-Path $OutFile) { $bitsOk = $true }
  } catch {
    $bitsOk = $false
  }

  if (-not $bitsOk) {
    Log "BITS did not produce a ZIP file. Falling back to Invoke-WebRequest..." -Level "Warn"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
  }

  if (-not (Test-Path $OutFile)) {
    throw "Download failed: ZIP file not found at '$OutFile'."
  }

  $len = (Get-Item $OutFile).Length
  if ($len -lt 1024) {
    throw "Downloaded file is too small ($len bytes). Likely blocked or HTML error."
  }

  if (-not (Test-IsZipFile -Path $OutFile)) {
    throw "Downloaded file is not a valid ZIP (missing PK header)."
  }
}

function Extract-DriverZip {
  param([string]$ZipPath,[string]$DestDir)

  New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

  Get-ChildItem -Path $DestDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

  Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force

  # Try to locate an INF; prefer oemsetup.inf if present
  $inf = Join-Path $DestDir "oemsetup.inf"
  if (!(Test-Path $inf)) {
    $found = Get-ChildItem -Path $DestDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw "No .inf found after extraction." }
    $inf = $found.FullName
  }

  return $inf
}

# ---------------- MAIN ----------------
Show-Banner -Title "RICOH Color Printer Auto-Installer (ZIP Driver Source) - Hardened" -Version "1.0.0" -Author "Shourav (rhshourav)"
New-BarLine

try {
  Assert-Admin

  if ([string]::IsNullOrWhiteSpace($PortName)) {
  $PortName = "LPR_{0}" -f $PrinterIP
}

  Render-Bar -Percent 1 -Phase "Init" -Detail "Starting" -Mood "Good"

  Log ("Target: IP={0}, PrinterName={1}, Port={2}, Queue={3}" -f $PrinterIP,$PrinterName,$PortName,$LprQueue)
  Log ("DriverName: {0}" -f $DriverName)
  Log ("ZIP: {0}" -f $ZipUrl)
  Log ("Local driver dir: {0}" -f $LocalDriverDir)
  Log ("ForceFullCleanup={0}, RemoveDriver={1}" -f $ForceFullCleanup.IsPresent, $RemoveDriver.IsPresent) -Level "Warn"

  # Download
  Render-Bar -Percent 5 -Phase "Download" -Detail "Starting" -Mood "Good"
  $zipPath = Join-Path $env:TEMP "SCP2000_PCL.zip"
  Download-ZipWithBits -Url $ZipUrl -OutFile $zipPath

  # Extract
  Render-Bar -Percent 25 -Phase "Extract" -Detail "Unpacking" -Mood "Good"
  try { Unblock-File -Path $zipPath -ErrorAction SilentlyContinue } catch {}
  $infPath = Extract-DriverZip -ZipPath $zipPath -DestDir $LocalDriverDir
  Render-Bar -Percent 35 -Phase "Extract" -Detail "Done" -Mood "Good"

  # Cleanup / reset spooler
  Render-Bar -Percent 40 -Phase "Cleanup" -Detail "Reset spooler" -Mood "Warn"
  Stop-SpoolerHard; Clear-SpoolFiles; Start-Spooler

  # Remove printer (safe even if missing)
  Render-Bar -Percent 48 -Phase "Cleanup" -Detail ("Remove {0} (if exists)" -f $PrinterName) -Mood "Warn"
  PrintUI-DeletePrinter -Name $PrinterName

  # Remove port (best-effort)
  if ($ForceFullCleanup) {
    Render-Bar -Percent 55 -Phase "Cleanup" -Detail "Remove port (best-effort)" -Mood "Warn"
    try { Delete-PortBestEffort -PortName $PortName } catch {}
  }

  # Remove driver (best-effort)
  if ($RemoveDriver) {
    Render-Bar -Percent 58 -Phase "Cleanup" -Detail "Remove driver (best-effort)" -Mood "Warn"
    try { PrintUI-DeleteDriver -ModelName $DriverName } catch {}
  }

  Render-Bar -Percent 60 -Phase "Cleanup" -Detail "Done" -Mood "Good"

  # Register driver
  Render-Bar -Percent 72 -Phase "Driver" -Detail "Register driver" -Mood "Good"
  PrintUI-InstallDriverFromInf -InfPath $infPath -ModelName $DriverName

  # Create port
  Render-Bar -Percent 85 -Phase "Port" -Detail "Create LPR port" -Mood "Good"
  try { Delete-PortBestEffort -PortName $PortName } catch {}
  Ensure-LprPort -PortName $PortName -IP $PrinterIP -Queue $LprQueue

  if (-not (Wait-Port -Name $PortName -Seconds 20)) {
    throw "LPR port '$PortName' was not registered in time. Aborting to avoid error 0x00000704."
  }

  # Install printer
  Render-Bar -Percent 95 -Phase "Printer" -Detail "Install printer" -Mood "Good"
  PrintUI-InstallPrinter -PrinterName $PrinterName -PortName $PortName -DriverName $DriverName -InfPath $infPath

  Finish-Bar -Final "Completed" -Mood "Good"
  Log ("SUCCESS: Installed '{0}' using '{1}' on port '{2}'" -f $PrinterName,$DriverName,$PortName)

} catch {
  Finish-Bar -Final "Failed" -Mood "Fail"
  Log ("FAILED: {0}" -f $_.Exception.Message) -Level "Error"
  throw
}
