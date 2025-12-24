# =============================================================
# GitHub Font Installer
# Downloads fonts from a GitHub repo folder and installs them
# =============================================================

$RepoOwner = "rhshourav"
$RepoName  = "ideal-fishstick"
$Folder    = "erp_font"

$ApiUrl  = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$Folder"
$TempDir = "$env:TEMP\erp_fonts"
$FontDir = "$env:WINDIR\Fonts"

# -----------------------------
# Admin Check
# -----------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "This script must be run as Administrator." }

# -----------------------------
# Prepare Temp Folder
# -----------------------------
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
        Write-Warning "Failed to download $($File.name): $_"
        continue
    }
}
Write-Progress -Activity "Downloading fonts" -Completed

# -----------------------------
# Install Fonts
# -----------------------------
$DownloadedFonts = Get-ChildItem $TempDir -Include *.ttf,*.ttc,*.fon
foreach ($Font in $DownloadedFonts) {
    $Dest = Join-Path $FontDir $Font.Name
    try {
        if (-not (Test-Path $Dest)) {
            Copy-Item $Font.FullName $Dest -Force
            $res = [FontHelper]::AddFontResource($Dest)
            if ($res -eq 0) { Write-Warning "Failed to register font $($Font.Name)" }
            else {
                # Notify system of font change
                [FontHelper]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero, $SMTO_ABORTIFHUNG, 100, [ref]([IntPtr]::Zero)) | Out-Null
                Write-Host "Installed font: $($Font.Name)"
            }
        } else {
            Write-Host "Font already exists: $($Font.Name)"
        }
    } catch {
        Write-Warning "Error installing font $($Font.Name): $_"
    }
}

# -----------------------------
# Clean Up
# -----------------------------
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nAll done! Fonts installed successfully."
