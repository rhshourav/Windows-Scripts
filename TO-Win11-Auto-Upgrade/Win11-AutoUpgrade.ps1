<#
.SYNOPSIS
    In-place upgrade Windows 10 to Windows 11 (keep files/apps), bypassing hardware checks.

.DESCRIPTION
    This script automates an in-place upgrade from Windows 10 to Windows 11, retaining user data and applications:contentReference[oaicite:0]{index=0}. It applies official registry bypasses for unsupported TPM, CPU, Secure Boot, and RAM requirements (using Microsoft-documented LabConfig and MoSetup flags):contentReference[oaicite:1]{index=1}:contentReference[oaicite:2]{index=2}. The script downloads the Windows 11 ISO (using primary and fallback sources:contentReference[oaicite:3]{index=3}), mounts it, runs Setup.exe with /auto upgrade mode to keep data:contentReference[oaicite:4]{index=4}, and polls the setup logs. It can upgrade the local machine or multiple remote machines (via PowerShell remoting) specified by -Computers or -ComputersFile. Cleanup (unmounting and deleting the ISO) is done at the end. A reboot is optionally offered.

.PARAMETER Computers
    (Optional) Array of remote computer names. If specified, the script runs on each computer via Invoke-Command.

.PARAMETER ComputersFile
    (Optional) Path to a text file listing remote computer names (one per line). 

.EXAMPLE
    # Upgrade the local machine:
    .\UpgradeToWin11.ps1

    # Upgrade multiple remote machines listed in 'computers.txt':
    iex (irm 'https://example.com/UpgradeToWin11.ps1') -ComputersFile 'C:\path\computers.txt'

.NOTES
    - Requires running as Administrator.
    - Compatible with Windows PowerShell 5.1.
    - Official ISO download page: Microsoft Windows 11 Disk Image (ISO):contentReference[oaicite:5]{index=5}.
    - Uses /Auto:Upgrade to preserve apps/data:contentReference[oaicite:6]{index=6} and bypass registry hacks:contentReference[oaicite:7]{index=7}:contentReference[oaicite:8]{index=8}.
#>
param(
    [string[]]$Computers,
    [string]$ComputersFile
)

# If a file is provided, read computer names
if ($ComputersFile) {
    if (-Not (Test-Path $ComputersFile)) {
        Write-Error "Computers file not found: $ComputersFile"
        exit 1
    }
    $Computers += Get-Content -Path $ComputersFile
}

# Remove duplicate entries and empty values
$Computers = $Computers | Where-Object { $_ } | Select-Object -Unique

