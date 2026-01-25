# =========================================================
# Windows 10 → Windows 11 Automated Upgrade Script
#
# Author  : Shourav
# Role    : Cyber Security Engineer
# GitHub  : https://github.com/rhshourav
#
# Purpose :
# Fully automated in-place upgrade from Windows 10 to
# Windows 11 with optional ISO download or manual ISO
# selection, including unsupported hardware bypass.
#
# Warning :
# This script bypasses Microsoft hardware requirements.
# Use only on systems you control and understand.
#
# Tested On:
# - Windows 10 x64
# - PowerShell 5.1
# =========================================================
# Check for administrative privileges (requires admin):contentReference[oaicite:7]{index=7}

# -----------------------------
# Admin / Elevation
# -----------------------------
function Is-Admin {
  $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $wp.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Is-Admin)) {
  Write-Warn "Administrator rights are required. Elevating..."
  Start-Process powershell -Verb RunAs -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
  )
  exit
}
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

# Ensure the current OS is Windows 10:contentReference[oaicite:8]{index=8}
$osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
if ($osCaption -notlike "*Windows 10*") {
    Write-Host "Error: This script requires Windows 10 as the current OS. Detected OS: $osCaption" -ForegroundColor Red
    exit 1
}

# Ensure at least 30 GB free space on system drive:contentReference[oaicite:9]{index=9}
$sysDrive = $env:SystemDrive.TrimEnd(":")
$freeGB = [math]::Round((Get-Volume -DriveLetter $sysDrive).SizeRemaining / 1GB, 2)
if ($freeGB -lt 30) {
    Write-Host "Error: Not enough free space. $freeGB GB available on $sysDrive. At least 30 GB is required." -ForegroundColor Red
    exit 1
}

Write-Host "Select ISO source: [1] Download from Microsoft  [2] Use local ISO"
$choice = Read-Host "Enter 1 or 2"

if ($choice -eq "1") {
    # Example Microsoft URL for Windows 11 ISO (adjust as needed)
    $isoUrl = "https://software.download.prss.microsoft.com/dbazure/Win11_24H2_English_x64.iso"
    $isoPath = Join-Path -Path $PWD -ChildPath "Win11_Auto.iso"
    Write-Host "Downloading Windows 11 ISO from $isoUrl..."
    try {
        Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    } catch {
        Write-Host "Error: Failed to download ISO. $_" -ForegroundColor Red
        exit 1
    }
    if (!(Test-Path $isoPath)) {
        Write-Host "Error: Download failed, ISO file not found." -ForegroundColor Red
        exit 1
    }
    Write-Host "Download complete: $isoPath"
    $disk = Mount-DiskImage -ImagePath $isoPath -PassThru
} elseif ($choice -eq "2") {
    $isoPath = Read-Host "Enter full path to the Windows 11 ISO file"
    if (!(Test-Path $isoPath)) {
        Write-Host "Error: Specified ISO path not found." -ForegroundColor Red
        exit 1
    }
    $disk = Mount-DiskImage -ImagePath $isoPath -PassThru
} else {
    Write-Host "Invalid choice. Please run the script again and choose 1 or 2." -ForegroundColor Red
    exit 1
}

# Get the drive letter of the mounted ISO
$volume = $disk | Get-Volume
if (!$volume) { $volume = ($disk | Get-Disk | Get-Partition | Get-Volume) }
$driveLetter = "${volume.DriveLetter}:"
Write-Host "Mounted ISO at drive $driveLetter"

# Verify setup.exe is present in the ISO
$setupPath = Join-Path -Path $driveLetter -ChildPath "setup.exe"
if (!(Test-Path $setupPath)) {
    Write-Host "Error: setup.exe not found in the ISO. Aborting." -ForegroundColor Red
    Dismount-DiskImage -ImagePath $isoPath
    exit 1
}

# Apply registry bypass keys for unsupported hardware (TPM/CPU/SecureBoot/RAM):contentReference[oaicite:10]{index=10}:contentReference[oaicite:11]{index=11}
Write-Host "Applying registry bypass for TPM/CPU and other requirements..."
New-Item -Path "HKLM:\SYSTEM\Setup\MoSetup" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\Setup\MoSetup" -Name AllowUpgradesWithUnsupportedTPMOrCPU -PropertyType DWord -Value 1 -Force | Out-Null
New-Item -Path "HKLM:\SYSTEM\Setup\LabConfig" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name BypassTPMCheck -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name BypassSecureBootCheck -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name BypassRAMCheck -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name BypassCPUCheck -PropertyType DWord -Value 1 -Force | Out-Null

# Launch Windows 11 setup with silent upgrade parameters:contentReference[oaicite:12]{index=12}:contentReference[oaicite:13]{index=13}
Write-Host "Starting Windows 11 in-place upgrade..."
$arguments = "/auto upgrade /quiet /noreboot /eula accept /dynamicupdate disable /compat ignorewarning"
Start-Process -FilePath $setupPath -ArgumentList $arguments -Wait
Write-Host "Windows 11 Setup has completed its tasks."

# Prompt for reboot
$reboot = Read-Host "Installation complete. Reboot now? (Y/N)"
if ($reboot -match "^[Yy]") {
    Write-Host "Rebooting system..."
    Restart-Computer
} else {
    Write-Host "Please remember to reboot later to finish the upgrade."
}

# Cleanup: dismount the ISO and delete if downloaded
Dismount-DiskImage -ImagePath $isoPath
Write-Host "Dismounted ISO image."
if (($choice -eq "1") -and (Test-Path $isoPath)) {
    Remove-Item $isoPath -Force
    Write-Host "Removed downloaded ISO file."
}
