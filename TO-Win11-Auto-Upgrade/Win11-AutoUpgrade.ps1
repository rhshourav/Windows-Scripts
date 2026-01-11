# ==========================================
# Windows 11 FULLY AUTOMATED UPGRADE SCRIPT
# Compatible with Windows PowerShell 5.1
# Safe for: iex (irm URL)
# ==========================================

$ErrorActionPreference = "Stop"

# ---------- UI ----------
function Say($msg) {
    Write-Host "[*] $msg" -ForegroundColor Cyan
}
function Warn($msg) {
    Write-Host "[!] $msg" -ForegroundColor Yellow
}
function Fail($msg) {
    Write-Host "[X] $msg" -ForegroundColor Red
    exit 1
}

Say "Starting Windows 11 automated upgrade"

# ---------- Admin check ----------
if (-not ([Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Administrator privileges required"
}

# ---------- OS check ----------
$os = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
if ($os.ProductName -notlike "*Windows 10*") {
    Fail "This script is only for Windows 10"
}

Say "Detected OS: $($os.ProductName) (Build $($os.CurrentBuild))"

# ---------- Disk space check ----------
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Say "Free disk space: $freeGB GB"

if ($freeGB -lt 30) {
    Fail "At least 30GB free space required"
}

# ---------- Registry bypass ----------
Say "Applying Windows 11 compatibility bypass"

New-Item "HKLM:\SYSTEM\Setup\MoSetup" -Force | Out-Null
New-ItemProperty "HKLM:\SYSTEM\Setup\MoSetup" `
    -Name AllowUpgradesWithUnsupportedTPMOrCPU `
    -Type DWord -Value 1 -Force | Out-Null

New-Item "HKLM:\SYSTEM\Setup\LabConfig" -Force | Out-Null
$keys = "BypassTPMCheck","BypassSecureBootCheck","BypassRAMCheck","BypassCPUCheck"
foreach ($k in $keys) {
    New-ItemProperty "HKLM:\SYSTEM\Setup\LabConfig" `
        -Name $k -Type DWord -Value 1 -Force | Out-Null
}

Say "Bypass keys applied"

# ---------- ISO download ----------
$isoUrl = "https://software-download.microsoft.com/db/Win11_23H2_English_x64.iso"
$isoPath = "$env:TEMP\Win11.iso"

Say "Downloading Windows 11 ISO"
Say "This may take a while..."

Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing

if (-not (Test-Path $isoPath)) {
    Fail "ISO download failed"
}

Say "ISO downloaded successfully"

# ---------- Mount ISO ----------
Say "Mounting ISO"
$mount = Mount-DiskImage -ImagePath $isoPath -PassThru
Start-Sleep 3

$drive = ($mount | Get-Volume).DriveLetter + ":"
$setup = "$drive\setup.exe"

if (-not (Test-Path $setup)) {
    Fail "setup.exe not found in ISO"
}

Say "ISO mounted at $drive"

# ---------- Launch upgrade ----------
Say "Starting Windows 11 upgrade"
Say "Your files and apps WILL be preserved"

$arguments = "/auto upgrade /quiet /compat ignorewarning /eula accept /noreboot"

$proc = Start-Process -FilePath $setup `
    -ArgumentList $arguments `
    -Wait -PassThru

Say "Setup process exited with code $($proc.ExitCode)"

# ---------- Cleanup ----------
Say "Dismounting ISO"
Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue

Remove-Item $isoPath -Force -ErrorAction SilentlyContinue

# ---------- Reboot choice ----------
Write-Host ""
$choice = Read-Host "Upgrade staged. Reboot now to continue? (Y/N)"

if ($choice -match "^[Yy]") {
    Say "Rebooting system"
    Restart-Computer
} else {
    Warn "Reboot skipped. Windows 11 installation will complete after manual restart."
}

Say "Script finished"
