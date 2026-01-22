<#
.SYNOPSIS
  IPv4 Configurator (USL profile / Custom / DHCP) + IPv6 toggle (PS 5.1 compatible)

.DESCRIPTION
  - Shows current adapter configuration (IPv4, gateway, DNS, DHCP, IPv6 binding)
  - Lets you select:
      1) USL profile (preconfigured; asks for host IP last octet or full IP)
      2) Custom static IPv4 (full control)
      3) DHCP (IPv4 + DNS reset)
  - Optionally enable/disable IPv6 on the chosen adapter
  - Auto-corrects common input mistakes (spaces/commas/extra dots)
  - Always confirms before applying changes

.AUTHOR
  Shourav (rhshourav)
.GITHUB
  https://github.com/rhshourav
.VERSION
  1.0.1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# -----------------------------
# Helpers (UI)
# -----------------------------
function Write-Line { Write-Host ("=" * 78) -ForegroundColor DarkCyan }
function Write-Head([string]$t) { Write-Line; Write-Host $t -ForegroundColor Cyan; Write-Line }
function Write-Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Gray }
function Write-OK  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "[-] $m" -ForegroundColor Red }

function Confirm-YesNo([string]$Prompt) {
  while ($true) {
    $ans = (Read-Host ($Prompt + " [y/N]")).Trim().ToLowerInvariant()
    if ($ans -eq "y" -or $ans -eq "yes") { return $true }
    if ($ans -eq "n" -or $ans -eq "no" -or $ans -eq "") { return $false }
    Write-Warn "Please enter y or n."
  }
}

# -----------------------------
# Admin / Elevation
# -----------------------------
function Is-Admin {
  $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $wp.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Is-Admin)) {
  Write-Warn "Administrator rights are required. Elevating..."
  Start-Process powershell -Verb RunAs -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
  )
  exit
}

# -----------------------------
# IPv4 parsing/validation
# -----------------------------
function Normalize-Separators([string]$s) {
  if ($null -eq $s) { return "" }
  $x = $s.Trim()
  $x = $x -replace '[,\s/_-]+', '.'
  while ($x -match '\.\.+') { $x = $x -replace '\.\.+','.' }
  $x = $x.Trim('.')
  return $x
}

function Try-ParseIPv4([string]$Input, [ref]$IpOut) {
  $s = Normalize-Separators $Input
  if ([string]::IsNullOrWhiteSpace($s)) { return $false }

  # allow last octet only: "50"
  if ($s -match '^\d{1,3}$') {
    $IpOut.Value = $s
    return $true
  }

  if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
  $parts = $s.Split('.')
  foreach ($p in $parts) {
    $n = 0
    if (-not [int]::TryParse($p, [ref]$n)) { return $false }
    if ($n -lt 0 -or $n -gt 255) { return $false }
  }
  $IpOut.Value = ($parts -join '.')
  return $true
}

function Expand-IPv4WithBase([string]$MaybeLastOctetOrIp, [string]$Base3Octets) {
  $tmp = $null
  if (-not (Try-ParseIPv4 -Input $MaybeLastOctetOrIp -IpOut ([ref]$tmp))) {
    throw "Invalid IPv4 input: '$MaybeLastOctetOrIp'"
  }

  if ($tmp -match '^\d{1,3}$') {
    $oct = [int]$tmp
    if ($oct -lt 1 -or $oct -gt 254) { throw "Host octet must be 1-254 (got $oct)." }
    return "$Base3Octets.$oct"
  }

  return $tmp
}

