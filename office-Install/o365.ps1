# ============================================================
# O365 Installer (ODT Correct Flow)
# Author : rhshourav
# GitHub : rhshourav / rhshoura
# Works  : Windows 10 / 11
# ============================================================

$ErrorActionPreference = "Stop"

# -------- CONFIG --------
$ZipUrl = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/O365.zip"
$Base   = Join-Path $env:TEMP "O365_Install"
$Zip    = Join-Path $Base "O365.zip"
# ------------------------

# -------- ADMIN CHECK --------
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $admin) {
    Write-Error "Run this script as Administrator."
    exit 1
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

# -------- SETUP DIR --------
New-Item -ItemType Directory -Path $Base -Force | Out-Null
Set-Location $Base

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host " O365 Installer (ODT Download + Configure)" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# -------- DOWNLOAD ZIP --------
Write-Host "[*] Downloading O365.zip..."
Invoke-WebRequest -Uri $ZipUrl -OutFile $Zip -UseBasicParsing

# -------- EXTRACT --------
Write-Host "[*] Extracting..."
Expand-Archive -Path $Zip -DestinationPath $Base -Force

$Setup = Join-Path $Base "setup.exe"
$Xml   = Join-Path $Base "windows64bit.xml"

if (!(Test-Path $Setup) -or !(Test-Path $Xml)) {
    Write-Error "setup.exe or windows64bit.xml not found after extraction."
    exit 1
}

# -------- DOWNLOAD PHASE --------
Write-Host ""
Write-Host "[*] Downloading Office binaries (this WILL look quiet)..." -ForegroundColor Yellow
Write-Host "    Progress is shown by file count growth." -ForegroundColor DarkGray

$OfficeDir = Join-Path $Base "Office"
$lastCount = 0

# Start download in background
$downloadJob = Start-Process `
    -FilePath $Setup `
    -ArgumentList "/download `"$Xml`"" `
    -WorkingDirectory $Base `
    -PassThru

# Monitor progress
while (!$downloadJob.HasExited) {
    if (Test-Path $OfficeDir) {
        $count = (Get-ChildItem $OfficeDir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($count -ne $lastCount) {
            Write-Host ("    Downloaded files: {0}" -f $count)
            $lastCount = $count
        }
    }
    Start-Sleep 5
}

Write-Host "[*] Download phase completed. Exit code: $($downloadJob.ExitCode)"

# -------- CONFIGURE PHASE --------
Write-Host ""
Write-Host "[*] Installing Office..." -ForegroundColor Yellow

$installJob = Start-Process `
    -FilePath $Setup `
    -ArgumentList "/configure `"$Xml`"" `
    -WorkingDirectory $Base `
    -PassThru -Wait

Write-Host "[*] Configure phase exit code: $($installJob.ExitCode)"

# -------- FINISH --------
Write-Host ""
Write-Host "[+] Script finished." -ForegroundColor Green
Write-Host "[+] If installation failed, check logs in:" -ForegroundColor Green
Write-Host "    $env:TEMP\USL-*.log" -ForegroundColor Yellow
