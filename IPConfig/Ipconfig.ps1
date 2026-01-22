<#
.SYNOPSIS
  IPv4 Configurator (USL / Custom / DHCP) + IPv6 toggle (PowerShell 5.1 compatible)

.DESCRIPTION
  - Shows current adapter configuration (IPv4, gateway, DNS, DHCP, IPv6 binding)
  - Menus use single-key selection (no Enter needed) where possible
  - Modes:
      1) USL profile (preconfigured)
      2) Custom static IPv4 (full control)
      3) DHCP (automatic)
  - IPv6: Enable / Disable / Leave as-is
  - Input auto-correction:
      * Accepts dots, spaces, commas, dashes, underscores, slashes
      * Removes hidden/non-printable characters from pasted input
      * Canonicalizes IPv4 (removes leading zeros)
  - USL mode special input:
      * Full IP: 192.168.19.44   (or "192 168 19 44")
      * Two-octet: 19 44         => 192.168.19.44
      * Packed: 1944            => 192.168.19.44   (X=19, Y=44)
      * Packed: 18100           => 192.168.18.100  (X=18, Y=100)
      * Packed w/ prefix: 1921681944 => 192.168.19.44
      * Single octet: 44         => 192.168.DefaultX.44
  - Always confirms before applying changes
  - During input screens: Back / Exit supported

.AUTHOR
  Shourav (rhshourav)
.GITHUB
  https://github.com/rhshourav
.VERSION
  1.3.2
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# -----------------------------
# UI helpers
# -----------------------------
function Write-Line { Write-Host ("=" * 78) -ForegroundColor DarkCyan }
function Write-Head([string]$t) { Write-Line; Write-Host $t -ForegroundColor Cyan; Write-Line }
function Write-Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Gray }
function Write-OK  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "[-] $m" -ForegroundColor Red }

function Read-KeyChar {
  try {
    $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    return $k.Character
  } catch {
    return $null
  }
}

function Read-MenuKey {
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][string[]]$ValidKeys
  )
  while ($true) {
    Write-Host -NoNewline $Prompt
    $ch = Read-KeyChar

    # Ignore Enter / CR / LF silently (prevents "Invalid choice" spam)
    if ($ch -eq "`r" -or $ch -eq "`n") { continue }

    # Fallback if RawUI not available
    if ($null -eq $ch -or $ch -eq [char]0) {
      $fallback = (Read-Host "").Trim()
      if ($fallback.Length -ge 1) { $ch = $fallback[0] } else { $ch = '' }
    }

    $ch = ($ch.ToString()).ToUpperInvariant()

    if ($ValidKeys -contains $ch) {
      Write-Host $ch
      return $ch
    }

    Write-Host ""
    Write-Warn ("Invalid choice. Valid: {0}" -f ($ValidKeys -join ", "))
  }
}

function Confirm-YesNoKey([string]$Prompt) {
  $k = Read-MenuKey -Prompt ("{0} [Y/N]: " -f $Prompt) -ValidKeys @("Y","N")
  return ($k -eq "Y")
}
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

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
# Input normalization / parsing
# -----------------------------
function Normalize-Separators([string]$RawText) {
  if ($null -eq $RawText) { return "" }

  $x = $RawText.Trim()
  $x = $x.Trim('"').Trim("'")

  # Remove non-printable characters (incl. pasted junk)
  $x = -join ($x.ToCharArray() | Where-Object { ([int]$_ -ge 32) -and ([int]$_ -ne 127) })

  # Common separators -> dot
  $x = $x -replace '[,\s/_-]+', '.'

  # Collapse multiple dots, trim edges
  while ($x -match '\.\.+') { $x = $x -replace '\.\.+','.' }
  $x = $x.Trim('.')

  return $x
}

function Try-ParseOctet([string]$Text, [ref]$nOut) {
  $n = 0
  if (-not [int]::TryParse($Text, [ref]$n)) { return $false }
  if ($n -lt 0 -or $n -gt 255) { return $false }
  $nOut.Value = $n
  return $true
}

# Strict dotted-quad only (prevents "1944" => 0.0.7.152 and "19.44" => 19.0.0.44)
function Try-ParseIPv4DottedQuad([string]$Text, [ref]$IpOut) {
  $s = Normalize-Separators $Text
  if ([string]::IsNullOrWhiteSpace($s)) { return $false }

  if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }

  $ipObj = $null
  if (-not [System.Net.IPAddress]::TryParse($s, [ref]$ipObj)) { return $false }
  if ($ipObj.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }

  $b = $ipObj.GetAddressBytes()
  $IpOut.Value = ("{0}.{1}.{2}.{3}" -f $b[0], $b[1], $b[2], $b[3])
  return $true
}

