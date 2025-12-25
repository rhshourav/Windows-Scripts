# =============================================================
# Font Installer (Network Shares → GitHub Fallback)
# =============================================================
# Script Info
$ScriptName = "ERP Font Install"
$Author     = "rhshourav"
$GitHub     = "https://github.com/rhshourav/Windows-Scripts"
$Version    = "v1.0.4"

Write-Host ""
Write-Host ""
Write-Host (" Script   : " + $ScriptName) -ForegroundColor White
Write-Host (" Author   : " + $Author)     -ForegroundColor White
Write-Host (" GitHub   : " + $GitHub)     -ForegroundColor Cyan
Write-Host (" Version  : " + $Version)    -ForegroundColor Yellow

$ErrorActionPreference = "Stop"

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
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
}

Write-Header "Font Installer"

# -----------------------------
# Temp / Font Directories
# -----------------------------
$TempDir = "$env:TEMP\erp_fonts"
$FontDir = "$env:WINDIR\Fonts"

if (Test-Path $TempDir) {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $TempDir | Out-Null

# -----------------------------
# COM Import for Font Registration
# -----------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FontHelper {
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

$Summary = @()

# -----------------------------
# SOURCE DEFINITIONS (ORDERED)
# -----------------------------
$NetworkSources = @(
    "\\192.168.18.201\it\ERP\font",
    "\\192.168.19.44\it\FONTS\ERP"
)

$GitHubSource = @{
    RepoOwner = "rhshourav"
    RepoName  = "ideal-fishstick"
    Folder    = "erp_font"
}

# -----------------------------
# TRY NETWORK SHARES FIRST
# -----------------------------
$FontsFetched = $false

foreach ($Path in $NetworkSources) {

    Write-Step "Trying network source: $Path"

    try {
        if (-not (Test-Path $Path)) {
            throw "Path not accessible"
        }

        $Files = Get-ChildItem $Path -File |
            Where-Object { $_.Extension -match '\.(ttf|ttc|fon)$' }

        if ($Files.Count -eq 0) {
            throw "No font files found"
        }

        $total = $Files.Count
        $count = 0

        foreach ($File in $Files) {
            $count++
            Copy-Item $File.FullName (Join-Path $TempDir $File.Name) -Force
            Write-Progress `
                -Activity "Copying fonts from network" `
                -Status "$($File.Name) ($count/$total)" `
                -PercentComplete (($count / $total) * 100)
        }

        Write-Progress -Activity "Copying fonts from network" -Completed
        Write-Success "Fonts copied from $Path"
        $FontsFetched = $true
        break
    }
    catch {
        Write-Warn "Network source failed: $($_.Exception.Message)"
    }
}

# -----------------------------
# FALL BACK TO GITHUB (LAST)
# -----------------------------
if (-not $FontsFetched) {

    Write-Warn "All network sources failed. Falling back to GitHub..."

    try {
        $ApiUrl = "https://api.github.com/repos/$($GitHubSource.RepoOwner)/$($GitHubSource.RepoName)/contents/$($GitHubSource.Folder)"
        $Files = Invoke-RestMethod -Uri $ApiUrl -Headers @{ "User-Agent" = "PowerShell" }

        $FontFiles = $Files | Where-Object { $_.name -match '\.(ttf|ttc|fon)$' }
        if ($FontFiles.Count -eq 0) {
            throw "No fonts found in GitHub repo"
        }

        $total = $FontFiles.Count
        $count = 0

        foreach ($File in $FontFiles) {
            $count++
            $Out = Join-Path $TempDir $File.name
            Write-Progress `
                -Activity "Downloading fonts from GitHub" `
                -Status "$($File.name) ($count/$total)" `
                -PercentComplete (($count / $total) * 100)

            Invoke-WebRequest -Uri $File.download_url -OutFile $Out -ErrorAction Stop
        }

        Write-Progress -Activity "Downloading fonts from GitHub" -Completed
        Write-Success "Fonts downloaded from GitHub"
        $FontsFetched = $true
    }
    catch {
        throw "GitHub fallback failed: $($_.Exception.Message)"
    }
}

if (-not $FontsFetched) {
    throw "No available font sources succeeded."
}

# -----------------------------
# INSTALL FONTS
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
                $Status = "Failed"
                Write-Warn "Failed to register $($Font.Name)"
            }
            else {
                [FontHelper]::SendMessageTimeout(
                    $HWND_BROADCAST,
                    $WM_FONTCHANGE,
                    [IntPtr]::Zero,
                    [IntPtr]::Zero,
                    $SMTO_ABORTIFHUNG,
                    100,
                    [ref]([IntPtr]::Zero)
                ) | Out-Null

                $Status = "Installed"
                Write-Success "Installed: $($Font.Name)"
            }

        }
        else {
            $Status = "Already Exists"
            Write-Warn "Font already exists: $($Font.Name)"
        }
    }
    catch {
        $Status = "Error"
        Write-Warn "Error installing $($Font.Name): $_"
    }

    $Summary += [PSCustomObject]@{
        Font   = $Font.Name
        Status = $Status
    }
}

# -----------------------------
# CLEANUP
# -----------------------------
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------
# SUMMARY
# -----------------------------
Write-Header "Installation Summary"
$Summary | Format-Table -AutoSize

Write-Success "Font installation completed."
Write-Warn "Restart applications if fonts do not appear immediately."
