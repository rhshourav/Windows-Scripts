# =============================================================
# ERP Font Installer (Network → GitHub Fallback)
# Persistent Windows 10/11 Font Registration
# =============================================================

# -----------------------------
# Script Info
# -----------------------------
$ScriptName = "ERP Font Install"
$Author     = "rhshourav"
$GitHub     = "https://github.com/rhshourav/Windows-Scripts"
$Version    = "v1.1.0"

Write-Host ""
Write-Host (" Script   : $ScriptName") -ForegroundColor White
Write-Host (" Author   : $Author")     -ForegroundColor White
Write-Host (" GitHub   : $GitHub")     -ForegroundColor Cyan
Write-Host (" Version  : $Version")    -ForegroundColor Yellow
Write-Host ""

$ErrorActionPreference = "Stop"

# -----------------------------
# Helpers
# -----------------------------
function Write-Header ($t){ Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Write-Step   ($t){ Write-Host "[*] $t" -ForegroundColor White }
function Write-Success($t){ Write-Host "[OK] $t" -ForegroundColor Green }
function Write-Warn   ($t){ Write-Host "[!] $t" -ForegroundColor Yellow }

# -----------------------------
# Admin Check
# -----------------------------
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
}

# -----------------------------
# Directories
# -----------------------------
$TempDir = "$env:TEMP\erp_fonts"
$FontDir = "$env:WINDIR\Fonts"
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

if (Test-Path $TempDir) {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $TempDir | Out-Null

# -----------------------------
# Win32 API
# -----------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FontAPI {
    [DllImport("gdi32.dll", EntryPoint="AddFontResourceW", SetLastError=true)]
    public static extern int AddFontResource(string lpFileName);

    [DllImport("user32.dll")]
    public static extern int SendMessageTimeout(
        IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam,
        int flags, int timeout, out IntPtr lpdwResult
    );
}
"@

$HWND_BROADCAST = [intptr]0xffff
$WM_FONTCHANGE = 0x001D
$SMTO_ABORTIFHUNG = 0x0002

# -----------------------------
# Font Registry Registration
# -----------------------------
function Register-Font {
    param([string]$FontPath)

    $name = [IO.Path]::GetFileName($FontPath)
    $ext  = [IO.Path]::GetExtension($name).ToLower()

    switch ($ext) {
        ".ttf" { $suffix = " (TrueType)" }
        ".ttc" { $suffix = " (TrueType)" }
        ".fon" { $suffix = " (Raster)" }
        default { return $false }
    }

    $display = ($name -replace '\.(ttf|ttc|fon)$','') + $suffix

    New-ItemProperty `
        -Path $RegPath `
        -Name $display `
        -Value $name `
        -PropertyType String `
        -Force | Out-Null

    return $true
}

# -----------------------------
# Verification Function
# -----------------------------
function Verify-FontInstalled {
    param([string]$FontName)

    $fileExists = Test-Path (Join-Path $FontDir $FontName)

    $regExists = Get-ItemProperty `
        -Path $RegPath `
        -ErrorAction SilentlyContinue |
        Get-Member -Name ($FontName -replace '\.(ttf|ttc|fon)$','')

    return ($fileExists -and $regExists)
}

# -----------------------------
# Sources
# -----------------------------
$NetworkSources = @(
    "\\192.168.18.201\it\ERP\font",
    "\\192.168.19.44\it\FONTS\ERP"
)

$GitHubSource = @{
    Owner  = "rhshourav"
    Repo   = "ideal-fishstick"
    Folder = "erp_font"
}

# -----------------------------
# Fetch Fonts
# -----------------------------
Write-Header "Fetching Fonts"

$Fetched = $false

foreach ($src in $NetworkSources) {
    Write-Step "Trying $src"
    if (Test-Path $src) {
        Get-ChildItem $src -File |
            Where-Object { $_.Extension -match '\.(ttf|ttc|fon)$' } |
            Copy-Item -Destination $TempDir -Force
        $Fetched = $true
        Write-Success "Fonts copied from network"
        break
    }
}

if (-not $Fetched) {
    Write-Warn "Network failed, using GitHub fallback"
    $api = "https://api.github.com/repos/$($GitHubSource.Owner)/$($GitHubSource.Repo)/contents/$($GitHubSource.Folder)"
    $files = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent"="PowerShell" }
    foreach ($f in $files | Where-Object { $_.name -match '\.(ttf|ttc|fon)$' }) {
        Invoke-WebRequest $f.download_url -OutFile (Join-Path $TempDir $f.name)
    }
    Write-Success "Fonts downloaded from GitHub"
}

# -----------------------------
# Install Fonts
# -----------------------------
Write-Header "Installing Fonts"

$Summary = @()

foreach ($font in Get-ChildItem $TempDir -Include *.ttf,*.ttc,*.fon) {

    $dest = Join-Path $FontDir $font.Name
    $status = "Unknown"

    try {
        if (-not (Test-Path $dest)) {
            Copy-Item $font.FullName $dest -Force
            Register-Font $dest | Out-Null
            [FontAPI]::AddFontResource($dest) | Out-Null

            [FontAPI]::SendMessageTimeout(
                $HWND_BROADCAST,
                $WM_FONTCHANGE,
                [IntPtr]::Zero,
                [IntPtr]::Zero,
                $SMTO_ABORTIFHUNG,
                100,
                [ref]([IntPtr]::Zero)
            ) | Out-Null
        }

        if (Verify-FontInstalled $font.Name) {
            $status = "Installed & Verified"
            Write-Success "$($font.Name)"
        }
        else {
            $status = "Verification Failed"
            Write-Warn "$($font.Name) verification failed"
        }
    }
    catch {
        $status = "Error"
        Write-Warn "$($font.Name): $_"
    }

    $Summary += [PSCustomObject]@{
        Font   = $font.Name
        Status = $status
    }
}

# -----------------------------
# Cleanup
# -----------------------------
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------
# Summary
# -----------------------------
Write-Header "Installation Summary"
$Summary | Format-Table -AutoSize

Write-Success "Font installation completed."
Write-Warn "Restart ERP / Office apps if fonts were open during install."
