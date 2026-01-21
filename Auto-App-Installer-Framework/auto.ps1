# ============================================================
# Office LTSC 2021 Installer (ODT Download + Configure)
# Author : rhshourav
# Works  : Windows 10 / 11
# NOTE   : Does NOT change caller's working directory
# ============================================================

$ErrorActionPreference = "Stop"

# -------------------- CONFIG --------------------
$ZipUrl = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/OLTSC-2021.zip"
$Base   = Join-Path $env:TEMP "rhshourav\WindowsScripts\OLTSC2021"
$Zip    = Join-Path $Base "OLTSC-2021.zip"
# ------------------------------------------------

# -------------------- ADMIN CHECK --------------------
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $admin) {
    Write-Host "[X] Please run this script as Administrator." -ForegroundColor Red
    exit 1
}
# ----------------------------------------------------

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host " Office LTSC 2021 Installer (ODT Download+Configure)" -ForegroundColor Cyan
Write-Host " Author: rhshourav" -ForegroundColor DarkCyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "[*] WorkDir: $Base"
Write-Host ""

# -------------------- PREP WORKDIR --------------------
New-Item -ItemType Directory -Path $Base -Force | Out-Null
# -----------------------------------------------------

# -------------------- DOWNLOAD ZIP --------------------
Write-Host "[*] Downloading OLTSC-2021.zip..."
Invoke-WebRequest -Uri $ZipUrl -OutFile $Zip -UseBasicParsing
Write-Host "[+] Download complete."
# ------------------------------------------------------

# -------------------- EXTRACT ZIP --------------------
Write-Host "[*] Extracting..."
Expand-Archive -Path $Zip -DestinationPath $Base -Force
Write-Host "[+] Extraction complete."
# -----------------------------------------------------

# -------------------- FIND REQUIRED FILES --------------------
$setup = Get-ChildItem -Path $Base -Recurse -File -Filter "setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $setup) {
    Write-Host "[X] setup.exe not found after extraction." -ForegroundColor Red
    exit 1
}

$xml = Get-ChildItem -Path $Base -Recurse -File -Filter "Configuration.xml" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $xml) {
    Write-Host "[X] Configuration.xml not found after extraction." -ForegroundColor Red
    exit 1
}

$setupDir = Split-Path -Parent $setup.FullName

Write-Host ""
Write-Host "[+] Found files:"
Write-Host "    setup.exe        : $($setup.FullName)"
Write-Host "    Configuration.xml: $($xml.FullName)"
Write-Host ""
# -----------------------------------------------------------

# -------------------- DOWNLOAD PHASE --------------------
Write-Host "[*] Downloading Office LTSC 2021 binaries..."
Write-Host "    (ODT is silent; monitoring Office folder growth)"
Write-Host ""

$officeDir = Join-Path $setupDir "Office"
$lastCount = -1

Push-Location $setupDir
try {
    $dlProc = Start-Process -FilePath $setup.FullName `
        -ArgumentList "/download `"$($xml.FullName)`"" `
        -WorkingDirectory $setupDir `
        -PassThru

    while (-not $dlProc.HasExited) {
        if (Test-Path $officeDir) {
            $count = (Get-ChildItem $officeDir -Recurse -File -ErrorAction SilentlyContinue).Count
            if ($count -ne $lastCount) {
                Write-Host ("    Downloaded files: {0}" -f $count)
                $lastCount = $count
            }
        }
        Start-Sleep 5
    }

    Write-Host ""
    Write-Host "[*] Download phase exit code: $($dlProc.ExitCode)"
}
finally {
    Pop-Location
}
# --------------------------------------------------------

# -------------------- CONFIGURE PHASE --------------------
Write-Host ""
Write-Host "[*] Installing / Configuring Office LTSC 2021..."

Push-Location $setupDir
try {
    $cfgProc = Start-Process -FilePath $setup.FullName `
        -ArgumentList "/configure `"$($xml.FullName)`"" `
        -WorkingDirectory $setupDir `
        -PassThru -Wait

    Write-Host "[*] Configure phase exit code: $($cfgProc.ExitCode)"
}
finally {
    Pop-Location
}
# ---------------------------------------------------------

# -------------------- FINISH --------------------
Write-Host ""
if ($cfgProc.ExitCode -eq 0) {
    Write-Host "[+] Completed successfully." -ForegroundColor Green
} else {
    Write-Host "[!] Completed with errors." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[*] Logs (if needed):"
Write-Host "    $env:TEMP\USL-*.log"
Write-Host "    $env:WINDIR\Temp"
Write-Host ""
Write-Host "[*] WorkDir preserved at:"
Write-Host "    $Base"
