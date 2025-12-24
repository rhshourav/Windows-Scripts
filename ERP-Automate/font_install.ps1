# =============================================================
# GitHub Font Installer with Colorful Output
# Downloads fonts from a GitHub repo folder and installs them
# =============================================================

$RepoOwner = "rhshourav"
$RepoName  = "ideal-fishstick"
$Folder    = "erp_font"

$ApiUrl  = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$Folder"
$TempDir = "$env:TEMP\erp_fonts"
$FontDir = "$env:WINDIR\Fonts"

# -----------------------------
# Color Helpers
# -----------------------------
function Write-Header($Text) { Write-Host ""; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Step($Text)   { Write-Host "[*] $Text" -ForegroundColor White }
function Write-Success($Text){ Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Warn($Text)   { Write-Host "[!] $Text" -ForegroundColor Yellow }

# -----------------------------
# Admin Check
# -----------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "This script must be run as Administrator." }

Write-Header "GitHub Font Installer"

# -----------------------------
# Prepare Temp Folder
# -----------------------------
Write-Step "Preparing temporary folder..."
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $TempDir | Out-Null

# -----------------------------
# COM Import for Font Registration
# -----------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FontHelper {
    [DllImport("gdi32.dll", EntryPoint="AddFontResourceW", SetLastError=true)]
    public static extern int AddFontResource([MarshalAs(UnmanagedType.LPWStr)] string lpFileName);
    
    [DllImport("gdi32.dll", EntryPoint="RemoveFontResourceW", SetLastError=true)]
    public static extern bool RemoveFontResource([MarshalAs(UnmanagedType.LPWStr)] string lpFileName);
    
    [DllImport("user32.dll")]
    public static extern int SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@

# Constants for SendMessageTimeout
$HWND_BROADCAST = [intptr]0xffff
$WM_FONTCHANGE   = 0x001D
$SMTO_ABORTIFHUNG = 0x0002

# -----------------------------
# Download Fonts from GitHub
# -----------------------------
Write-Step "Fetching font list from GitHub..."
try {
    $Files = Invoke-RestMethod -Uri $ApiUrl -Headers @{ "User-Agent" = "PowerShell" }
} catch {
    throw "Failed to get files from GitHub: $_"
}

$FontFiles = $Files | Where-Object { $_.name -match '\.(ttf|ttc|fon)$' }
$total = $FontFiles.Count
$count = 0

foreach ($File in $FontFiles) {
    $count++
    $Out = Join-Path $TempDir $File.name
    try {
        Write-Progress -Activity "Downloading fonts" -Status "$($File.name) ($count/$total)" -PercentComplete (($count/$total)*100)
        Invoke-WebRequest -Uri $File.download_url -OutFile $Out -ErrorAction Stop
    } catch {
        Write-Warn "Failed to download $($File.name): $_"
        continue
    }
}
Write-Progress -Activity "Downloading fonts" -Completed
Write-Success "Downloaded $total font(s)."

# -----------------------------
# Install Fonts
# -----------------------------
Write-Step "Installing fonts..."
$InstalledCount = 0
$DownloadedFonts = Get-ChildItem $TempDir -Include *.ttf,*.ttc,*.fon

foreach ($Font in $DownloadedFonts) {
    $Dest = Join-Path $FontDir $Font.Name
    try {
        if (-not (Test-Path $Dest)) {
            Copy-Item $Font.FullName $Dest -Force
            $res = [FontHelper]::AddFontResource($Dest)
            if ($res -eq 0) { Write-Warn "Failed to register font $($Font.Name)" }
            else {
                [FontHelper]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero, $SMTO_ABORTIFHUNG, 100, [ref]([IntPtr]::Zero)) | Out-Null
                Write-Success "Installed font: $($Font.Name)"
                $InstalledCount++
            }
        } else {
            Write-Warn "Font already exists: $($Font.Name)"
        }
    } catch {
        Write-Warn "Error installing font $($Font.Name): $_"
    }
}

# -----------------------------
# Clean Up
# -----------------------------
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Success "Font installation completed. $InstalledCount font(s) installed."
Write-Warn "Some fonts may require a restart of apps to appear."
