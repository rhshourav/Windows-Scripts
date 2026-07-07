<#
  Disable-OpenFileSecurityWarning-ForIP.ps1

  Purpose:
    Permanently suppress "Open File - Security Warning" for executables launched from a specific UNC host
    by:
      1) Assigning the IP to a Security Zone (Trusted Sites by default)
      2) Setting URLACTION 1806 for that zone to Enable (0)

  Notes:
    - Default scope: Current user (HKCU)
    - Optional scope: Machine (HKLM) with -Scope Machine (requires admin)
    - Optional: Remove Mark-of-the-Web from files on the share using -UnblockPath

  Usage examples:
    # Current user, Trusted Sites, disable prompt:
    .\Disable-OpenFileSecurityWarning-ForIP.ps1 -Ip 192.168.18.201

    # Machine-wide (admin), Trusted Sites:
    .\Disable-OpenFileSecurityWarning-ForIP.ps1 -Ip 192.168.18.201 -Scope Machine

    # Also unblock files in the share (removes Zone.Identifier ADS):
    .\Disable-OpenFileSecurityWarning-ForIP.ps1 -Ip 192.168.18.201 -UnblockPath "\\192.168.18.201\it" -Recurse

    # Undo:
    .\Disable-OpenFileSecurityWarning-ForIP.ps1 -Ip 192.168.18.201 -Remove
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$false)]
  [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
  [string]$Ip = "192.168.18.201",

  [Parameter(Mandatory=$false)]
  [ValidateSet("TrustedSites","Intranet")]
  [string]$Zone = "TrustedSites",

  [Parameter(Mandatory=$false)]
  [ValidateSet("User","Machine")]
  [string]$Scope = "User",

  [switch]$Remove,

  [Parameter(Mandatory=$false)]
  [string]$UnblockPath,

  [switch]$Recurse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Get-ZoneNumber([string]$z) {
  switch ($z) {
    "Intranet"     { return 1 }
    "TrustedSites" { return 2 }
    default        { throw "Unsupported zone: $z" }
  }
}

function Get-RootHive([string]$s) {
  if ($s -eq "Machine") { return "HKLM:" }
  return "HKCU:"
}

function Ensure-AdminIfNeeded {
  if ($Scope -eq "Machine" -and -not (Test-IsAdmin)) {
    throw "Scope=Machine requires an elevated PowerShell (Run as Administrator)."
  }
}

function RangeKeyNameFromIp([string]$ip) {
  # Deterministic key name so we can update/remove cleanly
  return "Range_" + ($ip -replace '\.','_')
}

function Set-IpToZone {
  param(
    [Parameter(Mandatory)][string]$HiveRoot,  # HKCU: or HKLM:
    [Parameter(Mandatory)][string]$ip,
    [Parameter(Mandatory)][int]$zoneNum
  )

  $rangesBase = Join-Path $HiveRoot "Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges"
  $rangeKey   = Join-Path $rangesBase (RangeKeyNameFromIp $ip)

  if ($PSCmdlet.ShouldProcess("$rangeKey", "Create/Update IP-to-zone mapping")) {
    New-Item -Path $rangesBase -Force | Out-Null
    New-Item -Path $rangeKey -Force | Out-Null

    New-ItemProperty -Path $rangeKey -Name ":Range" -Value $ip -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $rangeKey -Name "*"      -Value $zoneNum -PropertyType DWord -Force | Out-Null
  }

  return $rangeKey
}

function Remove-IpFromZone {
  param(
    [Parameter(Mandatory)][string]$HiveRoot,
    [Parameter(Mandatory)][string]$ip
  )

  $rangesBase = Join-Path $HiveRoot "Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges"
  $rangeKey   = Join-Path $rangesBase (RangeKeyNameFromIp $ip)

  if (Test-Path $rangeKey) {
    if ($PSCmdlet.ShouldProcess("$rangeKey", "Remove IP-to-zone mapping")) {
      Remove-Item -Path $rangeKey -Recurse -Force
    }
  } else {
    Write-Host "[i] Mapping key not found (already removed): $rangeKey" -ForegroundColor DarkGray
  }
}

function Set-Zone1806 {
  param(
    [Parameter(Mandatory)][string]$HiveRoot,
    [Parameter(Mandatory)][int]$zoneNum,
    [Parameter(Mandatory)][int]$value
  )

  $zoneKey = Join-Path $HiveRoot "Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\$zoneNum"

  if ($PSCmdlet.ShouldProcess("$zoneKey", "Set 1806=$value")) {
    New-Item -Path $zoneKey -Force | Out-Null
    Set-ItemProperty -Path $zoneKey -Name 1806 -Type DWord -Value $value
  }
}

function Unblock-FilesAtPath {
  param(
    [Parameter(Mandatory)][string]$path,
    [switch]$recurse
  )

  if (-not (Test-Path $path)) {
    throw "UnblockPath not found or not reachable: $path"
  }

  $files = if ($recurse) {
    Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction Stop |
      Where-Object { $_.Extension -in ".exe",".msi",".bat",".cmd",".ps1" }
  } else {
    Get-ChildItem -LiteralPath $path -File -ErrorAction Stop |
      Where-Object { $_.Extension -in ".exe",".msi",".bat",".cmd",".ps1" }
  }

  $count = 0
  foreach ($f in $files) {
    try {
      # Unblock-File removes Zone.Identifier if present (safe no-op otherwise)
      Unblock-File -LiteralPath $f.FullName -ErrorAction SilentlyContinue
      $count++
    } catch {}
  }

  Write-Host "[OK] Unblock attempted on $count file(s) under: $path" -ForegroundColor Green
}

# -----------------------------
# Main
# -----------------------------
Ensure-AdminIfNeeded

$zoneNum = Get-ZoneNumber $Zone
$hive    = Get-RootHive $Scope

if ($Remove) {
  Remove-IpFromZone -HiveRoot $hive -ip $Ip
  Write-Host "[OK] Removed zone mapping for $Ip ($Scope)." -ForegroundColor Green
  exit 0
}

$rk = Set-IpToZone -HiveRoot $hive -ip $Ip -zoneNum $zoneNum

# 1806: Launching applications and unsafe files
# 0 = Enable (permit; no prompt), 1 = Prompt, 3 = Disable
Set-Zone1806 -HiveRoot $hive -zoneNum $zoneNum -value 0

Write-Host "[OK] Applied:" -ForegroundColor Green
Write-Host "     IP      : $Ip" -ForegroundColor Green
Write-Host "     Zone    : $Zone ($zoneNum)" -ForegroundColor Green
Write-Host "     Scope   : $Scope ($hive)" -ForegroundColor Green
Write-Host "     RangeKey: $rk" -ForegroundColor DarkGray
Write-Host ""
Write-Host "[i] If the warning still appears, the files likely have Mark-of-the-Web." -ForegroundColor Yellow
Write-Host "    Run again with -UnblockPath '\\$Ip\it' (-Recurse if needed)." -ForegroundColor Yellow

if ($UnblockPath) {
  Unblock-FilesAtPath -path $UnblockPath -recurse:$Recurse
}

Write-Host ""
Write-Host "[i] You may need to close/reopen Explorer (or sign out/in) for changes to fully reflect." -ForegroundColor DarkGray
