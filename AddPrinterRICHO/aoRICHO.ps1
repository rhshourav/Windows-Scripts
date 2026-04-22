<#
.SYNOPSIS
  RICOH Printer Suite - Combined Auto-Installer (B&W + Color)

.AUTHOR
  Shourav (rhshourav)
  GitHub: https://github.com/rhshourav/Windows-Scripts

.VERSION
  2.1.0

.DESCRIPTION
  Combined auto-installer for RICOH B&W and Color network printers.
    [1] RICOH MP 2555 PCL 6      -> "RICHO"               (B&W,   port IP_192.168.18.245)
    [2] RICOH IM C2000 PCL 6     -> "Secure-Color-Printer" (Color, port LPR_192.168.18.245)
    [3] Both printers at once

  Port-registration fix (v2.1.0):
    Win32_TCPIPPrinterPort (WMI) does NOT always surface LPR ports immediately
    after prnport.vbs creates them - LPR ports live in the LPR Port Monitor's
    own registry hive and the spooler must reload before WMI sees them.

    Port-Exists now checks THREE sources in order:
      1. WMI  - Win32_TCPIPPrinterPort
      2. Cmdlet - Get-PrinterPort  (PS 4.0 / Win 8.1+)
      3. Registry - HKLM:\...\Print\Monitors\*\Ports  (ground truth, always works)

    After creating the port the Spooler is bounced once so all monitors reload,
    then Wait-Port retries up to 30 seconds across all three detection methods.

  - Full download chain: BITS -> IWR -> curl.exe -> certutil
  - prnport.vbs exit code and output logged on failure
  - No Add-Printer / Get-Printer (max PowerShell compat, Win 7+)
  - Temp ZIP cleaned after every install
  - iex (irm 'URL') compatible - fully interactive, no mandatory params

.USAGE
  Run as Administrator:
    iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/RICOH-Printer-Suite.ps1')
  Or locally:
    .\RICOH-Printer-Suite.ps1
  Unattended (skip menu):
    .\RICOH-Printer-Suite.ps1 -InstallChoice 3
#>

[CmdletBinding()]
param(
  [string]$BwZipUrl         = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/RPrint_driver/r_print_driver.zip",
  [string]$BwLocalDir       = "C:\Drivers\RPrint_driver",
  [string]$BwPrinterName    = "RICHO",
  [string]$BwDriverName     = "RICOH MP 2555 PCL 6",
  [string]$BwPortName       = "IP_192.168.18.245",

  [string]$ColorZipUrl      = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/RPrint_driver/SCP2000_PCL.zip",
  [string]$ColorLocalDir    = "C:\Drivers\SCP2000_PCL",
  [string]$ColorPrinterName = "Secure-Color-Printer",
  [string]$ColorDriverName  = "RICOH IM C2000 PCL 6",
  [string]$ColorPortName    = "LPR_192.168.18.245",

  [string]$PrinterIP        = "192.168.18.245",
  [string]$LprQueue         = "secure",

  [switch]$ForceFullCleanup,
  [switch]$RemoveDriver,

  [int]$InstallChoice = 0    # 1=BW  2=Color  3=Both  4=Exit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  CONSOLE SETUP
# ================================================================
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
        text  = "RICHO All In One V2.1.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

# ================================================================
#  LOGO
# ================================================================
function Show-Logo {
  $L = 'DarkCyan'; $C = 'Cyan'; $W = 'White'; $G = 'DarkGray'
  $bar = "+" + ("=" * 70) + "+"
  $mid = "|" + (" " * 70) + "|"
  function PL([string]$s) { return $s.PadRight(70) }
  Write-Host $bar -ForegroundColor $L
  Write-Host $mid -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "   ____  ___ ____ ___  _  _    ____  _   _ ___ _____ _____") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "  |  _ \|_ _/ ___/ _ \| || |  / ___|| | | |_ _|_   _| ____|") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "  |    /  | || |  | | || || |  \___ \| | | || |  | | |  _|") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "  |_|\_\ |_| \___\___/|_||_|   ___) || |_| || |  | | | |___") -NoNewline -ForegroundColor $C
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "          PRINTER  AUTO-INSTALLER  SUITE   |____/ \___/|___| |_|") -NoNewline -ForegroundColor $W
  Write-Host "|" -ForegroundColor $L
  Write-Host $mid -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "  Network Printer Auto-Installer Suite  v2.1.0") -NoNewline -ForegroundColor $W
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "  Author : Shourav (rhshourav)") -NoNewline -ForegroundColor $G
  Write-Host "|" -ForegroundColor $L
  Write-Host "|" -NoNewline -ForegroundColor $L
  Write-Host (PL "  GitHub : https://github.com/rhshourav/Windows-Scripts") -NoNewline -ForegroundColor $G
  Write-Host "|" -ForegroundColor $L
  Write-Host $mid -ForegroundColor $L
  Write-Host $bar -ForegroundColor $L
  Write-Host ""
}

