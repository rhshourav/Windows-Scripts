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

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

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
