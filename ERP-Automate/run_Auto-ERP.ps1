# ============================================================
# Oracle Instant Client Installer
# With COM Auto-Detection, Progress Bars, and Colorful Output
# ============================================================

$ErrorActionPreference = "Stop"

# -----------------------------
# Configuration
# -----------------------------
$SourceShare      = "\\192.168.16.251\erp"
$InstantClientDir = "instantclient_10_2"
$OracleDir        = "C:\Program Files\$InstantClientDir"
$SourceOracle     = Join-Path $SourceShare $InstantClientDir

$SourceDll = Join-Path $SourceShare "XceedZip.dll"
$DestDll   = "C:\Windows\XceedZip.dll"

# -----------------------------
# Color Helpers
# -----------------------------
function Write-Header($Text) { Write-Host ""; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Step($Text)   { Write-Host "[*] $Text" -ForegroundColor White }
function Write-Success($Text){ Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Warn($Text)   { Write-Host "[!] $Text" -ForegroundColor Yellow }
function Write-Verify($Text) { Write-Host "[VERIFIED] $Text" -ForegroundColor DarkGreen }

# -----------------------------
# Admin Check
# -----------------------------
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

# -----------------------------
# PATH Handling
# -----------------------------
function Add-ToSystemPath {
    param([string]$Entry)
    $entry = $Entry.TrimEnd('\')
    $path  = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = $path.Split(";") | ForEach-Object { $_.TrimEnd('\') }
    if ($parts -notcontains $entry) {
        $newPath = $path.TrimEnd(";") + ";" + $entry
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Step "Added '$entry' to system PATH"
    }
    else { Write-Step "'$entry' already exists in system PATH" }
}

# -----------------------------
# Validation
# -----------------------------
function Verify-SystemVariable { param([string]$Name, [string]$Expected)
    $actual = [Environment]::GetEnvironmentVariable($Name, "Machine")
    if (-not $actual) { throw "System variable '$Name' is missing." }
    if ($actual.TrimEnd('\') -ne $Expected.TrimEnd('\')) {
        throw "System variable '$Name' mismatch. Expected '$Expected', found '$actual'."
    }
    Write-Verify "$Name = $actual"
}

function Verify-SystemPath { param([string]$ExpectedEntry)
    $expected = $ExpectedEntry.TrimEnd('\')
    $path = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = $path.Split(";") | ForEach-Object { $_.TrimEnd('\') }
    $count = ($parts | Where-Object { $_ -eq $expected }).Count
    if ($count -eq 0) { throw "PATH does not contain '$expected'." }
    elseif ($count -gt 1) { throw "PATH contains duplicate entries for '$expected'." }
    Write-Verify "PATH contains '$expected' exactly once"
    if ($path.Length -gt 1800) { Write-Warn "PATH length is $($path.Length) characters (near limit)" }
}

# -----------------------------
# COM Detection
# -----------------------------
if (-not ([System.Management.Automation.PSTypeName]'NativeMethods')) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr LoadLibrary(string lpFileName);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    [DllImport("kernel32.dll")]
    public static extern bool FreeLibrary(IntPtr hModule);
}
"@
}
function Test-ComDll { param([string]$DllPath)
    if (-not (Test-Path $DllPath)) { return $false }
    $hModule = [NativeMethods]::LoadLibrary($DllPath)
    if ($hModule -eq [IntPtr]::Zero) { return $false }
    $proc = [NativeMethods]::GetProcAddress($hModule, "DllRegisterServer")
    [NativeMethods]::FreeLibrary($hModule)
    return ($proc -ne [IntPtr]::Zero)
}

# -----------------------------
# Start
# -----------------------------
Write-Header "Oracle Instant Client Installer"
Assert-Admin

if (-not (Test-Path $SourceOracle)) { throw "Source path not found: $SourceOracle" }
if (-not (Test-Path $SourceDll))    { throw "Source DLL not found: $SourceDll" }

# -----------------------------
# Copy Oracle Instant Client (Progress)
# -----------------------------
if (-not (Test-Path $OracleDir)) {
    Write-Step "Copying Oracle Instant Client (this may take a moment)..."

    # Get all files recursively
    $files = Get-ChildItem -Path $SourceOracle -Recurse -File
    $total = $files.Count; $count = 0

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($SourceOracle.Length).TrimStart('\')
        $destPath = Join-Path $OracleDir $relative
        $destDir  = Split-Path $destPath
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        Copy-Item -Path $file.FullName -Destination $destPath -Force
        $count++
        Write-Progress -Activity "Copying Oracle Instant Client" `
                       -Status "$count of $total files" `
                       -PercentComplete (($count/$total)*100)
    }

    Write-Progress -Activity "Copying Oracle Instant Client" -Completed
    Write-Success "Oracle Instant Client copied"
} else { Write-Warn "Oracle Instant Client already exists" }

# -----------------------------
# Copy DLL (Progress)
# -----------------------------
Write-Step "Copying XceedZip.dll..."
$size = (Get-Item $SourceDll).Length; $copied = 0; $buffer = 4MB
$in  = [IO.File]::OpenRead($SourceDll)
$out = [IO.File]::Create($DestDll)
$buf = New-Object byte[] $buffer
while (($read = $in.Read($buf,0,$buf.Length)) -gt 0) {
    $out.Write($buf,0,$read); $copied += $read
    $percent = [math]::Round(($copied/$size)*100,0)
    Write-Progress -Activity "Copying XceedZip.dll" -Status "$percent% Complete" -PercentComplete $percent
}
$in.Close(); $out.Close()
Write-Progress -Activity "Copying XceedZip.dll" -Completed
Write-Success "XceedZip.dll copied"

# -----------------------------
# COM Auto-Register
# -----------------------------
if (Test-ComDll $DestDll) {
    Write-Step "XceedZip.dll supports COM. Registering..."
    $proc = Start-Process "$env:windir\System32\regsvr32.exe" -ArgumentList "/s `"$DestDll`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "DLL registration failed (exit code $($proc.ExitCode))" }
    Write-Success "XceedZip.dll registered successfully"
} else { Write-Warn "XceedZip.dll does not support COM. Registration skipped." }

# -----------------------------
# Environment Variables
# -----------------------------
Write-Step "Configuring system environment variables..."
[Environment]::SetEnvironmentVariable("TNS_ADMIN",  $OracleDir, "Machine")
[Environment]::SetEnvironmentVariable("ORACLE_HOME", $OracleDir, "Machine")
Add-ToSystemPath $OracleDir

# -----------------------------
# Verification
# -----------------------------
Write-Header "Validating system configuration..."
Verify-SystemVariable "TNS_ADMIN"  $OracleDir
Verify-SystemVariable "ORACLE_HOME" $OracleDir
Verify-SystemPath $OracleDir

# -----------------------------
# Done
# -----------------------------
Write-Host ""
Write-Success "Installation completed successfully."
Write-Warn "Log off or restart required for PATH changes to apply."
