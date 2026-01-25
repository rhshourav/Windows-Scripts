<#
  Edge-Recover.ps1 (PowerShell 5.1-safe) - Install + Repair
  - Enables EdgeUpdate services
  - Auto-installs WebView2 if missing (or reinstalls)
  - Installs or Repairs Edge via Enterprise MSI
  - If msedge.exe still missing, falls back to Setup EXE
  - Verifies msedge.exe exists; launches if requested

  Usage:
    .\Edge-Recover.ps1
    .\Edge-Recover.ps1 -Action Install
    .\Edge-Recover.ps1 -Action Repair -DeepRepair
    .\Edge-Recover.ps1 -ReinstallWebView2
    .\Edge-Recover.ps1 -NoLaunch

  Exit codes:
    0 = success (or elevation handoff)
    1 = cannot elevate / not run from file
    3 = download/validation failure
    4 = signature validation failed
    5 = Edge still missing after MSI + EXE attempt
#>

[CmdletBinding()]
param(
  [ValidateSet("Install","Repair")]
  [string]$Action = "Repair",

  [switch]$DeepRepair,
  [switch]$NoLaunch,
  [switch]$ReinstallWebView2,
  [switch]$UseWingetFallback
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -----------------------------
# UI / Logging
# -----------------------------
$C_OK="Green"; $C_WARN="Yellow"; $C_ERR="Red"; $C_INFO="Cyan"; $C_DIM="DarkGray"
function Log([string]$msg, [string]$color="Gray") { Write-Host $msg -ForegroundColor $color }

function Set-Theme {
  try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = "Black"
    $raw.ForegroundColor = "Gray"
    $raw.WindowTitle = "Edge Recovery Installer"
    Clear-Host
  } catch {}
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
}

# -----------------------------
# Admin / Elevation
# -----------------------------
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptPath {
  $p = $PSCommandPath
  if (-not $p) { $p = $MyInvocation.MyCommand.Path }
  return $p
}

