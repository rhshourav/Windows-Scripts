<#
.SYNOPSIS
  RICOH Color Printer Auto-Installer (ZIP driver source) - Hardened

.AUTHOR
  Shourav (rhshourav)

.VERSION
  1.3.0

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
        text  = "Install Color RICHO v1.3.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

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
    if ((Get-Date) -gt $deadline) { return $false }
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
Show-Banner -Title "RICOH Color Printer Auto-Installer (ZIP Driver Source) - Hardened" -Version "1.3.0" -Author "Shourav (rhshourav)"
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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUVmgnr6wsWChbikYnXGlRky84
# xMOgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBTbO7VuQnpw0GDZh54vNfmaSBwpBjANBgkq
# hkiG9w0BAQEFAASCAQAP8yzFt8LCL7rxpitisLLwGSRQYJVPAykEifayDwjUuQe4
# S9Qhj3KWsW77YpwqYijCnEzHrlWpSlSONoBho03XDWIPhux0ltRGMQnEQy4qXE9D
# iDmRx6SWpP9LeAIp0RMM1am6JDr56PICYgl/bvWJrur58b7jiI4KKFO5eYrZ7aBU
# zjQsN5tA0s71ZCuFjXo4Yp5KGlb/+TtGE8myQaUcFy9YlG4J6XAVaMKfe9LtWVEF
# 9Zfw4m54roY2h0Q0/9DTnTeq83Oc0sXceo84T6PVggl1ll1pZ/SPv3ijD9M6Ee+c
# EhymHLxl1ZaUXOClarT/OAq40ZWqnypQDur/tMXhoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQyOVowLwYJKoZIhvcNAQkEMSIEIIXad9dNuf6vWqMd
# PuoquaOXNb6hu9lhBwZvhZ+ipyKiMA0GCSqGSIb3DQEBAQUABIICAHE2SbMF2w9l
# D7PxrPwMuJ/x/ryu58aTbM2ax2dkGh0lgs3t/H+GOe46h+MHQUUrbtD9P5W21kNu
# NBd4ZEiQmSSF2GmbSkTv8m9eUw0tu/yvA0aUu/HLAYXcmVGoDXi8j3ZDZdEAtDoL
# OEM7slQbq9kX0Nsh4Nw2xlOY4YPyXYBSHCkhgcUpNB6HzdeEh6bSnWWvaDgk9BxU
# mbk+/QTh3055SSONgOIdkikLleSRXDAcOc/x8G+Nwb2Z/6elObl0KQnRWSjyqs/e
# /aijUMOK/QhTFTNnZwWrAA+gWbHL+faSDNKxwMYs776MA8rdve7xc7ftYLcuo40y
# hgFtMbaAg05RFf6ho9vHlhPt0c4+R2xl4kIuPfOgsQlEUPzH4IrKtObw+TuUIHM9
# 8wKH+/WLY9NVOtDxHpOTM9rFXtkf90EONEnt3NEGjbNTaJ+vugbjvL38nCtveD51
# o74bI8/fKc+hDZtmZZpusxw8+mX81dKvD9mUZPOvFkbzEY5fbY5LShjXM2+ZoX4w
# jR9zu13mKAzK9uIcmrveGMmKgQ0sBkk8ySnqzYSW+Gfz5Xxw1FSTy9oUdH5YJiAB
# I5dwnCZuTowG++SpayK4kPRj2cCvg83jK5DvTzVb9iOuOkd6ZrXQ1/f9+fSCSSno
# HARxdH1diHHThESDWsP+LnVeCKvvD12t
# SIG # End signature block