function MaskToPrefixLength([string]$MaskText) {
  $m = Normalize-Separators $MaskText
  if ($m -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid subnet mask: '$MaskText'" }

  $octets = @()
  foreach ($o in $m.Split('.')) {
    $n = 0
    if (-not (Try-ParseOctet $o ([ref]$n))) { throw "Invalid subnet mask octet: $o" }
    $octets += $n
  }

  $bin = ""
  foreach ($n in $octets) { $bin += ([Convert]::ToString($n,2).PadLeft(8,'0')) }
  if ($bin -notmatch '^1*0*$') { throw "Subnet mask is not contiguous: $m" }

  $prefix = 0
  foreach ($ch in $bin.ToCharArray()) { if ($ch -eq '1') { $prefix++ } }
  return $prefix
}

function Parse-PrefixOrMask([string]$Text) {
  $s = ""
  if ($null -ne $Text) { $s = $Text.Trim() }

  if ($s -match '^\d{1,2}$') {
    $p = [int]$s
    if ($p -lt 1 -or $p -gt 32) { throw "Prefix length must be 1-32 (got $p)." }
    return $p
  }
  return (MaskToPrefixLength $s)
}

# USL resolver: 192.168.X.Y with multiple input styles
function Resolve-USLIPv4([string]$Text, [int]$DefaultX) {
  $s = Normalize-Separators $Text
  if ([string]::IsNullOrWhiteSpace($s)) { throw "Empty IP input." }

  # E) Packed with explicit prefix 192168 + tail(4-5)
  if ($s -match '^192168(\d{4,5})$') {
    $tail = $Matches[1]
    $xStr = $tail.Substring(0,2)
    $yStr = $tail.Substring(2)
    $x = 0; $y = 0
    if (-not (Try-ParseOctet $xStr ([ref]$x))) { throw "Invalid packed X: $xStr" }
    if (-not (Try-ParseOctet $yStr ([ref]$y))) { throw "Invalid packed Y: $yStr" }
    return ("192.168.{0}.{1}" -f $x, $y)
  }

  # D) Packed 4-5 digits: first 2 digits = X, rest = Y
  if ($s -match '^\d{4,5}$') {
    $xStr = $s.Substring(0,2)
    $yStr = $s.Substring(2)
    $x = 0; $y = 0
    if (-not (Try-ParseOctet $xStr ([ref]$x))) { throw "Invalid packed X: $xStr" }
    if (-not (Try-ParseOctet $yStr ([ref]$y))) { throw "Invalid packed Y: $yStr" }
    return ("192.168.{0}.{1}" -f $x, $y)
  }

  # B) "X.Y" => 192.168.X.Y   (covers: "19.44" and "19 44" -> "19.44")
  if ($s -match '^\d{1,3}\.\d{1,3}$') {
    $parts = $s.Split('.')
    $x = 0; $y = 0
    if (-not (Try-ParseOctet $parts[0] ([ref]$x))) { throw "Invalid X octet: $($parts[0])" }
    if (-not (Try-ParseOctet $parts[1] ([ref]$y))) { throw "Invalid Y octet: $($parts[1])" }
    return ("192.168.{0}.{1}" -f $x, $y)
  }

  # C) "Y" => 192.168.DefaultX.Y
  if ($s -match '^\d{1,3}$') {
    $y = 0
    if (-not (Try-ParseOctet $s ([ref]$y))) { throw "Invalid host octet: $s" }
    return ("192.168.{0}.{1}" -f $DefaultX, $y)
  }

  # A) Full dotted-quad only
  $full = $null
  if (Try-ParseIPv4DottedQuad -Text $s -IpOut ([ref]$full)) {
    if ($full -notmatch '^192\.168\.\d{1,3}\.\d{1,3}$') {
      throw "USL expects 192.168.X.Y. You entered: $full"
    }
    return $full
  }

  throw "Invalid IPv4 input: '$Text'"
}

function Resolve-CustomIPv4([string]$Text) {
  $ip = $null
  if (-not (Try-ParseIPv4DottedQuad -Text $Text -IpOut ([ref]$ip))) {
    throw "Custom mode requires full dotted IPv4 (e.g., 192.168.18.50). Input: '$Text'"
  }
  return $ip
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

  if ($adapters.Count -le 9) {
    $valid = @()
    for ($n=1; $n -le $adapters.Count; $n++) { $valid += $n.ToString() }
    $k = Read-MenuKey -Prompt "Choose adapter number: " -ValidKeys $valid
    return $adapters[[int]$k - 1].Name
  }

  while ($true) {
    $sel = (Read-Host "Choose adapter number").Trim()
    if ($sel -match '^\d+$') {
      $idx = [int]$sel
      if ($idx -ge 1 -and $idx -le $adapters.Count) { return $adapters[$idx-1].Name }
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
function Menu-AfterApply {
  Write-Head "Next Action"
  Write-Host "1) Configure same adapter again" -ForegroundColor Gray
  Write-Host "2) Select a different adapter"    -ForegroundColor Gray
  Write-Host "X) Exit"                           -ForegroundColor DarkGray
  return (Read-MenuKey -Prompt "Select: " -ValidKeys @("1","2","X"))
}

# -----------------------------
# Menus (single-key)
# -----------------------------
function Menu-Mode {
  Write-Head "IPv4 Configuration Mode"
  Write-Host "1) USL profile (preconfigured)" -ForegroundColor Gray
  Write-Host "2) Custom static IPv4 (full control)" -ForegroundColor Gray
  Write-Host "3) DHCP (automatic)" -ForegroundColor Gray
  Write-Host "X) Exit" -ForegroundColor DarkGray
  return (Read-MenuKey -Prompt "Select: " -ValidKeys @("1","2","3","X"))
}

function Menu-IPv6Toggle {
  Write-Head "IPv6 Option (adapter binding)"
  Write-Host "1) Leave as-is" -ForegroundColor Gray
  Write-Host "2) Disable IPv6" -ForegroundColor Gray
  Write-Host "3) Enable IPv6"  -ForegroundColor Gray
  Write-Host "B) Back" -ForegroundColor DarkGray
  Write-Host "X) Exit" -ForegroundColor DarkGray
  return (Read-MenuKey -Prompt "Select: " -ValidKeys @("1","2","3","B","X"))
}

function Prompt-InputAction([string]$Title) {
  Write-Head $Title
  Write-Host "I) Input value" -ForegroundColor Gray
  Write-Host "B) Back" -ForegroundColor DarkGray
  Write-Host "X) Exit" -ForegroundColor DarkGray
  return (Read-MenuKey -Prompt "Select: " -ValidKeys @("I","B","X"))
}

# -----------------------------
# MAIN
# -----------------------------
# -----------------------------
# MAIN
# -----------------------------
Write-Head "IPv4 Configurator + IPv6 Toggle | v1.3.2 | rhshourav"

# USL profile config
$USL_DefaultX = 18
$USL_Prefix   = MaskToPrefixLength "255.255.248.0" # /21
$USL_GW       = "192.168.18.254"
$USL_DNS      = @("192.168.18.248","192.168.18.210")

# Outer loop: allows selecting a new adapter without restarting the script
$alias = $null

while ($true) {

  if (-not $alias) {
    $alias = Select-Adapter
    Show-AdapterConfig -Alias $alias
  }

  # Inner loop: repeated configuration for the currently selected adapter
  while ($true) {

    $mode = Menu-Mode
    if ($mode -eq "X") { Write-Warn "Exit."; exit 0 }

    $ipv6Choice = Menu-IPv6Toggle
    if ($ipv6Choice -eq "X") { Write-Warn "Exit."; exit 0 }
    if ($ipv6Choice -eq "B") { continue }

    $ipv6Action = $null
    if ($ipv6Choice -eq "2") { $ipv6Action = "Disable" }
    elseif ($ipv6Choice -eq "3") { $ipv6Action = "Enable" }

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
      Write-Info ("Subnet mask : 255.255.248.0 (/{0})" -f $USL_Prefix)
      Write-Info ("Gateway     : {0}" -f $USL_GW)
      Write-Info ("DNS         : {0}" -f ($USL_DNS -join ", "))
      Write-Info ("USL examples: 192.168.19.44 | 19 44 | 1944 | 18100 | 1921681944 | 44 (uses X={0})" -f $USL_DefaultX)

      while ($true) {
        $act = Prompt-InputAction "USL IP Input"
        if ($act -eq "X") { Write-Warn "Exit."; exit 0 }
        if ($act -eq "B") { break }

        $ipIn = Read-Host "Enter IP (any style)"
        try {
          $resolved = Resolve-USLIPv4 -Text $ipIn -DefaultX $USL_DefaultX
          Write-Info ("Resolved IP: {0}" -f $resolved)
          if (-not (Confirm-YesNoKey "Use this IP?")) { continue }

          $plan.IPv4_IP = $resolved
          $plan.Prefix  = $USL_Prefix
          $plan.Gateway = $USL_GW
          $plan.DNS     = ($USL_DNS -join ", ")
          break
        } catch {
          Write-Warn $_.Exception.Message
        }
      }

      if (-not $plan.IPv4_IP) { continue }
    }
    elseif ($mode -eq "2") {
      Write-Head "Custom Static IPv4"

      while ($true) {
        $act = Prompt-InputAction "Custom IPv4 - IP Address"
        if ($act -eq "X") { Write-Warn "Exit."; exit 0 }
        if ($act -eq "B") { break }

        $ipIn = Read-Host "Enter full IPv4 (any separators)"
        try {
          $resolved = Resolve-CustomIPv4 -Text $ipIn
          Write-Info ("Resolved IP: {0}" -f $resolved)
          if (-not (Confirm-YesNoKey "Use this IP?")) { continue }
          $plan.IPv4_IP = $resolved
          break
        } catch {
          Write-Warn $_.Exception.Message
        }
      }
      if (-not $plan.IPv4_IP) { continue }

      while ($true) {
        $act = Prompt-InputAction "Custom IPv4 - Subnet Mask / Prefix"
        if ($act -eq "X") { Write-Warn "Exit."; exit 0 }
        if ($act -eq "B") { $plan.IPv4_IP = $null; break }

        $maskIn = Read-Host "Subnet mask (255.255.255.0) OR prefix length (24)"
        try { $plan.Prefix = Parse-PrefixOrMask $maskIn; break } catch { Write-Warn $_.Exception.Message }
      }
      if (-not $plan.Prefix) { continue }

      while ($true) {
        $act = Prompt-InputAction "Custom IPv4 - Gateway (Optional)"
        if ($act -eq "X") { Write-Warn "Exit."; exit 0 }
        if ($act -eq "B") { $plan.Prefix = $null; break }

        $gwIn = Read-Host "Gateway (press Enter for none)"
        if ([string]::IsNullOrWhiteSpace($gwIn)) { $plan.Gateway = ""; break }

        $gwResolved = $null
        if (Try-ParseIPv4DottedQuad -Text $gwIn -IpOut ([ref]$gwResolved)) { $plan.Gateway = $gwResolved; break }
        Write-Warn "Invalid gateway IPv4."
      }

      $dnsList = @()

      while ($true) {
        $act = Prompt-InputAction "Custom IPv4 - Primary DNS (Optional)"
        if ($act -eq "X") { Write-Warn "Exit."; exit 0 }
        if ($act -eq "B") { break }

        $d1 = Read-Host "Primary DNS (press Enter for none)"
        if ([string]::IsNullOrWhiteSpace($d1)) { break }

        $d1Resolved = $null
        if (Try-ParseIPv4DottedQuad -Text $d1 -IpOut ([ref]$d1Resolved)) { $dnsList += $d1Resolved; break }
        Write-Warn "Invalid DNS IPv4."
      }

      while ($true) {
        $act = Prompt-InputAction "Custom IPv4 - Secondary DNS (Optional)"
        if ($act -eq "X") { Write-Warn "Exit."; exit 0 }
        if ($act -eq "B") { break }

        $d2 = Read-Host "Secondary DNS (press Enter for none)"
        if ([string]::IsNullOrWhiteSpace($d2)) { break }

        $d2Resolved = $null
        if (Try-ParseIPv4DottedQuad -Text $d2 -IpOut ([ref]$d2Resolved)) { $dnsList += $d2Resolved; break }
        Write-Warn "Invalid DNS IPv4."
      }

      if ($dnsList.Count -gt 0) { $plan.DNS = ($dnsList -join ", ") } else { $plan.DNS = "Reset/Auto" }
    }
    else {
      $plan.DNS = "Reset/Auto"
    }

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

    if (-not (Confirm-YesNoKey "Apply these settings now?")) {
      Write-Warn "Cancelled. Returning to menu."
      continue
    }

    try {
      if ($plan.Mode -eq "DHCP") {
        Set-IPv4DHCP -Alias $alias
      }
      elseif ($plan.Mode -eq "USL") {
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
        if (Confirm-YesNoKey ("Confirm IPv6 change: {0} on '{1}'?" -f $ipv6Action, $alias)) {
          Set-IPv6Binding -Alias $alias -Mode $ipv6Action
        } else {
          Write-Warn "IPv6 change skipped by user."
        }
      }

      Write-OK "All requested changes applied."
      Show-AdapterConfig -Alias $alias

      # NEW: decide what to do next (loop)
      $next = Menu-AfterApply
      if ($next -eq "X") { Write-Warn "Exit."; exit 0 }
      if ($next -eq "2") { $alias = $null; break }  # break inner loop -> pick adapter again
      # else "1": continue inner loop for same adapter
      continue

    } catch {
      Write-Err ("Failed: {0}" -f $_.Exception.Message)
      Show-AdapterConfig -Alias $alias

      $next = Menu-AfterApply
      if ($next -eq "X") { Write-Warn "Exit."; exit 1 }
      if ($next -eq "2") { $alias = $null; break }
      continue
    }
  }
}