function Get-NativePowerShellExe {
  if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    return Join-Path $env:WINDIR "SysNative\WindowsPowerShell\v1.0\powershell.exe"
  }
  return Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Elevate-Self {
  if (Test-Admin) { return $true }

  $scriptPath = Get-ScriptPath
  if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path $scriptPath)) {
    Log "[!] Cannot self-elevate: script must be saved as a .ps1 file." $C_ERR
    return $false
  }

  Log "[!] Not running as Administrator. Relaunching elevated..." $C_WARN
  $psExe = Get-NativePowerShellExe
  $args  = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$scriptPath`"")
  $args += @("-Action",$Action)
  if ($DeepRepair) { $args += "-DeepRepair" }
  if ($NoLaunch) { $args += "-NoLaunch" }
  if ($ReinstallWebView2) { $args += "-ReinstallWebView2" }
  if ($UseWingetFallback) { $args += "-UseWingetFallback" }

  Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $args | Out-Null
  exit 0
}

# -----------------------------
# Helpers
# -----------------------------
function Get-OSInfo {
  $os = Get-CimInstance Win32_OperatingSystem
  [pscustomobject]@{
    Caption = $os.Caption
    Version = $os.Version
    Build   = [int]$os.BuildNumber
    Arch    = $os.OSArchitecture
  }
}

function Get-NativeArch {
  if (-not [Environment]::Is64BitOperatingSystem) { return "x86" }
  return "x64"
}

function Get-RegValueSafe {
  param([string]$Path, [string]$Name)
  try {
    $v = Get-ItemProperty -Path $Path -ErrorAction Stop
    $p = $v.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
  } catch { return $null }
}

function Download-File {
  param([string]$Url, [string]$OutFile, [int]$Retries = 3)

  if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }

  for ($i=1; $i -le $Retries; $i++) {
    try {
      Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
      return $true
    } catch {
      try {
        $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $headers -MaximumRedirection 10 -UseBasicParsing -ErrorAction Stop
        return $true
      } catch {
        if ($i -lt $Retries) { Start-Sleep -Seconds (2 * $i) }
      }
    }
  }
  return $false
}

function Test-OleHeader {
  param([string]$Path)
  try {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      $buf = New-Object byte[] 8
      [void]$fs.Read($buf, 0, 8)
      $hex = ($buf | ForEach-Object { $_.ToString("X2") }) -join " "
      return ($hex -eq "D0 CF 11 E0 A1 B1 1A E1")
    } finally { $fs.Dispose() }
  } catch { return $false }
}

function Test-FileLooksValid {
  param([string]$Path, [ValidateSet("MSI","EXE")] [string]$Type)
  if (-not (Test-Path $Path)) { return $false }
  $fi = Get-Item $Path -ErrorAction SilentlyContinue
  if ($null -eq $fi) { return $false }
  if ($fi.Length -lt 1MB) { return $false }
  if ($Type -eq "MSI") { return (Test-OleHeader -Path $Path) }
  return $true
}

function Test-MicrosoftSignature {
  param([string]$Path)
  $sig = Get-AuthenticodeSignature -FilePath $Path
  if ($null -eq $sig) { return $false }
  if ($sig.Status -ne "Valid") { return $false }
  $subject = ""
  try { $subject = $sig.SignerCertificate.Subject } catch {}
  return ($subject -match "Microsoft")
}

function Wait-ForEdgeBinary {
  param([int]$TimeoutSec = 120)

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do {
    Start-Sleep -Seconds 2
    $p = Resolve-EdgeExe
    if ($p) { return $p }
  } while ((Get-Date) -lt $deadline)

  return $null
}

# -----------------------------
# Edge / WebView2 detection
# -----------------------------
function Get-EdgeExeCandidates {
  $pfx = ${env:ProgramFiles(x86)}
  $pf  = $env:ProgramFiles

  $c = New-Object System.Collections.Generic.List[string]
  if ($pfx) { $c.Add((Join-Path $pfx "Microsoft\Edge\Application\msedge.exe")) }
  if ($pf)  { $c.Add((Join-Path $pf  "Microsoft\Edge\Application\msedge.exe")) }

  $ap1 = Get-RegValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -Name "(default)"
  $ap2 = Get-RegValueSafe -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -Name "(default)"
  if ($ap1) { $c.Add([string]$ap1) }
  if ($ap2) { $c.Add([string]$ap2) }

  return ($c | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-EdgeExe {
  $cands = Get-EdgeExeCandidates
  foreach ($p in $cands) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Get-WebView2RuntimeVersion {
  $guid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
  $paths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
    "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$guid"
  )
  foreach ($p in $paths) {
    $pv = Get-RegValueSafe -Path $p -Name "pv"
    if ($pv -and ($pv -ne "0.0.0.0") -and (-not [string]::IsNullOrWhiteSpace($pv))) { return [string]$pv }
  }
  return $null
}

# -----------------------------
# EdgeUpdate services (critical)
# -----------------------------
function Ensure-EdgeUpdateServices {
  $svcNames = @("edgeupdate","edgeupdatem")
  foreach ($s in $svcNames) {
    try {
      $svc = Get-Service -Name $s -ErrorAction Stop
      if ($svc.StartType -eq "Disabled") {
        Log "[!] Service $s is Disabled. Setting to Automatic..." $C_WARN
        sc.exe config $s start= auto | Out-Null
      }
      if ($svc.Status -ne "Running") {
        Log "[i] Starting service $s..." $C_INFO
        Start-Service -Name $s -ErrorAction SilentlyContinue
      }
    } catch {
      Log "[!] Service $s not found (it may be installed by Edge installer)." $C_WARN
    }
  }

  foreach ($s in $svcNames) {
    try {
      $svc = Get-Service -Name $s -ErrorAction Stop
      Log ("[i] {0}: {1} | StartType: {2}" -f $svc.Name, $svc.Status, $svc.StartType) $C_DIM
    } catch {}
  }
}

# -----------------------------
# Optional system-level repair
# -----------------------------
function Run-DeepRepair {
  Log "[!] DeepRepair enabled: running DISM + SFC (this can take a while)." $C_WARN
  try {
    Start-Process -FilePath "dism.exe" -ArgumentList "/Online","/Cleanup-Image","/RestoreHealth" -Wait -WindowStyle Hidden | Out-Null
    Log "[+] DISM completed." $C_OK
  } catch {
    Log "[!] DISM failed: $($_.Exception.Message)" $C_WARN
  }

  try {
    Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" -Wait -WindowStyle Hidden | Out-Null
    Log "[+] SFC completed." $C_OK
  } catch {
    Log "[!] SFC failed: $($_.Exception.Message)" $C_WARN
  }
}

# -----------------------------
# WebView2 installer
# -----------------------------
function Ensure-WebView2 {
  $before = Get-WebView2RuntimeVersion
  if ($before -and -not $ReinstallWebView2) {
    Log "[i] WebView2 detected: $before" $C_DIM
    return $true
  }

  if ($before -and $ReinstallWebView2) { Log "[i] WebView2 detected: $before (reinstalling)" $C_WARN }
  else { Log "[i] WebView2 not detected (installing)" $C_WARN }

  $tempDir = Join-Path $env:TEMP "EdgeRecover_WebView2"
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

  $url = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
  $exe = Join-Path $tempDir "MicrosoftEdgeWebView2Setup.exe"

  Log "[i] Downloading WebView2..." $C_INFO
  if (-not (Download-File -Url $url -OutFile $exe -Retries 3)) { Log "[!] WebView2 download failed." $C_ERR; return $false }
  if (-not (Test-FileLooksValid -Path $exe -Type "EXE")) { Log "[!] WebView2 installer looks invalid." $C_ERR; return $false }
  if (-not (Test-MicrosoftSignature -Path $exe)) { Log "[!] WebView2 signature validation failed." $C_ERR; exit 4 }

  Log "[i] Installing WebView2 silently..." $C_INFO
  Start-Process -FilePath $exe -ArgumentList @("/silent","/install") -WindowStyle Hidden | Out-Null

  $deadline = (Get-Date).AddSeconds(120)
  do {
    Start-Sleep -Seconds 2
    $now = Get-WebView2RuntimeVersion
    if ($now) { Log "[+] WebView2 present: $now" $C_OK; return $true }
  } while ((Get-Date) -lt $deadline)

  Log "[!] WebView2 install not confirmed after timeout." $C_WARN
  return $false
}

# -----------------------------
# Edge installers (MSI install + MSI repair + fallback EXE)
# -----------------------------
function Get-EdgeMsiUrlForArch {
  $arch = Get-NativeArch
  if ($arch -eq "x64") { return "https://go.microsoft.com/fwlink/?LinkID=2093437" }
  return "https://go.microsoft.com/fwlink/?LinkID=2093505"
}

function InstallOrRepair-Edge-MSI {
  param([ValidateSet("Install","Repair")] [string]$Mode)

  $tempDir = Join-Path $env:TEMP "EdgeRecover_Edge"
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

  $msiUrl = Get-EdgeMsiUrlForArch
  $msi = Join-Path $tempDir "MicrosoftEdgeEnterprise.msi"
  $log = Join-Path $tempDir ("EdgeMSI_{0}_{1}.log" -f $Mode, (Get-Date -Format "yyyyMMdd_HHmmss"))

  Log "[i] Downloading Edge MSI..." $C_INFO
  Log "    $msiUrl" $C_DIM

  if (-not (Download-File -Url $msiUrl -OutFile $msi -Retries 3)) { return @{Ok=$false;Log=$log;Code=-1} }
  if (-not (Test-FileLooksValid -Path $msi -Type "MSI")) { return @{Ok=$false;Log=$log;Code=-2} }
  if (-not (Test-MicrosoftSignature -Path $msi)) { Log "[!] Edge MSI signature validation failed." $C_ERR; exit 4 }

  # Install vs Repair
  $args = @()
  if ($Mode -eq "Repair") {
    # MSI repair/reinstall: REINSTALLMODE=vomus repairs files/registry/shortcuts, etc.
    $args = @("/i","`"$msi`"","REINSTALL=ALL","REINSTALLMODE=vomus","/qn","/norestart","/l*v","`"$log`"")
    Log "[i] Repairing Edge via MSI (REINSTALL=ALL REINSTALLMODE=vomus)..." $C_INFO
  } else {
    $args = @("/i","`"$msi`"","/qn","/norestart","/l*v","`"$log`"")
    Log "[i] Installing Edge via MSI..." $C_INFO
  }

  $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
  $ok = ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641 -or $p.ExitCode -eq 1638)

  return @{Ok=$ok;Log=$log;Code=$p.ExitCode}
}

