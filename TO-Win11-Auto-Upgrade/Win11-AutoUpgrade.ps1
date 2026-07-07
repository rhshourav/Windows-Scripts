# =========================================================
# Windows 10 → Windows 11 Automated Upgrade Script (PS 5.1)
# Author : Shourav
# Role   : Cyber Security Engineer
# Purpose: Fully automated in-place upgrade (ISO mount)
# Notes  : Optional unsupported hardware bypass included.
# =========================================================

[CmdletBinding()]
param(
  [ValidateSet("Download","Local")]
  [string]$IsoSource,

  [string]$IsoUrl,
  [string]$IsoPath,

  [switch]$BypassHardwareChecks,
  [switch]$AutoReboot,
  [switch]$KeepDownloadedIso
)

Set-StrictMode -Version 2.1.0
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
        text  = "Windows10 to 11 Upgrade v2.1.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
# -----------------------------
# Helpers
# -----------------------------
function Test-IsAdmin {
  $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-End {
  if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ""
    Read-Host "Press Enter to exit"
  }
}

function Prompt-YesNo {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [bool]$DefaultYes = $false
  )
  $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
  while ($true) {
    $ans = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
    if ($ans -match '^[Yy]$') { return $true }
    if ($ans -match '^[Nn]$') { return $false }
    Write-Host "Please answer Y or N." -ForegroundColor Yellow
  }
}

function Prompt-Choice {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$true)][string[]]$Options
  )
  while ($true) {
    Write-Host $Message -ForegroundColor Cyan
    for ($i=0; $i -lt $Options.Count; $i++) {
      Write-Host ("  [{0}] {1}" -f ($i+1), $Options[$i])
    }
    $pick = Read-Host "Enter number (1-$($Options.Count))"
    if ($pick -match '^\d+$') {
      $n = [int]$pick
      if ($n -ge 1 -and $n -le $Options.Count) { return $Options[$n-1] }
    }
    Write-Host "Invalid selection." -ForegroundColor Yellow
  }
}

function Select-IsoFile {
  Add-Type -AssemblyName System.Windows.Forms
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "ISO files (*.iso)|*.iso|All files (*.*)|*.*"
  $dlg.Title  = "Select Windows 11 ISO"
  $dlg.Multiselect = $false
  if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    throw "ISO selection cancelled."
  }
  return $dlg.FileName
}

function Download-Iso {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$OutFile
  )
  Write-Host "Downloading ISO..." -ForegroundColor Yellow
  Write-Host "URL: $Url"
  Write-Host "OUT: $OutFile"

  try {
    Start-BitsTransfer -Source $Url -Destination $OutFile -DisplayName "Win11 ISO Download" -Description "Windows 11 ISO"
  } catch {
    Write-Warning "BITS failed; falling back to Invoke-WebRequest. Error: $($_.Exception.Message)"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  }

  if (-not (Test-Path $OutFile)) {
    throw "Download failed: ISO not found after download."
  }
}

function Resolve-MountedDriveLetter {
  param([Parameter(Mandatory=$true)][string]$ImagePath)

  $vol = Get-DiskImage -ImagePath $ImagePath | Get-Disk | Get-Partition | Get-Volume |
         Where-Object { $_.DriveLetter } | Select-Object -First 1

  if (-not $vol) { return $null }
  return "$($vol.DriveLetter):"
}

# -----------------------------
# Elevation (keep elevated window open)
# -----------------------------
if (-not (Test-IsAdmin)) {
  Write-Warning "Administrator rights are required. Elevating..."

  # Relaunch elevated and keep the window open
  $argList = @(
    "-NoExit",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`""
  )

  # Preserve any parameters passed (optional)
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) {
      if ($v.IsPresent) { $argList += "-$k" }
    } else {
      $argList += "-$k"
      $argList += "`"$v`""
    }
  }

  Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList | Out-Null
  exit
}

# -----------------------------
# UI
# -----------------------------
try {
  $raw = $Host.UI.RawUI
  $raw.BackgroundColor = 'Black'
  $raw.ForegroundColor = 'White'
  Clear-Host
} catch {}

