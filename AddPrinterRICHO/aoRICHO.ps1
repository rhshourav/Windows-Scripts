<#
.SYNOPSIS
  RICOH Printer Suite - Combined Auto-Installer (B&W + Color)

.AUTHOR
  Shourav (rhshourav)
  GitHub: https://github.com/rhshourav/Windows-Scripts

.VERSION
  2.0.0

.DESCRIPTION
  Combined auto-installer for RICOH B&W and Color network printers.
    [1] RICOH MP 2555 PCL 6      -> "RICHO"               (B&W)
    [2] RICOH IM C2000 PCL 6     -> "Secure-Color-Printer" (Color)
    [3] Both printers at once

  - Downloads driver ZIPs from GitHub (raw)
  - Extracts locally, registers driver, creates LPR port, installs printer
  - Full fallback download chain: BITS -> IWR -> curl.exe -> certutil
  - Hardened against 0x00000704 (port race), Set-StrictMode Latest
  - No Add-Printer / Get-Printer cmdlets (max PS version compat)
  - All temp files cleaned up after install

.USAGE
  Run as Administrator:
    iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/RICOH-Printer-Suite.ps1')
  Or locally:
    .\RICOH-Printer-Suite.ps1
#>

[CmdletBinding()]
param(
  # --- B&W Printer ---
  [string]$BwZipUrl         = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/RPrint_driver/r_print_driver.zip",
  [string]$BwLocalDir       = "C:\Drivers\RPrint_driver",
  [string]$BwPrinterName    = "RICHO",
  [string]$BwDriverName     = "RICOH MP 2555 PCL 6",
  [string]$BwPortName       = "IP_192.168.18.245",

  # --- Color Printer ---
  [string]$ColorZipUrl      = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/RPrint_driver/SCP2000_PCL.zip",
  [string]$ColorLocalDir    = "C:\Drivers\SCP2000_PCL",
  [string]$ColorPrinterName = "Secure-Color-Printer",
  [string]$ColorDriverName  = "RICOH IM C2000 PCL 6",
  [string]$ColorPortName    = "LPR_192.168.18.245",

  # --- Shared ---
  [string]$PrinterIP        = "192.168.18.245",
  [string]$LprQueue         = "secure",

  [switch]$ForceFullCleanup,
  [switch]$RemoveDriver,

  # Skip interactive menu - pass 1=BW, 2=Color, 3=Both
  [int]$InstallChoice       = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
#  CONSOLE SETUP
# ============================================================
try {
  $raw = $Host.UI.RawUI
  $raw.BackgroundColor = 'Black'
  $raw.ForegroundColor = 'White'
  Clear-Host
} catch {}
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
        text  = "RICHO All In One V2.0.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

# ============================================================
#  LOGO + BANNER
# ============================================================
function Show-Logo {
  $w = 72
  $top    = "+" + ("=" * ($w - 2)) + "+"
  $mid    = "|" + (" " * ($w - 2)) + "|"
  $cyan   = 'Cyan'
  $dcyan  = 'DarkCyan'

  Write-Host $top -ForegroundColor $dcyan
  Write-Host $mid -ForegroundColor $dcyan
  Write-Host "|   ____  ___ ____ ___  _  _    ____  _   _ ___ _____ _____      |" -ForegroundColor $cyan
  Write-Host "|  |  _ \|_ _/ ___/ _ \| || |  / ___|| | | |_ _|_   _| ____|     |" -ForegroundColor $cyan
  Write-Host "|  |    /  | | |  | | | | || |  \___ \| | | || |  | | |  _|       |" -ForegroundColor $cyan
  Write-Host "|  |_|\_\ |_|\___\___/|_||_|   ___) || |_| || |  | | | |___      |" -ForegroundColor $cyan
  Write-Host "|         PRINTER  AUTO-INSTALLER  SUITE  |____/ \___/|___| |_|   |____||" -ForegroundColor $cyan
  Write-Host $mid -ForegroundColor $dcyan
  Write-Host "|         Network Printer Auto-Installer Suite  v2.0.0              |" -ForegroundColor 'White'
  Write-Host "|         Author: Shourav (rhshourav)                               |" -ForegroundColor DarkGray
  Write-Host "|         https://github.com/rhshourav/Windows-Scripts              |" -ForegroundColor DarkGray
  Write-Host $mid -ForegroundColor $dcyan
  Write-Host $top -ForegroundColor $dcyan
  Write-Host ""
}

function Show-Logo {
  $L = 'DarkCyan'; $C = 'Cyan'; $W = 'White'; $G = 'DarkGray'
  $bar = "+" + ("=" * 70) + "+"
  Write-Host $bar -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host ("  ____  ___ ____ ___  _  _    ____  _   _ ___ ____  _____     " + "   ") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (" |  _ \|_ _/ ___/ _ \| || |  / ___|| | | |_ _|_  _||  ___|    " + "   ") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (" |    /  | || |  | | || || |  \___ \| | | || |  ||  |  _|      " + "   ") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (" |_|\_\ |_| \___\___/|_||_|   ___) || |_| || |  ||  | |___    " + "   ") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host ("            PRINTER AUTO-INSTALLER SUITE  |____/ \___/|___| |__|" + "   ") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host ("" + (" " * 70)) -NoNewline -ForegroundColor $L
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host ("  Network Printer Auto-Installer Suite  v2.0.0" + (" " * 25)) -NoNewline -ForegroundColor $W
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host ("  Author : Shourav (rhshourav)" + (" " * 42)) -NoNewline -ForegroundColor $G
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host ("  GitHub : https://github.com/rhshourav/Windows-Scripts" + (" " * 18)) -NoNewline -ForegroundColor $G
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (" " * 70) -NoNewline
  Write-Host "|" -ForegroundColor $L
  Write-Host $bar -ForegroundColor $L
  Write-Host ""
}

# ============================================================
#  LOGGING
# ============================================================
function Log {
  param(
    [string]$Message,
    [ValidateSet("Info","Warn","Error")] [string]$Level = "Info"
  )
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $prefix = "[$ts]"
  switch ($Level) {
    "Info"  { Write-Host "$prefix $Message" -ForegroundColor White }
    "Warn"  { Write-Host "$prefix $Message" -ForegroundColor Yellow }
    "Error" { Write-Host "$prefix $Message" -ForegroundColor Red }
  }
}

function Write-Section {
  param([string]$Text)
  $line = "-" * 70
  Write-Host ""
  Write-Host $line -ForegroundColor DarkCyan
  Write-Host ("  >> " + $Text) -ForegroundColor Cyan
  Write-Host $line -ForegroundColor DarkCyan
}

# ============================================================
#  PROGRESS BAR
# ============================================================
$script:LastBarText = ""
$script:BarLine     = $null

function New-BarLine {
  Write-Host ""
  $script:BarLine     = [Console]::CursorTop - 1
  $script:LastBarText = ""
}

function Render-Bar {
  param(
    [ValidateRange(0,100)][int]$Percent,
    [string]$Phase,
    [string]$Detail = "",
    [ValidateSet("Good","Warn","Fail")] [string]$Mood = "Good"
  )
  $width  = 28
  $filled = [int]([Math]::Round(($Percent / 100) * $width))
  if ($filled -gt $width) { $filled = $width }
  if ($filled -lt 0)      { $filled = 0 }

  $bar  = ("#" * $filled) + ("-" * ($width - $filled))
  if ($Detail.Length -gt 55) { $Detail = $Detail.Substring(0, 52) + "..." }
  $text = ("[{0}] {1,3}%  {2,-12} {3}" -f $bar, $Percent, $Phase, $Detail).TrimEnd()
  if ($text -eq $script:LastBarText) { return }
  $script:LastBarText = $text

  $fg = switch ($Mood) { "Warn" { "Yellow" } "Fail" { "Red" } default { "Green" } }

  $savedLeft = [Console]::CursorLeft
  $savedTop  = [Console]::CursorTop

  [Console]::SetCursorPosition(0, $script:BarLine)
  Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
  [Console]::SetCursorPosition(0, $script:BarLine)
  Write-Host $text -ForegroundColor $fg -NoNewline

  [Console]::SetCursorPosition($savedLeft, $savedTop)
}

function Finish-Bar {
  param(
    [string]$Final = "Completed",
    [ValidateSet("Good","Fail")] [string]$Mood = "Good"
  )
  Render-Bar -Percent 100 -Phase "Complete" -Detail $Final -Mood $Mood
  Write-Host ""
}

# ============================================================
#  SYSTEM / ADMIN
# ============================================================
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
  }
}