function Install-Edge-SetupEXE {
  $tempDir = Join-Path $env:TEMP "EdgeRecover_Edge"
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

  $exeUrl = "https://go.microsoft.com/fwlink/?linkid=2100017&Channel=Stable"
  $exe = Join-Path $tempDir "MicrosoftEdgeSetup.exe"
  $log = Join-Path $tempDir ("EdgeSetup_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

  Log "[i] Downloading Edge Setup EXE..." $C_INFO
  Log "    $exeUrl" $C_DIM

  if (-not (Download-File -Url $exeUrl -OutFile $exe -Retries 3)) { return @{Ok=$false;Log=$log} }
  if (-not (Test-FileLooksValid -Path $exe -Type "EXE")) { return @{Ok=$false;Log=$log} }
  if (-not (Test-MicrosoftSignature -Path $exe)) { Log "[!] Edge Setup signature validation failed." $C_ERR; exit 4 }

  Log "[i] Installing/repairing Edge via Setup EXE (silent)..." $C_INFO
  $args = @("--silent","--install","--system-level","--verbose-logging","--log-file=`"$log`"")
  Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden | Out-Null

  return @{Ok=$true;Log=$log}
}

function Try-WingetFallback {
  if (-not $UseWingetFallback) { return $false }

  $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
  if (-not $wg) {
    Log "[!] Winget fallback requested but winget.exe not found." $C_WARN
    return $false
  }

  Log "[i] Winget fallback: attempting Microsoft.Edge install..." $C_INFO
  try {
    # Keep it silent; accept agreements
    $args = @(
      "install","--id","Microsoft.Edge",
      "--source","winget",
      "--silent",
      "--accept-package-agreements",
      "--accept-source-agreements"
    )
    Start-Process -FilePath $wg.Source -ArgumentList $args -Wait -WindowStyle Hidden | Out-Null
    return $true
  } catch {
    Log "[!] Winget failed: $($_.Exception.Message)" $C_WARN
    return $false
  }
}

# -----------------------------
# Launch
# -----------------------------
function Get-CurrentSessionId {
  try { return (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { return -1 }
}

function Wait-EdgeProcess {
  param([int]$SessionId, [int]$TimeoutSec = 12)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do {
    Start-Sleep -Milliseconds 500
    $p = Get-Process -Name "msedge" -ErrorAction SilentlyContinue |
         Where-Object { $_.SessionId -eq $SessionId } | Select-Object -First 1
    if ($p) { return $true }
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Launch-Edge {
  param([string]$EdgeExe)

  if (-not $EdgeExe -or -not (Test-Path $EdgeExe)) { return $false }
  $sess = Get-CurrentSessionId
  $args = "--no-first-run --new-window"

  try {
    Start-Process -FilePath $EdgeExe -ArgumentList $args | Out-Null
    if ($sess -gt 0 -and (Wait-EdgeProcess -SessionId $sess -TimeoutSec 6)) { return $true }
  } catch {}

  try {
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$EdgeExe`" $args" | Out-Null
    if ($sess -gt 0 -and (Wait-EdgeProcess -SessionId $sess -TimeoutSec 6)) { return $true }
  } catch {}

  return $false
}

# =============================
# MAIN
# =============================
Set-Theme
Log "======================================================================" $C_INFO
Log " Edge Recovery Installer (Install + Repair)                             " $C_INFO
Log "======================================================================" $C_INFO
Log "" $C_DIM

if (-not (Elevate-Self)) { exit 1 }

$os = Get-OSInfo
Log ("[i] OS: {0} | Version: {1} | Build: {2} | Arch: {3}" -f $os.Caption, $os.Version, $os.Build, $os.Arch) $C_DIM
Log ("[i] Action: {0} | SessionId: {1} | PS 64-bit: {2}" -f $Action, (Get-CurrentSessionId), [Environment]::Is64BitProcess) $C_DIM
Log "" $C_DIM

# Pre-check: if Edge exists and Action=Install, do nothing; if Action=Repair, run repair anyway.
$edgeExe = Resolve-EdgeExe
if ($edgeExe -and $Action -eq "Install") {
  Log "[+] Edge already present: $edgeExe" $C_OK
  if (-not $NoLaunch) { [void](Launch-Edge -EdgeExe $edgeExe) }
  exit 0
}

# System repair (optional)
if ($DeepRepair) {
  Run-DeepRepair
  Log "" $C_DIM
}

# Ensure EdgeUpdate services (some environments require these)
Ensure-EdgeUpdateServices
Log "" $C_DIM

# Ensure WebView2 (auto)
$wvOk = Ensure-WebView2
if (-not $wvOk) { Log "[!] WebView2 did not confirm (continuing anyway)." $C_WARN }
Log "" $C_DIM

# MSI install/repair
$r1 = InstallOrRepair-Edge-MSI -Mode $Action
Log ("[i] Edge MSI exit: {0} | Log: {1}" -f $r1.Code, $r1.Log) $C_DIM

$edgeExe = Wait-ForEdgeBinary -TimeoutSec 120
if (-not $edgeExe) {
  Log "[!] After MSI, msedge.exe is still missing. Falling back to Setup EXE..." $C_WARN
  $r2 = Install-Edge-SetupEXE
  Log ("[i] Edge Setup log: {0}" -f $r2.Log) $C_DIM

  $edgeExe = Wait-ForEdgeBinary -TimeoutSec 240
}

# Optional winget fallback
if (-not $edgeExe) {
  $didWinget = Try-WingetFallback
  if ($didWinget) { $edgeExe = Wait-ForEdgeBinary -TimeoutSec 240 }
}

# Final verify
$edgeExe = Resolve-EdgeExe
if (-not $edgeExe) {
  Log "[!] Edge is still not present on disk after MSI + Setup EXE." $C_ERR
  Log "[i] This is almost certainly policy/EDR removal or hardening. Evidence on your machine already shows registry points to a non-existent file." $C_DIM
  Log "" $C_DIM
  Log "[i] Run these and inspect for blocks/removals:" $C_INFO
  Log "    Get-WinEvent -LogName Microsoft-Windows-CodeIntegrity/Operational -MaxEvents 50 | Select TimeCreated,Id,Message" $C_DIM
  Log "    Get-WinEvent -LogName Microsoft-Windows-AppLocker/EXE and DLL -MaxEvents 50 | Select TimeCreated,Id,Message" $C_DIM
  Log "    Windows Security -> Protection history (look for Edge/EdgeUpdate removals)" $C_DIM
  exit 5
}

Log "[+] Edge present: $edgeExe" $C_OK
try { Log "[+] Edge version: $((Get-Item $edgeExe).VersionInfo.ProductVersion)" $C_OK } catch {}

if (-not $NoLaunch) {
  if (Launch-Edge -EdgeExe $edgeExe) { Log "[+] Edge launch confirmed." $C_OK }
  else { Log "[!] Edge did not launch (possible pending reboot or policy)." $C_WARN }
} else {
  Log "[i] Launch skipped." $C_DIM
}

exit 0
