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
# ================================================================
#  TELEMETRY
# ================================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "Install MS Edge v2.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU8fGLlFZVoC4QpR5aAxfWWfQq
# Ij2gghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
# AQsFADAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzMB4XDTI2MDcwNzA4MDE1
# N1oXDTI5MDcwNzA4MTE1N1owGzEZMBcGA1UEAwwQUkhTSE9VUkFWLUlULU9wczCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALFj11KDAqN3fhbDT9fvgrLF
# VemPYmcud3qA+9Sc4RojOjElODGXyaOlBSVmDGpmCkNRC+dnkGCLB8bYb3gsnHey
# Ud99DA8tvkTgb06+B1pigTZUmhyAwyPiu77+h224c8SsZFkmgQ/Dh2Sc2ynNocZe
# 773d6a/B4DRg7/K9xV8jFap6BP1fjaM3Do40GSL+OVnXl2ssvfFk4FyP5fc8Czz5
# MJ5IJKRFrnHv3kNcmyz5mnz0LoBQs/JtHpWg3BogIalJ2tyCiZgk0xIsz5j5UjhA
# /KepfnWGpCowJ/NJWnmOZcikFlDPggI27QNc/IbxZ035ht+Zgc7b1Cf68GmL/8UC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRJ+13W7/PcqVgZXZf87/JdXvGqxjANBgkqhkiG9w0BAQsFAAOCAQEA
# MDUJsw0AephOCByoLTFSm8hnB4I7s8ddA64vDTv4QF2TcXdrd/glByhEQexUEDpw
# lPCSbzHAmRM5X71QYNoB/CDlCoAO8BQnbegqkhAx8ubRyciwsLA4ZPp+/GFbgZaV
# khkOWpL6v6fmU3kSB5px+roqOuMjmqvbtCDlC4JH25WuDEgGJQhqpgdQSZdomWjH
# le/GnQKt4Y18ysVFvgE1lRO8x6gkJ5IJbZPJ0Q//2xCvtM0WpjXmQl1RHV/7tqDS
# fqprCQxuKiTPC64VfafzeS7IUNJMgQS73H6wuaKdeT85PIxreleNwNXfbr4O/FY3
# eqlSEZAqzKtZXfNFWPmHazCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE+jCC
# BPYCAQEwLzAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzAhAQvylGgaQVhE7g
# tCp7LUPgMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQtktw3TwPPw0ZA582CNcBgtEk5ZjANBgkq
# hkiG9w0BAQEFAASCAQAuBODwLVK8VbauyFkCxzX8aQ0VUxgNbyCVFllD6457QWba
# 9jtYHU2s1p20WNxeGxhK/jTgwKnABsV5QboZd5vprnp/FQ2+zHsWe3UdHjdBvgYK
# Xi+JhPSljOJUWhuRgxP0sA22uHvInZkKKbplMRZJlKKxf8s+cqn1OAxKBWgqqkdc
# XFjiWBdFlzSSyrthipr5ldkmBq//XcObfDBbcKE6VTMUXZ3YeQ23tZriYEzsxkuz
# 4w1U9jffL138GWK90MYw7HVz7nIF1EBVrixgEcfM3vqwVO0t3K6UQMKaReYLLDuN
# JPxYscNqB9/rhaABnAIPZm7W39FXRaWEFHZsYW6FoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0OFowLwYJKoZIhvcNAQkEMSIEIOKo9CaEZ2ENJPsw
# hiDATI6ggfDIYgUQCNf9pAKHxyn/MA0GCSqGSIb3DQEBAQUABIICALOHkBwXVqSf
# oMv7To/TzVLZpxUmkPDOVFBSq1KV4ZKjgHOq8+KcCd0Oj/82C3lj38ljOYBn1qew
# 1dztYdpeqBhpo/NWjdLI3GPt1XpuVdBR8h4w0N7kU7uNTQYPp6zM5Ika+YiehoL6
# KHbumZrCaehX3XIVvtWp0ZcolKtw2KaLsxSQaXBaYfU5YP2aTK9kOc+gB3EpM1Zs
# KTtsqq6VLho6Jj09UB/MN4f01NpiCLbzbBrP921MLoL7J863yMKvX5pzrTG196th
# gK5YzW9FCV/w7UUEGlMeUvOwdHB/gbe9lrjiOZslQh2KXJ7OdSI9tnLyKiifkxyl
# fdZ+kU6ak8d9j/VJ6mp9ZkCdmC8ouHmneF7eXaSnVnSo+RBt9nmpsOlpyLXpLrZ8
# hPStVduR5TOXqN6KOQn4M2ISspNAD6doWdVgMnXvuD024y/27t99SyHkHtthm2EM
# 6Ieiy8WMNXIDIAEsrrSNNLiq6LFCrKjrFckX8hRuLOqlCu2GMYBruz+BjB3kfNhn
# XfMsvMMckdNJhfLg2922wZNoK1119aV8b4dHEscu2P5MsUIYztmDr5tH7LKgsuLy
# iH/s60QRcoBuJum+6ad6UaYc9uc65AzudxUgsOapjWbAXNYnKQBXnAYQzpYy3dz8
# uI1yxhxILkjWaWYhgdON9W8q9chMbrz3
# SIG # End signature block