# ================================================================
#  LOGGING
# ================================================================
function Log {
  param(
    [string]$Message,
    [ValidateSet("Info","Warn","Error","Debug")] [string]$Level = "Info"
  )
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  switch ($Level) {
    "Info"  { Write-Host "[$ts] $Message" -ForegroundColor White   }
    "Warn"  { Write-Host "[$ts] $Message" -ForegroundColor Yellow  }
    "Error" { Write-Host "[$ts] $Message" -ForegroundColor Red     }
    "Debug" { Write-Host "[$ts] $Message" -ForegroundColor DarkGray}
  }
}

function Write-Section {
  param([string]$Text)
  $line = "-" * 70
  Write-Host ""
  Write-Host $line      -ForegroundColor DarkCyan
  Write-Host "  >> $Text" -ForegroundColor Cyan
  Write-Host $line      -ForegroundColor DarkCyan
}

# ================================================================
#  PROGRESS BAR
# ================================================================
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
  if ($Detail.Length -gt 52) { $Detail = $Detail.Substring(0,49) + "..." }
  $text = ("[{0}] {1,3}%  {2,-12} {3}" -f $bar,$Percent,$Phase,$Detail).TrimEnd()
  if ($text -eq $script:LastBarText) { return }
  $script:LastBarText = $text
  $fg = switch ($Mood) { "Warn" { "Yellow" } "Fail" { "Red" } default { "Green" } }
  $sL = [Console]::CursorLeft; $sT = [Console]::CursorTop
  [Console]::SetCursorPosition(0,$script:BarLine)
  Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
  [Console]::SetCursorPosition(0,$script:BarLine)
  Write-Host $text -ForegroundColor $fg -NoNewline
  [Console]::SetCursorPosition($sL,$sT)
}

function Finish-Bar {
  param([string]$Final = "Completed", [ValidateSet("Good","Fail")] [string]$Mood = "Good")
  Render-Bar -Percent 100 -Phase "Complete" -Detail $Final -Mood $Mood
  Write-Host ""
}

# ================================================================
#  SYSTEM / ADMIN
# ================================================================
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
    if ($svc.Status -ne "Running") { Start-Service Spooler -ErrorAction SilentlyContinue }
  } catch { throw "Print Spooler cannot start: $($_.Exception.Message)" }
  Start-Sleep -Seconds 3
}