function Stop-SpoolerHard {
  try { Stop-Service Spooler -Force -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Seconds 2
  Get-Process spoolsv -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

function Start-Spooler {
  try {
    $svc = Get-Service Spooler -ErrorAction Stop
    if ($svc.Status -ne "Running") {
      Start-Service Spooler -ErrorAction SilentlyContinue
    }
  } catch {
    throw "Print Spooler cannot be started: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 2
}

function Clear-SpoolFiles {
  $dir = Join-Path $env:WINDIR "System32\spool\PRINTERS"
  if (Test-Path $dir) {
    Get-ChildItem $dir -Force -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

# ============================================================
#  PRINTUI WRAPPERS
# ============================================================
function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory)][string]$CommandLine,
    [string]$FailMessage = "Native command failed."
  )
  $out  = cmd.exe /c "$CommandLine" 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "$FailMessage`nCmd: $CommandLine`nCode: $code`nOut:`n$out"
  }
  return $out
}

function PrintUI-DeletePrinter {
  param([string]$Name)
  $null = cmd.exe /c "rundll32 printui.dll,PrintUIEntry /dl /n `"$Name`" /q" 2>&1
}

function PrintUI-DeleteDriver {
  param([string]$ModelName)
  $null = cmd.exe /c "rundll32 printui.dll,PrintUIEntry /dd /m `"$ModelName`" /q" 2>&1
}

