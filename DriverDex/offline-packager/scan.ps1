#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Offline Scanner - Gathers hardware IDs from an air-gapped machine.
.DESCRIPTION
    Scans PnP devices via CIM/WMI, exports architecture and HWIDs to inventory.json.
    Run this on the target machine, then copy inventory.json to an online machine
    with DriverDex to build the offline driver bundle.
.NOTES
    Compatible: Windows 7 SP1 / 8.1 / 10 / 11
    Author:     DriverDex - https://github.com/rhshourav/driverdex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Console setup ────────────────────────────────────────────────────────
try {
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'White'
    try { $Host.UI.RawUI.WindowTitle = 'DriverDex Offline Scanner' } catch {}
    Clear-Host
} catch {}

Write-Host ""
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  DriverDex Offline Scanner                                   |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# ── Detect architecture ──────────────────────────────────────────────────
Write-Host "  [>] Detecting system architecture..." -ForegroundColor Gray

$arch = 'x86'
try {
    $osArch = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).OSArchitecture
    if ($osArch -match '64') { $arch = 'Am64' }
    else { $arch = 'x86' }
} catch {
    try {
        $osArch = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).OSArchitecture
        if ($osArch -match '64') { $arch = 'Am64' }
        else { $arch = 'x86' }
    } catch {
        Write-Host "  [!] Could not detect architecture, defaulting to x86" -ForegroundColor Yellow
    }
}
Write-Host "  [+] Architecture: $arch" -ForegroundColor Green

# ── Enumerate hardware IDs ───────────────────────────────────────────────
Write-Host "  [>] Scanning hardware IDs..." -ForegroundColor Gray

$hwidSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

$devices = $null
try {
    $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
               Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 }
} catch {
    Write-Host "  [!] CIM failed, falling back to WMI..." -ForegroundColor Yellow
    try {
        $devices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 }
    } catch {
        Write-Host "  [!] WMI query also failed." -ForegroundColor Red
    }
}

if ($devices) {
    $count = 0
    foreach ($dev in $devices) {
        foreach ($id in @($dev.HardwareID)) {
            $upper = $id.ToUpperInvariant()
            if ($upper -match '^(PCI|USB|ACPI|HDAUDIO|SCSI|IDE|SBEMBUS|HTREE|SW)\\') {
                if ($hwidSet.Add($upper)) { $count++ }
            }
        }
    }
    Write-Host "  [+] Found $count unique hardware ID(s)" -ForegroundColor Green
} else {
    Write-Host "  [!] No PnP devices found." -ForegroundColor Red
}

# ── Sort and build output ────────────────────────────────────────────────
$hwidArray = @($hwidSet | Sort-Object)

# ── Write inventory.json ─────────────────────────────────────────────────
$outputPath = Join-Path $PSScriptRoot 'inventory.json'

$inventory = [ordered]@{
    Architecture = $arch
    HWIDs        = ,$hwidArray
}

$inventory | ConvertTo-Json -Depth 4 | Set-Content -Path $outputPath -Encoding UTF8

Write-Host ""
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  Inventory saved to:                                         |" -ForegroundColor Green
Write-Host "  |  $outputPath" -ForegroundColor White
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Copy inventory.json to an online machine" -ForegroundColor DarkGray
Write-Host "    2. Run DriverDex -> [P] Offline Packager" -ForegroundColor DarkGray
Write-Host "    3. Point to inventory.json when prompted" -ForegroundColor DarkGray
Write-Host ""
