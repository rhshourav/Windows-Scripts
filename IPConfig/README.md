<h1 align="center">IPConfig - IPv4 Configurator (USL / Custom / DHCP) + IPv6 Toggle</h1>

<p align="center">
  Hardened PowerShell script to view and change IPv4 settings (USL profile or fully custom), switch to DHCP, and enable/disable IPv6 — with safe confirmations.
</p>

---

## Features

### Current adapter status (before changes)
Shows the selected adapter’s current configuration:
- IPv4 address + prefix length
- Default gateway
- DNS servers
- DHCP state (IPv4)
- IPv6 binding state (enabled/disabled)

### Configuration modes
- **USL profile (preconfigured)**  

- **Custom (full control)**  
  You provide:
  - IPv4 address
  - Subnet mask or prefix length
  - Gateway (optional)
  - DNS servers (optional)

- **DHCP mode**
  - Enables DHCP for IPv4
  - Resets DNS to automatic

### IPv6 toggle (per adapter)
- Leave as-is
- Disable IPv6
- Enable IPv6

### Input auto-correction (USL mode)
USL mode accepts IP input in multiple styles and resolves it safely:
- Full IP: `192.168.10.14`
- With spaces: `192 168 10 144`
- Two-octet: `10 24` → `192.168.10.24`
- Packed: `1844` → `192.168.18.44`
- Packed: `18100` → `192.168.18.100`
- Packed with prefix: `1921681044` → `192.168.10.44`

### Safety & UX
- Single-key menu selection (no Enter needed) where possible
- Back/Exit options in input screens
- Always confirms the final plan before applying changes
- Requires Administrator (auto-elevates)

---

## One-line execution (Run as Administrator)

Open **PowerShell as Administrator**, then run:

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1")
````

---

## Requirements

* Windows 10 / Windows 11
* PowerShell 5.1+ (default on Windows)
* Administrator privileges

---

## Notes

* The script changes adapter settings immediately. If you disconnect yourself (wrong IP/Gateway), you may lose network access until corrected.
* In corporate/domain environments, some network settings may be enforced by policy.

---

## Author

**Shourav (rhshourav)**
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)