function PrintUI-InstallDriverFromInf {
  param([string]$InfPath, [string]$ModelName)
  Invoke-NativeChecked `
    -CommandLine "rundll32 printui.dll,PrintUIEntry /ia /m `"$ModelName`" /f `"$InfPath`"" `
    -FailMessage "Driver install via PrintUIEntry failed."
}

function PrintUI-InstallPrinter {
  param(
    [string]$PrinterName,
    [string]$PortName,
    [string]$DriverName,
    [string]$InfPath
  )
  Invoke-NativeChecked `
    -CommandLine "rundll32 printui.dll,PrintUIEntry /if /b `"$PrinterName`" /r `"$PortName`" /m `"$DriverName`" /f `"$InfPath`"" `
    -FailMessage "Printer install via PrintUIEntry failed."
}

# ============================================================
#  PORT MANAGEMENT
# ============================================================
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
    $filter = "Name='{0}'" -f $Name.Replace("'", "''")
    $p = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter $filter -ErrorAction Stop
    return [bool]$p
  } catch {
    return $false
  }
}

function Delete-PortBestEffort {
  param([string]$PortName)
  try {
    $vbs = Get-PrnPortVbs
    $null = cmd.exe /c "cscript //nologo `"$vbs`" -d -s localhost -r `"$PortName`"" 2>&1
  } catch {}
}

function Ensure-LprPort {
  param(
    [string]$PortName,
    [string]$IP,
    [string]$Queue
  )
  $vbs  = Get-PrnPortVbs

  # Attempt 1: with -2e (double-spool)
  $cmd1 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue -2e"
  $out1 = cmd.exe /c $cmd1 2>&1
  if ($LASTEXITCODE -eq 0) { return }

  # Attempt 2: without -2e
  $cmd2 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue"
  $out2 = cmd.exe /c $cmd2 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "prnport.vbs failed.`nAttempt 1: $cmd1`n$out1`nAttempt 2: $cmd2`n$out2"
  }
}

function Wait-Port {
  # BUG FIX: "Get-Date -gt $deadline" causes:
  #   "A parameter cannot be found that matches parameter name 'gt'"
  # because PowerShell parses -gt as a param of Get-Date.
  # FIX: wrap Get-Date in parens -> (Get-Date) -gt $deadline
  param([string]$Name, [int]$Seconds = 20)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while (-not (Port-Exists -Name $Name)) {
    if ((Get-Date) -gt $deadline) { return $false }   # <-- FIXED
    Start-Sleep -Milliseconds 500
  }
  return $true
}

# ============================================================
#  DOWNLOAD (HARDENED: BITS -> IWR -> curl.exe -> certutil)
# ============================================================
function Set-TlsDefaults {
  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.SecurityProtocolType]::Tls12 -bor
      [Net.SecurityProtocolType]::Tls11 -bor
      [Net.SecurityProtocolType]::Tls
  } catch {}
}

