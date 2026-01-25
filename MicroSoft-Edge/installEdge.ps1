<#
  Windows-Scripts | Install Microsoft Edge (Stable) - Silent
  Supports: Windows 10 19H1 (1903) -> Windows 11 current | PowerShell 5.1+
  Author : Shourav
  GitHub : https://github.com/rhshourav
  Version: 1.0.1

  - No GUI wizard (MSI quiet mode)
  - No prompts / no "press enter"
  - WebView2 is NOT installed by this script

  Exit codes:
    0  = success (or already installed)
    1  = not admin / cannot elevate
    2  = unsupported OS version
    3  = download failed / unsupported arch
    4  = signature validation failed
    5  = install failed
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -----------------------------
# UI / Theme
# -----------------------------
$C_OK="Green"; $C_WARN="Yellow"; $C_ERR="Red"; $C_INFO="Cyan"; $C_DIM="DarkGray"; $C_MAIN="White"

function Set-Theme {
    try {
        $raw = $Host.UI.RawUI
        $raw.BackgroundColor = "Black"
        $raw.ForegroundColor = "Gray"
        $raw.WindowTitle = "Windows-Scripts | Edge Silent Installer"
        Clear-Host
    } catch {}
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
}

function Log([string]$msg, [string]$color="Gray") { Write-Host $msg -ForegroundColor $color }

# -----------------------------
# Admin / OS checks
# -----------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Elevate-Self {
    if (Test-Admin) { return $true }

    Log "[!] Not running as Administrator. Relaunching elevated..." $C_WARN
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args | Out-Null
        return $false
    } catch {
        Log "[!] Elevation failed: $($_.Exception.Message)" $C_ERR
        return $false
    }
}

function Test-Win10_1903_OrNewer {
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    return ($build -ge 18362) # 1903
}

# -----------------------------
# Safe property getters (StrictMode-proof)
# -----------------------------
function Get-PropValue {
    param(
        [Parameter(Mandatory=$true)]$Obj,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# -----------------------------
# Detect Edge (StrictMode-safe)
# -----------------------------
function Get-InstalledEdgeVersion {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($p in $paths) {
        $items = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        foreach ($i in @($items)) {
            $dn = Get-PropValue -Obj $i -Name "DisplayName"
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }

            # We only care about Edge (Stable/Enterprise). Ignore WebView2 and EdgeUpdate.
            if ($dn -notmatch '^Microsoft Edge') { continue }
            if ($dn -match 'WebView2|Update') { continue }

            $pub = Get-PropValue -Obj $i -Name "Publisher"
            if ($pub -and ($pub -notmatch 'Microsoft')) { continue }

            $dv = Get-PropValue -Obj $i -Name "DisplayVersion"
            if ($dv) { return $dv }
        }
    }

    return $null
}

# -----------------------------
# Download helpers
# -----------------------------
function Download-File {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutFile
    )

    if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }

    try {
        # BITS is more resilient; may fail if BITS disabled by policy.
        Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
        return $true
    } catch {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
}

function Test-MicrosoftSignature {
    param([Parameter(Mandatory=$true)][string]$Path)

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($null -eq $sig) { return $false }
    if ($sig.Status -ne "Valid") { return $false }

    $subject = ""
    try { $subject = $sig.SignerCertificate.Subject } catch {}
    return ($subject -match "Microsoft")
}

# -----------------------------
# Install
# -----------------------------
function Install-EdgeMsiSilent {
    param(
        [Parameter(Mandatory=$true)][string]$MsiPath,
        [Parameter(Mandatory=$true)][string]$LogPath
    )

    $args = @(
        "/i", "`"$MsiPath`"",
        "/qn",
        "/norestart",
        "/l*v", "`"$LogPath`""
    )

    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

# -----------------------------
# Main
# -----------------------------
Set-Theme
Log "======================================================================" $C_INFO
Log " Windows-Scripts | Install Microsoft Edge (Stable) - Silent  v1.0.1"   $C_INFO
Log " Author: Shourav | GitHub: github.com/rhshourav"                       $C_DIM
Log "======================================================================" $C_INFO
Log "" $C_DIM

if (-not (Elevate-Self)) { exit 1 }
if (-not (Test-Win10_1903_OrNewer)) {
    Log "[!] Unsupported OS. Need Windows 10 1903 (build 18362) or newer." $C_ERR
    exit 2
}

$arch = $env:PROCESSOR_ARCHITECTURE
Log "[i] Architecture: $arch" $C_DIM

$existing = Get-InstalledEdgeVersion
if ($existing) {
    Log "[i] Edge detected (version: $existing). Will silently repair/upgrade." $C_DIM
} else {
    Log "[i] Edge not detected. Installing silently..." $C_DIM
}

# Official Enterprise MSI permalinks (Stable)
# X64: LinkID=2093437, X86: LinkID=2093505
$msiUrl = $null
switch -Regex ($arch) {
    "ARM64" {
        Log "[!] ARM64 detected. Provide an ARM64 Edge Enterprise MSI URL to enable this path." $C_WARN
        exit 3
    }
    "AMD64|x64" { $msiUrl = "https://go.microsoft.com/fwlink/?LinkID=2093437" }
    default     { $msiUrl = "https://go.microsoft.com/fwlink/?LinkID=2093505" }
}

$tempDir = Join-Path $env:TEMP "Windows-Scripts_EdgeInstall"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$msiPath = Join-Path $tempDir "MicrosoftEdgeEnterprise.msi"
$msiLog  = Join-Path $tempDir ("EdgeInstall_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

Log "[i] Downloading MSI..." $C_INFO
Log "    $msiUrl" $C_DIM

if (-not (Download-File -Url $msiUrl -OutFile $msiPath)) {
    Log "[!] Download failed." $C_ERR
    exit 3
}

Log "[i] Validating signature..." $C_INFO
if (-not (Test-MicrosoftSignature -Path $msiPath)) {
    Log "[!] MSI signature validation failed. Aborting." $C_ERR
    exit 4
}

Log "[i] Installing silently (no GUI)..." $C_INFO
$code = Install-EdgeMsiSilent -MsiPath $msiPath -LogPath $msiLog

if ($code -eq 0) {
    Log "[+] Edge install completed successfully." $C_OK
    $ver = Get-InstalledEdgeVersion
    if ($ver) { Log "[+] Installed version: $ver" $C_OK }
    Log "[i] MSI log: $msiLog" $C_DIM
    exit 0
} else {
    Log "[!] Install failed. ExitCode: $code" $C_ERR
    Log "[i] MSI log: $msiLog" $C_DIM
    exit 5
}