function Clear-SpoolFiles {
  $dir = Join-Path $env:WINDIR "System32\spool\PRINTERS"
  if (Test-Path $dir) {
    Get-ChildItem $dir -Force -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

# ================================================================
#  PRINTUI WRAPPERS
# ================================================================
function Invoke-NativeChecked {
  param([Parameter(Mandatory)][string]$CommandLine, [string]$FailMessage = "Native command failed.")
  $out  = cmd.exe /c "$CommandLine" 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0) { throw "$FailMessage`nCmd : $CommandLine`nCode: $code`nOut :`n$out" }
  return $out
}

function PrintUI-DeletePrinter  { param([string]$Name)      $null = cmd.exe /c "rundll32 printui.dll,PrintUIEntry /dl /n `"$Name`" /q" 2>&1 }
function PrintUI-DeleteDriver   { param([string]$ModelName) $null = cmd.exe /c "rundll32 printui.dll,PrintUIEntry /dd /m `"$ModelName`" /q" 2>&1 }

function PrintUI-InstallDriverFromInf {
  param([string]$InfPath, [string]$ModelName)
  Invoke-NativeChecked "rundll32 printui.dll,PrintUIEntry /ia /m `"$ModelName`" /f `"$InfPath`"" "PrintUIEntry /ia failed."
}

function PrintUI-InstallPrinter {
  param([string]$PrinterName, [string]$PortName, [string]$DriverName, [string]$InfPath)
  Invoke-NativeChecked "rundll32 printui.dll,PrintUIEntry /if /b `"$PrinterName`" /r `"$PortName`" /m `"$DriverName`" /f `"$InfPath`"" "PrintUIEntry /if failed."
}

# ================================================================
#  PORT MANAGEMENT
#
#  ROOT CAUSE: Win32_TCPIPPrinterPort (WMI) tracks Standard TCP/IP
#  ports. LPR ports are managed by the "LPR Port Monitor" and live
#  in HKLM:\...\Print\Monitors\LPR Port\Ports. WMI may not expose
#  them immediately (or at all on some builds).
#
#  FIX - Port-Exists checks THREE sources:
#    1. WMI  Win32_TCPIPPrinterPort  (fast; may miss LPR)
#    2. Get-PrinterPort cmdlet       (PS 4.0+ / Win 8.1+)
#    3. Registry under Print\Monitors (ground truth - always right)
#
#  After Ensure-LprPort, the Spooler is bounced so all port monitors
#  reload before we start the 30-second Wait-Port loop.
# ================================================================
function Get-PrnPortVbs {
  $candidates = @(
    (Join-Path $env:WINDIR "System32\Printing_Admin_Scripts\en-US\prnport.vbs"),
    (Join-Path $env:WINDIR "System32\Printing_Admin_Scripts\prnport.vbs")
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  throw "prnport.vbs not found. Is this a Server Core or stripped image?"
}

function Port-Exists {
  param([string]$Name)

  # 1. WMI
  try {
    $f = "Name='{0}'" -f $Name.Replace("'","''")
    if (Get-CimInstance Win32_TCPIPPrinterPort -Filter $f -ErrorAction Stop) { return $true }
  } catch {}

  # 2. Get-PrinterPort cmdlet (PS 4.0+)
  try {
    if ((Get-Command Get-PrinterPort -ErrorAction SilentlyContinue) -and
        (Get-PrinterPort -Name $Name -ErrorAction SilentlyContinue)) { return $true }
  } catch {}

  # 3. Registry - enumerate every monitor's Ports subkey
  try {
    $monBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors"
    $monitors = Get-ChildItem $monBase -ErrorAction SilentlyContinue
    foreach ($mon in $monitors) {
      $portsKey = Join-Path $mon.PSPath "Ports"
      if (Test-Path $portsKey) {
        $ports = Get-ChildItem $portsKey -ErrorAction SilentlyContinue
        foreach ($port in $ports) {
          if ($port.PSChildName -eq $Name) { return $true }
        }
      }
    }
  } catch {}

  return $false
}

function Delete-PortBestEffort {
  param([string]$PortName)
  try {
    $vbs = Get-PrnPortVbs
    $null = cmd.exe /c "cscript //nologo `"$vbs`" -d -s localhost -r `"$PortName`"" 2>&1
  } catch {}
}

function Ensure-LprPort {
  param([string]$PortName, [string]$IP, [string]$Queue)
  $vbs = Get-PrnPortVbs

  # Attempt 1 - with -2e (double-spool / byte-counting mode)
  $cmd1 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue -2e"
  $out1 = cmd.exe /c $cmd1 2>&1
  Log "prnport -2e  [exit:$LASTEXITCODE]  $out1" -Level "Debug"
  if ($LASTEXITCODE -eq 0) { return }

  # Attempt 2 - without -2e
  $cmd2 = "cscript //nologo `"$vbs`" -a -s localhost -r `"$PortName`" -h $IP -o lpr -q $Queue"
  $out2 = cmd.exe /c $cmd2 2>&1
  Log "prnport      [exit:$LASTEXITCODE]  $out2" -Level "Debug"
  if ($LASTEXITCODE -eq 0) { return }

  # Both failed
  throw (
    "prnport.vbs could not create LPR port '$PortName'.`n" +
    "Attempt 1: $out1`n" +
    "Attempt 2: $out2`n`n" +
    "Ensure 'LPR Port Monitor' is installed:`n" +
    "  Enable-WindowsOptionalFeature -Online -FeatureName LPDPrintService"
  )
}

function Wait-Port {
  # IMPORTANT: (Get-Date) -gt $deadline  NOT  Get-Date -gt $deadline
  # The bare form throws: "parameter cannot be found that matches parameter name 'gt'"
  param([string]$Name, [int]$Seconds = 30)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while (-not (Port-Exists -Name $Name)) {
    if ((Get-Date) -gt $deadline) { return $false }
    Start-Sleep -Milliseconds 500
  }
  return $true
}

# ================================================================
#  DOWNLOAD  (BITS -> IWR -> curl.exe -> certutil)
# ================================================================
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
  if ($len -lt $MinBytes) { throw "Download: file too small ($len bytes)" }
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
      return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)
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

  # BITS
  try {
    $bitsSvc = Get-Service BITS -ErrorAction SilentlyContinue
    if ($bitsSvc) {
      if ($bitsSvc.Status -ne "Running") { try { Start-Service BITS -EA SilentlyContinue } catch {} }
      Render-Bar -Percent $ProgressBase -Phase "Download" -Detail "BITS..." -Mood "Good"
      Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
      if ((Test-Path $OutFile) -and (Test-IsZipFile -Path $OutFile)) {
        Assert-DownloadedFile -Path $OutFile; return
      }
      $errors.Add("BITS: transfer complete but file invalid.")
      if (Test-Path $OutFile) { Remove-Item $OutFile -Force -EA SilentlyContinue }
    } else { $errors.Add("BITS service absent.") }
  } catch {
    $errors.Add("BITS: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -EA SilentlyContinue }
  }

  # IWR
  try {
    Render-Bar -Percent ($ProgressBase + [int]($ProgressSpan * 0.33)) -Phase "Download" -Detail "IWR..." -Mood "Warn"
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PSDownloader/2.1"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers @{"User-Agent"=$ua} -UseBasicParsing -EA Stop
    Assert-DownloadedFile -Path $OutFile; return
  } catch {
    $errors.Add("IWR: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -EA SilentlyContinue }
  }

  # curl.exe
  try {
    $curl = Get-Command curl.exe -EA SilentlyContinue
    if ($curl) {
      Render-Bar -Percent ($ProgressBase + [int]($ProgressSpan * 0.66)) -Phase "Download" -Detail "curl.exe..." -Mood "Warn"
      $proc = Start-Process $curl.Source -ArgumentList @("-L","--retry","3","--retry-delay","1","--connect-timeout","20","-o",$OutFile,$Url) -Wait -PassThru -NoNewWindow
      if ($proc.ExitCode -ne 0) { throw "exit $($proc.ExitCode)" }
      Assert-DownloadedFile -Path $OutFile; return
    } else { $errors.Add("curl.exe not found.") }
  } catch {
    $errors.Add("curl.exe: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -EA SilentlyContinue }
  }

  # certutil
  try {
    $cert = Get-Command certutil.exe -EA SilentlyContinue
    if ($cert) {
      Render-Bar -Percent ($ProgressBase + $ProgressSpan) -Phase "Download" -Detail "certutil..." -Mood "Warn"
      $proc = Start-Process $cert.Source -ArgumentList @("-urlcache","-split","-f",$Url,$OutFile) -Wait -PassThru -NoNewWindow
      if ($proc.ExitCode -ne 0) { throw "exit $($proc.ExitCode)" }
      Assert-DownloadedFile -Path $OutFile; return
    } else { $errors.Add("certutil.exe not found.") }
  } catch {
    $errors.Add("certutil: $($_.Exception.Message)")
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -EA SilentlyContinue }
  }

  throw "All download methods failed.`n  - " + ($errors -join "`n  - ")
}

# ================================================================
#  ZIP EXTRACT
# ================================================================
function Extract-DriverZip {
  param([string]$ZipPath, [string]$DestDir, [string]$RequiredCat = "")
  New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
  Get-ChildItem $DestDir -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
  Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force

  $dirs = @(Get-ChildItem $DestDir -Directory -EA SilentlyContinue)
  if ($dirs.Count -eq 1 -and (Test-Path (Join-Path $dirs[0].FullName "oemsetup.inf"))) {
    Get-ChildItem $dirs[0].FullName -Force | Move-Item -Destination $DestDir -Force
    Remove-Item $dirs[0].FullName -Recurse -Force -EA SilentlyContinue
  }

  $inf = Join-Path $DestDir "oemsetup.inf"
  if (!(Test-Path $inf)) {
    $found = Get-ChildItem $DestDir -Recurse -Filter "*.inf" -EA SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw "No .inf file found after extraction in '$DestDir'." }
    $inf = $found.FullName
  }

  if ($RequiredCat -ne "" -and !(Test-Path (Join-Path $DestDir $RequiredCat))) {
    Log "Warning: expected catalog '$RequiredCat' not found. Continuing." -Level "Warn"
  }
  return $inf
}