# -----------------------------
# Wizard prompts (only if not provided)
# -----------------------------
try {
  Write-Host "Windows 10 → Windows 11 Upgrade Wizard" -ForegroundColor Green
  Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

  if ([string]::IsNullOrWhiteSpace($IsoSource)) {
    $IsoSource = Prompt-Choice -Message "Select ISO source:" -Options @("Download","Local")
  }

  $downloadedIso = $false

  if ($IsoSource -eq "Download") {
    if ([string]::IsNullOrWhiteSpace($IsoUrl)) {
      $IsoUrl = Read-Host "Enter direct Windows 11 ISO URL"
      if ([string]::IsNullOrWhiteSpace($IsoUrl)) { throw "ISO URL cannot be empty." }
    }

    if ([string]::IsNullOrWhiteSpace($IsoPath)) {
      $defaultOut = Join-Path $PWD ("Win11_Auto_{0}.iso" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
      $IsoPath = Read-Host "Save ISO as (press Enter for default: $defaultOut)"
      if ([string]::IsNullOrWhiteSpace($IsoPath)) { $IsoPath = $defaultOut }
    }

    if (-not $PSBoundParameters.ContainsKey('KeepDownloadedIso')) {
      $KeepDownloadedIso = Prompt-YesNo -Message "Keep downloaded ISO after completion?" -DefaultYes:$false
    }

    $downloadedIso = $true
  }
  else {
    if ([string]::IsNullOrWhiteSpace($IsoPath)) {
      $usePicker = Prompt-YesNo -Message "Use file picker to select ISO?" -DefaultYes:$true
      if ($usePicker) {
        $IsoPath = Select-IsoFile
      } else {
        $IsoPath = Read-Host "Enter full path to the Windows 11 ISO"
      }
    }
  }

  if (-not (Test-Path $IsoPath)) {
    throw "ISO path not found: $IsoPath"
  }

  if (-not $PSBoundParameters.ContainsKey('BypassHardwareChecks')) {
    $BypassHardwareChecks = (Prompt-YesNo -Message "Apply unsupported hardware bypass (TPM/CPU/SecureBoot/RAM)?" -DefaultYes:$false)
  }

  if (-not $PSBoundParameters.ContainsKey('AutoReboot')) {
    $AutoReboot = (Prompt-YesNo -Message "Reboot automatically when setup phase completes?" -DefaultYes:$false)
  }

  # -----------------------------
  # Preconditions
  # -----------------------------
  $osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
  if ($osCaption -notlike "*Windows 10*") {
    throw "This script must be run on Windows 10. Detected: $osCaption"
  }

  $sysDriveLetter = ($env:SystemDrive.TrimEnd(":"))
  $freeGB = [math]::Round(((Get-PSDrive -Name $sysDriveLetter).Free / 1GB), 2)
  if ($freeGB -lt 30) {
    throw "Not enough free space on $sysDriveLetter`: ($freeGB GB). Need >= 30 GB."
  }

  # -----------------------------
  # Logging
  # -----------------------------
  $logRoot = Join-Path $env:SystemDrive "Win11-Upgrade-Logs"
  New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
  $stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
  $logPath = Join-Path $logRoot "Win11Upgrade-$stamp.log"
  Start-Transcript -Path $logPath -Append | Out-Null
  Write-Host "Log: $logPath" -ForegroundColor Cyan

  # -----------------------------
  # Download if needed
  # -----------------------------
  if ($IsoSource -eq "Download") {
    Download-Iso -Url $IsoUrl -OutFile $IsoPath
    Write-Host "Download complete: $IsoPath" -ForegroundColor Green
  }

  Write-Host "Using ISO: $IsoPath" -ForegroundColor Green

  # -----------------------------
  # Mount ISO
  # -----------------------------
  Write-Host "Mounting ISO..." -ForegroundColor Yellow
  $null = Mount-DiskImage -ImagePath $IsoPath -PassThru
  Start-Sleep -Seconds 2

  $driveLetter = Resolve-MountedDriveLetter -ImagePath $IsoPath
  if (-not $driveLetter) {
    throw "Failed to resolve mounted ISO drive letter."
  }
  Write-Host "Mounted at: $driveLetter" -ForegroundColor Cyan

  $setupPath = Join-Path $driveLetter "setup.exe"
  if (-not (Test-Path $setupPath)) {
    throw "setup.exe not found at: $setupPath"
  }

  # -----------------------------
  # Optional bypass keys
  # -----------------------------
  if ($BypassHardwareChecks) {
    Write-Host "Applying bypass registry keys..." -ForegroundColor Yellow

    New-Item -Path "HKLM:\SYSTEM\Setup\MoSetup" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\Setup\MoSetup" -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -PropertyType DWord -Value 1 -Force | Out-Null

    New-Item -Path "HKLM:\SYSTEM\Setup\LabConfig" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassTPMCheck"        -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassSecureBootCheck" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassRAMCheck"        -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassCPUCheck"        -PropertyType DWord -Value 1 -Force | Out-Null
  } else {
    Write-Host "Bypass not applied." -ForegroundColor DarkYellow
  }

  # -----------------------------
  # Run setup
  # -----------------------------
  Write-Host "Starting Windows 11 in-place upgrade..." -ForegroundColor Green

  $arguments = @(
    "/auto", "upgrade",
    "/quiet",
    "/noreboot",
    "/eula", "accept",
    "/dynamicupdate", "disable",
    "/compat", "ignorewarning"
  ) -join " "

  $proc = Start-Process -FilePath $setupPath -ArgumentList $arguments -Wait -PassThru
  Write-Host "setup.exe exit code: $($proc.ExitCode)" -ForegroundColor Cyan

  if ($proc.ExitCode -ne 0) {
    Write-Warning "Setup returned a non-zero exit code. Review transcript + Windows setup logs."
  }

  # -----------------------------
  # Reboot handling
  # -----------------------------
  if ($AutoReboot) {
    Write-Host "AutoReboot enabled. Rebooting..." -ForegroundColor Yellow
    Restart-Computer
  } else {
    $rebootNow = Prompt-YesNo -Message "Setup phase finished. Reboot now to continue upgrade?" -DefaultYes:$false
    if ($rebootNow) {
      Write-Host "Rebooting..." -ForegroundColor Yellow
      Restart-Computer
    } else {
      Write-Host "Reboot later to complete the upgrade." -ForegroundColor Yellow
    }
  }
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "If it closes or fails silently, this is why. Read the transcript log if created." -ForegroundColor Yellow
}
finally {
  # Dismount ISO
  try {
    if ($IsoPath -and (Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue)) {
      Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
      Write-Host "Dismounted ISO." -ForegroundColor Cyan
    }
  } catch {
    Write-Warning "Failed to dismount ISO: $($_.Exception.Message)"
  }

  # Remove downloaded ISO if applicable
  try {
    if (($IsoSource -eq "Download") -and (-not $KeepDownloadedIso) -and (Test-Path $IsoPath)) {
      Remove-Item $IsoPath -Force
      Write-Host "Removed downloaded ISO: $IsoPath" -ForegroundColor Cyan
    }
  } catch {
    Write-Warning "Failed to remove ISO: $($_.Exception.Message)"
  }

  try { Stop-Transcript | Out-Null } catch {}

  Pause-End
}

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUtNhaScoJ4juAUWKzLux59SrT
# A5ygghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQjTOx/JCvjzPxsZVw3uUY/zhCUhTANBgkq
# hkiG9w0BAQEFAASCAQAh/t1TGGNw8auszA+8TyMO9PwKIvK2m/2bkk0IvMgAlvmx
# 83PNJULRFwDr9805K3ECHua3VCDpGojXbE75vVAGPLUPk5hOrtceTHfOV1GnHHNh
# jVjG7UZwBLcAOx+3EKPE6E1RN6QbdekGkMXQt6viJJsZxu+sZ460EW8HCBYKlYyx
# H4sK8FBwotnhsGFqtK7kWVzSoHjtDbmdv0HmzZ1Tn07yL9PviCIFLX/lLvNY4a7R
# Lis5jD9OLpZ24zRKOHlyU6b3HGNdIyxYIB57LbwAwsCBGZpz55AezkbPbJKPzgVa
# f+p+Pwcs6fZxI+XcG8Ma8pvbABZ7MBSQM9EeoZ+joYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ1MlowLwYJKoZIhvcNAQkEMSIEICFKhtCqaNXbE4E1
# zh6rzwnu/D9Jp2Uwe27DtpAPRbG3MA0GCSqGSIb3DQEBAQUABIICACG8WDne6hIq
# OmlwdHzOHTryWkdI9mIhFoi6pA06/BaC9DwsYRfLbQQae/ff0GwlUvhpYp8bQfZl
# kNKAsMx1gtPMN4Kf2YmJScgwftGNkDjLMBFRJYXAxfqXC1mICRJKpeQJ2H/Ko+8F
# SQcD1vIxP5L7iniv5BDd7cU3q06eZdmoajSmwiAQ7ra1/R96nzcQnV3UfdeWqCiS
# X+SssxJcAYlsTYegx7uXmXeiRocrXemjKtzjh33RG6v0v6oOtnGCgoR9KiD0W7xC
# jYjkHoWpLX4DOuIF4i0+ORO+lHc/ZB44UQW7HO9Q4e0r404bm4pz6Sacgj+rByPI
# TP3SJE+yqKho4g/myk9Ezx+uMUuMfAfePeSxntxQBZCZ4iCHNxwlS8C2hE1wT9wi
# 9Gva9ndZAe2iIFVvdPyDg+dJHcO+W3bdvmZGtNASvvud9KEdP1fxkwyoA+TtfjBu
# s5M1TPqMvMkDaWxUtuW8tlNh4nOoo0UU3ZBpWrVLLa6ibYmiJQcA0TCVV95iAUDc
# Qn1du0QdfcRjUqYK8yrsgUi+Bgs5nrSW8VgvWk2pYenZFyzm2GLb4Kagsm1OS+w2
# 6JU41R/UaXiBVq3Od1RteVoAiIYsNGqUC9vQ2kShJz4QrhVJEpjF3ErByDeElrdH
# 9c6GLJ4qLrlIYam+Gv7/zgvjt7qt4DKK
# SIG # End signature block
