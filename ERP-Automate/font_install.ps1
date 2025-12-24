# =============================================================
# Font Installer: GitHub or Network Share
# =============================================================

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

Write-Header "Font Installer"

# -----------------------------
# User Choice
# -----------------------------
Write-Host "Select font source:"
Write-Host "1 - GitHub"
Write-Host "2 - Network Share"
Write-Host "0 - Exit"

$choice = Read-Host "Enter your choice (0/1/2)"
switch ($choice) {
    "0" { Write-Host "Exiting..."; exit }
    "1" { $Source = "GitHub" }
    "2" { $Source = "Network" }
    default { Write-Warn "Invalid choice. Exiting..."; exit }
}

# -----------------------------
# Setup Temp and Font Directories
# -----------------------------
$TempDir = "$env:TEMP\erp_fonts"
$FontDir = "$env:WINDIR\Fonts"
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
$HWND_BROADCAST = [intptr]0xffff
$WM_FONTCHANGE   = 0x001D
$SMTO_ABORTIFHUNG = 0x0002

$Summary = @()  # Array to store font status

# -----------------------------
# Fetch Fonts
# -----------------------------
if ($Source -eq "GitHub") {
    # GitHub Settings
    $RepoOwner = "rhshourav"
    $RepoName  = "ideal-fishstick"
    $Folder    = "erp_font"
    $ApiUrl    = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$Folder"

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
}
elseif ($Source -eq "Network") {
    # Network Share Settings
    $NetworkPath = "\\192.168.18.201\it\ERP\font"
    if (-not (Test-Path $NetworkPath)) {
        throw "Network path not accessible: $NetworkPath"
    }

    Write-Step "Copying fonts from network share..."
    $Files = Get-ChildItem -Path $NetworkPath -File | Where-Object { $_.Extension -match '(\.ttf|\.ttc|\.fon)$' }
$total = $Files.Count
if ($total -eq 0) { Write-Warn "No font files found in $NetworkPath"; return }

$count = 0
foreach ($File in $Files) {
    $count++
    $Dest = Join-Path $TempDir $File.Name
    try {
        Copy-Item $File.FullName $Dest -Force
        Write-Progress -Activity "Copying fonts" -Status "$($File.Name) ($count/$total)" -PercentComplete (($count/$total)*100)
    } catch {
        Write-Warn "Failed to copy $($File.Name): $_"
        continue
    }
}
Write-Progress -Activity "Copying fonts" -Completed
Write-Success "Copied $total font(s) from network share."

}

# -----------------------------
# Install Fonts
# -----------------------------
Write-Step "Installing fonts..."
$DownloadedFonts = Get-ChildItem $TempDir -Include *.ttf,*.ttc,*.fon

foreach ($Font in $DownloadedFonts) {
    $Dest = Join-Path $FontDir $Font.Name
    $Status = ""
    try {
        if (-not (Test-Path $Dest)) {
            Copy-Item $Font.FullName $Dest -Force
            $res = [FontHelper]::AddFontResource($Dest)
            if ($res -eq 0) { 
                $Status = "Failed to Register"
                Write-Warn "Failed to register font $($Font.Name)"
            } else {
                [FontHelper]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero, $SMTO_ABORTIFHUNG, 100, [ref]([IntPtr]::Zero)) | Out-Null
                $Status = "Installed"
                Write-Success "Installed font: $($Font.Name)"
            }
        } else {
            $Status = "Already Exists"
            Write-Warn "Font already exists: $($Font.Name)"
        }
    } catch {
        $Status = "Error"
        Write-Warn "Error installing font $($Font.Name): $_"
    }
    $Summary += [PSCustomObject]@{
        Font   = $Font.Name
        Status = $Status
    }
}

# -----------------------------
# Clean Up
# -----------------------------
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------
# Summary Table
# -----------------------------
Write-Header "Installation Summary"
$Summary | Format-Table -AutoSize

Write-Success "`nFont installation completed."
Write-Warn "Some fonts may require a restart of apps to appear."
