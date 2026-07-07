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

    This file previously carried an Authenticode signature block. Any edit
    invalidates that signature, so the stale block was removed rather than
    left in place (a stale signature fails closed under AllSigned and is
    misleading under any other policy). scan.cmd launches this script with
    -ExecutionPolicy Bypass, so signing isn't required for that flow. If your
    environment enforces AllSigned/RemoteSigned, re-sign this file with
    Set-AuthenticodeSignature before distributing it.
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
            # NOTE: HID was missing from this allowlist, which silently dropped
            # every HID-enumerated device (touchpads, biometric readers, HID
            # sensors, some keyboards/mice) from the inventory. Added below.
            if ($upper -match '^(PCI|USB|ACPI|HDAUDIO|SCSI|IDE|SBEMBUS|HTREE|SW|HID)\\') {
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

# ── JSON writer ──────────────────────────────────────────────────────────
# ConvertTo-Json was found to emit an invalid, unescaped backslash for
# certain hardware IDs (reported case: "HID\VEN_ATML&DEV_1000&COL01"),
# producing an inventory.json that DriverDex could not parse. Because that
# break is only discovered later, on a different machine, after the
# air-gapped PC has already been disconnected, inventory.json is written by
# hand below instead, with its own escaper, and the output is re-parsed and
# checked before it is ever written to disk - so a bug here fails loudly on
# THIS machine instead of silently shipping a bad file.

function ConvertTo-JsonStringLiteral {
    <#
    .SYNOPSIS Encodes a raw string as a JSON string literal (quotes included).
    .DESCRIPTION
        Escapes per RFC 8259 (control chars, backslash, double quote), plus
        \u-escapes &, ', <, > so the file is also safe to embed directly in
        HTML/JS without further processing.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }

    $sb = [System.Text.StringBuilder]::new($Value.Length + 8)
    [void]$sb.Append('"')

    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch   = $Value[$i]
        $code = [int]$ch

        if     ($ch -eq '"')  { [void]$sb.Append('\"') }
        elseif ($ch -eq '\')  { [void]$sb.Append('\\') }
        elseif ($code -eq 0x08) { [void]$sb.Append('\b') }
        elseif ($code -eq 0x09) { [void]$sb.Append('\t') }
        elseif ($code -eq 0x0A) { [void]$sb.Append('\n') }
        elseif ($code -eq 0x0C) { [void]$sb.Append('\f') }
        elseif ($code -eq 0x0D) { [void]$sb.Append('\r') }
        elseif ($code -lt 0x20 -or $code -eq 0x26 -or $code -eq 0x27 -or $code -eq 0x3C -or $code -eq 0x3E) {
            [void]$sb.Append([string]::Format('\u{0:x4}', $code))
        }
        else { [void]$sb.Append($ch) }
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-InventoryJson {
    <#
    .SYNOPSIS Hand-rolled, self-validating JSON writer for inventory.json.
    .DESCRIPTION
        Builds the document with ConvertTo-JsonStringLiteral (no
        ConvertTo-Json involved), then re-parses its own output and checks
        the HWID count round-trips before writing anything to disk.
    #>
    param(
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$HWIDs,
        [Parameter(Mandatory)][string]$Path
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('{')

    [void]$sb.Append('  "Architecture": ')
    [void]$sb.AppendLine((ConvertTo-JsonStringLiteral $Architecture) + ',')

    if ($HWIDs.Count -eq 0) {
        [void]$sb.AppendLine('  "HWIDs": []')
    } else {
        [void]$sb.AppendLine('  "HWIDs": [')
        for ($i = 0; $i -lt $HWIDs.Count; $i++) {
            $literal = ConvertTo-JsonStringLiteral $HWIDs[$i]
            if ($i -lt $HWIDs.Count - 1) { $literal += ',' }
            [void]$sb.AppendLine('    ' + $literal)
        }
        [void]$sb.AppendLine('  ]')
    }

    [void]$sb.AppendLine('}')
    $json = $sb.ToString()

    # Self-validate before trusting this file.
    try {
        $parsed = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "generated JSON failed to round-trip parse - $($_.Exception.Message)"
    }
    # NOTE: @($null).Count is 1, not 0 (a well-known PowerShell quirk), and
    # some PS versions parse an empty JSON array back as $null - so $null is
    # treated as count 0 here rather than being wrapped naively, or a
    # legitimate zero-HWID scan would spuriously fail this check.
    $parsedCount = if ($null -eq $parsed.HWIDs) { 0 } else { @($parsed.HWIDs).Count }
    if ($parsedCount -ne $HWIDs.Count) {
        throw "JSON round-trip HWID count mismatch (wrote $($HWIDs.Count), read back $parsedCount)"
    }

    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -NoNewline
}

# ── Write inventory.json ─────────────────────────────────────────────────
$outputPath = Join-Path $PSScriptRoot 'inventory.json'

try {
    Write-InventoryJson -Architecture $arch -HWIDs $hwidArray -Path $outputPath
} catch {
    Write-Host ""
    Write-Host "  [!] Failed to write inventory.json: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  [!] No file was written. Please report this error." -ForegroundColor Red
    Write-Host ""
    exit 1
}

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