function MaskToPrefixLength([string]$Mask) {
  $m = Normalize-Separators $Mask
  if ($m -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid subnet mask: '$Mask'" }

  $octets = @()
  foreach ($o in $m.Split('.')) {
    $n = [int]$o
    if ($n -lt 0 -or $n -gt 255) { throw "Invalid subnet mask octet: $n" }
    $octets += $n
  }

  $bin = ""
  foreach ($n in $octets) { $bin += ([Convert]::ToString($n,2).PadLeft(8,'0')) }

  if ($bin -notmatch '^1*0*$') { throw "Subnet mask is not contiguous: $m" }

  $prefix = 0
  foreach ($ch in $bin.ToCharArray()) { if ($ch -eq '1') { $prefix++ } }
  return $prefix
}

function Parse-PrefixOrMask([string]$Input) {
  $s = ""
  if ($null -ne $Input) { $s = $Input.Trim() }

  if ($s -match '^\d{1,2}$') {
    $p = [int]$s
    if ($p -lt 1 -or $p -gt 32) { throw "Prefix length must be 1-32 (got $p)." }
    return $p
  }

  return (MaskToPrefixLength $s)
}

# -----------------------------
# Adapter info / selection
# -----------------------------
function Get-IPv6BindingState([string]$Alias) {
  try {
    $b = Get-NetAdapterBinding -InterfaceAlias $Alias -ComponentID ms_tcpip6 -ErrorAction Stop
    return [bool]$b.Enabled
  } catch {
    return $null
  }
}

function Show-AdapterConfig([string]$Alias) {
  $cfg = Get-NetIPConfiguration -InterfaceAlias $Alias -ErrorAction SilentlyContinue
  if (-not $cfg) { Write-Warn "Unable to read IP configuration for $Alias"; return }

  $ipv4 = $cfg.IPv4Address | Select-Object -First 1
  $gw4  = $cfg.IPv4DefaultGateway | Select-Object -First 1
  $dns  = $cfg.DnsServer.ServerAddresses

  $dhcpState = $null
  try {
    $ipif = Get-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction Stop
    $dhcpState = $ipif.Dhcp
  } catch { }

  $ipv6Enabled = Get-IPv6BindingState -Alias $Alias

  $ipStr = "None"
  $pfxStr = "None"
  $gwStr = "None"
  if ($ipv4 -and $ipv4.IPAddress) { $ipStr = $ipv4.IPAddress }
  if ($ipv4 -and $ipv4.PrefixLength) { $pfxStr = $ipv4.PrefixLength }
  if ($gw4 -and $gw4.NextHop) { $gwStr = $gw4.NextHop }

  $dnsStr = "None"
  if ($dns -and $dns.Count -gt 0) { $dnsStr = ($dns -join ", ") }

  $ipv6Str = "Unknown"
  if ($ipv6Enabled -eq $true) { $ipv6Str = "Enabled" }
  elseif ($ipv6Enabled -eq $false) { $ipv6Str = "Disabled" }

  Write-Line
  Write-Host ("Current configuration for: {0}" -f $Alias) -ForegroundColor Yellow
  Write-Host ("  IPv4 Address : {0}" -f $ipStr) -ForegroundColor Gray
  Write-Host ("  PrefixLength : {0}" -f $pfxStr) -ForegroundColor Gray
  Write-Host ("  Gateway      : {0}" -f $gwStr) -ForegroundColor Gray
  Write-Host ("  DNS Servers  : {0}" -f $dnsStr) -ForegroundColor Gray
  Write-Host ("  DHCP (IPv4)  : {0}" -f $(if ($dhcpState) { $dhcpState } else { "Unknown" })) -ForegroundColor Gray
  Write-Host ("  IPv6 Binding : {0}" -f $ipv6Str) -ForegroundColor Gray
  Write-Line
}

function Select-Adapter {
  $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object -Property Status, Name
  if (-not $adapters) { throw "No adapters found." }

  Write-Head "Select Network Adapter"
  for ($i=0; $i -lt $adapters.Count; $i++) {
    $a = $adapters[$i]
    Write-Host ("{0}) {1} | Status={2} | IfIndex={3} | MAC={4}" -f ($i+1), $a.Name, $a.Status, $a.ifIndex, $a.MacAddress) -ForegroundColor Gray
  }

  while ($true) {
    $sel = (Read-Host "Choose adapter number").Trim()
    if ($sel -match '^\d+$') {
      $idx = [int]$sel
      if ($idx -ge 1 -and $idx -le $adapters.Count) {
        return $adapters[$idx-1].Name
      }
    }
    Write-Warn "Invalid selection."
  }
}

# -----------------------------
# Apply config actions
# -----------------------------
function Clear-IPv4ManualConfig([string]$Alias) {
  try {
    $manualIps = Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.PrefixOrigin -eq "Manual" -or $_.SuffixOrigin -eq "Manual" }
    foreach ($ip in $manualIps) {
      try { Remove-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
  } catch { }

  try {
    $routes = Get-NetRoute -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
    foreach ($r in $routes) {
      try { Remove-NetRoute -InterfaceAlias $Alias -DestinationPrefix "0.0.0.0/0" -NextHop $r.NextHop -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
  } catch { }
}

function Set-IPv4DHCP([string]$Alias) {
  Write-Info "Setting IPv4 to DHCP and resetting DNS..."
  Set-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
  try { Clear-IPv4ManualConfig -Alias $Alias } catch { }
  try { Set-DnsClientServerAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ResetServerAddresses -ErrorAction SilentlyContinue } catch { }
  Write-OK "DHCP enabled (IPv4)."
}

function Set-IPv4Static([string]$Alias, [string]$Ip, [int]$Prefix, [string]$Gateway, [string[]]$DnsServers) {
  Write-Info "Applying static IPv4 configuration..."
  Clear-IPv4ManualConfig -Alias $Alias

  try { Set-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue } catch { }

  if ([string]::IsNullOrWhiteSpace($Gateway)) {
    New-NetIPAddress -InterfaceAlias $Alias -IPAddress $Ip -PrefixLength $Prefix -ErrorAction Stop | Out-Null
  } else {
    New-NetIPAddress -InterfaceAlias $Alias -IPAddress $Ip -PrefixLength $Prefix -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
  }

  if ($DnsServers -and $DnsServers.Count -gt 0) {
    Set-DnsClientServerAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ServerAddresses $DnsServers -ErrorAction Stop
  } else {
    Set-DnsClientServerAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ResetServerAddresses -ErrorAction SilentlyContinue
  }

  Write-OK "Static IPv4 applied."
}

function Set-IPv6Binding([string]$Alias, [ValidateSet("Enable","Disable")] [string]$Mode) {
  if ($Mode -eq "Disable") {
    Disable-NetAdapterBinding -InterfaceAlias $Alias -ComponentID ms_tcpip6 -ErrorAction Stop | Out-Null
    Write-OK "IPv6 disabled on adapter: $Alias"
  } else {
    Enable-NetAdapterBinding -InterfaceAlias $Alias -ComponentID ms_tcpip6 -ErrorAction Stop | Out-Null
    Write-OK "IPv6 enabled on adapter: $Alias"
  }
}

# -----------------------------
# Input flows
# -----------------------------
function Prompt-IPv6Toggle {
  Write-Line
  Write-Host "IPv6 Option (adapter binding)" -ForegroundColor Cyan
  Write-Host "  1) Leave as-is" -ForegroundColor Gray
  Write-Host "  2) Disable IPv6" -ForegroundColor Gray
  Write-Host "  3) Enable IPv6"  -ForegroundColor Gray

  while ($true) {
    $x = (Read-Host "Select").Trim()
    switch ($x) {
      "1" { return $null }
      "2" { return "Disable" }
      "3" { return "Enable" }
      default { Write-Warn "Invalid selection." }
    }
  }
}

function Menu-Mode {
  Write-Head "IPv4 Configuration Mode"
  Write-Host "1) USL profile (preconfigured)" -ForegroundColor Gray
  Write-Host "2) Custom static IPv4 (full control)" -ForegroundColor Gray
  Write-Host "3) DHCP (automatic)" -ForegroundColor Gray

  while ($true) {
    $m = (Read-Host "Select option").Trim()
    if ($m -eq "1" -or $m -eq "2" -or $m -eq "3") { return $m }
    Write-Warn "Invalid selection."
  }
}

# -----------------------------
# MAIN
# -----------------------------
Write-Head "IPv4 Configurator + IPv6 Toggle | v1.0.1 | rhshourav"

$alias = Select-Adapter
Show-AdapterConfig -Alias $alias

$mode = Menu-Mode
$ipv6Action = Prompt-IPv6Toggle

# USL profile config
$USL_Base3  = "192.168.18"
$USL_Prefix = MaskToPrefixLength "255.255.248.0" # /21
$USL_GW     = "192.168.18.254"
$USL_DNS    = @("192.168.18.248","192.168.18.210")

# Build plan (for confirmation)
$plan = New-Object PSObject -Property @{
  Adapter = $alias
  Mode    = $(if ($mode -eq "1") { "USL" } elseif ($mode -eq "2") { "Custom" } else { "DHCP" })
  IPv4_IP = $null
  Prefix  = $null
  Gateway = $null
  DNS     = $null
  IPv6    = $(if ($ipv6Action) { $ipv6Action } else { "No change" })
}

if ($mode -eq "1") {
  Write-Head "USL Profile"
  Write-Info ("Subnet mask: 255.255.248.0 (Prefix /{0})" -f $USL_Prefix)
  Write-Info ("Gateway    : {0}" -f $USL_GW)
  Write-Info ("DNS        : {0}" -f ($USL_DNS -join ", "))
  Write-Info ("IP base    : {0}.x" -f $USL_Base3)

  while ($true) {
    $ipIn = Read-Host "Enter IP (full) OR just host octet (e.g., 50). Auto-fix enabled"
    try {
      $ip = Expand-IPv4WithBase -MaybeLastOctetOrIp $ipIn -Base3Octets $USL_Base3
      $plan.IPv4_IP = $ip
      $plan.Prefix  = $USL_Prefix
      $plan.Gateway = $USL_GW
      $plan.DNS     = ($USL_DNS -join ", ")
      break
    } catch {
      Write-Warn $_.Exception.Message
    }
  }
}
elseif ($mode -eq "2") {
  Write-Head "Custom Static IPv4"

  while ($true) {
    $ipIn = Read-Host "IP address (e.g., 192 168 18 50) - auto-fix enabled"
    $ipTmp = $null
    if (Try-ParseIPv4 -Input $ipIn -IpOut ([ref]$ipTmp)) {
      if ($ipTmp -match '^\d{1,3}$') { Write-Warn "Custom mode requires full IPv4 (4 octets)."; continue }
      $plan.IPv4_IP = $ipTmp
      break
    }
    Write-Warn "Invalid IPv4."
  }

  while ($true) {
    $maskIn = Read-Host "Subnet mask (e.g., 255.255.255.0) OR prefix length (e.g., 24)"
    try {
      $plan.Prefix = Parse-PrefixOrMask $maskIn
      break
    } catch {
      Write-Warn $_.Exception.Message
    }
  }

  while ($true) {
    $gwIn = Read-Host "Gateway (optional; press Enter to skip)"
    if ([string]::IsNullOrWhiteSpace($gwIn)) { $plan.Gateway = ""; break }
    $gwTmp = $null
    if (Try-ParseIPv4 -Input $gwIn -IpOut ([ref]$gwTmp)) {
      if ($gwTmp -match '^\d{1,3}$') { Write-Warn "Gateway must be full IPv4."; continue }
      $plan.Gateway = $gwTmp
      break
    }
    Write-Warn "Invalid gateway IPv4."
  }

  $dnsList = @()

  while ($true) {
    $d1 = Read-Host "Primary DNS (optional; press Enter to skip)"
    if ([string]::IsNullOrWhiteSpace($d1)) { break }
    $d1Tmp = $null
    if (Try-ParseIPv4 -Input $d1 -IpOut ([ref]$d1Tmp)) {
      if ($d1Tmp -match '^\d{1,3}$') { Write-Warn "DNS must be full IPv4."; continue }
      $dnsList += $d1Tmp
      break
    }
    Write-Warn "Invalid DNS IPv4."
  }

  while ($true) {
    $d2 = Read-Host "Secondary DNS (optional; press Enter to skip)"
    if ([string]::IsNullOrWhiteSpace($d2)) { break }
    $d2Tmp = $null
    if (Try-ParseIPv4 -Input $d2 -IpOut ([ref]$d2Tmp)) {
      if ($d2Tmp -match '^\d{1,3}$') { Write-Warn "DNS must be full IPv4."; continue }
      $dnsList += $d2Tmp
      break
    }
    Write-Warn "Invalid DNS IPv4."
  }

  if ($dnsList.Count -gt 0) { $plan.DNS = ($dnsList -join ", ") } else { $plan.DNS = "Reset/Auto" }
}
else {
  Write-Head "DHCP (IPv4)"
}

# Plan + confirm
Write-Head "Planned Changes"
Write-Host ("Adapter : {0}" -f $plan.Adapter) -ForegroundColor Gray
Write-Host ("Mode    : {0}" -f $plan.Mode) -ForegroundColor Gray
if ($plan.Mode -eq "USL" -or $plan.Mode -eq "Custom") {
  Write-Host ("IPv4 IP  : {0}" -f $plan.IPv4_IP) -ForegroundColor Gray
  Write-Host ("Prefix   : /{0}" -f $plan.Prefix) -ForegroundColor Gray
  Write-Host ("Gateway  : {0}" -f $(if ([string]::IsNullOrWhiteSpace($plan.Gateway)) { "None" } else { $plan.Gateway })) -ForegroundColor Gray
  Write-Host ("DNS      : {0}" -f $plan.DNS) -ForegroundColor Gray
} else {
  Write-Host "IPv4     : DHCP Enabled + DNS Reset" -ForegroundColor Gray
}
Write-Host ("IPv6     : {0}" -f $plan.IPv6) -ForegroundColor Gray
Write-Line

if (-not (Confirm-YesNo "Apply these settings now?")) {
  Write-Warn "Cancelled by user. No changes applied."
  exit 1
}

# Apply
try {
  if ($mode -eq "3") {
    Set-IPv4DHCP -Alias $alias
  }
  elseif ($mode -eq "1") {
    Set-IPv4Static -Alias $alias -Ip $plan.IPv4_IP -Prefix $plan.Prefix -Gateway $USL_GW -DnsServers $USL_DNS
  }
  else {
    $dnsServers = @()
    if ($plan.DNS -and $plan.DNS -ne "Reset/Auto") {
      $dnsServers = ($plan.DNS.Split(',') | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
    }
    Set-IPv4Static -Alias $alias -Ip $plan.IPv4_IP -Prefix $plan.Prefix -Gateway $plan.Gateway -DnsServers $dnsServers
  }

  if ($ipv6Action) {
    if (Confirm-YesNo ("Confirm IPv6 change: {0} on '{1}'?" -f $ipv6Action, $alias)) {
      Set-IPv6Binding -Alias $alias -Mode $ipv6Action
    } else {
      Write-Warn "IPv6 change skipped by user."
    }
  }

  Write-OK "All requested changes applied."
} catch {
  Write-Err ("Failed: {0}" -f $_.Exception.Message)
  exit 1
}

Show-AdapterConfig -Alias $alias
Write-OK "Done."