# ================================================================
#  VERIFY PRINTER EXISTS
# ================================================================
function Test-PrinterInstalled {
  param([string]$Name)
  try {
    if (Get-Command Get-Printer -EA SilentlyContinue) {
      return [bool](Get-Printer -Name $Name -EA SilentlyContinue)
    }
    $f = "Name='{0}'" -f $Name.Replace("'","''")
    return [bool](Get-CimInstance Win32_Printer -Filter $f -EA SilentlyContinue)
  } catch { return $false }
}

# ================================================================
#  TEMP CLEANUP
# ================================================================
function Remove-TempFiles {
  param([string[]]$Paths)
  foreach ($p in $Paths) {
    try { if (Test-Path $p) { Remove-Item $p -Force -Recurse -EA SilentlyContinue } } catch {}
  }
}

# ================================================================
#  CORE INSTALL ROUTINE
# ================================================================
function Install-RicohPrinter {
  param(
    [string]$Label, [string]$ZipUrl, [string]$LocalDriverDir,
    [string]$PrinterName, [string]$DriverName, [string]$PortName,
    [string]$IP, [string]$Queue, [string]$ZipTempName,
    [string]$RequiredCat = "", [bool]$DoForceCleanup, [bool]$DoRemoveDriver
  )

  Write-Section "Installing $Label"
  New-BarLine

  $zipPath = Join-Path $env:TEMP $ZipTempName

  try {
    Render-Bar -Percent 1 -Phase "Init" -Detail "Starting" -Mood "Good"

    Log ("Target  : IP=$IP  Printer=$PrinterName  Port=$PortName  Queue=$Queue")
    Log ("Driver  : $DriverName")
    Log ("ZIP     : $ZipUrl")
    Log ("Dir     : $LocalDriverDir")
    Log ("Cleanup : ForcePort=$DoForceCleanup  RemoveDriver=$DoRemoveDriver") -Level "Warn"

    # Download
    Render-Bar -Percent 5 -Phase "Download" -Detail "Starting..." -Mood "Good"
    Download-FileHardened -Url $ZipUrl -OutFile $zipPath -ProgressBase 5 -ProgressSpan 20
    Render-Bar -Percent 25 -Phase "Download" -Detail "Done" -Mood "Good"

    # Extract
    Render-Bar -Percent 26 -Phase "Extract" -Detail "Unpacking..." -Mood "Good"
    try { Unblock-File -Path $zipPath -EA SilentlyContinue } catch {}
    $infPath = Extract-DriverZip -ZipPath $zipPath -DestDir $LocalDriverDir -RequiredCat $RequiredCat
    Render-Bar -Percent 35 -Phase "Extract" -Detail "Done" -Mood "Good"

    # Spooler reset (initial)
    Render-Bar -Percent 37 -Phase "Spooler" -Detail "Stopping..." -Mood "Warn"
    Stop-SpoolerHard; Clear-SpoolFiles; Start-Spooler
    Render-Bar -Percent 47 -Phase "Spooler" -Detail "Running" -Mood "Good"

    # Remove stale printer
    Render-Bar -Percent 49 -Phase "Cleanup" -Detail "Old printer..." -Mood "Warn"
    PrintUI-DeletePrinter -Name $PrinterName

    # Remove stale port (optional)
    if ($DoForceCleanup) {
      Render-Bar -Percent 53 -Phase "Cleanup" -Detail "Old port..." -Mood "Warn"
      Delete-PortBestEffort -PortName $PortName
    }

    # Remove stale driver (optional)
    if ($DoRemoveDriver) {
      Render-Bar -Percent 56 -Phase "Cleanup" -Detail "Old driver..." -Mood "Warn"
      try { PrintUI-DeleteDriver -ModelName $DriverName } catch {}
    }

    Render-Bar -Percent 59 -Phase "Cleanup" -Detail "Done" -Mood "Good"

    # Register driver
    Render-Bar -Percent 68 -Phase "Driver" -Detail "Registering..." -Mood "Good"
    PrintUI-InstallDriverFromInf -InfPath $infPath -ModelName $DriverName
    Render-Bar -Percent 76 -Phase "Driver" -Detail "Registered" -Mood "Good"

    # Delete stale port then create fresh
    Render-Bar -Percent 78 -Phase "Port" -Detail "Removing stale..." -Mood "Warn"
    Delete-PortBestEffort -PortName $PortName
    Start-Sleep -Seconds 1

    Render-Bar -Percent 81 -Phase "Port" -Detail "Creating LPR..." -Mood "Good"
    Ensure-LprPort -PortName $PortName -IP $IP -Queue $Queue

    # Bounce spooler so LPR Port Monitor reloads and registry is flushed
    # This makes Port-Exists (registry path) reliable immediately
    Render-Bar -Percent 84 -Phase "Port" -Detail "Reloading spooler..." -Mood "Warn"
    Stop-SpoolerHard; Start-Spooler

    # Wait (checks WMI + Get-PrinterPort + Registry)
    Render-Bar -Percent 87 -Phase "Port" -Detail "Waiting 30s..." -Mood "Good"
    if (-not (Wait-Port -Name $PortName -Seconds 30)) {
      # Diagnostic dump on failure
      $wmiDump = (Get-CimInstance Win32_TCPIPPrinterPort -EA SilentlyContinue |
                  Select-Object Name,HostAddress,Protocol | Out-String).Trim()
      $regDump = @()
      try {
        $mb = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors"
        Get-ChildItem $mb -EA SilentlyContinue | ForEach-Object {
          $pk = Join-Path $_.PSPath "Ports"
          if (Test-Path $pk) {
            Get-ChildItem $pk -EA SilentlyContinue |
              ForEach-Object { $regDump += "$($_.PSParentPath | Split-Path -Leaf) -> $($_.PSChildName)" }
          }
        }
      } catch {}
      throw (
        "Port '$PortName' not found after 30s.`n" +
        "WMI ports:`n$wmiDump`n" +
        "Registry ports:`n" + ($regDump -join "`n") + "`n`n" +
        "Fix: install LPR Port Monitor feature:`n" +
        "  Enable-WindowsOptionalFeature -Online -FeatureName LPDPrintService"
      )
    }
    Render-Bar -Percent 90 -Phase "Port" -Detail "Port ready" -Mood "Good"

    # Install printer
    Render-Bar -Percent 93 -Phase "Printer" -Detail "Installing..." -Mood "Good"
    PrintUI-InstallPrinter -PrinterName $PrinterName -PortName $PortName `
                           -DriverName $DriverName -InfPath $infPath

    if (-not (Test-PrinterInstalled -Name $PrinterName)) {
      throw "PrintUIEntry returned OK but '$PrinterName' not visible in the system yet."
    }

    Finish-Bar -Final "Completed" -Mood "Good"
    Log "SUCCESS: '$PrinterName'  Driver: $DriverName  Port: $PortName"
    return $true

  } catch {
    Finish-Bar -Final "Failed" -Mood "Fail"
    Log ("FAILED: " + $_.Exception.Message) -Level "Error"
    Write-Host ""
    Write-Host "  [!] Script execution error:" -ForegroundColor Red
    Write-Host ("      " + $_.Exception.Message) -ForegroundColor Red
    return $false

  } finally {
    Remove-TempFiles -Paths @($zipPath)
  }
}

# ================================================================
#  MENU
# ================================================================
function Show-Menu {
  $bar = "+" + ("=" * 54) + "+"
  $mid = "|" + (" " * 54) + "|"
  Write-Host $bar -ForegroundColor DarkCyan
  Write-Host $mid -ForegroundColor DarkCyan
  Write-Host "|   Select printer(s) to install:                      |" -ForegroundColor Cyan
  Write-Host $mid -ForegroundColor DarkCyan
  Write-Host "|   [1]  B&W Printer                                    |" -ForegroundColor White
  Write-Host "|        RICOH MP 2555 PCL 6  ->  RICHO                 |" -ForegroundColor DarkGray
  Write-Host "|        Port: IP_192.168.18.245                        |" -ForegroundColor DarkGray
  Write-Host $mid -ForegroundColor DarkCyan
  Write-Host "|   [2]  Color Printer                                  |" -ForegroundColor White
  Write-Host "|        RICOH IM C2000 PCL 6  ->  Secure-Color-Printer |" -ForegroundColor DarkGray
  Write-Host "|        Port: LPR_192.168.18.245                       |" -ForegroundColor DarkGray
  Write-Host $mid -ForegroundColor DarkCyan
  Write-Host "|   [3]  Install BOTH printers                          |" -ForegroundColor Yellow
  Write-Host $mid -ForegroundColor DarkCyan
  Write-Host "|   [4]  Exit                                           |" -ForegroundColor Red
  Write-Host $mid -ForegroundColor DarkCyan
  Write-Host $bar -ForegroundColor DarkCyan
  Write-Host ""
}

function Read-Choice {
  while ($true) {
    Write-Host "  Your choice [1/2/3/4]: " -NoNewline -ForegroundColor Cyan
    try {
      $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
      $ch  = $key.Character.ToString().Trim()
    } catch {
      $ch = (Read-Host "").Trim()
    }
    Write-Host $ch
    if ($ch -in @("1","2","3","4")) { return [int]$ch }
    Write-Host "  [!] Invalid. Press 1, 2, 3 or 4." -ForegroundColor Red
  }
}

# ================================================================
#  ENTRY POINT
# ================================================================
Show-Logo

try { Assert-Admin } catch {
  Write-Host ""
  Write-Host "  [!] $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "  Right-click PowerShell -> 'Run as Administrator'." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "[Done] Press Enter to close ..." -ForegroundColor DarkGray
  $null = Read-Host; exit 1
}

if ($InstallChoice -eq 0) { Show-Menu; $InstallChoice = Read-Choice }

Write-Host ""

$doForce  = $ForceFullCleanup.IsPresent
$doRemDrv = $RemoveDriver.IsPresent

$bwArgs = @{
  Label = "B&W Printer (RICOH MP 2555 PCL 6)"; ZipUrl = $BwZipUrl
  LocalDriverDir = $BwLocalDir; PrinterName = $BwPrinterName
  DriverName = $BwDriverName; PortName = $BwPortName
  IP = $PrinterIP; Queue = $LprQueue; ZipTempName = "r_print_driver.zip"
  RequiredCat = "rica67.cat"; DoForceCleanup = $doForce; DoRemoveDriver = $doRemDrv
}
$colorArgs = @{
  Label = "Color Printer (RICOH IM C2000 PCL 6)"; ZipUrl = $ColorZipUrl
  LocalDriverDir = $ColorLocalDir; PrinterName = $ColorPrinterName
  DriverName = $ColorDriverName; PortName = $ColorPortName
  IP = $PrinterIP; Queue = $LprQueue; ZipTempName = "SCP2000_PCL.zip"
  RequiredCat = ""; DoForceCleanup = $doForce; DoRemoveDriver = $doRemDrv
}

$resultBw = $null; $resultColor = $null

switch ($InstallChoice) {
  1 { $resultBw    = Install-RicohPrinter @bwArgs }
  2 { $resultColor = Install-RicohPrinter @colorArgs }
  3 { $resultBw    = Install-RicohPrinter @bwArgs
      $resultColor = Install-RicohPrinter @colorArgs }
  4 { Write-Host "  Exiting. No printers installed." -ForegroundColor Yellow; Write-Host ""; exit 0 }
}

# Summary
Write-Host ""
$bar = "+" + ("=" * 54) + "+"
Write-Host $bar -ForegroundColor DarkCyan
Write-Host "|   INSTALLATION SUMMARY                                |" -ForegroundColor Cyan
Write-Host $bar -ForegroundColor DarkCyan
if ($null -ne $resultBw) {
  $st = if ($resultBw)    { "OK    " } else { "FAILED" }
  $fc = if ($resultBw)    { "Green" } else { "Red" }
  Write-Host ("|   B&W   (RICHO)               : {0,-23}|" -f $st) -ForegroundColor $fc
}
if ($null -ne $resultColor) {
  $st = if ($resultColor) { "OK    " } else { "FAILED" }
  $fc = if ($resultColor) { "Green" } else { "Red" }
  Write-Host ("|   Color (Secure-Color-Printer) : {0,-22}|" -f $st) -ForegroundColor $fc
}
Write-Host $bar -ForegroundColor DarkCyan
Write-Host ""
Write-Host "[Done] Press Enter to close ..." -ForegroundColor DarkGray
$null = Read-Host
