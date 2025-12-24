# ============================================================
# Oracle Instant Client Installer
# With COM Auto-Detection for XceedZip.dll
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
        Write-Host "Added '$entry' to system PATH"
    }
    else {
        Write-Host "'$entry' already exists in system PATH"
    }
}

# -----------------------------
# Validation
# -----------------------------
function Verify-SystemVariable {
    param([string]$Name, [string]$Expected)

    $actual = [Environment]::GetEnvironmentVariable($Name, "Machine")

    if (-not $actual) {
        throw "System variable '$Name' is missing."
    }

    if ($actual.TrimEnd('\') -ne $Expected.TrimEnd('\')) {
        throw "System variable '$Name' mismatch. Expected '$Expected', found '$actual'."
    }

    Write-Host "Verified $Name = $actual"
}

function Verify-SystemPath {
    param([string]$ExpectedEntry)

    $expected = $ExpectedEntry.TrimEnd('\')
    $path = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = $path.Split(";") | ForEach-Object { $_.TrimEnd('\') }

    $count = ($parts | Where-Object { $_ -eq $expected }).Count

    if ($count -eq 0) {
        throw "PATH does not contain '$expected'."
    }
    elseif ($count -gt 1) {
        throw "PATH contains duplicate entries for '$expected'."
    }

    Write-Host "Verified PATH contains '$expected' exactly once"

    if ($path.Length -gt 1800) {
        Write-Host "WARNING: PATH length is $($path.Length) characters (near limit)"
    }
}

# -----------------------------
# COM Detection
# -----------------------------
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

function Test-ComDll {
    param([string]$DllPath)

    if (-not (Test-Path $DllPath)) {
        return $false
    }

    $hModule = [NativeMethods]::LoadLibrary($DllPath)
    if ($hModule -eq [IntPtr]::Zero) {
        return $false
    }

    $proc = [NativeMethods]::GetProcAddress($hModule, "DllRegisterServer")
    [NativeMethods]::FreeLibrary($hModule)

    return ($proc -ne [IntPtr]::Zero)
}

# -----------------------------
# Start
# -----------------------------
Write-Host "=== Oracle Instant Client Installer ==="
Assert-Admin

if (-not (Test-Path $SourceOracle)) {
    throw "Source path not found: $SourceOracle"
}
if (-not (Test-Path $SourceDll)) {
    throw "Source DLL not found: $SourceDll"
}

# -----------------------------
# Copy Oracle Instant Client
# -----------------------------
if (-not (Test-Path $OracleDir)) {
    Write-Host "Copying Oracle Instant Client..."
    Copy-Item -Path $SourceOracle -Destination "C:\Program Files" -Recurse
    Write-Host "Oracle Instant Client copied"
}
else {
    Write-Host "Oracle Instant Client already exists"
}

# -----------------------------
# Copy DLL
# -----------------------------
Write-Host "Copying XceedZip.dll..."
Copy-Item -Path $SourceDll -Destination $DestDll -Force
Write-Host "XceedZip.dll copied"

# -----------------------------
# COM Auto-Register
# -----------------------------
if (Test-ComDll $DestDll) {

    Write-Host "XceedZip.dll supports COM. Registering..."

    $regsvr32 = "$env:windir\System32\regsvr32.exe"

    $proc = Start-Process `
        -FilePath $regsvr32 `
        -ArgumentList "/s `"$DestDll`"" `
        -Wait `
        -PassThru

    if ($proc.ExitCode -ne 0) {
        throw "DLL registration failed (exit code $($proc.ExitCode))"
    }

    Write-Host "XceedZip.dll registered successfully"
}
else {
    Write-Host "XceedZip.dll does NOT support COM. Registration skipped."
}

# -----------------------------
# Environment Variables
# -----------------------------
Write-Host "Configuring system environment variables..."

[Environment]::SetEnvironmentVariable("TNS_ADMIN",  $OracleDir, "Machine")
[Environment]::SetEnvironmentVariable("ORACLE_HOME", $OracleDir, "Machine")

Add-ToSystemPath $OracleDir

# -----------------------------
# Verification
# -----------------------------
Write-Host "Validating system configuration..."

Verify-SystemVariable "TNS_ADMIN"  $OracleDir
Verify-SystemVariable "ORACLE_HOME" $OracleDir
Verify-SystemPath $OracleDir

# -----------------------------
# Done
# -----------------------------
Write-Host ""
Write-Host "Installation completed successfully."
Write-Host "Log off or restart required for PATH changes to apply."