function Assert-DownloadedFile {
  param([string]$Path, [int64]$MinBytes = 10240)
  if (-not (Test-Path $Path)) { throw "Download: file not found at $Path" }
  $len = (Get-Item $Path -ErrorAction Stop).Length
  if ($len -lt $MinBytes) { throw "Download: file too small ($len bytes) at $Path" }
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
      return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)   # "PK"
    } finally { $fs.Dispose() }
  } catch { return $false }
}

function Download-FileHardened {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [int]$ProgressBase = 5,
    [int]$ProgressSpan = 20
  )
  Set-TlsDefaults
  $parent = Split-Path -Parent $OutFile
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

  $errors = [System.Collections.Generic.List[string]]::new()

  # --- Method 1: BITS ---
  try {
    $bitsSvc = Get-Service -Name BITS -ErrorAction SilentlyContinue
    if ($bitsSvc) {
      if ($bitsSvc.Status -ne "Running") {
        try { Start-Service BITS -ErrorAction SilentlyContinue } catch {}
      }
      Render-Bar -Percent $ProgressBase -Phase "Download" -Detail "BITS" -Mood "Good"
      Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
      if ((Test-Path $OutFile) -and (Test-IsZipFile -Path $OutFile)) {
        Assert-DownloadedFile -Path $OutFile
        return
      }
      $errors.Add("BITS completed but file invalid.")
      if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
    } else {
      $errors.Add("BITS service not present.")
    }
  } catch {
    $errors.Add("BITS: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
  }

  # --- Method 2: Invoke-WebRequest ---
  try {
    Render-Bar -Percent ($ProgressBase + [int]($ProgressSpan * 0.33)) -Phase "Download" -Detail "IWR" -Mood "Warn"
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellDownloader/2.0"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers @{"User-Agent" = $ua} -UseBasicParsing -ErrorAction Stop
    Assert-DownloadedFile -Path $OutFile
    return
  } catch {
    $errors.Add("IWR: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
  }

  # --- Method 3: curl.exe ---
  try {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
      Render-Bar -Percent ($ProgressBase + [int]($ProgressSpan * 0.66)) -Phase "Download" -Detail "curl.exe" -Mood "Warn"
      $curlArgs = @("-L","--retry","3","--retry-delay","1","--connect-timeout","20","-o",$OutFile,$Url)
      $proc = Start-Process -FilePath $curl.Source -ArgumentList $curlArgs -Wait -PassThru -NoNewWindow
      if ($proc.ExitCode -ne 0) { throw "curl.exe exit: $($proc.ExitCode)" }
      Assert-DownloadedFile -Path $OutFile
      return
    } else { $errors.Add("curl.exe not found.") }
  } catch {
    $errors.Add("curl.exe: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
  }

  # --- Method 4: certutil ---
  try {
    $cert = Get-Command certutil.exe -ErrorAction SilentlyContinue
    if ($cert) {
      Render-Bar -Percent ($ProgressBase + $ProgressSpan) -Phase "Download" -Detail "certutil" -Mood "Warn"
      $proc = Start-Process -FilePath $cert.Source -ArgumentList @("-urlcache","-split","-f",$Url,$OutFile) -Wait -PassThru -NoNewWindow
      if ($proc.ExitCode -ne 0) { throw "certutil exit: $($proc.ExitCode)" }
      Assert-DownloadedFile -Path $OutFile
      return
    } else { $errors.Add("certutil.exe not found.") }
  } catch {
    $errors.Add("certutil: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
  }

  throw "All download methods failed.`n  - " + ($errors -join "`n  - ")
}

# ============================================================
#  ZIP EXTRACT
# ============================================================
function Extract-DriverZip {
  param([string]$ZipPath, [string]$DestDir, [string]$RequiredCat = "")
  New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
  Get-ChildItem -Path $DestDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

  Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force

  # Flatten single nested folder
  $dirs = @(Get-ChildItem -Path $DestDir -Directory -ErrorAction SilentlyContinue)
  if ($dirs.Count -eq 1) {
    $nested = $dirs[0].FullName
    $maybeInf = Join-Path $nested "oemsetup.inf"
    if (Test-Path $maybeInf) {
      Get-ChildItem -Path $nested -Force | Move-Item -Destination $DestDir -Force
      Remove-Item -Path $nested -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  # Locate INF
  $inf = Join-Path $DestDir "oemsetup.inf"
  if (!(Test-Path $inf)) {
    $found = Get-ChildItem -Path $DestDir -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if (-not $found) { throw "No .inf file found after extraction in '$DestDir'." }
    $inf = $found.FullName
  }

  # Validate required CAT if specified
  if ($RequiredCat -ne "" -and !(Test-Path (Join-Path $DestDir $RequiredCat))) {
    Log "Warning: expected catalog file '$RequiredCat' not found. Continuing..." -Level "Warn"
  }

  return $inf
}

# ============================================================
#  VERIFY
# ============================================================
function Test-PrinterInstalled {
  param([string]$Name)
  try {
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
      return [bool](Get-Printer -Name $Name -ErrorAction SilentlyContinue)
    }
    $filter = "Name='{0}'" -f $Name.Replace("'","''")
    return [bool](Get-CimInstance -ClassName Win32_Printer -Filter $filter -ErrorAction SilentlyContinue)
  } catch { return $false }
}

# ============================================================
#  CLEANUP LEFTOVER FILES
# ============================================================
function Remove-TempFiles {
  param([string[]]$Paths)
  foreach ($p in $Paths) {
    try {
      if (Test-Path $p) { Remove-Item $p -Force -Recurse -ErrorAction SilentlyContinue }
    } catch {}
  }
}

# ============================================================
#  CORE INSTALL ROUTINE (shared by B&W and Color)
# ============================================================
function Install-RicohPrinter {
  param(
    [string]$Label,
    [string]$ZipUrl,
    [string]$LocalDriverDir,
    [string]$PrinterName,
    [string]$DriverName,
    [string]$PortName,
    [string]$IP,
    [string]$Queue,
    [string]$ZipTempName,
    [string]$RequiredCat = "",
    [bool]  $DoForceCleanup,
    [bool]  $DoRemoveDriver
  )

  Write-Section "Installing $Label"
  New-BarLine

  $zipPath = Join-Path $env:TEMP $ZipTempName
  $tempFiles = @($zipPath)

  try {
    Render-Bar -Percent 1 -Phase "Init" -Detail "Starting" -Mood "Good"

    Log ("Target  : IP={0}, Printer={1}, Port={2}, Queue={3}" -f $IP,$PrinterName,$PortName,$Queue)
    Log ("Driver  : $DriverName")
    Log ("ZIP URL : $ZipUrl")
    Log ("LocalDir: $LocalDriverDir")
    Log ("Cleanup : ForcePort=$DoForceCleanup  RemoveDriver=$DoRemoveDriver") -Level "Warn"

    # ---- Download ----
    Render-Bar -Percent 5 -Phase "Download" -Detail "Starting" -Mood "Good"
    Download-FileHardened -Url $ZipUrl -OutFile $zipPath -ProgressBase 5 -ProgressSpan 20
    Render-Bar -Percent 25 -Phase "Download" -Detail "Done" -Mood "Good"

    # ---- Extract ----
    Render-Bar -Percent 26 -Phase "Extract" -Detail "Unpacking" -Mood "Good"
    try { Unblock-File -Path $zipPath -ErrorAction SilentlyContinue } catch {}
    $infPath = Extract-DriverZip -ZipPath $zipPath -DestDir $LocalDriverDir -RequiredCat $RequiredCat
    Render-Bar -Percent 35 -Phase "Extract" -Detail "Done" -Mood "Good"

    # ---- Reset Spooler ----
    Render-Bar -Percent 40 -Phase "Spooler" -Detail "Stop + Clear" -Mood "Warn"
    Stop-SpoolerHard
    Clear-SpoolFiles
    Start-Spooler
    Render-Bar -Percent 48 -Phase "Spooler" -Detail "Running" -Mood "Good"

    # ---- Remove old printer ----
    Render-Bar -Percent 50 -Phase "Cleanup" -Detail "Remove old printer" -Mood "Warn"
    PrintUI-DeletePrinter -Name $PrinterName

    # ---- Remove port (optional) ----
    if ($DoForceCleanup) {
      Render-Bar -Percent 55 -Phase "Cleanup" -Detail "Remove old port" -Mood "Warn"
      try { Delete-PortBestEffort -PortName $PortName } catch {}
    }

    # ---- Remove driver (optional) ----
    if ($DoRemoveDriver) {
      Render-Bar -Percent 58 -Phase "Cleanup" -Detail "Remove old driver" -Mood "Warn"
      try { PrintUI-DeleteDriver -ModelName $DriverName } catch {}
    }

    Render-Bar -Percent 60 -Phase "Cleanup" -Detail "Done" -Mood "Good"

    # ---- Register driver ----
    Render-Bar -Percent 72 -Phase "Driver" -Detail "Registering" -Mood "Good"
    PrintUI-InstallDriverFromInf -InfPath $infPath -ModelName $DriverName
    Render-Bar -Percent 80 -Phase "Driver" -Detail "Registered" -Mood "Good"

    # ---- Create LPR port ----
    Render-Bar -Percent 82 -Phase "Port" -Detail "Delete stale" -Mood "Warn"
    try { Delete-PortBestEffort -PortName $PortName } catch {}
    Render-Bar -Percent 85 -Phase "Port" -Detail "Create LPR" -Mood "Good"
    Ensure-LprPort -PortName $PortName -IP $IP -Queue $Queue

    Render-Bar -Percent 88 -Phase "Port" -Detail "Waiting for registration" -Mood "Good"
    if (-not (Wait-Port -Name $PortName -Seconds 20)) {
      $sample = Get-CimInstance Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue |
        Select-Object -First 20 Name,HostAddress,Protocol |
        Out-String
      throw "LPR port '$PortName' was not registered within timeout.`nExisting ports:`n$sample"
    }
    Render-Bar -Percent 90 -Phase "Port" -Detail "Ready" -Mood "Good"

    # ---- Install printer ----
    Render-Bar -Percent 95 -Phase "Printer" -Detail "Installing" -Mood "Good"
    PrintUI-InstallPrinter -PrinterName $PrinterName -PortName $PortName -DriverName $DriverName -InfPath $infPath

    if (-not (Test-PrinterInstalled -Name $PrinterName)) {
      throw "PrintUIEntry returned OK but printer '$PrinterName' is not visible in the system."
    }

    Finish-Bar -Final "Completed" -Mood "Good"
    Log ("SUCCESS: '$PrinterName' installed  [Driver: $DriverName | Port: $PortName]") -Level "Info"

    return $true

  } catch {
    Finish-Bar -Final "Failed" -Mood "Fail"
    Log ("FAILED: " + $_.Exception.Message) -Level "Error"
    return $false
  } finally {
    Remove-TempFiles -Paths $tempFiles
  }
}

# ============================================================
#  INTERACTIVE MENU
# ============================================================
function Show-Menu {
  $bar = "+" + ("=" * 50) + "+"
  $mid = "|" + (" " * 50) + "|"

  Write-Host $bar         -ForegroundColor DarkCyan
  Write-Host $mid         -ForegroundColor DarkCyan
  Write-Host "|  Select printer(s) to install:" + (" " * 19) + "|" -ForegroundColor Cyan
  Write-Host $mid         -ForegroundColor DarkCyan
  Write-Host "|  [1]  B&W Printer     (RICOH MP 2555 PCL 6)    |" -ForegroundColor White
  Write-Host "|       Name: RICHO  -  Port: IP_192.168.18.245  |" -ForegroundColor DarkGray
  Write-Host $mid         -ForegroundColor DarkCyan
  Write-Host "|  [2]  Color Printer   (RICOH IM C2000 PCL 6)   |" -ForegroundColor White
  Write-Host "|       Name: Secure-Color-Printer                |" -ForegroundColor DarkGray
  Write-Host $mid         -ForegroundColor DarkCyan
  Write-Host "|  [3]  Install BOTH printers                     |" -ForegroundColor Yellow
  Write-Host $mid         -ForegroundColor DarkCyan
  Write-Host "|  [4]  Exit                                      |" -ForegroundColor Red
  Write-Host $mid         -ForegroundColor DarkCyan
  Write-Host $bar         -ForegroundColor DarkCyan
  Write-Host ""
}

function Read-Choice {
  while ($true) {
    Write-Host "  Your choice [1/2/3/4]: " -NoNewline -ForegroundColor Cyan
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    $ch  = $key.Character.ToString().Trim()
    Write-Host $ch
    if ($ch -in @("1","2","3","4")) { return [int]$ch }
    Write-Host "  [!] Invalid - press 1, 2, 3 or 4." -ForegroundColor Red
  }
}

# ============================================================
#  ENTRY POINT
# ============================================================
Show-Logo

try { Assert-Admin } catch {
  Write-Host ""
  Write-Host "  [!] ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ""
  Write-Host "  Right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "[Done] Press Enter to close ..." -ForegroundColor DarkGray
  $null = Read-Host
  exit 1
}

if ($InstallChoice -eq 0) {
  Show-Menu
  $InstallChoice = Read-Choice
}

Write-Host ""

$doForce  = $ForceFullCleanup.IsPresent
$doRemDrv = $RemoveDriver.IsPresent

$resultBw    = $null
$resultColor = $null

switch ($InstallChoice) {
  1 {
    $resultBw = Install-RicohPrinter `
      -Label          "B&W Printer (RICOH MP 2555)" `
      -ZipUrl         $BwZipUrl `
      -LocalDriverDir $BwLocalDir `
      -PrinterName    $BwPrinterName `
      -DriverName     $BwDriverName `
      -PortName       $BwPortName `
      -IP             $PrinterIP `
      -Queue          $LprQueue `
      -ZipTempName    "r_print_driver.zip" `
      -RequiredCat    "rica67.cat" `
      -DoForceCleanup $doForce `
      -DoRemoveDriver $doRemDrv
  }
  2 {
    $resultColor = Install-RicohPrinter `
      -Label          "Color Printer (RICOH IM C2000)" `
      -ZipUrl         $ColorZipUrl `
      -LocalDriverDir $ColorLocalDir `
      -PrinterName    $ColorPrinterName `
      -DriverName     $ColorDriverName `
      -PortName       $ColorPortName `
      -IP             $PrinterIP `
      -Queue          $LprQueue `
      -ZipTempName    "SCP2000_PCL.zip" `
      -DoForceCleanup $doForce `
      -DoRemoveDriver $doRemDrv
  }
  3 {
    $resultBw = Install-RicohPrinter `
      -Label          "B&W Printer (RICOH MP 2555)" `
      -ZipUrl         $BwZipUrl `
      -LocalDriverDir $BwLocalDir `
      -PrinterName    $BwPrinterName `
      -DriverName     $BwDriverName `
      -PortName       $BwPortName `
      -IP             $PrinterIP `
      -Queue          $LprQueue `
      -ZipTempName    "r_print_driver.zip" `
      -RequiredCat    "rica67.cat" `
      -DoForceCleanup $doForce `
      -DoRemoveDriver $doRemDrv

    $resultColor = Install-RicohPrinter `
      -Label          "Color Printer (RICOH IM C2000)" `
      -ZipUrl         $ColorZipUrl `
      -LocalDriverDir $ColorLocalDir `
      -PrinterName    $ColorPrinterName `
      -DriverName     $ColorDriverName `
      -PortName       $ColorPortName `
      -IP             $PrinterIP `
      -Queue          $LprQueue `
      -ZipTempName    "SCP2000_PCL.zip" `
      -DoForceCleanup $doForce `
      -DoRemoveDriver $doRemDrv
  }
  4 {
    Write-Host "  Exiting. No printers were installed." -ForegroundColor Yellow
    Write-Host ""
    exit 0
  }
}

# ---- Final Summary ----
Write-Host ""
$sumBar = "+" + ("=" * 50) + "+"
Write-Host $sumBar -ForegroundColor DarkCyan
Write-Host "|  INSTALLATION SUMMARY                            |" -ForegroundColor Cyan
Write-Host $sumBar -ForegroundColor DarkCyan

if ($null -ne $resultBw) {
  $bwStatus = if ($resultBw) { "OK" } else { "FAILED" }
  $bwColor  = if ($resultBw) { "Green" } else { "Red" }
  Write-Host ("|  B&W   (RICHO)               : {0,-19}|" -f $bwStatus) -ForegroundColor $bwColor
}
if ($null -ne $resultColor) {
  $cStatus = if ($resultColor) { "OK" } else { "FAILED" }
  $cColor  = if ($resultColor) { "Green" } else { "Red" }
  Write-Host ("|  Color (Secure-Color-Printer) : {0,-19}|" -f $cStatus) -ForegroundColor $cColor
}

Write-Host $sumBar -ForegroundColor DarkCyan
Write-Host ""
Write-Host "[Done] Press Enter to close ..." -ForegroundColor DarkGray
$null = Read-Host
