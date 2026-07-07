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
  1.3.3
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

  if (-not $ValidKeys -or $ValidKeys.Count -eq 0) {
    throw "Read-MenuKey called with empty ValidKeys. Upstream menu builder produced no choices."
  }

  while ($true) {
    Write-Host -NoNewline $Prompt
    $ch = Read-KeyChar
    if ($ch -eq "`r" -or $ch -eq "`n") { continue }
    if ($null -eq $ch -or $ch -eq [char]0) {
      $fallback = (Read-Host "").Trim()
      if ($fallback.Length -ge 1) { $ch = $fallback[0] } else { $ch = '' }
    }
    $ch = ($ch.ToString()).ToUpperInvariant()
    if ($ValidKeys -contains $ch) { Write-Host $ch; return $ch }
    Write-Host ""; Write-Warn ("Invalid choice. Valid: {0}" -f ($ValidKeys -join ", "))
  }
}


function Confirm-YesNoKey([string]$Prompt) {
  $k = Read-MenuKey -Prompt ("{0} [Y/N]: " -f $Prompt) -ValidKeys @("Y","N")
  return ($k -eq "Y")
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
        text  = "IP Config V1.3.3`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
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

  # Prefer physical adapters, but fall back to all adapters if none are returned
  $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)

  if ($adapters.Count -eq 0) {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
  }

  # Final hard stop if still nothing
  if ($adapters.Count -eq 0) {
    throw "No network adapters were returned by Get-NetAdapter. Run: Get-NetAdapter | Format-Table -Auto"
  }

  $adapters = $adapters | Sort-Object -Property Status, Name

  Write-Head "Select Network Adapter"
  for ($i = 0; $i -lt $adapters.Count; $i++) {
    $a = $adapters[$i]
    Write-Host ("{0}) {1} | Status={2} | IfIndex={3} | MAC={4}" -f ($i+1), $a.Name, $a.Status, $a.ifIndex, $a.MacAddress) -ForegroundColor Gray
  }

  if ($adapters.Count -le 9) {
    $valid = @(1..$adapters.Count | ForEach-Object { $_.ToString() })
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
Write-Head "IPv4 Configurator + IPv6 Toggle | v1.3.3 | rhshourav"

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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUGTM2N9dsAWZSM3Pckbb4C2mM
# QOugghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRMRBYOOz66l5p9PLxrhjCznLzsoTANBgkq
# hkiG9w0BAQEFAASCAQCq0bFo6KInixvMeh2X2bZcNGCG4fUrhSor6fzMM8ymg3vy
# dkVfXyvWzPz+Gky89c6e8vnyzVsaGI3dMmApN37WbxY3nDMZvmyrnFB+2htoimOH
# RAZ76knvbdaT9DkMNN+NavksAylKs/HdTXlt/2qr1Pcis2C5hR7TRQ22Sq8cAkDI
# WeKkifXXQmqWUJXjtulgp94skfRNCzmjSAEb1W83d2P7+BaR5FoWvh8T59TEwsgR
# pin3SxH1TA3uSeEizr0KeKbM35SQ5uRyLNy87X6kr6hFJJXY666+ys4BPul4FwL7
# o8bg+ZCBXo5pO1jON+lXKAZWv4KKHarf0UKmJ5/PoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0NVowLwYJKoZIhvcNAQkEMSIEIN7fz11BOAVzd4kh
# UAdlZRUdO5Q9TUr+VzWhYogRYT4qMA0GCSqGSIb3DQEBAQUABIICAEv3ALT3zTBY
# VSd9+EwUSDlgko7lsO5fbdQxDshtz5M0+z3EyUFVQQMulPTDZ1kFOLQu4knlvAwH
# g8D1Wpek0pzpWP0Q10LWwKqt4bOwFDNHYO7xP340mof1vlYSrq7DQoUtqchRE+G6
# AcleoMEK8XnzKGoZj1TuFxVFWq0g5s6hfH+y2Z7iiirA5Fz7qenOP+C/VceKdGkV
# diOXwebbyTntpBgj106d43oTFHLCeLHHLAc9ZZkB8xB3udKfw9xMmiw85HoUj6/r
# y9XDXItfvwNnOvfjO9syyASGrINdtMFTmqGqUBcpwhH4Y3H1IyN11oyQmADwaSlF
# lqwptqMhbMh274WODqnR/bOe82Gwgl6aBQ29sVPMkl4ufnb+myC7UR4KEXOr5p6q
# 2RNeWkICs73b2XWQlObswIi6grDS0a+GeXo4uwitK9CYhWaoYh9/GAzXSgVgaGAu
# iocZvu34trDo0ZEdBhsZWbiMJGmuGtESQ97LJiGBqqHkirYUrkqkO8Si2B5d0+CX
# 7+nHwGP53P6Xa7YGYE5zCHr590+nS+wHW5qjoMo0txxSZ7Dk3cmzuSfGrY/nkYgQ
# ZyJStp44ThtLi5pDxCx9U8GHSSAqV2N0QIh64Kb0BkEuMv8UMWNEsaAQIFLVg+xk
# Vr5FsMG/Rf0LvfqCCv1zh6zE+rrSjG8V
# SIG # End signature block