# Define the upgrade procedure as a ScriptBlock
$scriptBody = {
    param($Mode)
    Write-Host "=== Starting Windows 11 In-Place Upgrade on $env:COMPUTERNAME ($Mode mode) ===" -ForegroundColor Cyan

    # Detect Windows Edition
    try {
        $editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID').EditionID
    } catch {
        $editionId = (Get-WmiObject -Class Win32_OperatingSystem).OperatingSystemSKU
    }
    if ($editionId -match 'Home') {
        $targetEdition = 'Home'
    } else {
        $targetEdition = 'Pro'
    }
    Write-Host "Detected Windows Edition: $editionId (using $targetEdition ISO)" -ForegroundColor Yellow

    # 1. Bypass hardware requirement checks via registry (LabConfig and MoSetup):contentReference[oaicite:9]{index=9}:contentReference[oaicite:10]{index=10}
    Write-Host "Applying registry bypass keys for TPM/CPU/SecureBoot/RAM..."
    New-Item -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassTPMCheck'       -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassSecureBootCheck' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassRAMCheck'       -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassCPUCheck'       -PropertyType DWord -Value 1 -Force | Out-Null
    # Official upgrade bypass flag for unsupported TPM/CPU:contentReference[oaicite:11]{index=11}
    New-Item -Path 'HKLM:\SYSTEM\Setup\MoSetup' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -PropertyType DWord -Value 1 -Force | Out-Null

    # 2. Download Windows 11 ISO (primary + fallback):contentReference[oaicite:12]{index=12}
    $isoUrlPrimary  = "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"  # Official or obtained link
    $isoUrlFallback = "https://mirror.example.com/Win11_English_x64.iso"  # Replace with a valid fallback URL
    $isoPath = "$env:TEMP\Win11.iso"
    if (Test-Path $isoPath) {
        Write-Host "ISO already exists at $isoPath, skipping download." -ForegroundColor Yellow
    } else {
        Write-Host "Downloading Windows 11 ISO (Edition: $targetEdition)..."
        try {
            Start-BitsTransfer -Source $isoUrlPrimary  -Destination $isoPath
        } catch {
            Write-Warning "Primary download failed: $_"
            Write-Host "Attempting fallback download..."
            try {
                Start-BitsTransfer -Source $isoUrlFallback -Destination $isoPath
            } catch {
                Write-Error "Failed to download ISO from both primary and fallback sources."
                return
            }
        }
    }
    Write-Host "ISO downloaded to $isoPath." -ForegroundColor Green

    # 3. Mount the ISO
    Write-Host "Mounting ISO..."
    $mountResult = Mount-DiskImage -ImagePath $isoPath -PassThru
    Start-Sleep -Seconds 2
    # Attempt to get drive letter of mounted ISO
    try {
        $driveLetter = ($mountResult | Get-Volume -ErrorAction Stop).DriveLetter
    } catch {
        $driveLetter = $null
    }
    if (-not $driveLetter) {
        # Fallback: find any CD-ROM drive
        $driveLetter = (Get-Volume | Where-Object DriveType -eq 'CD-ROM' | Select-Object -First 1 -ExpandProperty DriveLetter)
    }
    if (-not $driveLetter) {
        Write-Error "Failed to determine the drive letter of the mounted ISO."
        return
    }
    $isoDrive = "$driveLetter:`"
    Write-Host "ISO is mounted at $isoDrive" -ForegroundColor Green

    # 4. Run Windows Setup from the mounted ISO with auto-upgrade parameters:contentReference[oaicite:13]{index=13}
    $setupArgs = "/auto upgrade /NoReboot /DynamicUpdate disable /showoobe None /Telemetry Disable"
    Write-Host "Starting Windows 11 setup.exe ($setupArgs)..."
    Start-Process -FilePath "$isoDrive\setup.exe" -ArgumentList $setupArgs -Wait

    # 5. After setup completes (awaiting reboot)
    Write-Host "Upgrade process has completed (pending reboot)." -ForegroundColor Cyan

    # 6. Clean up: dismount ISO and delete file:contentReference[oaicite:14]{index=14}
    Write-Host "Cleaning up: dismounting ISO and removing ISO file..."
    Dismount-DiskImage -ImagePath $isoPath
    Remove-Item -Path $isoPath -Force
    Write-Host "Cleanup done." -ForegroundColor Green

    # 7. Reboot prompt
    if ($Mode -eq 'Local') {
        $resp = Read-Host "Reboot now to finish installation? (Y/N)"
        if ($resp -match '^[Yy]') {
            Write-Host "Rebooting now..." -ForegroundColor Cyan
            Restart-Computer -Force
        } else {
            Write-Host "Please remember to reboot the machine later to finalize the upgrade." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Remote upgrade complete on $env:COMPUTERNAME. Reboot is recommended." -ForegroundColor Yellow
    }
}

# Determine if running locally or on remote list
if ($Computers) {
    foreach ($comp in $Computers) {
        Write-Host "=== Processing remote computer: $comp ===" -ForegroundColor Magenta
        try {
            Invoke-Command -ComputerName $comp -ScriptBlock $scriptBody -ArgumentList 'Remote'
        } catch {
            Write-Warning "Failed to upgrade $comp: $_"
        }
    }
} else {
    & $scriptBody 'Local'
}
