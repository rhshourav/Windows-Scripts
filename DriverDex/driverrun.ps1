#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex — Automatic Hardware Driver Detector & Installer  v2.2.3
    Run via: irm https://your-url/DriverDex-Installer.ps1 | iex

.DESCRIPTION
    Scans all PnP hardware devices, queries the DriverDex REST API for matching
    drivers, lets the user review and select packages, then downloads (with
    real-time progress + SHA-256 verification), extracts, and installs via
    pnputil — all in a single self-contained file. Git LFS pointers are
    resolved transparently. Multi-part archives are reassembled automatically.

.NOTES
    Compatible : Windows 7 SP1 · 8.1 · 10 · 11  (x86 & x64)
    Requires   : PowerShell 5.1+
    Elevation  : Recommended (auto-elevates on request)
    Author     : DriverDex — https://github.com/rhshourav/driverdex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Suppress PS built-in progress bars

# ═══════════════════════════════════════════════════════════════════════════════
#  SAFE PROPERTY ACCESS  (StrictMode guard for dynamic/JSON-shaped objects)
# ═══════════════════════════════════════════════════════════════════════════════
function Get-Prop {
    <#
    .SYNOPSIS Reads a property safely under Set-StrictMode -Version Latest.
             Handles BOTH PSCustomObject (PS 6+) and Newtonsoft JObject (PS 5.1).

             In PowerShell 5.1, ConvertFrom-Json returns Newtonsoft.Json.Linq.JObject
             instances. PSObject.Properties[] wrapping a JObject does NOT expose JSON
             fields — every lookup returns $null. This function detects JObject and
             uses the Newtonsoft Item[] indexer instead, which works correctly on PS 5.1.

             In PowerShell 6+, ConvertFrom-Json returns proper PSCustomObject, so
             PSObject.Properties[] works as expected.
    .PARAMETER Obj      The object to read from (may be $null)
    .PARAMETER Name     Property name to look up
    .PARAMETER Default  Value to return if the object is $null or lacks the property
    #>
    param(
        [object]$Obj,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Obj) { return $Default }

    # ── PS 5.1: ConvertFrom-Json returns Newtonsoft JObject/JArray ──────────
    # JObject exposes properties via its Item[] indexer, not PSObject.Properties.
    # JToken.ToObject([string]) converts the JValue to a native .NET type.
    $typeName = $Obj.GetType().FullName
    if ($typeName -like 'Newtonsoft.Json.Linq.*') {
        try {
            $token = $Obj[$Name]
            if ($null -eq $token) { return $Default }
            # JTokenType.Null means the JSON field is explicitly null
            if ($token.Type.ToString() -eq 'Null') { return $Default }
            $val = $token.ToObject([object])
            if ($null -eq $val) { return $Default }
            return $val
        } catch { return $Default }
    }

    # ── PS 6+ / PSCustomObject: reflection-based lookup ─────────────────────
    $member = $Obj.PSObject.Properties[$Name]
    if ($null -eq $member) { return $Default }
    $val = $member.Value
    if ($null -eq $val) { return $Default }
    return $val
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ARRAY-SAFE FIELD FLATTENING
# ═══════════════════════════════════════════════════════════════════════════════
function ConvertTo-CleanFieldString {
    <#
    .SYNOPSIS Normalizes a raw API field into a short, readable string.
    .DESCRIPTION
        For broad/generic queries, DriverDex sometimes returns a field (arch,
        version, provider, category, display_name) whose value is a genuinely
        bundled result covering many devices — and critically, that bundling
        already happened server-side, so by the time it reaches us it's a
        plain STRING full of space-separated duplicate tokens
        (e.g. "x64 x86 x86 x86 x64 x64..."), not a structured JSON array.
        A raw [string](...) cast just passes that straight through unchanged.

        This function splits on whitespace, de-duplicates (case-insensitive,
        order-preserving), and only rewrites the value when duplicates were
        actually found — a real, clean multi-word name like "Atmel Corp" or
        "Intel Corporation" has no duplicate tokens and is returned as-is,
        untouched. True JSON arrays are handled the same way, token-by-token.
    .PARAMETER Value      Raw value (string, array, JArray, or $null)
    .PARAMETER Separator  Delimiter used to join distinct values (default ' / ')
    .PARAMETER MaxItems   Max distinct values shown before collapsing to "+N more"
    #>
    param(
        $Value,
        [string]$Separator = ' / ',
        [int]$MaxItems = 3
    )

    if ($null -eq $Value) { return '' }

    $isRealArray = ($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])

    $rawTokens = [System.Collections.Generic.List[string]]::new()
    if ($isRealArray) {
        foreach ($v in @($Value)) {
            $s = try { ([string]$v).Trim() } catch { '' }
            if ($s) { $rawTokens.Add($s) }
        }
    } else {
        $s = try { ([string]$Value).Trim() } catch { '' }
        if ($s) { foreach ($tok in ($s -split '\s+')) { if ($tok) { $rawTokens.Add($tok) } } }
    }

    if ($rawTokens.Count -eq 0) { return '' }

    $unique = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tok in $rawTokens) {
        if ($seen.Contains($tok)) { continue }
        [void]$seen.Add($tok)
        $unique.Add($tok)
    }

    # No duplicates collapsed and it wasn't a true array -> this is an ordinary
    # human-readable value (e.g. "Atmel Corp"); return it exactly as received.
    if (-not $isRealArray -and $unique.Count -eq $rawTokens.Count) {
        return ([string]$Value).Trim()
    }

    if ($unique.Count -le $MaxItems) { return ($unique -join $Separator) }
    return "$($unique[0..($MaxItems-1)] -join $Separator) +$($unique.Count - $MaxItems) more"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════
$Script:VERSION       = '2.2.3'
$Script:API_BASE      = 'https://driverdex-check.driverdex.workers.dev/api/hwid'
$Script:LFS_BATCH_URL = 'https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch'
$Script:EXTRACTOR_URL = 'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/extractor/extractor.exe'
$Script:GITHUB_HOST   = 'github.com'
$Script:API_HOST      = 'driverdex-check.driverdex.workers.dev'
$Script:LOG_PATH      = Join-Path $env:TEMP "DriverDex-$(Get-Date -Format 'yyyyMMdd').log"
$Script:scratch       = $null   # set in Main, cleaned up on exit

# ═══════════════════════════════════════════════════════════════════════════════
#  TLS BOOTSTRAP  (required for Windows 7/8 compatibility)
# ═══════════════════════════════════════════════════════════════════════════════
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor
        [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LOGGING
# ═══════════════════════════════════════════════════════════════════════════════
function Write-Log {
    <#
    .SYNOPSIS Appends a timestamped line to the session log file.
    .PARAMETER Level  Severity label: INFO / WARN / ERROR
    .PARAMETER Msg    Message text
    .PARAMETER Err    Optional ErrorRecord for stack-trace capture
    #>
    param([string]$Level, [string]$Msg, [System.Management.Automation.ErrorRecord]$Err = $null)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    try { Add-Content -LiteralPath $Script:LOG_PATH -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    if ($Err) {
        try { Add-Content -LiteralPath $Script:LOG_PATH -Value $Err.ScriptStackTrace -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SEMANTIC OUTPUT HELPERS  (ALL console output routes through these)
# ═══════════════════════════════════════════════════════════════════════════════
function Write-Step    { param([string]$Msg) Write-Host "  » $Msg"       -ForegroundColor White }
function Write-OK      { param([string]$Msg) Write-Host "  ✔ $Msg"       -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "  ⚠ $Msg"       -ForegroundColor Yellow; Write-Log -Level WARN  -Msg $Msg }
function Write-Info    { param([string]$Msg) Write-Host "    $Msg"        -ForegroundColor DarkGray }
function Write-Sub     { param([string]$Msg) Write-Host "    ↓ $Msg"     -ForegroundColor Cyan }
function Write-Accent  { param([string]$Msg) Write-Host "  $Msg"         -ForegroundColor Magenta }
function Write-Divider { Write-Host "  $('─' * 60)"                       -ForegroundColor DarkGray }

function Write-Err {
    <#
    .SYNOPSIS Renders a structured error message. Never exposes raw exceptions.
    .PARAMETER What   Plain-English description of what failed
    .PARAMETER Reason Technical detail (no raw exception text)
    .PARAMETER Fix    Actionable next step for the user
    .PARAMETER Err    Optional ErrorRecord for log capture
    #>
    param(
        [string]$What,
        [string]$Reason = '',
        [string]$Fix    = '',
        [System.Management.Automation.ErrorRecord]$Err = $null
    )
    Write-Host "  ✘ $What"                               -ForegroundColor Red
    if ($Reason) { Write-Host "    Reason : $Reason"    -ForegroundColor DarkGray }
    if ($Fix)    { Write-Host "    Fix    : $Fix"        -ForegroundColor DarkGray }
    Write-Host   "    Log    : $Script:LOG_PATH"         -ForegroundColor DarkGray
    Write-Log -Level ERROR -Msg "$What | $Reason" -Err $Err
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ASCII BANNER
# ═══════════════════════════════════════════════════════════════════════════════
function Write-Header {
    <#
    .SYNOPSIS Renders the DriverDex branded header using box-drawing characters.
             Box width is computed from the widest art row so content never overflows.
    #>

    # Inner width = 74 → terminal line = 2(indent) + 1(╔) + 74 + 1(╗) = 78 chars
    # Safe on any 80-column console.
    $inner = 74

    # Pad a string to exactly $inner chars (truncates if somehow over, never overflows)
    function _Pad { param([string]$s) $s.PadRight($inner).Substring(0, $inner) }

    $top = '╔' + ('═' * $inner) + '╗'
    $bot = '╚' + ('═' * $inner) + '╝'
    $blank = '║' + (' ' * $inner) + '║'

    Write-Host ""
    Write-Host "  $top"    -ForegroundColor DarkCyan
    Write-Host "  $blank"  -ForegroundColor DarkCyan

    # ── ASCII art logo — each row is ≤71 chars, padded to 74 ──────────────
    $artRows = @(
        ' ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗',
        ' ██╔══██╗██╔══██╗██║██║   ██║██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝',
        ' ██║  ██║██████╔╝██║╚██╗ ██╔╝█████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝ ',
        ' ██║  ██║██╔══██╗██║ ╚████╔╝ ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗ ',
        ' ██████╔╝██║  ██║██║  ╚██╔╝  ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗',
        ' ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝'
    )
    foreach ($row in $artRows) {
        Write-Host "  ║$(_Pad $row)║" -ForegroundColor Cyan
    }

    # ── Metadata rows ──────────────────────────────────────────────────────
    Write-Host "  $blank" -ForegroundColor DarkCyan

    # Separator line inside box
    $sepLine = '  ' + ('─' * ($inner - 4))
    Write-Host "  ║$(_Pad $sepLine)║" -ForegroundColor DarkGray

    $v      = "  Automatic Driver Detector & Installer  v$Script:VERSION"
    $tag    = "  Hardware confidence, one script away."
    $url    = "  https://github.com/rhshourav/driverdex"
    Write-Host "  ║$(_Pad $v)║"   -ForegroundColor White
    Write-Host "  ║$(_Pad $tag)║" -ForegroundColor DarkGray
    Write-Host "  ║$(_Pad $url)║" -ForegroundColor DarkGray
    Write-Host "  $blank"         -ForegroundColor DarkCyan
    Write-Host "  $bot"           -ForegroundColor DarkCyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SPINNER  (animated single-line wait indicator)
# ═══════════════════════════════════════════════════════════════════════════════
$Script:SpinnerFrames = [char[]]@(0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
                                   0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
$Script:SpinIdx = 0

function Show-Spinner {
    <#
    .SYNOPSIS Renders one spinner frame on the current line (no newline).
    .PARAMETER Label  Text to show beside the spinner
    #>
    param([string]$Label)
    $f = $Script:SpinnerFrames[$Script:SpinIdx % $Script:SpinnerFrames.Count]
    $Script:SpinIdx++
    Write-Host "`r  $f $Label   " -NoNewline -ForegroundColor Cyan
}

function Clear-SpinnerLine {
    Write-Host "`r$(' ' * 72)`r" -NoNewline
}

# ═══════════════════════════════════════════════════════════════════════════════
#  VALIDATED INPUT  (single function for ALL user prompts)
# ═══════════════════════════════════════════════════════════════════════════════
function Read-Input {
    <#
    .SYNOPSIS Unified prompt with default value and optional validator.
    .PARAMETER Prompt    Display text
    .PARAMETER Default   Value used when user presses Enter with no input
    .PARAMETER Validator ScriptBlock returning $true/$false; receives typed value
    .PARAMETER ErrMsg    Inline error shown on validation failure
    #>
    param(
        [string]$Prompt,
        [string]$Default   = '',
        [scriptblock]$Validator = $null,
        [string]$ErrMsg    = 'Invalid input. Please try again.'
    )
    $attempts = 0
    while ($attempts -lt 3) {
        Write-Host "  ▸ $Prompt " -ForegroundColor White -NoNewline
        if ($Default) { Write-Host "[default: $Default] " -ForegroundColor DarkGray -NoNewline }
        Write-Host "> " -ForegroundColor DarkCyan -NoNewline
        $val = $Host.UI.ReadLine()
        if ([string]::IsNullOrWhiteSpace($val)) { $val = $Default }
        $val = $val.Trim()
        if (-not $Validator -or (& $Validator $val)) { return $val }
        Write-Host "  ✘ $ErrMsg" -ForegroundColor Red
        $attempts++
    }
    Write-Warn "Using default: $Default"
    return $Default
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ELEVATION & OS DETECTION
# ═══════════════════════════════════════════════════════════════════════════════
function Test-Administrator {
    <#.SYNOPSIS Returns $true if the current process is elevated.#>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OSInfo {
    <#.SYNOPSIS Returns a PSObject with OS caption, build, arch, and PS version.#>
    $os = $null
    try   { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
    catch { try { $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {} }
    [pscustomobject]@{
        Caption   = if ($os) { $os.Caption }     else { 'Unknown Windows' }
        Build     = if ($os) { $os.BuildNumber } else { '0' }
        Version   = if ($os) { $os.Version }     else { '0.0' }
        Arch      = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        PSVersion = $PSVersionTable.PSVersion.ToString()
    }
}

function Request-Elevation {
    <#
    .SYNOPSIS Offers to relaunch the script as Administrator if not already elevated.
    Works whether the script was invoked via a file path or via irm | iex.
    Strategy: always write the running script to a temp .ps1 file, then
    Start-Process -Verb RunAs that file so the elevated window has something
    concrete to execute and stays open for user interaction.
    #>
    if (Test-Administrator) { return }

    Write-Warn 'Not running as Administrator.'
    Write-Info 'Steps requiring elevation: driver install via pnputil.'
    Write-Info 'Without elevation: files are saved but drivers will NOT be installed.'
    Write-Host ""

    $choice = Read-Input -Prompt 'Relaunch as Administrator?' -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'

    if ($choice -notmatch '^[Yy]') {
        Write-Warn "Continuing without elevation — driver install will be skipped (download still works)."
        return
    }

    try {
        # Determine the script source path
        $scriptPath = $PSCommandPath   # non-empty when run as a .ps1 file

        if (-not $scriptPath) {
            # Invoked via irm | iex — $PSCommandPath is empty.
            # Download the script to a temp file so the elevated process has a
            # real file to execute (avoids the flash-and-close problem).
            $scriptPath = Join-Path $env:TEMP 'DriverDex-elevated.ps1'
            $installerUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex/driverrun.ps1'
            Write-Step "Saving script for elevated relaunch..."
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $scriptPath `
                    -UseBasicParsing -ErrorAction Stop
                Write-OK "Script saved to temp file."
            } catch {
                Write-Warn "Could not save script for relaunch: $($_.Exception.Message)"
                Write-Warn "Continuing without elevation — driver install will be skipped."
                Write-Log -Level WARN -Msg "Elevation relaunch download failed: $($_.Exception.Message)"
                return
            }
        }

        Write-Step "Relaunching as Administrator..."
        Start-Process powershell.exe -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -ErrorAction Stop

        # Original (non-elevated) process exits — elevated window owns the session.
        exit 0

    } catch {
        Write-Warn "Auto-elevation failed. Continuing without admin — install step will be skipped."
        Write-Log -Level WARN -Msg "Auto-elevation failed: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  NETWORK CHECK
# ═══════════════════════════════════════════════════════════════════════════════
function Test-NetworkConnectivity {
    <#
    .SYNOPSIS DNS-resolves known hosts to verify internet access before API calls.
    Returns $true if both resolve successfully.
    #>
    $Script:SpinIdx = 0
    $ok = $true
    foreach ($host_ in @($Script:GITHUB_HOST, $Script:API_HOST)) {
        Show-Spinner -Label "Checking connectivity to $host_..."
        try {
            [System.Net.Dns]::GetHostEntry($host_) | Out-Null
        } catch {
            Clear-SpinnerLine
            Write-Err -What "No internet detected — cannot reach $host_." `
                      -Reason "DNS resolution failed for $host_." `
                      -Fix    "Check your network connection and re-run the script."
            $ok = $false
            break
        }
    }
    Clear-SpinnerLine
    if ($ok) { Write-OK "Network connectivity confirmed." }
    return $ok
}

# ═══════════════════════════════════════════════════════════════════════════════
#  HARDWARE ENUMERATION
# ═══════════════════════════════════════════════════════════════════════════════
function Get-AllHardwareIDs {
    <#
    .SYNOPSIS Collects every unique hardware ID from PnP devices.
    Returns a string[] of de-duplicated, upper-cased HWID strings.
    #>
    Write-Step "Scanning hardware..."
    $hwids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Primary: CIM Win32_PnPEntity (PS 5.1+)
    $devices = $null
    try {
        $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 }
    } catch {
        Write-Warn "CIM query failed — falling back to WMI (Windows 7 mode)..."
        Write-Log -Level WARN -Msg "CIM fallback: $($_.Exception.Message)"
        try {
            $devices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.HardwareID }
        } catch {
            Write-Log -Level ERROR -Msg "WMI also failed: $($_.Exception.Message)" -Err $_
        }
    }

    if ($devices) {
        $i = 0
        foreach ($dev in $devices) {
            $i++
            if ($i % 50 -eq 0) {
                Write-Host "`r    Scanning... $(@($hwids).Count) IDs found so far" -NoNewline -ForegroundColor DarkGray
            }
            foreach ($id in $dev.HardwareID) {
                if ($id -match '^(PCI|USB|ACPI|HDAUDIO|HID|ROOT|SCSI|DISPLAY|IDE|STORAGE)\\') {
                    [void]$hwids.Add($id.ToUpper())
                }
            }
        }
        Write-Host "`r$(' ' * 72)`r" -NoNewline
    }

    # Supplemental: pnputil /enum-devices (Win 8+)
    try {
        $pnpBin = "$env:SystemRoot\System32\pnputil.exe"
        if (Test-Path $pnpBin) {
            $out = & $pnpBin /enum-devices 2>$null
            if ($out) {
                $out | Select-String 'Hardware IDs:\s+(.+)' | ForEach-Object {
                    $_.Matches.Groups[1].Value -split ',' | ForEach-Object {
                        $id = $_.Trim().ToUpper()
                        if ($id -match '^(PCI|USB|ACPI|HDAUDIO)\\') { [void]$hwids.Add($id) }
                    }
                }
            }
        }
    } catch { <# supplemental — non-fatal #> }

    Write-OK "Found $(@($hwids).Count) unique hardware IDs"
    return [array]$hwids
}

function Get-ProblemDevices {
    <#
    .SYNOPSIS Returns HWIDs of devices with non-zero ConfigManagerErrorCode.
    These are devices with missing or broken drivers.
    #>
    $problem = [System.Collections.Generic.List[string]]::new()
    $count   = 0
    try {
        $bad = $null
        try {
            $bad = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.ConfigManagerErrorCode -gt 0 -and $_.HardwareID }
        } catch {
            $bad = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.ConfigManagerErrorCode -gt 0 -and $_.HardwareID }
        }
        if ($bad) {
            foreach ($dev in $bad) {
                foreach ($id in $dev.HardwareID) { $problem.Add($id.ToUpper()); $count++ }
            }
        }
    } catch { Write-Log -Level WARN -Msg "Problem device scan error: $($_.Exception.Message)" }

    if ($count -gt 0) {
        Write-Accent "  [$count PROBLEM DEVICE(S) DETECTED — missing or broken drivers]"
    }
    return [array]$problem
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LOCAL DRIVER INTELLIGENCE
#  Everything needed to answer two questions BEFORE the table is ever drawn:
#    1) For each DB match, is it already installed — and at what version?
#    2) What's installed locally that the DB has never heard of?
#  This is what lets the table show NEW / UPDATE / INSTALLED / NEWER instead
#  of dumping every match and sorting it out mid-install.
# ═══════════════════════════════════════════════════════════════════════════════
function Compare-DriverVersion {
    <#
    .SYNOPSIS Numerically compares two dotted version strings, part by part.
    Returns -1 if A is older than B, 0 if equal, 1 if A is newer than B.
    Non-numeric parts compare as 0; this is "good enough" for driver versions,
    which are virtually always dotted-numeric (e.g. 27.20.100.9664).
    #>
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -and [string]::IsNullOrWhiteSpace($B)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($A)) { return -1 }
    if ([string]::IsNullOrWhiteSpace($B)) { return 1 }
    if ($A -eq $B) { return 0 }

    $aParts = $A -split '[.\-]'
    $bParts = $B -split '[.\-]'
    $len    = [Math]::Max($aParts.Count, $bParts.Count)

    for ($i = 0; $i -lt $len; $i++) {
        $av = 0; $bv = 0
        if ($i -lt $aParts.Count) { [void][int]::TryParse($aParts[$i], [ref]$av) }
        if ($i -lt $bParts.Count) { [void][int]::TryParse($bParts[$i], [ref]$bv) }
        if ($av -ne $bv) { return [Math]::Sign($av - $bv) }
    }
    return [string]::Compare($A, $B)   # tie-break for otherwise-equal numeric parts
}

function Get-InstalledDriverSnapshot {
    <#
    .SYNOPSIS Indexes every locally-installed signed driver by hardware ID.
    Returns a hashtable: key = uppercased HardWareID, value = {Provider,
    Version, DeviceName, DriverDate}. Built ONCE up front so every later
    "is this installed?" check is an O(1) lookup instead of a fresh WMI query.
    #>
    Write-Step "Indexing locally installed drivers..."
    $snapshot = @{}
    try {
        $signed = $null
        try {
            $signed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop
        } catch {
            $signed = Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction SilentlyContinue
        }
        foreach ($s in $signed) {
            if (-not $s.HardWareID) { continue }
            $key   = $s.HardWareID.ToUpper()
            $entry = [pscustomobject]@{
                Provider   = $s.DriverProviderName
                Version    = $s.DriverVersion
                DeviceName = $s.DeviceName
                DriverDate = $s.DriverDate
            }
            if (-not $snapshot.ContainsKey($key) -or
                (Compare-DriverVersion $entry.Version $snapshot[$key].Version) -gt 0) {
                $snapshot[$key] = $entry
            }
        }
    } catch {
        Write-Log -Level WARN -Msg "Installed driver snapshot failed: $($_.Exception.Message)"
    }
    Write-OK "Indexed $($snapshot.Count) installed driver record(s) by hardware ID."
    return $snapshot
}

function Get-UnmatchedLocalDrivers {
    <#
    .SYNOPSIS Finds hardware whose installed driver works fine, but whose
    hardware ID returned ZERO matches from the DriverDex API — i.e. hardware
    the database has never seen. These are the strongest possible
    contribution candidates: a working driver only the user currently has.
    .PARAMETER AllHWIDs       Every hardware ID found on this machine
    .PARAMETER MatchedDrivers Results from Search-Drivers (have .MatchedHWID)
    .PARAMETER Snapshot       Result of Get-InstalledDriverSnapshot
    #>
    param([string[]]$AllHWIDs, [object[]]$MatchedDrivers, [hashtable]$Snapshot)

    $matchedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $MatchedDrivers) { [void]$matchedSet.Add($d.MatchedHWID) }

    $unknown = [System.Collections.Generic.List[object]]::new()
    foreach ($hwid in $AllHWIDs) {
        if ($matchedSet.Contains($hwid)) { continue }
        $info = $Snapshot[$hwid.ToUpper()]
        if (-not $info) { continue }   # nothing installed for this ID either — not contributable
        $unknown.Add([pscustomobject]@{
            HWID       = $hwid
            DeviceName = $info.DeviceName
            Provider   = $info.Provider
            Version    = $info.Version
        })
    }
    return [array]$unknown
}

function Get-DriverClassification {
    <#
    .SYNOPSIS Single source of truth for how a driver row is labeled, colored,
    and whether it's selected by default. Combines DB install-status with
    problem-device and superseded flags so the table and the menu's "SMART"
    default always agree with each other.
    #>
    param([object]$Driver, [string[]]$ProblemHWIDs)

    $isProblem    = $ProblemHWIDs -contains $Driver.MatchedHWID
    $isSuperseded = [bool]$Driver.SupersededBy
    $status       = $Driver.InstallStatus

    $label = switch ($status) {
        'NEW'     { 'NEW' }
        'UPDATE'  { "UPDATE → v$($Driver.Version)" }
        'CURRENT' { 'INSTALLED ✔' }
        'NEWER'   { 'NEWER INSTALLED' }
        default   { 'NEW' }
    }
    $color = switch ($status) {
        'NEW'     { 'Green' }
        'UPDATE'  { 'Cyan' }
        'CURRENT' { 'DarkGray' }
        'NEWER'   { 'DarkGray' }
        default   { 'White' }
    }
    $code = $status

    if ($isSuperseded) {
        $code  = 'SUPERSEDED'
        $label = '[SUPERSEDED]'
        $color = 'DarkGray'
    }
    if ($isProblem) {
        $code  = 'PROBLEM'
        $label = "⚠ PROBLEM DEV · $label"
        $color = 'Yellow'
    }

    # Recommended-by-default = needs action AND isn't a known-worse pick
    $recommended = (-not $isSuperseded) -and ($isProblem -or $status -in @('NEW', 'UPDATE'))

    return [pscustomobject]@{
        StatusCode   = $code
        Label        = $label
        Color        = $color
        Recommended  = $recommended
        IsProblem    = $isProblem
        IsSuperseded = $isSuperseded
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  API QUERY
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-ApiWithRetry {
    <#
    .SYNOPSIS Calls the HWID API with up to 3 retries and exponential backoff.
             Used by the auto-detect flow where reliability matters more than speed.
    .PARAMETER HWID  The hardware ID string to query
    Returns the parsed JSON response or $null on failure.
    #>
    param([string]$HWID)
    $encoded = [Uri]::EscapeDataString($HWID)
    $url     = "$Script:API_BASE/$encoded"
    $delays  = @(2, 4, 8)
    for ($try = 0; $try -le 2; $try++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            return ($resp.Content | ConvertFrom-Json)
        } catch {
            if ($try -lt 2) {
                $d = $delays[$try]
                Write-Log -Level WARN -Msg "API retry $($try+1)/3 for $HWID in ${d}s: $($_.Exception.Message)"
                Start-Sleep -Seconds $d
            }
        }
    }
    return $null
}

function Invoke-ApiFast {
    <#
    .SYNOPSIS Single-shot HWID API call with a short timeout — no retries, no backoff.
             Used by the search cache builder where speed matters and failures are cheap
             (the cache just skips that HWID and moves on).
    .PARAMETER HWID    Hardware ID string to query
    .PARAMETER ApiBase Base API URL
    Returns the parsed JSON response or $null on any failure.
    #>
    param([string]$HWID, [string]$ApiBase)
    try {
        $url  = "$ApiBase/$([Uri]::EscapeDataString($HWID))"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        return ($resp.Content | ConvertFrom-Json)
    } catch { return $null }
}

function ConvertTo-NormalizedDriverRecord {
    <#
    .SYNOPSIS Converts one raw API match object into the canonical PascalCase
             [pscustomobject] shape used everywhere downstream. This is the
             ONLY place that should ever read snake_case API fields — every
             other function (rendering, install, detail view) must consume
             objects that already went through here. Centralizing this means
             a malformed/raw API object can never reach Show-SearchResultsTable
             or Get-SearchResultDetail and trip Set-StrictMode.
    .PARAMETER M           Raw match object from the API JSON response
    .PARAMETER MatchedHWID Optional HWID this record was matched against
    .PARAMETER Score       Relevance score to tag onto the record
    #>
    param(
        [Parameter(Mandatory)] $M,
        [string]$MatchedHWID = '',
        [int]$Score = 50
    )
    $dn   = ConvertTo-CleanFieldString (Get-Prop $M 'display_name' (Get-Prop $M 'name' ''))
    $prov = ConvertTo-CleanFieldString (Get-Prop $M 'provider' '')
    $cat  = ConvertTo-CleanFieldString (Get-Prop $M 'category' '')
    $id   = Get-Prop $M 'driver_id' (Get-Prop $M 'id' '')
    $zip  = Get-Prop $M 'zip_parts' 1
    $arch = ConvertTo-CleanFieldString (Get-Prop $M 'arch' 'any')
    return [pscustomobject]@{
        DriverId    = $id
        DisplayName = if ($dn)            { $dn }             else { "$prov $cat".Trim() }
        Provider    = $prov
        Category    = $cat
        Version     = ConvertTo-CleanFieldString (Get-Prop $M 'version' '')
        Arch        = if ($arch) { $arch } else { 'any' }
        PrimaryUrl  = Get-Prop $M 'primary_url' ''
        ZipParts    = [int]$zip
        MatchedHWID = $MatchedHWID
        Score       = $Score
    }
}

function Build-HwidCache {
    <#
    .SYNOPSIS Scans all local hardware IDs against the HWID API and stores the
             flattened driver list in $Script:HwidCache. Called once per session
             the first time a keyword search needs a fallback.

    Strategy: query every unique HWID CONCURRENTLY via a runspace pool (works
    on PowerShell 5.1+, no extra modules required) instead of one-at-a-time.
    A hard wall-clock budget caps total build time regardless of how many
    HWIDs are queried or how unresponsive the API is — a dead endpoint can no
    longer turn this into a multi-minute stall. Whatever finished within the
    budget is kept; anything still in flight is abandoned.
    #>
    param(
        [string]$ApiBase,
        [int]$MaxConcurrency = 16,
        [int]$PerCallTimeoutSec = 5,
        [int]$TotalBudgetSec = 12
    )

    # ── Collect unique HWIDs from PnP ────────────────────────────────────────
    $hwids = $null
    try {
        $hwids = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 } |
                   ForEach-Object { $_.HardwareID } |
                   Sort-Object -Unique)
    } catch {
        try {
            $hwids = @(Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.HardwareID } |
                       ForEach-Object { $_.HardwareID } |
                       Sort-Object -Unique)
        } catch { $hwids = @() }
    }
    if (-not $hwids -or $hwids.Count -eq 0) {
        $Script:HwidCache      = @()
        $Script:HwidCacheBuilt = $true
        return
    }

    $all  = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # ── Runspace pool: fire all HWID lookups concurrently ───────────────────
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrency)
    $pool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()

    $workerScript = {
        param($Hwid, $ApiBase, $TimeoutSec)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        try {
            $url  = "$ApiBase/$([Uri]::EscapeDataString($Hwid))"
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            return [pscustomobject]@{ Hwid = $Hwid; Data = ($resp.Content | ConvertFrom-Json) }
        } catch {
            return [pscustomobject]@{ Hwid = $Hwid; Data = $null }
        }
    }

    $total = $hwids.Count
    foreach ($hwid in $hwids) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).AddArgument($hwid).AddArgument($ApiBase).AddArgument($PerCallTimeoutSec)
        $jobs.Add([pscustomobject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() })
    }

    # ── Poll with a hard total-budget ceiling; draw progress as jobs finish ─
    $barW = 24
    do {
        Start-Sleep -Milliseconds 150
        $finished = @($jobs | Where-Object { $_.Handle.IsCompleted }).Count
        $fill     = if ($total -gt 0) { [int](($finished / $total) * $barW) } else { $barW }
        $bar      = ('[' + ('█' * $fill) + ('░' * ($barW - $fill)) + ']')
        Write-Host "`r  ◈ Building search index... $bar $finished/$total  " -NoNewline -ForegroundColor DarkGray
    } while (($finished -lt $total) -and ($sw.Elapsed.TotalSeconds -lt $TotalBudgetSec))

    # ── Collect whatever completed in time; stop and abandon the rest ───────
    $abandoned = @($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count
    foreach ($job in $jobs) {
        if ($job.Handle.IsCompleted) {
            try {
                $result = $job.Pipe.EndInvoke($job.Handle)
                $data   = if ($result) { $result[0].Data } else { $null }
                $matches = try { $data.matches } catch { $null }
                if ($matches) {
                    foreach ($m in @($matches)) {
                        $mEnabled = try { $m.enabled }    catch { $true }
                        $mId      = try { [string]($m.driver_id) } catch { '' }
                        if ($null -ne $mEnabled -and $mEnabled -eq $false) { continue }
                        if (-not $mId)                   { continue }
                        if ($seen.Contains($mId))         { continue }
                        [void]$seen.Add($mId)
                        $all.Add((ConvertTo-NormalizedDriverRecord -M $m -MatchedHWID $result[0].Hwid -Score 50))
                    }
                }
            } catch { }
        } else {
            try { $job.Pipe.Stop() } catch { }
        }
        $job.Pipe.Dispose()
    }
    $pool.Close()
    $pool.Dispose()

    Write-Host "`r$(' ' * 72)`r" -NoNewline   # erase progress line

    if ($abandoned -gt 0) {
        Write-Warn "Index build hit its ${TotalBudgetSec}s budget — $abandoned/$total lookup(s) skipped. Results may be partial."
    }

    $Script:HwidCache      = $all.ToArray()
    $Script:HwidCacheBuilt = $true
}

function Search-Drivers {
    <#
    .SYNOPSIS Queries the API for every HWID and returns de-duplicated driver list.
    Each result is tagged with InstallStatus (NEW/UPDATE/CURRENT/NEWER) and
    InstalledVersion by cross-referencing the local driver snapshot — so the
    table never has to guess, and nothing gets silently skipped mid-install.
    .PARAMETER HWIDs             Array of hardware ID strings
    .PARAMETER SystemArch        'x64' or 'x86'
    .PARAMETER InstalledSnapshot Result of Get-InstalledDriverSnapshot
    #>
    param([string[]]$HWIDs, [string]$SystemArch, [hashtable]$InstalledSnapshot = @{})

    Write-Step "Querying DriverDex API for $(@($HWIDs).Count) hardware IDs..."
    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $total   = @($HWIDs).Count
    $count   = 0
    $barW    = 20

    foreach ($id in $HWIDs) {
        $count++
        # Progress bar
        $pct  = [int](($count / $total) * 100)
        $fill = [int](($count / $total) * $barW)
        $bar  = ('█' * $fill) + ('░' * ($barW - $fill))
        Write-Host "`r  » Querying API... [$bar] $count / $total  " -NoNewline -ForegroundColor White

        $apiResult  = Invoke-ApiWithRetry -HWID $id
        $apiMatches = Get-Prop $apiResult 'matches'
        if (-not $apiResult -or -not $apiMatches -or @($apiMatches).Count -eq 0) { continue }

        foreach ($match in $apiMatches) {
            $mEnabled  = Get-Prop $match 'enabled'
            $mDriverId = Get-Prop $match 'driver_id' ''
            if (-not $mEnabled)                { continue }
            if ($seen.Contains($mDriverId))    { continue }

            # Arch filtering: include exact match, universal, and x86 on x64 (compat)
            $mArchRaw = Get-Prop $match 'arch'
            $mArch    = if ($mArchRaw) { $mArchRaw.ToLower() } else { '' }
            $sArch    = $SystemArch.ToLower()
            $archOk = ($mArch -eq $sArch) -or
                      ($mArch -in @('any','noarch','')) -or
                      ($mArch -eq 'x86' -and $sArch -eq 'x64')
            if (-not $archOk) { continue }

            # Determine recommendation flag: arch-matched + non-generic
            $mIsGenericRaw = Get-Prop $match 'matched_is_generic' 0
            $isRecommended = ($mArch -eq $sArch) -and ([int]$mIsGenericRaw -eq 0)

            $mVersion = Get-Prop $match 'version' ''

            # ── Cross-reference against what's actually installed locally ──────
            $localInfo = $InstalledSnapshot[$id.ToUpper()]
            if (-not $localInfo) {
                $installStatus    = 'NEW'
                $installedVersion = $null
            } else {
                $cmp = Compare-DriverVersion $localInfo.Version $mVersion
                $installStatus    = if     ($cmp -lt 0) { 'UPDATE' }
                                     elseif ($cmp -eq 0) { 'CURRENT' }
                                     else                { 'NEWER' }
                $installedVersion = $localInfo.Version
            }

            [void]$seen.Add($mDriverId)
            $mProvider  = Get-Prop $match 'provider' ''
            $mCategory  = Get-Prop $match 'category' ''
            $mDispName  = Get-Prop $match 'display_name'
            $mPrimUrl   = Get-Prop $match 'primary_url' ''
            $mZipParts  = Get-Prop $match 'zip_parts' 1
            $results.Add([pscustomobject]@{
                DriverId         = $mDriverId
                DisplayName      = if ($mDispName) { $mDispName } else { "$mProvider $mCategory".Trim() }
                Provider         = $mProvider
                Category         = $mCategory
                Version          = $mVersion
                Arch             = if ($mArchRaw) { $mArchRaw } else { 'any' }
                PrimaryUrl       = $mPrimUrl
                ZipParts         = [int]$mZipParts
                MatchedHWID      = $id
                SupersededBy     = Get-Prop $match 'superseded_by'
                IsGeneric        = [int]$mIsGenericRaw
                IsRecommended    = $isRecommended
                InstallStatus    = $installStatus
                InstalledVersion = $installedVersion
            })
        }
    }
    Write-Host ""   # newline after progress bar
    return [array]$results
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DRIVER SELECTION TABLE
# ═══════════════════════════════════════════════════════════════════════════════
function Show-DriverTable {
    <#
    .SYNOPSIS Renders a formatted, numbered driver selection table — now with
    install-status awareness (NEW / UPDATE / INSTALLED / NEWER) so the user
    can see at a glance exactly what needs action vs. what's already fine.
    .PARAMETER Drivers       Array of driver PSObjects (classified by Search-Drivers)
    .PARAMETER ProblemHWIDs  Array of HWIDs with ConfigManagerErrorCode > 0
    #>
    param([object[]]$Drivers, [string[]]$ProblemHWIDs)

    Write-Host ""
    Write-Divider
    Write-Host "  Found $($Drivers.Count) matching driver package(s) for your hardware:" -ForegroundColor Cyan
    Write-Host "  ⚠  Default: installs PROBLEM devices only (error code > 0)  ·  Optional updates listed separately" -ForegroundColor DarkYellow
    Write-Divider
    Write-Host ""

    # Column widths
    $colN = 3; $colStar = 2; $colName = 22; $colProv = 13
    $colCat = 9; $colVer = 13; $colInst = 11; $colStat = 22

    # Header
    $h = "  {0,-$colN} │ {1,-$colStar} │ {2,-$colName} │ {3,-$colProv} │ {4,-$colCat} │ {5,-$colVer} │ {6,-$colInst} │ {7}" `
         -f '#','','Name','Provider','Category','DB Ver','Installed','Status'
    Write-Host $h -ForegroundColor DarkGray
    $sep = '  {0}─┼─{1}─┼─{2}─┼─{3}─┼─{4}─┼─{5}─┼─{6}─┼─{7}' -f `
           ('─'*$colN),('─'*$colStar),('─'*$colName),('─'*$colProv),`
           ('─'*$colCat),('─'*$colVer),('─'*$colInst),('─'*$colStat)
    Write-Host $sep -ForegroundColor DarkGray

    $idx = 0
    foreach ($d in $Drivers) {
        $idx++
        $star = if ($d.IsRecommended) { '★' } else { ' ' }
        $cls  = Get-DriverClassification -Driver $d -ProblemHWIDs $ProblemHWIDs

        $dName = if ($d.DisplayName) { $d.DisplayName } else { '—' }
        $dProv = if ($d.Provider)    { $d.Provider }    else { '—' }
        $name = if ($dName.Length -gt $colName) { $dName.Substring(0,$colName-1)+'…' } else { $dName }
        $prov = if ($dProv.Length -gt $colProv) { $dProv.Substring(0,$colProv-1)+'…' } else { $dProv }
        $inst = if ($d.InstalledVersion) { $d.InstalledVersion } else { '—' }
        if ($inst.Length -gt $colInst) { $inst = $inst.Substring(0,$colInst-1)+'…' }

        $row = "  {0,-$colN} │ {1,-$colStar} │ {2,-$colName} │ {3,-$colProv} │ {4,-$colCat} │ {5,-$colVer} │ {6,-$colInst} │ {7}" `
               -f $idx, $star, $name, $prov, $d.Category, $d.Version, $inst, $cls.Label

        Write-Host $row -ForegroundColor $cls.Color
    }

    Write-Host ""
    Write-Info "★ = best arch match    PROBLEM = error/missing (default install)    UPDATE = optional    INSTALLED/NEWER = already fine"
    Write-Host ""
}

function Show-DriverMenu {
    <#
    .SYNOPSIS Renders driver table and returns the user-selected subset.
    Default selection is "SMART": only drivers that actually need action
    (NEW, UPDATE AVAILABLE, or on a PROBLEM device) are pre-selected.
    Already-installed and newer-than-DB drivers are left out unless the
    user explicitly asks for ALL or picks them by number.
    .PARAMETER Drivers       All available driver objects
    .PARAMETER ProblemHWIDs  HWIDs flagged as problem devices
    #>
    param([object[]]$Drivers, [string[]]$ProblemHWIDs)

    Show-DriverTable -Drivers $Drivers -ProblemHWIDs $ProblemHWIDs

    $classified = @($Drivers | ForEach-Object {
        [pscustomobject]@{
            Driver = $_
            Class  = (Get-DriverClassification -Driver $_ -ProblemHWIDs $ProblemHWIDs)
        }
    })
    # PROBLEMS = default: only devices flagged with ConfigManagerErrorCode > 0 (missing/broken drivers)
    $problemSet = @($Drivers | Where-Object { $ProblemHWIDs -contains $_.MatchedHWID })
    # UPDATE set: drivers with a newer version available (shown as optional, not selected by default)
    $updateSet  = @($classified | Where-Object {
        $_.Class.StatusCode -eq 'UPDATE' -and -not ($ProblemHWIDs -contains $_.Driver.MatchedHWID)
    } | ForEach-Object { $_.Driver })

    if (@($problemSet).Count -gt 0) {
        Write-OK "$(@($problemSet).Count) PROBLEM device(s) with missing/broken drivers — selected by default."
    } else {
        Write-OK "No problem devices detected. All hardware has functional drivers."
    }
    if (@($updateSet).Count -gt 0) {
        Write-Host ""
        Write-Host "  ℹ  $(@($updateSet).Count) optional driver update(s) available (older versions — not selected by default):" -ForegroundColor DarkYellow
        foreach ($u in $updateSet) {
            Write-Host "       · $($u.DisplayName)  installed v$($u.InstalledVersion) → DB v$($u.Version)" -ForegroundColor DarkGray
        }
        Write-Host "     Use 'UPDATES' or enter numbers to install these." -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Info "Selection: PROBLEMS (default, errors only) · UPDATES (optional) · ALL · NONE · numbers · q to quit"
    Write-Host ""

    $raw = Read-Input -Prompt 'Select drivers' -Default 'PROBLEMS' `
        -Validator { param($v) $v -match '^(PROBLEMS|UPDATES|ALL|NONE|q|[0-9, ]+)$' } `
        -ErrMsg    'Enter PROBLEMS, UPDATES, ALL, NONE, a list of numbers, or q to quit.'

    if ($raw -eq 'q')    { return @() }
    if ($raw -eq 'NONE') { return @() }

    if ($raw -eq 'PROBLEMS') {
        $sel = $problemSet
        if (@($sel).Count -eq 0) {
            Write-Info "No problem devices found. Use UPDATES or ALL to install/update drivers."
            return @()
        }
    } elseif ($raw -eq 'UPDATES') {
        $sel = $updateSet
        if (-not $sel -or @($sel).Count -eq 0) {
            Write-Warn "No optional updates available in the current list."
            return @()
        }
    } elseif ($raw -eq 'ALL') {
        $sel = $Drivers
    } else {
        $indices = $raw -split '[,\s]+' | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -ge 1 -and $n -le @($Drivers).Count) { $n }
        } | Where-Object { $_ } | Sort-Object -Unique
        $sel = @($indices | ForEach-Object { $Drivers[$_ - 1] })
    }

    if (-not $sel -or @($sel).Count -eq 0) { return @() }

    # Echo selection
    $names = ($sel | ForEach-Object { $_.DisplayName }) -join ', '
    Write-OK "Selected: $names"

    # Warn on superseded picks
    $supersededPicked = @($sel | Where-Object { $_.SupersededBy })
    foreach ($s in $supersededPicked) {
        Write-Warn "'$($s.DisplayName)' is superseded by $($s.SupersededBy) — consider deselecting."
    }

    # Flag deliberate repairs / downgrades so the user knows exactly what they're getting
    $alreadyCurrent = @($sel | Where-Object { $_.InstallStatus -eq 'CURRENT' })
    foreach ($c in $alreadyCurrent) {
        Write-Info "'$($c.DisplayName)' is already at v$($c.Version) — will be force-reinstalled (repair)."
    }
    $downgrades = @($sel | Where-Object { $_.InstallStatus -eq 'NEWER' })
    foreach ($dn in $downgrades) {
        Write-Warn "'$($dn.DisplayName)': installed v$($dn.InstalledVersion) is NEWER than the DB's v$($dn.Version) — this would be a downgrade."
    }

    # Confirm
    Write-Host ""
    $confirm = Read-Input -Prompt "Proceed with $(@($sel).Count) driver(s)?" -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
    if ($confirm -match '^[Nn]') { return @() }

    return @($sel)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  OUTPUT FOLDER
# ═══════════════════════════════════════════════════════════════════════════════
function Get-OutputFolder {
    <#
    .SYNOPSIS Prompts for and validates the driver output/staging folder.
    Returns the resolved, writable directory path.
    #>
    $defaultOut = Join-Path $env:USERPROFILE 'Downloads\DriverDex'
    $path = Read-Input -Prompt 'Save drivers to' -Default $defaultOut `
        -Validator { param($v) $v.Length -gt 0 } -ErrMsg 'Path cannot be empty.'

    try {
        New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop | Out-Null
        # Write test
        $testFile = Join-Path $path ".driverdex_write_test"
        [System.IO.File]::WriteAllText($testFile, 'ok')
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Err -What "Cannot write to output folder." `
                  -Reason $_.Exception.Message `
                  -Fix    "Choose a different folder or check permissions."
        throw
    }

    # Disk space check
    try {
        $drive = Split-Path -Qualifier $path
        $disk  = Get-PSDrive ($drive -replace ':','') -ErrorAction SilentlyContinue
        if ($disk) {
            $freeGB = [Math]::Round($disk.Free / 1GB, 1)
            $freeMB = $disk.Free / 1MB
            if ($freeMB -lt 500) {
                Write-Warn "Only ${freeGB} GB free on $drive — less than 500 MB recommended."
            } else {
                Write-Info "  ${freeGB} GB free on $drive ✔"
            }
        }
    } catch { <# non-fatal — disk check best-effort #> }

    Write-OK "Output folder: $path"
    return $path
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DOWNLOAD ENGINE
# ═══════════════════════════════════════════════════════════════════════════════
function Get-PartUrls {
    <#
    .SYNOPSIS Builds multi-part archive URL list from primary_url + zip_parts count.
    .PARAMETER PrimaryUrl  URL ending in .0001 (or the single file URL)
    .PARAMETER ZipParts    Number of parts (1 = single file)
    #>
    param([string]$PrimaryUrl, [int]$ZipParts)
    if ($ZipParts -le 1) { return @($PrimaryUrl) }
    $base = $PrimaryUrl -replace '\.0001$', ''
    return @(1..$ZipParts | ForEach-Object { '{0}.{1:D4}' -f $base, $_ })
}

function Resolve-LFSPointer {
    <#
    .SYNOPSIS Resolves a Git LFS pointer file to a real download URL.
    .PARAMETER PointerPath  Local path to the downloaded pointer file
    Returns the resolved download URL and any auth headers as a hashtable.
    #>
    param([string]$PointerPath)

    $oid = ''; $size = ''
    Get-Content -LiteralPath $PointerPath | ForEach-Object {
        $t = $_.Trim()
        if ($t -like 'oid sha256:*') { $oid  = $t.Substring($t.IndexOf(':') + 1).Trim() }
        elseif ($t -like 'size *')   { $size = $t.Substring(5).Trim() }
    }
    if (-not $oid -or -not $size) { throw 'Malformed Git LFS pointer: missing oid or size.' }

    $body = @{
        operation = 'download'
        transfers = @('basic')
        objects   = @(@{ oid = $oid; size = [long]$size })
    } | ConvertTo-Json -Depth 5

    $batch = Invoke-RestMethod -Uri $Script:LFS_BATCH_URL -Method Post `
             -Body $body -ContentType 'application/vnd.git-lfs+json' `
             -Headers @{ Accept = 'application/vnd.git-lfs+json' } -ErrorAction Stop

    $obj = $batch.objects[0]
    if ($obj.error) { throw "Git LFS error: $($obj.error.message)" }
    $href = $obj.actions.download.href
    if (-not $href) { throw 'Git LFS returned no download URL.' }

    $dlHeaders = @{}
    if ($obj.actions.download.header) {
        $obj.actions.download.header.PSObject.Properties |
            ForEach-Object { $dlHeaders[$_.Name] = $_.Value }
    }
    return @{ Href = $href; Headers = $dlHeaders }
}

function Get-DriverFile {
    <#
    .SYNOPSIS Downloads a file with real-time progress, LFS resolution, retry logic, and SHA-256 verify.
    .PARAMETER Url            Source URL
    .PARAMETER Dest           Local destination path
    .PARAMETER Label          Display name for progress lines
    .PARAMETER ExpectedSha256 If provided, hard-fail on hash mismatch
    .PARAMETER MaxRetries     Number of download attempts (default 3)
    #>
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label          = '',
        [string]$ExpectedSha256 = '',
        [int]   $MaxRetries     = 3
    )

    $delays = @(2, 4, 8)
    $sw     = [System.Diagnostics.Stopwatch]::new()

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $sw.Restart()
            # Initial request to get content-length
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method  = 'GET'
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 60000
            $resp = $req.GetResponse()
            $totalBytes = $resp.ContentLength   # -1 if unknown (chunked)

            $stream    = $resp.GetResponseStream()
            $outStream = [System.IO.File]::OpenWrite($Dest)
            $buf       = New-Object byte[] 65536
            $downloaded = [long]0
            $barW       = 20
            $displayLabel = if ($Label) { $Label } else { Split-Path $Url -Leaf }

            try {
                while ($true) {
                    $read = $stream.Read($buf, 0, $buf.Length)
                    if ($read -le 0) { break }
                    $outStream.Write($buf, 0, $read)
                    $downloaded += $read

                    # Progress display
                    if ($totalBytes -gt 0) {
                        $pct  = [int](($downloaded / $totalBytes) * 100)
                        $fill = [int](($downloaded / $totalBytes) * $barW)
                        $bar  = ('█' * $fill) + ('░' * ($barW - $fill))
                        $dlMB = [Math]::Round($downloaded / 1MB, 1)
                        $totMB= [Math]::Round($totalBytes / 1MB, 1)
                        Write-Host "`r  ↓ $displayLabel  [$bar]  $dlMB MB / $totMB MB  ($pct%)" -NoNewline -ForegroundColor Cyan
                    } else {
                        $f = $Script:SpinnerFrames[$Script:SpinIdx++ % $Script:SpinnerFrames.Count]
                        $dlMB = [Math]::Round($downloaded / 1MB, 1)
                        Write-Host "`r  $f $displayLabel  ${dlMB} MB downloaded" -NoNewline -ForegroundColor Cyan
                    }
                }
            } finally {
                $outStream.Close()
                $stream.Close()
                $resp.Close()
            }
            Write-Host "`r$(' ' * 80)`r" -NoNewline

            # ── Git LFS pointer detection ──────────────────────────────────────
            $fi = Get-Item -LiteralPath $Dest
            if ($fi.Length -le 1024) {
                try {
                    $firstLine = Get-Content -LiteralPath $Dest -TotalCount 1 -ErrorAction Stop
                    if ($firstLine -like 'version https://git-lfs.github.com/spec/*') {
                        Write-Sub "LFS pointer detected — resolving real file..."
                        $lfs   = Resolve-LFSPointer -PointerPath $Dest
                        $sw.Restart()
                        Invoke-WebRequest -Uri $lfs.Href -OutFile $Dest `
                            -UseBasicParsing -Headers $lfs.Headers -ErrorAction Stop
                        $fi = Get-Item -LiteralPath $Dest
                    }
                } catch [System.IO.IOException] { <# binary, not LFS — fine #> }
            }

            $elapsed = $sw.Elapsed.TotalSeconds
            $sizeMB  = [Math]::Round($fi.Length / 1MB, 2)

            # ── SHA-256 verification ───────────────────────────────────────────
            $hashResult = 'SKIPPED'
            if ($ExpectedSha256) {
                $actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLower()
                if ($actual -ne $ExpectedSha256.ToLower()) {
                    Remove-Item $Dest -Force -ErrorAction SilentlyContinue
                    throw "SHA-256 mismatch. Expected: $ExpectedSha256 | Got: $actual"
                }
                $hashResult = 'OK'
                Write-Log -Level INFO -Msg "SHA256 verified for $displayLabel"
            }

            Write-OK "$displayLabel  ·  $sizeMB MB  ·  $($elapsed.ToString('F1'))s  ·  SHA256 $hashResult"
            return

        } catch {
            Write-Host "`r$(' ' * 80)`r" -NoNewline
            $reason = $_.Exception.Message
            if ($attempt -lt $MaxRetries) {
                $d = $delays[$attempt - 1]
                Write-Host "  ↻ Retry $attempt/$MaxRetries in ${d}s — $reason" -ForegroundColor DarkYellow
                Write-Log -Level WARN -Msg "Download retry $attempt for ${Url}: $reason"
                Start-Sleep -Seconds $d
            } else {
                Write-Log -Level ERROR -Msg "Download failed after $MaxRetries attempts for ${Url}: $reason" -Err $_
                throw "Download failed after $MaxRetries attempts: $reason"
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DRIVER ALREADY INSTALLED CHECK
# ═══════════════════════════════════════════════════════════════════════════════
function Test-DriverInstalled {
    <#
    .SYNOPSIS Checks Win32_PnPSignedDriver for a matching Provider + Version.
    Returns $true if the driver is already registered in the system.
    #>
    param([string]$Provider, [string]$Version)
    try {
        $installed = $null
        try {
            $installed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
                         Where-Object { $_.ProviderName -like "*$Provider*" -and $_.DriverVersion -eq $Version }
        } catch {
            $installed = Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                         Where-Object { $_.ProviderName -like "*$Provider*" -and $_.DriverVersion -eq $Version }
        }
        return ($installed -and @($installed).Count -gt 0)
    } catch { return $false }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PER-DRIVER WORK PANEL
# ═══════════════════════════════════════════════════════════════════════════════
function Show-DriverPanel {
    <#
    .SYNOPSIS Renders the bordered work panel shown before processing each driver.
    .PARAMETER Driver  Driver PSObject
    .PARAMETER Idx     Current index (1-based)
    .PARAMETER Total   Total drivers being processed
    #>
    param([object]$Driver, [int]$Idx, [int]$Total)
    $inner = 60
    $title = "[$Idx/$Total] $($Driver.DisplayName)"
    $dash  = '─' * ([Math]::Max(0, $inner - $title.Length - 1))

    Write-Host ""
    Write-Host "  ┌─ $title $dash┐" -ForegroundColor DarkCyan
    $row1 = "  Provider: $($Driver.Provider)  │  v$($Driver.Version)  │  $($Driver.Arch)  │  $($Driver.Category)"
    $padded1 = $row1.PadRight($inner + 4)
    Write-Host "$padded1│" -ForegroundColor DarkGray
    $hwid = $Driver.MatchedHWID
    if ($hwid.Length -gt $inner - 8) { $hwid = $hwid.Substring(0, $inner - 11) + '...' }
    $row2 = "  HWID: $hwid"
    $padded2 = $row2.PadRight($inner + 4)
    Write-Host "$padded2│" -ForegroundColor DarkGray
    Write-Host "  └$('─' * ($inner + 2))┘" -ForegroundColor DarkCyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN INSTALL ROUTINE  (one driver at a time, isolated try/catch)
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-Extractor {
    <#
    .SYNOPSIS Runs extractor.exe against an archive. Fixes two separate failure modes:

             1) PATH-WITH-SPACES BUG: Start-Process -ArgumentList just joins its array
                with plain spaces and does NOT quote elements that contain spaces (e.g.
                an output folder derived from a vendor name like "Synaptics FP Sensors").
                That silently splits into multiple argv tokens and the extractor's own
                argparse rejects the stray pieces as "unrecognized arguments". The call
                operator (&) below quotes each splatted argument correctly regardless of
                embedded spaces, so this can no longer happen.

             2) CORRUPTED/TAMPERED BINARY: a failure whose own output contains a
                "[PYI-####:ERROR]" tag comes from the PyInstaller bootloader trying to
                self-extract its OWN bundled modules — i.e. extractor.exe itself is
                broken on disk (incomplete download, or antivirus quarantining/locking a
                bundled crypto module — a common false-positive trigger), not a problem
                with our arguments or the driver archive. In that case we re-download
                extractor.exe once and retry before giving up.
    .PARAMETER ExtractorPath Path to extractor.exe (overwritten in place if re-downloaded)
    .PARAMETER ArchivePath   Archive file to extract
    .PARAMETER OutputDir     Destination folder
    .OUTPUTS PSObject { Success, Output, ExitCode, IsBootstrapFailure }
    #>
    param(
        [string]$ExtractorPath,
        [string]$ArchivePath,
        [string]$OutputDir
    )

    $extractArgs = @('--file', $ArchivePath, '--output', $OutputDir, '--verify')

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $output   = @(& $ExtractorPath @extractArgs 2>&1)
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            return [pscustomobject]@{ Success = $true; Output = $output; ExitCode = 0; IsBootstrapFailure = $false }
        }

        $isBootstrapFailure = ($output -join "`n") -match '\[PYI-\d+:ERROR\]'

        if ($isBootstrapFailure -and $attempt -eq 1) {
            Write-Warn "Extractor self-extraction failed — binary may be corrupted or blocked by antivirus. Re-downloading and retrying once..."
            try {
                Remove-Item -LiteralPath $ExtractorPath -Force -ErrorAction SilentlyContinue
                Get-DriverFile -Url $Script:EXTRACTOR_URL -Dest $ExtractorPath -Label 'extractor.exe'
                continue
            } catch {
                # Re-download itself failed — fall through and report the original error.
            }
        }

        return [pscustomobject]@{ Success = $false; Output = $output; ExitCode = $exitCode; IsBootstrapFailure = $isBootstrapFailure }
    }
}

function Install-DriverPackage {
    <#
    .SYNOPSIS Downloads, extracts, and installs a single driver package.
    Returns a PSObject: { Name, Success, Skipped, RebootRequired, Path }
    .PARAMETER Driver        Driver PSObject from Search-Drivers
    .PARAMETER OutputRoot    Root folder where driver files are saved
    .PARAMETER ScratchDir    Temp directory for staging
    .PARAMETER ExtractorPath Path to the extractor.exe binary
    .PARAMETER IsAdmin       Whether the session is elevated
    #>
    param(
        [object]$Driver,
        [string]$OutputRoot,
        [string]$ScratchDir,
        [string]$ExtractorPath,
        [bool]  $IsAdmin
    )

    $result = [pscustomobject]@{
        Name           = $Driver.DisplayName
        Success        = $false
        Skipped        = $false
        RebootRequired = $false
        Path           = ''
        PartialFailure = $false   # true = some INFs in the package installed, some didn't
        PackagesAdded  = 0
        PackagesTotal  = 0
        FailedInfs     = @()
    }

    $safeName = "$($Driver.Provider)_$($Driver.Category)_$($Driver.Version)_$($Driver.Arch)" `
                -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_' -replace '_+', '_'
    $outDir   = Join-Path $OutputRoot $safeName
    $pkgTemp  = Join-Path $ScratchDir ([System.Guid]::NewGuid().ToString('N').Substring(0,8))

    try {
        New-Item -ItemType Directory -Force -Path $outDir  | Out-Null
        New-Item -ItemType Directory -Force -Path $pkgTemp | Out-Null
        $result.Path = $outDir

        # ── Already installed? ──────────────────────────────────────────────
        # InstallStatus was computed BEFORE the table was shown, so the user
        # has already seen exactly what this driver's status is. Reaching
        # this point means they explicitly chose to (re)install it via ALL,
        # PROBLEMS, or a manual number pick — so we proceed and tell them
        # what's happening, instead of silently skipping mid-run.
        if ($Driver.InstallStatus -eq 'CURRENT') {
            Write-Info "v$($Driver.Version) is already installed — reinstalling as requested (repair)."
        } elseif ($Driver.InstallStatus -eq 'NEWER') {
            Write-Warn "Installed v$($Driver.InstalledVersion) is newer than v$($Driver.Version) — proceeding anyway as requested (downgrade)."
        }

        # ── Download all parts ─────────────────────────────────────────────
        $partUrls  = @(Get-PartUrls -PrimaryUrl $Driver.PrimaryUrl -ZipParts $Driver.ZipParts)
        $firstPart = $null

        for ($pi = 0; $pi -lt @($partUrls).Count; $pi++) {
            $url      = $partUrls[$pi]
            $fileName = Split-Path $url -Leaf
            $dest     = Join-Path $pkgTemp $fileName
            if ($pi -eq 0) { $firstPart = $dest }

            Write-Sub "[$($pi+1)/$(@($partUrls).Count)] $fileName"
            Get-DriverFile -Url $url -Dest $dest -Label $fileName
        }

        # ── Extract ────────────────────────────────────────────────────────
        Write-Step "Extracting archive..."
        $extractResult = Invoke-Extractor -ExtractorPath $ExtractorPath -ArchivePath $firstPart -OutputDir $outDir
        if (-not $extractResult.Success) {
            $errLines = ($extractResult.Output | Select-Object -Last 5) -join ' | '
            $hint = if ($extractResult.IsBootstrapFailure) {
                " — this points to antivirus interference or a corrupted extractor download (re-download already retried once), not a bad archive. Try excluding the DriverDex temp/output folders from real-time scanning."
            } else { '' }
            throw "Extractor failed (exit $($extractResult.ExitCode))$hint — $errLines"
        }
        Write-OK "Extracted to: $outDir"

        # ── Manifest ───────────────────────────────────────────────────────
        @{
            driver_id       = $Driver.DriverId
            display_name    = $Driver.DisplayName
            provider        = $Driver.Provider
            category        = $Driver.Category
            version         = $Driver.Version
            arch            = $Driver.Arch
            matched_hwid    = $Driver.MatchedHWID
            sha256_parts    = @()
            installed_on    = (Get-Date -Format 'o')
            install_result  = 'pending'
            pnputil_exit    = $null
            reboot_required = $false
            generated_by    = "DriverDex v$Script:VERSION — https://github.com/rhshourav/driverdex"
        } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir 'manifest.json') -Encoding UTF8

        # ── Install via pnputil ────────────────────────────────────────────
        $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_ -ne $null })

        if (@($infs).Count -gt 0 -and $IsAdmin) {
            Write-Step "Installing $(@($infs).Count) INF package(s) via pnputil..."
            # pnputil /add-driver on a glob is not reliable in all PS versions; pass the folder instead
            $pnpArgs = @('/add-driver', "$outDir\*.inf", '/subdirs', '/install')

            # NOTE: pnputil installs every matching INF in ONE batch call and returns
            # a SINGLE exit code for the whole batch. If 2 of 3 INFs install fine and
            # one fails (e.g. a redundant/incompatible INF bundled in the same archive),
            # the exit code alone makes the WHOLE package look like a hard failure even
            # though most of it actually went in. So we capture pnputil's own console
            # output and parse its "Total/Added driver packages" tally instead of
            # trusting the exit code alone.
            $pnpOutput = @(& "$env:SystemRoot\System32\pnputil.exe" @pnpArgs 2>&1)
            $exitCode  = $LASTEXITCODE

            # Echo pnputil's own lines back to the console (capturing the output above
            # means it no longer prints live on its own).
            $pnpOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

            $totalMatch = $pnpOutput | Select-String -Pattern 'Total driver packages:\s*(\d+)'
            $addedMatch = $pnpOutput | Select-String -Pattern 'Added driver packages:\s*(\d+)'
            $totalCount = if ($totalMatch) { [int]$totalMatch[0].Matches[0].Groups[1].Value } else { @($infs).Count }
            $addedCount = if ($addedMatch) { [int]$addedMatch[0].Matches[0].Groups[1].Value } else { 0 }

            # Pair each "Adding driver package: X.inf" line with the line right after it —
            # if that next line is a failure, X.inf is the one that didn't make it in.
            $failedInfs = [System.Collections.Generic.List[string]]::new()
            for ($li = 0; $li -lt (@($pnpOutput).Count - 1); $li++) {
                if ($pnpOutput[$li] -match 'Adding driver package:\s*(.+\.inf)\s*$' -and
                    $pnpOutput[$li + 1] -match 'Failed to add driver package') {
                    $failedInfs.Add($Matches[1].Trim())
                }
            }

            $result.PackagesAdded = $addedCount
            $result.PackagesTotal = $totalCount
            $result.FailedInfs    = @($failedInfs)

            if ($exitCode -in @(0, 3010) -or ($totalCount -gt 0 -and $addedCount -eq $totalCount)) {
                Write-OK "pnputil succeeded — $addedCount/$totalCount package(s) added (exit $exitCode)"
                if ($exitCode -eq 3010) {
                    Write-Warn "Reboot required to complete driver installation."
                    $result.RebootRequired = $true
                }
                $result.Success = $true

            } elseif ($addedCount -gt 0) {
                # Partial success — this is the case you hit: some INFs installed,
                # at least one didn't. The device is very likely already working off
                # the package(s) that DID install, so this is not treated as a failure.
                $result.Success        = $true
                $result.PartialFailure = $true
                $infList = if ($failedInfs.Count -gt 0) { $failedInfs -join ', ' } else { 'one or more packages' }
                Write-Warn "Partially installed — $addedCount of $totalCount package(s) added. Not added: $infList"
                Write-Info "This is usually fine: the package that failed is often redundant or built for a different architecture/Windows build than the one(s) that succeeded."

            } else {
                $pnpMsg = switch ($exitCode) {
                    2    { "Driver may be incompatible with this Windows version." }
                    5    { "Access denied — check that you are running as Administrator." }
                    87   { "Invalid parameter passed to pnputil." }
                    default { "Unexpected pnputil exit code ($exitCode)." }
                }
                Write-Err -What "Driver install failed for $($Driver.DisplayName)" `
                          -Reason $pnpMsg `
                          -Fix    "Try the x86 variant or install manually via Device Manager at: $outDir"
            }

            # Post-install cross-check
            Start-Sleep -Seconds 2
            if (Test-DriverInstalled -Provider $Driver.Provider -Version $Driver.Version) {
                Write-OK "Cross-check PASSED — driver registered in Win32_PnPSignedDriver."
            } else {
                Write-Warn "Cross-check: driver not yet reflected in system — a reboot may be required."
            }

        } elseif (@($infs).Count -gt 0 -and -not $IsAdmin) {
            Write-Warn "INF found but script is not elevated. Open Device Manager and point it at:"
            Write-Host "      $outDir" -ForegroundColor Cyan
            $result.Success = $true   # files are ready, install is manual

        } else {
            # Fallback: vendor setup.exe / MSI
            $installer = @(Get-ChildItem -Path $outDir -Include 'setup.exe','*.msi' `
                                       -Recurse -ErrorAction SilentlyContinue |
                         Where-Object { $_ -ne $null }) | Select-Object -First 1
            if ($installer) {
                Write-Step "Vendor installer detected: $($installer.Name)"
                $run = Read-Input -Prompt "Run installer now?" -Default 'Y' `
                    -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
                if ($run -match '^[Yy]') {
                    $iArgs = if ($installer.Extension -eq '.msi') { @('/i', $installer.FullName, '/qn') } else { @() }
                    Start-Process -FilePath $installer.FullName -ArgumentList $iArgs -Wait
                    Write-OK "Vendor installer completed."
                    $result.Success = $true
                }
            } else {
                Write-Warn "No INF or vendor installer found. Files are at: $outDir"
                $result.Success = $true   # files present, user can install manually
            }
        }

        # Update manifest with final result
        try {
            $manifest = Get-Content -LiteralPath (Join-Path $outDir 'manifest.json') -Raw | ConvertFrom-Json
            $manifest.install_result  = if ($result.PartialFailure) { 'partial' } elseif ($result.Success) { 'success' } else { 'failed' }
            $manifest.reboot_required = $result.RebootRequired
            $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir 'manifest.json') -Encoding UTF8
        } catch { <# manifest update is best-effort #> }

        return $result

    } catch {
        $errMsg = $_.Exception.Message -replace [regex]::Escape($_.Exception.GetType().FullName), '' -replace '^\s*:\s*', ''
        Write-Err -What "Failed to process $($Driver.DisplayName)" `
                  -Reason $errMsg `
                  -Fix    "Check the log file for the full stack trace and try re-running the script." `
                  -Err    $_
        $result.Success = $false
        return $result

    } finally {
        Remove-Item -Recurse -Force $pkgTemp -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SUMMARY BOX
# ═══════════════════════════════════════════════════════════════════════════════
function Show-Summary {
    <#
    .SYNOPSIS Renders a bordered installation summary box after all drivers are processed.
    .PARAMETER Results  Array of driver result PSObjects
    #>
    param([object[]]$Results)

    $inner = 44
    $title = ' Installation Summary '
    $fill  = $inner - $title.Length
    $lFill = [Math]::Floor($fill / 2)
    $rFill = $fill - $lFill

    Write-Host ""
    Write-Host "  ╔══$title$('═' * $rFill)╗" -ForegroundColor DarkCyan

    foreach ($r in $Results) {
        if     ($r.Skipped)        { $sym = '─'; $col = 'DarkGray'; $label = 'skipped (already installed)' }
        elseif ($r.PartialFailure) { $sym = '⚠'; $col = 'Yellow';   $label = "installed (partial — $($r.PackagesAdded)/$($r.PackagesTotal) packages)" }
        elseif ($r.Success)        { $sym = '✔'; $col = 'Green';    $label = 'installed' }
        else                        { $sym = '✘'; $col = 'Red';      $label = 'failed' }
        $rb = if ($r.RebootRequired) { ' ⟳ reboot needed' } else { '' }
        $line = "  $sym $($r.Name)$rb — $label"
        $padded = $line.PadRight($inner + 4)
        Write-Host "  ║$padded║" -ForegroundColor $col
    }

    Write-Host "  ╚$('═' * ($inner + 2))╝" -ForegroundColor DarkCyan
    Write-Host ""

    $passed  = @($Results | Where-Object { $_.Success -and -not $_.Skipped -and -not $_.PartialFailure }).Count
    $partial = @($Results | Where-Object { $_.PartialFailure }).Count
    $skipped = @($Results | Where-Object { $_.Skipped }).Count
    $failed  = @($Results | Where-Object { -not $_.Success -and -not $_.Skipped }).Count
    Write-Info "  $passed installed  ·  $partial partial  ·  $skipped skipped  ·  $failed failed"
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  REBOOT PROMPT
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-RebootPrompt {
    <#
    .SYNOPSIS Prompts for reboot only if at least one driver flagged pnputil exit 3010.
    .PARAMETER Results  Array of driver result PSObjects
    #>
    param([object[]]$Results)
    $needsReboot = @($Results | Where-Object { $_.RebootRequired })
    if (@($needsReboot).Count -eq 0) { return }

    Write-Warn "$(@($needsReboot).Count) driver(s) require a reboot to activate."
    Write-Host ""
    $choice = Read-Input -Prompt 'Restart now to apply all drivers?' -Default 'N' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'

    if ($choice -match '^[Yy]') {
        Write-Warn "Restarting in 10 seconds... Press Ctrl+C to cancel."
        for ($i = 10; $i -ge 1; $i--) {
            Write-Host "`r    $i second(s) remaining...  " -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
        Write-Host ""
        Restart-Computer -Force
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CONTRIBUTION PROMPT
#  Shown when: (a) zero drivers found for this machine, or (b) some installed
#  drivers have no database entry / were already installed from elsewhere.
#  DriverDex is community-driven — every submission makes it better for everyone.
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-ContributePrompt {
    <#
    .SYNOPSIS  Invites the user to contribute their driver data to the DriverDex
               community database. Explains what is collected, what is NOT
               collected, and gives two launch options (TUI / background).
    .PARAMETER HWIDs                The full list of hardware IDs found on this machine
    .PARAMETER Reason               'no_drivers' | 'partial' — shapes the message tone
    .PARAMETER UnmatchedLocalDrivers Devices with a working local driver that the
                                     DriverDex database has zero record of — these
                                     get named specifically, because "we don't have
                                     YOUR Realtek audio driver" is a far stronger,
                                     more honest ask than a generic appeal.
    #>
    param(
        [string[]]$HWIDs,
        [string]  $Reason = 'no_drivers',
        [object[]]$UnmatchedLocalDrivers = @()
    )

    $w = 66
    $top = '╔' + ('═' * ($w - 2)) + '╗'
    $bot = '╚' + ('═' * ($w - 2)) + '╝'
    $mid = { param($s) "  ║  $($s.PadRight($w - 6))  ║" }

    Write-Host ""
    Write-Host "  $top" -ForegroundColor Magenta

    if ($Reason -eq 'no_drivers') {
        Write-Host (& $mid "  DriverDex has no drivers for your hardware — yet.") -ForegroundColor White
    } elseif (@($UnmatchedLocalDrivers).Count -gt 0) {
        Write-Host (& $mid "  $(@($UnmatchedLocalDrivers).Count) working driver(s) on this PC aren't in our database.") -ForegroundColor White
    } else {
        Write-Host (& $mid "  Some of your devices aren't in the DriverDex database yet.") -ForegroundColor White
    }
    Write-Host (& $mid "") -ForegroundColor Magenta
    Write-Host (& $mid "  You can change that.") -ForegroundColor Cyan
    Write-Host (& $mid "") -ForegroundColor Magenta
    Write-Host "  $bot" -ForegroundColor Magenta
    Write-Host ""

    # ── The pitch ──────────────────────────────────────────────────────────
    Write-Host "  DriverDex is 100% community-driven." -ForegroundColor White
    Write-Host "  Every hardware profile submitted makes the database smarter" -ForegroundColor DarkGray
    Write-Host "  for the next person with the same machine — maybe someone who" -ForegroundColor DarkGray
    Write-Host "  can't figure out why their device doesn't work." -ForegroundColor DarkGray
    Write-Host ""

    if (@($UnmatchedLocalDrivers).Count -gt 0) {
        Write-Host "  Here's the thing: these drivers already work, right now, on" -ForegroundColor White
        Write-Host "  YOUR machine. Nobody has to write anything new — we just need" -ForegroundColor DarkGray
        Write-Host "  a copy of what Windows already installed. As far as DriverDex" -ForegroundColor DarkGray
        Write-Host "  can tell, you may be the only person who currently has these," -ForegroundColor DarkGray
        Write-Host "  which makes you the only person who can contribute them." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Specifically, these devices have NO entry in DriverDex at all:" -ForegroundColor Cyan
        $shown = @($UnmatchedLocalDrivers | Select-Object -First 6)
        foreach ($u in $shown) {
            $dn = if ($u.DeviceName) { $u.DeviceName } else { $u.HWID }
            $vr = if ($u.Version)    { "v$($u.Version)" } else { 'version unknown' }
            Write-Host "    · $dn  ($vr)" -ForegroundColor White
        }
        if (@($UnmatchedLocalDrivers).Count -gt 6) {
            Write-Host "    · ... and $(@($UnmatchedLocalDrivers).Count - 6) more" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-Host "  Contributing takes under a minute and requires no account." -ForegroundColor White
    Write-Host ""

    # ── Transparency: what IS and ISN'T collected ──────────────────────────
    Write-Host "  What the contribution tool collects:" -ForegroundColor Cyan
    Write-Host "    ✔  Hardware IDs (PCI\VEN_..., USB\VID_... strings)" -ForegroundColor Green
    Write-Host "    ✔  Device categories and friendly names from Windows" -ForegroundColor Green
    Write-Host "    ✔  Currently installed driver versions (Provider, Version, Date)" -ForegroundColor Green
    Write-Host "    ✔  Windows version and architecture (to flag driver compatibility)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  What it does NOT collect:" -ForegroundColor Yellow
    Write-Host "    ✘  Your name, username, or any account information" -ForegroundColor DarkGray
    Write-Host "    ✘  IP address or location (submissions are anonymised server-side)" -ForegroundColor DarkGray
    Write-Host "    ✘  Files, documents, browsing data, or anything personal" -ForegroundColor DarkGray
    Write-Host "    ✘  Serial numbers, MAC addresses, or unique device identifiers" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Submissions are reviewed by maintainers before entering the" -ForegroundColor DarkGray
    Write-Host "  database. You can read the full privacy policy at:" -ForegroundColor DarkGray
    Write-Host "  https://github.com/rhshourav/driverdex/blob/main/PRIVACY.md" -ForegroundColor Cyan
    Write-Host ""

    # ── Show what would be submitted (preview) ────────────────────────────
    if (@($UnmatchedLocalDrivers).Count -eq 0) {
        Write-Host "  Preview — hardware IDs that would be submitted from this machine:" -ForegroundColor White
        $preview = @($HWIDs | Select-Object -First 6)
        foreach ($id in $preview) {
            Write-Host "    · $id" -ForegroundColor DarkGray
        }
        if (@($HWIDs).Count -gt 6) {
            Write-Host "    · ... and $(@($HWIDs).Count - 6) more hardware ID(s)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # ── Ask ────────────────────────────────────────────────────────────────
    if (@($UnmatchedLocalDrivers).Count -gt 0) {
        Write-Host "  Your submission fills in a gap only you can fill right now." -ForegroundColor White
        Write-Host "  It costs you nothing and takes less than 60 seconds." -ForegroundColor White
    } else {
        Write-Host "  Your submission directly helps the next person with your" -ForegroundColor White
        Write-Host "  hardware. It costs you nothing and takes less than 60 seconds." -ForegroundColor White
    }
    Write-Host ""

    $contrib = Read-Input `
        -Prompt  'Contribute your hardware profile to the DriverDex community?' `
        -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } `
        -ErrMsg  'Enter Y or N.'

    if ($contrib -notmatch '^[Yy]') {
        Write-Info "No problem — you can always contribute later by re-running this script."
        Write-Info "Or visit: https://github.com/rhshourav/driverdex"
        Write-Host ""
        return
    }

    # ── Thank-you ──────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  Thank you! You're helping build something genuinely useful" -ForegroundColor Green
    Write-Host "  for everyone who has the same hardware as you." -ForegroundColor Green
    Write-Host "  Your submission will be reviewed and, if valid, added to" -ForegroundColor Green
    Write-Host "  the public database — credited to the DriverDex community." -ForegroundColor Green
    Write-Host ""

    # ── Two launch options ─────────────────────────────────────────────────
    Write-Divider
    Write-Host "  How would you like to run the contribution tool?" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1]  TUI mode    — interactive, step-by-step walkthrough" -ForegroundColor Cyan
    Write-Host "       Reviews exactly what will be sent before it goes anywhere." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [2]  Background  — silent, zero-click, runs in under 30 seconds" -ForegroundColor Cyan
    Write-Host "       Collects and submits automatically; no prompts." -ForegroundColor DarkGray
    Write-Host ""

    $mode = Read-Input `
        -Prompt  'Choose contribution mode' `
        -Default '1' `
        -Validator { param($v) $v -match '^[12]$' } `
        -ErrMsg  'Enter 1 (TUI) or 2 (Background).'

    Write-Host ""

    if ($mode -eq '1') {
        Write-Step "Launching DriverDex Contribution Tool (TUI)..."
        try {
            Invoke-Expression (Invoke-RestMethod `
                'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/run.ps1')
        } catch {
            Write-Err -What "Could not launch the TUI contribution tool." `
                      -Reason $_.Exception.Message `
                      -Fix    "Run manually: irm https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/run.ps1 | iex"
        }
    } else {
        Write-Step "Launching DriverDex Contribution Tool (Background)..."
        try {
            Invoke-Expression (Invoke-RestMethod `
                'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/bg/run_bg.ps1')
        } catch {
            Write-Err -What "Could not launch the background contribution tool." `
                      -Reason $_.Exception.Message `
                      -Fix    "Run manually: irm https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/bg/run_bg.ps1 | iex"
        }
    }

    Write-Host ""
}


# ═══════════════════════════════════════════════════════════════════════════════
#  DRIVER SEARCH ENGINE  — Standalone search, download, and install menu
#  Always forces black background. Production-ready with pagination, filters,
#  multi-result display, and download-only or download+install modes.
# ═══════════════════════════════════════════════════════════════════════════════

$Script:SEARCH_API    = 'https://driverdex-check.driverdex.workers.dev/api/search'

# Session-level HWID result cache — populated once on first keyword search,
# reused for all subsequent searches. Keyword filtering is then instant in-memory.
# $null = not yet built; @() = built but empty; populated = ready to filter.
$Script:HwidCache      = $null   # [object[]] all driver records from local HWIDs
$Script:HwidCacheBuilt = $false  # set to $true once the cache population is complete

function Set-BlackBackground {
    <#
    .SYNOPSIS Forces the terminal background to black for the Search Engine UI.
             Restores on exit when called with -Restore.
    #>
    param([switch]$Restore)
    if (-not $Restore) {
        try {
            $Host.UI.RawUI.BackgroundColor = [System.ConsoleColor]::Black
            $Host.UI.RawUI.ForegroundColor = [System.ConsoleColor]::White
            Clear-Host
        } catch { <# non-fatal in non-interactive hosts #> }
    } else {
        try {
            $Host.UI.RawUI.BackgroundColor = [System.ConsoleColor]::Black
        } catch {}
    }
}

function Write-SearchBanner {
    <#.SYNOPSIS Renders the DriverDex Search Engine branded header.#>
    $inner = 74
    function _SPad { param([string]$s) $s.PadRight($inner).Substring(0, $inner) }

    $top   = '╔' + ('═' * $inner) + '╗'
    $bot   = '╚' + ('═' * $inner) + '╝'
    $blank = '║' + (' ' * $inner) + '║'

    Write-Host ""
    Write-Host "  $top"   -ForegroundColor DarkCyan
    Write-Host "  $blank" -ForegroundColor DarkCyan

    $art = @(
        '  ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗',
        '  ██╔══██╗██╔══██╗██║██║   ██║██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝',
        '  ██║  ██║██████╔╝██║╚██╗ ██╔╝█████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝ ',
        '  ██║  ██║██╔══██╗██║ ╚████╔╝ ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗ ',
        '  ██████╔╝██║  ██║██║  ╚██╔╝  ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗',
        '  ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝'
    )
    foreach ($row in $art) {
        Write-Host "  ║$(_SPad $row)║" -ForegroundColor Cyan
    }

    Write-Host "  $blank" -ForegroundColor DarkCyan
    $tagLine = "  ◈  DRIVER SEARCH ENGINE  ◈  Search · Download · Install"
    Write-Host "  ║$(_SPad $tagLine)║" -ForegroundColor Yellow
    $sub = "  Type a keyword, device name, HWID, or category to find drivers"
    Write-Host "  ║$(_SPad $sub)║"     -ForegroundColor DarkGray
    Write-Host "  $blank"              -ForegroundColor DarkCyan
    Write-Host "  $bot"               -ForegroundColor DarkCyan
    Write-Host ""
}

function Invoke-SearchAPI {
    <#
    .SYNOPSIS Queries the DriverDex search endpoint. Falls back to HWID API for
    HWID-style queries (PCI\, USB\, ACPI\, etc.) when search endpoint returns nothing.
    Always returns [object[]] — never $null, never a bare object.

    API SCHEMA (confirmed from live responses):
      Search endpoint  → .results[]  fields: driver_id, display_name, provider,
                         category, version, arch, primary_url, zip_parts, enabled
      HWID endpoint    → .matches[]  fields: driver_id (string), id (int, ignore),
                         display_name, provider, category, version, arch,
                         primary_url, zip_parts, enabled, matched_is_generic

    .PARAMETER Query  User search string
    .PARAMETER Arch   Optional architecture filter (x64 / x86 / any)
    .PARAMETER Category Optional category filter
    #>
    param(
        [string]$Query,
        [string]$Arch     = '',
        [string]$Category = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # ── Helper: build a canonical record from one raw API item ─────────────
    # Direct dot-access + try/catch bypasses PSObject.Properties[] which in PS 5.1
    # silently returns $null for pscustomobject members created inside scriptblocks.
    $buildRecord = {
        param([object]$M, [string]$HwidTag, [int]$Score)

        $mId      = try { $s = [string]($M.driver_id);    if ($s.Trim()) { $s } else { '' } } catch { '' }
        $mName    = try { ConvertTo-CleanFieldString $M.display_name } catch { '' }
        $mProv    = try { ConvertTo-CleanFieldString $M.provider }     catch { '' }
        $mCat     = try { ConvertTo-CleanFieldString $M.category }     catch { '' }
        $mVer     = try { ConvertTo-CleanFieldString $M.version }      catch { '' }
        $mArchRaw = try { $a = ConvertTo-CleanFieldString $M.arch; if ($a) { $a } else { 'any' } } catch { 'any' }
        $mUrl     = try { $s = [string]($M.primary_url);  if ($s.Trim()) { $s } else { '' } } catch { '' }

        $mZip = 1
        try {
            $zRaw = [string]($M.zip_parts)
            $zInt = 1
            if ([int]::TryParse($zRaw, [ref]$zInt) -and $zInt -ge 1) { $mZip = $zInt }
        } catch {}

        # Fallback display name when display_name is blank
        if (-not $mName.Trim()) {
            $mName = if ($mProv -or $mCat) { "$mProv $mCat".Trim() } else { $mId }
        }

        return [pscustomobject]@{
            DriverId    = $mId
            DisplayName = $mName
            Provider    = $mProv
            Category    = $mCat
            Version     = $mVer
            Arch        = $mArchRaw
            PrimaryUrl  = $mUrl
            ZipParts    = $mZip
            MatchedHWID = $HwidTag
            Score       = $Score
        }
    }

    # ── Helper: true when a record has real payload worth showing ──────────
    # Ghost/stub records have null provider, version, url — all fields empty.
    # try/catch on each field guards against StrictMode member-not-found throws.
    $hasPayload = {
        param([object]$R)
        $p = try { [string]($R.Provider)   } catch { '' }
        $v = try { [string]($R.Version)    } catch { '' }
        $u = try { [string]($R.PrimaryUrl) } catch { '' }
        $c = try { [string]($R.Category)   } catch { '' }
        ($p -and $p.Trim()) -or ($v -and $v.Trim()) -or
        ($u -and $u.Trim()) -or ($c -and $c.Trim())
    }

    # ── Detect HWID-style queries (anything containing a backslash) ─────────
    $isHWID = $Query -match '\\'
    if ($isHWID) {
        Write-Host "  ◈ Detected hardware ID — querying HWID endpoint..." -ForegroundColor DarkGray
        try {
            $encoded = [Uri]::EscapeDataString($Query.ToUpper())
            $resp    = Invoke-WebRequest -Uri "$Script:API_BASE/$encoded" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $data    = $resp.Content | ConvertFrom-Json

            $rawItems = try { $data.matches } catch { $null }
            if ($rawItems) {
                foreach ($m in @($rawItems)) {
                    if ($null -eq $m) { continue }
                    $mEnabled = try { $m.enabled } catch { $true }
                    if ($null -ne $mEnabled -and $mEnabled -eq $false) { continue }

                    $mArchRaw2 = try { ConvertTo-CleanFieldString $m.arch } catch { 'any' }
                    $mCat2     = try { ConvertTo-CleanFieldString $m.category } catch { '' }
                    $mArch = if ($mArchRaw2.Trim()) { $mArchRaw2.Trim().ToLower() } else { 'any' }
                    $mCat  = $mCat2
                    $archOk = (-not $Arch) -or ($mArch -match "\b$([regex]::Escape($Arch.ToLower()))\b") -or ($mArch -in @('any','noarch',''))
                    $catOk  = (-not $Category) -or ($mCat -like "*$Category*")
                    if (-not $archOk -or -not $catOk) { continue }

                    $rec = & $buildRecord $m $Query.ToUpper() 100
                    $rid = $rec.DriverId
                    if ($rid -and $seen.Contains($rid)) { continue }
                    if ($rid) { [void]$seen.Add($rid) }
                    if (& $hasPayload $rec) { $results.Add($rec) }
                }
            }

            if ($results.Count -eq 0) {
                Write-Host "  ◈ Hardware ID recognized but no driver package is available yet." -ForegroundColor DarkGray
                Write-Host "    Try a keyword search (e.g. 'elan touchpad') or contribute this driver." -ForegroundColor DarkGray
            }
        } catch {
            Write-Warn "HWID lookup failed: $($_.Exception.Message)"
            Write-Host "  ◈ Try a keyword search instead." -ForegroundColor DarkGray
        }
        return , [object[]]$results.ToArray()
    }

    # ── Text / keyword search endpoint ─────────────────────────────────────
    $searchUrl = "$Script:SEARCH_API`?q=$([Uri]::EscapeDataString($Query))"
    if ($Arch)     { $searchUrl += "&arch=$Arch" }
    if ($Category) { $searchUrl += "&category=$([Uri]::EscapeDataString($Category))" }

    try {
        $resp = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json

        $rawItems = try { $data.results } catch { $null }     # confirmed field from live response
        if (-not $rawItems) { $rawItems = try { $data.matches } catch { $null } }
        if (-not $rawItems) { $rawItems = $data }

        if ($rawItems) {
            foreach ($m in @($rawItems)) {
                if ($null -eq $m) { continue }
                $mEnabled2 = try { $m.enabled } catch { $true }
                if ($null -ne $mEnabled2 -and $mEnabled2 -eq $false) { continue }

                $scoreRaw = try { [string]($m.score) } catch { '0' }
                $score    = 0; [void][int]::TryParse($scoreRaw, [ref]$score)

                $rec = & $buildRecord $m '' $score
                $rid = $rec.DriverId
                if ($rid -and $seen.Contains($rid)) { continue }
                if ($rid) { [void]$seen.Add($rid) }
                if (& $hasPayload $rec) { $results.Add($rec) }
            }
        }
    } catch {
        Write-Host "  ◈ Search endpoint unavailable — using local index..." -ForegroundColor DarkGray
    }

    # ── Cache-based keyword fallback ───────────────────────────────────────────
    # If the search API returned nothing, filter the session-level HWID cache
    # in memory. Build the cache on first use (one scan per session, not per query).
    if ($results.Count -eq 0) {

        if (-not $Script:HwidCacheBuilt) {
            Write-Host "  ◈ Building local driver index (one-time, ~30 s on live API)..." -ForegroundColor DarkGray
            Build-HwidCache -ApiBase $Script:API_BASE
            if ($Script:HwidCache -and $Script:HwidCache.Count -gt 0) {
                Write-OK "Index ready — $($Script:HwidCache.Count) driver record(s) indexed from your hardware."
            } else {
                Write-Warn "Index is empty — no drivers found for this machine's hardware IDs."
            }
        }

        if ($Script:HwidCache -and $Script:HwidCache.Count -gt 0) {
            foreach ($entry in $Script:HwidCache) {
                # Arch / category filters
                $rawArch = if ($entry.Arch) { $entry.Arch } else { 'any' }
                $archOk  = (-not $Arch) -or ($rawArch -eq $Arch) -or ($rawArch -in @('any','noarch',''))
                $catOk   = (-not $Category) -or ($entry.Category -like "*$Category*")
                if (-not $archOk -or -not $catOk) { continue }

                # Keyword match (case-insensitive) across name, provider, category, HWID, and driver ID
                $hit = ($entry.DisplayName -like "*$Query*") -or
                       ($entry.Provider    -like "*$Query*") -or
                       ($entry.Category    -like "*$Query*") -or
                       ($entry.MatchedHWID -like "*$Query*") -or
                       ($entry.DriverId    -like "*$Query*")
                if (-not $hit) { continue }

                $results.Add($entry)
            }
        }
    }

    return , [object[]]$results.ToArray()
}

function Show-SearchResultsTable {
    <#
    .SYNOPSIS Renders a paginated, indexed results table for the search engine.
             All string columns are null-guarded before any .Length/.Substring call.
    .PARAMETER Results     Array of search result objects
    .PARAMETER Page        Current page (1-based)
    .PARAMETER PageSize    Results per page (default 10)
    #>
    param([object[]]$Results, [int]$Page = 1, [int]$PageSize = 10)

    $total      = @($Results).Count
    if ($total -eq 0) {
        Write-Warn "No results to display."
        return [pscustomobject]@{ Page = 1; TotalPages = 0; StartIdx = 0 }
    }

    $totalPages = [Math]::Ceiling($total / $PageSize)
    if ($Page -lt 1)           { $Page = 1 }
    if ($Page -gt $totalPages) { $Page = $totalPages }

    $startIdx  = ($Page - 1) * $PageSize
    $endIdx    = [Math]::Min($startIdx + $PageSize - 1, $total - 1)
    $pageItems = @($Results[$startIdx..$endIdx])
    $showFrom  = $startIdx + 1
    $showTo    = $endIdx   + 1

    # ── Column widths ───────────────────────────────────────────────────────
    $cN = 3; $cName = 26; $cProv = 16; $cCat = 11; $cVer = 14; $cArch = 5

    # ── Box header ─────────────────────────────────────────────────────────
    $boxW  = 79   # total inner width of box
    $left  = "  SEARCH RESULTS   $showFrom–$showTo of $total   Page $Page / $totalPages"
    $pad   = [Math]::Max(0, $boxW - $left.Length - 1)
    Write-Host ""
    Write-Host "  ┌$('─' * $boxW)┐" -ForegroundColor DarkCyan
    Write-Host "  │$left$(' ' * $pad)│" -ForegroundColor Cyan
    Write-Host "  └$('─' * $boxW)┘" -ForegroundColor DarkCyan
    Write-Host ""

    # ── Column header ───────────────────────────────────────────────────────
    $hdr = "  {0,-$cN} │ {1,-$cName} │ {2,-$cProv} │ {3,-$cCat} │ {4,-$cVer} │ {5,-$cArch}" `
           -f '#', 'Driver Name', 'Provider', 'Category', 'Version', 'Arch'
    Write-Host $hdr -ForegroundColor DarkGray
    $sep = "  {0}─┼─{1}─┼─{2}─┼─{3}─┼─{4}─┼─{5}" `
           -f ('─'*$cN),('─'*$cName),('─'*$cProv),('─'*$cCat),('─'*$cVer),('─'*$cArch)
    Write-Host $sep -ForegroundColor DarkGray

    # ── Rows (null-guarded) ─────────────────────────────────────────────────
    $rowNum = $startIdx
    foreach ($item in $pageItems) {
        $rowNum++
        # Direct dot-access — PSObject.Properties[] fails silently in PS 5.1
        # for pscustomobject members; dot-access goes through the native binder.
        $rawName = try { $v = [string]($item.DisplayName); if ($v) { $v } else { '—' } } catch { '—' }
        $rawProv = try { $v = [string]($item.Provider);    if ($v) { $v } else { '—' } } catch { '—' }
        $rawCat  = try { $v = [string]($item.Category);    if ($v) { $v } else { '—' } } catch { '—' }
        $rawVer  = try { $v = [string]($item.Version);     if ($v) { $v } else { '—' } } catch { '—' }
        $rawArch = try { $v = [string]($item.Arch);        if ($v) { $v } else { 'any' } } catch { 'any' }

        $name = if ($rawName.Length -gt $cName) { $rawName.Substring(0,$cName-1)+'…' } else { $rawName }
        $prov = if ($rawProv.Length -gt $cProv)  { $rawProv.Substring(0,$cProv-1)+'…'  } else { $rawProv }
        $cat  = if ($rawCat.Length  -gt $cCat)   { $rawCat.Substring(0,$cCat-1)+'…'    } else { $rawCat  }
        $ver  = if ($rawVer.Length  -gt $cVer)   { $rawVer.Substring(0,$cVer-1)+'…'    } else { $rawVer  }

        $row = "  {0,-$cN} │ {1,-$cName} │ {2,-$cProv} │ {3,-$cCat} │ {4,-$cVer} │ {5,-$cArch}" `
               -f $rowNum, $name, $prov, $cat, $ver, $rawArch
        Write-Host $row -ForegroundColor White
    }

    # ── Pagination nav bar ──────────────────────────────────────────────────
    Write-Host ""
    if ($totalPages -gt 1) {
        $prevStr = if ($Page -gt 1)           { "[p] ◄ Prev  " } else { "             " }
        $nextStr = if ($Page -lt $totalPages) { "  Next ► [n]" } else { "            " }
        $pageStr = "  Page $Page / $totalPages"
        $jumpStr = "  · g<N> jump · n/p page"
        Write-Host "  $prevStr$pageStr$nextStr" -ForegroundColor DarkCyan
        Write-Host "  $jumpStr" -ForegroundColor DarkGray
    }
    Write-Host "  d<N>=download  i<N>=install  det<N>=details  q=menu" -ForegroundColor DarkGray
    Write-Host ""

    return [pscustomobject]@{ Page = $Page; TotalPages = $totalPages; StartIdx = $startIdx }
}

function Get-SearchResultDetail {
    <#
    .SYNOPSIS Shows full details for a single search result.
    .PARAMETER Item Driver result object
    #>
    param([object]$Item)

    $inner = 70
    Write-Host ""
    Write-Host "  ╔══ DRIVER DETAILS $('═' * ($inner - 17))╗" -ForegroundColor DarkCyan
    # Direct dot-access — avoids PSObject.Properties[] PS 5.1 silent-null bug
    $zipParts = try { $zv = $Item.ZipParts; if ($null -ne $zv) { [int]$zv } else { 1 } } catch { 1 }
    $fields = [ordered]@{
        'Name'        = (try { $v=[string]($Item.DisplayName); if($v){$v}else{'—'} } catch {'—'})
        'Provider'    = (try { $v=[string]($Item.Provider);    if($v){$v}else{'—'} } catch {'—'})
        'Category'    = (try { $v=[string]($Item.Category);    if($v){$v}else{'—'} } catch {'—'})
        'Version'     = (try { $v=[string]($Item.Version);     if($v){$v}else{'—'} } catch {'—'})
        'Arch'        = (try { $v=[string]($Item.Arch);        if($v){$v}else{'any'} } catch {'any'})
        'Driver ID'   = (try { $v=[string]($Item.DriverId);    if($v){$v}else{'—'} } catch {'—'})
        'Matched HWID'= (try { $v=[string]($Item.MatchedHWID); if($v){$v}else{'N/A (keyword match)'} } catch {'N/A (keyword match)'})
        'Parts'       = "$zipParts archive part(s)"
        'Download URL'= (try { $v=[string]($Item.PrimaryUrl);  if($v){$v}else{'—'} } catch {'—'})
    }
    foreach ($kv in $fields.GetEnumerator()) {
        $label = $kv.Key.PadRight(14)
        $val   = if ($kv.Value) { $kv.Value } else { '—' }
        # Wrap long values
        if ($val.Length -gt ($inner - 18)) { $val = $val.Substring(0,$inner - 21) + '...' }
        Write-Host "  ║  $label : $($val.PadRight($inner - 18))  ║" -ForegroundColor White
    }
    Write-Host "  ╚$('═' * ($inner + 2))╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Invoke-SearchDownload {
    <#
    .SYNOPSIS Handles download (and optionally install) for a single search result.
    .PARAMETER Item        Driver result object
    .PARAMETER OutRoot     Root output folder
    .PARAMETER ScratchDir  Temp staging directory
    .PARAMETER Extractor   Path to extractor.exe
    .PARAMETER IsAdmin     Whether the session is elevated
    .PARAMETER InstallMode 'download' | 'install'
    #>
    param(
        [object]$Item,
        [string]$OutRoot,
        [string]$ScratchDir,
        [string]$Extractor,
        [bool]  $IsAdmin,
        [string]$InstallMode = 'download'
    )

    $safeName = "$($Item.Provider)_$($Item.Category)_$($Item.Version)_$($Item.Arch)" `
                -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_' -replace '_+', '_'
    if (-not $safeName.Trim('_')) { $safeName = "driver_$($Item.DriverId)" }
    $outDir   = Join-Path $OutRoot $safeName
    $pkgTemp  = Join-Path $ScratchDir ([System.Guid]::NewGuid().ToString('N').Substring(0,8))

    try {
        New-Item -ItemType Directory -Force -Path $outDir  | Out-Null
        New-Item -ItemType Directory -Force -Path $pkgTemp | Out-Null

        # Download all parts
        $partUrls  = @(Get-PartUrls -PrimaryUrl $Item.PrimaryUrl -ZipParts $Item.ZipParts)
        $firstPart = $null

        for ($pi = 0; $pi -lt @($partUrls).Count; $pi++) {
            $url      = $partUrls[$pi]
            $fileName = Split-Path $url -Leaf
            $dest     = Join-Path $pkgTemp $fileName
            if ($pi -eq 0) { $firstPart = $dest }
            Write-Sub "[$($pi+1)/$(@($partUrls).Count)] $fileName"
            Get-DriverFile -Url $url -Dest $dest -Label $fileName
        }

        # Extract
        Write-Step "Extracting..."
        $extractResult = Invoke-Extractor -ExtractorPath $Extractor -ArchivePath $firstPart -OutputDir $outDir
        if (-not $extractResult.Success) {
            $errLines = ($extractResult.Output | Select-Object -Last 3) -join ' | '
            $hint = if ($extractResult.IsBootstrapFailure) {
                " — looks like antivirus interference or a corrupted extractor download (already retried once)."
            } else { '' }
            throw "Extractor failed (exit $($extractResult.ExitCode))$hint — $errLines"
        }
        Write-OK "Extracted to: $outDir"

        if ($InstallMode -eq 'install') {
            $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue |
                      Where-Object { $_ -ne $null })
            if (@($infs).Count -gt 0 -and $IsAdmin) {
                Write-Step "Installing via pnputil ($(@($infs).Count) INF)..."
                $pnpOutput = @(& "$env:SystemRoot\System32\pnputil.exe" `
                                '/add-driver' "$outDir\*.inf" '/subdirs' '/install' 2>&1)
                $exitCode  = $LASTEXITCODE
                $pnpOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

                $totalMatch = $pnpOutput | Select-String -Pattern 'Total driver packages:\s*(\d+)'
                $addedMatch = $pnpOutput | Select-String -Pattern 'Added driver packages:\s*(\d+)'
                $totalCount = if ($totalMatch) { [int]$totalMatch[0].Matches[0].Groups[1].Value } else { @($infs).Count }
                $addedCount = if ($addedMatch) { [int]$addedMatch[0].Matches[0].Groups[1].Value } else { 0 }

                if ($exitCode -in @(0,3010) -or ($totalCount -gt 0 -and $addedCount -eq $totalCount)) {
                    Write-OK "Driver installed successfully — $addedCount/$totalCount package(s)$(if ($exitCode -eq 3010) { ' — reboot required' } else { '' })"
                } elseif ($addedCount -gt 0) {
                    Write-Warn "Partially installed — $addedCount of $totalCount package(s) added. The rest may be redundant or for a different Windows build; check Device Manager if the device isn't working at: $outDir"
                } else {
                    Write-Warn "pnputil returned exit code $exitCode — try Device Manager at: $outDir"
                }
            } elseif (@($infs).Count -gt 0 -and -not $IsAdmin) {
                Write-Warn "Not elevated. Point Device Manager to: $outDir"
            } else {
                $inst = @(Get-ChildItem -Path $outDir -Include 'setup.exe','*.msi' -Recurse `
                          -ErrorAction SilentlyContinue | Where-Object { $_ -ne $null }) | Select-Object -First 1
                if ($inst) {
                    Write-Step "Running vendor installer: $($inst.Name)"
                    $iArgs = if ($inst.Extension -eq '.msi') { @('/i', $inst.FullName, '/qn') } else { @() }
                    Start-Process $inst.FullName -ArgumentList $iArgs -Wait
                    Write-OK "Vendor installer completed."
                } else {
                    Write-Warn "No INF or setup.exe found — files at: $outDir"
                }
            }
        } else {
            Write-OK "Download complete. Files saved to:"
            Write-Host "      $outDir" -ForegroundColor Cyan
        }

    } catch {
        Write-Err -What "Failed to process $($Item.DisplayName)" -Reason $_.Exception.Message `
                  -Fix "Check the log and try again."
    } finally {
        Remove-Item -Recurse -Force $pkgTemp -ErrorAction SilentlyContinue
    }
}

function Show-SearchHelp {
    <#.SYNOPSIS Prints search engine help and usage examples.#>
    Write-Host ""
    Write-Host "  ┌─ SEARCH ENGINE HELP ──────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  SEARCH EXAMPLES:                                                          │" -ForegroundColor DarkCyan
    Write-Host "  │   realtek audio           Search by device name keyword                   │" -ForegroundColor White
    Write-Host "  │   intel network           Search by brand + category                      │" -ForegroundColor White
    Write-Host "  │   PCI\VEN_8086&DEV_1234   Direct hardware ID lookup                       │" -ForegroundColor White
    Write-Host "  │   nvidia gpu              Category keyword search                          │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  FILTERS (type after search):                                              │" -ForegroundColor DarkCyan
    Write-Host "  │   arch x64 / x86 / any   Filter by architecture                          │" -ForegroundColor White
    Write-Host "  │   cat audio / network / display / storage / bluetooth / chipset           │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  NAVIGATION:                                                               │" -ForegroundColor DarkCyan
    Write-Host "  │   n / p                   Next / Previous page                            │" -ForegroundColor White
    Write-Host "  │   g<N>                    Go to page N  (e.g. g3)                        │" -ForegroundColor White
    Write-Host "  │   <number>                Select a result by row number                   │" -ForegroundColor White
    Write-Host "  │   d<number>               Download only (e.g. d3)                        │" -ForegroundColor White
    Write-Host "  │   i<number>               Download + Install (e.g. i3)                   │" -ForegroundColor White
    Write-Host "  │   det<number>             Show full detail for a result                   │" -ForegroundColor White
    Write-Host "  │   new / s <query>         New search                                      │" -ForegroundColor White
    Write-Host "  │   filter                  Apply arch/category filters                     │" -ForegroundColor White
    Write-Host "  │   clear                   Clear filters                                   │" -ForegroundColor White
    Write-Host "  │   back / q                Return to main menu                             │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  └────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""
}

function Invoke-DriverSearchEngine {
    <#
    .SYNOPSIS  Entry point for the DriverDex Search Engine.
               Separate from the auto-detect flow. Always black background.
    .PARAMETER IsAdmin     Whether the session is elevated
    .PARAMETER ScratchDir  Temp directory for staging downloads
    #>
    param([bool]$IsAdmin, [string]$ScratchDir)

    Set-BlackBackground
    Write-SearchBanner

    # ── Output folder (ask once per search session) ─────────────────────────
    $defaultOut = Join-Path $env:USERPROFILE 'Downloads\DriverDex'
    $outRoot    = Read-Input -Prompt 'Save drivers to' -Default $defaultOut `
                      -Validator { param($v) $v.Length -gt 0 } -ErrMsg 'Path cannot be empty.'
    try {
        New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
        Write-OK "Output folder: $outRoot"
    } catch {
        Write-Err -What "Cannot create output folder" -Reason $_.Exception.Message -Fix "Choose a different path."
        $outRoot = $env:TEMP
    }

    # ── Ensure extractor is available ──────────────────────────────────────
    $extractor = Join-Path $ScratchDir 'extractor.exe'
    if (-not (Test-Path $extractor)) {
        Write-Step "Downloading extractor utility..."
        try {
            Get-DriverFile -Url $Script:EXTRACTOR_URL -Dest $extractor -Label 'extractor.exe'
            Write-OK "Extractor ready."
        } catch {
            Write-Warn "Extractor download failed — install mode will be unavailable. Download-only will work."
            $extractor = $null
        }
    }

    # ── Session state ───────────────────────────────────────────────────────
    $currentResults = @()
    $currentPage    = 1
    $pageSize       = 10
    $currentQuery   = ''
    $filterArch     = ''
    $filterCategory = ''
    $pageState      = $null

    Write-Host ""
    Write-Host "  Type a search query to find drivers. Type 'help' for usage." -ForegroundColor DarkGray
    Write-Host ""

    # ── Main search REPL ────────────────────────────────────────────────────
    while ($true) {
        # Build prompt context
        $filterStr  = ''
        if ($filterArch)     { $filterStr += " [arch:$filterArch]" }
        if ($filterCategory) { $filterStr += " [cat:$filterCategory]" }
        $promptText = if ($currentQuery) { "Search$filterStr" } else { "Search$filterStr" }

        Write-Host "  ▸ $promptText" -ForegroundColor White -NoNewline
        Write-Host " > " -ForegroundColor DarkCyan -NoNewline
        $userInput = $Host.UI.ReadLine()
        if ($null -eq $userInput) { break }
        $userInput = $userInput.Trim()
        if (-not $userInput) { continue }

        # ── Command dispatch ──────────────────────────────────────────────
        # Wrapped in try/catch: a failure in any single command (bad network
        # response, unexpected data shape, etc.) is reported through this
        # script's own error format and the search session keeps running,
        # instead of an unhandled exception escaping all the way out.
        try {
        switch -Regex ($userInput.ToLower()) {

            '^(back|q|quit|exit)$' {
                Write-Host ""
                Write-Host "  Returning to main menu..." -ForegroundColor DarkGray
                Set-BlackBackground -Restore
                return
            }

            '^help$' {
                Show-SearchHelp
                continue
            }

            '^clear$' {
                $filterArch = ''; $filterCategory = ''
                Write-OK "Filters cleared."
                continue
            }

            '^filter$' {
                Write-Host "  Arch filter  (x64/x86/any, blank=all) > " -ForegroundColor White -NoNewline
                $fa = $Host.UI.ReadLine()
                Write-Host "  Category filter (audio/network/display/storage/bluetooth/chipset, blank=all) > " -ForegroundColor White -NoNewline
                $fc = $Host.UI.ReadLine()
                $filterArch     = $fa.Trim().ToLower()
                $filterCategory = $fc.Trim().ToLower()
                Write-OK "Filter set: arch='$filterArch'  category='$filterCategory'"
                # Re-run last search with new filters if available
                if ($currentQuery) {
                    Write-Step "Re-searching '$currentQuery' with new filters..."
                    $currentResults = @(Invoke-SearchAPI -Query $currentQuery -Arch $filterArch -Category $filterCategory)
                    $currentPage    = 1
                    if (@($currentResults).Count -gt 0) {
                        $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                    } else {
                        Write-Warn "No results with current filters."
                    }
                }
                continue
            }

            '^n(ext)?$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results. Run a search first."; continue }
                $currentPage++
                $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^p(rev)?$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results. Run a search first."; continue }
                $currentPage = [Math]::Max(1, $currentPage - 1)
                $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^g\s*(\d+)$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results."; continue }
                $gPage = [int]($Matches[1])
                $currentPage = $gPage
                $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^det\s*(\d+)$' {
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    Get-SearchResultDetail -Item $currentResults[$idx]
                } else { Write-Warn "Invalid result number." }
                continue
            }

            '^d\s*(\d+)$' {
                # Download only
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    $item = $currentResults[$idx]
                    Get-SearchResultDetail -Item $item
                    Write-Step "Downloading: $($item.DisplayName)"
                    if (-not $extractor) { Write-Warn "Extractor unavailable — download will be raw parts only."; return }
                    Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                         -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'download'
                } else { Write-Warn "Invalid result number. Valid range: 1–$(@($currentResults).Count)" }
                continue
            }

            '^i\s*(\d+)$' {
                # Download + Install
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    $item = $currentResults[$idx]
                    Get-SearchResultDetail -Item $item
                    if (-not $IsAdmin) {
                        Write-Warn "Not running as Administrator. Driver install may require elevation."
                    }
                    $confirm = Read-Input -Prompt "Download and INSTALL '$($item.DisplayName)'?" -Default 'Y' `
                                   -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Y or N'
                    if ($confirm -match '^[Yy]') {
                        if (-not $extractor) { Write-Err -What "Extractor not available" -Reason "Download failed earlier" -Fix "Check internet and retry."; continue }
                        Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                             -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'install'
                    }
                } else { Write-Warn "Invalid result number. Valid range: 1–$(@($currentResults).Count)" }
                continue
            }

            '^(\d+)$' {
                # Select by number — show details then ask action
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    $item = $currentResults[$idx]
                    Get-SearchResultDetail -Item $item
                    Write-Host "  What would you like to do with '$($item.DisplayName)'?" -ForegroundColor White
                    Write-Host "   [d] Download only     [i] Download + Install     [x] Cancel" -ForegroundColor DarkGray
                    Write-Host "  > " -ForegroundColor DarkCyan -NoNewline
                    $act = $Host.UI.ReadLine()
                    if ($act -match '^[Dd]') {
                        if (-not $extractor) { Write-Warn "Extractor unavailable."; continue }
                        Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                             -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'download'
                    } elseif ($act -match '^[Ii]') {
                        if (-not $extractor) { Write-Err -What "Extractor not available" -Reason "Earlier download failed" -Fix "Retry."; continue }
                        if (-not $IsAdmin) { Write-Warn "Not elevated — install may be incomplete." }
                        Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                             -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'install'
                    }
                } else { Write-Warn "Invalid result number. Valid range: 1–$(@($currentResults).Count)" }
                continue
            }

            '^(new|s )(.+)$' {
                # Explicit new search command: "new nvidia" or "s realtek"
                $query = $userInput -replace '^(new|s)\s+', ''
                $currentQuery   = $query
                $currentPage    = 1
                $currentResults = @()
                Write-Host ""
                Write-Step "Searching for '$query'..."
                $Script:SpinIdx = 0
                Show-Spinner -Label "Querying DriverDex..."
                $currentResults = @(Invoke-SearchAPI -Query $query -Arch $filterArch -Category $filterCategory)
                Clear-SpinnerLine
                if (@($currentResults).Count -gt 0) {
                    $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                    $currentPage = $pageState.Page
                    Write-Host ""
                    Write-Host "  Use d<N> to download, i<N> to install, det<N> for details, n/p to page." -ForegroundColor DarkGray
                } else {
                    Write-Warn "No drivers found for '$query'. Try a different keyword."
                    Write-Info "Examples: 'realtek audio', 'intel wifi', 'PCI\\VEN_8086&DEV_1234'"
                }
                continue
            }

            default {
                # Treat anything else as a new search query
                $query          = $userInput
                $currentQuery   = $query
                $currentPage    = 1
                $currentResults = @()
                Write-Host ""
                Write-Step "Searching for '$query'..."
                $Script:SpinIdx = 0
                Show-Spinner -Label "Querying DriverDex..."
                $currentResults = @(Invoke-SearchAPI -Query $query -Arch $filterArch -Category $filterCategory)
                Clear-SpinnerLine
                if (@($currentResults).Count -gt 0) {
                    $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                    $currentPage = $pageState.Page
                    Write-Host ""
                    Write-Host "  Use d<N> to download, i<N> to install, det<N> for details, n/p to page." -ForegroundColor DarkGray
                } else {
                    Write-Warn "No drivers found for '$query'. Try a different keyword or HWID."
                    Write-Info "Examples: 'realtek audio', 'intel wifi', 'nvidia gpu'"
                    Write-Info "For HWID lookup: 'PCI\VEN_8086&DEV_1234', 'ACPI\GenuineIntel_-_Intel64_Family_6_Model_165'"
                    Write-Info "Note: some hardware IDs are known but have no driver package in the database yet."
                    Write-Info "Type 'help' for full command reference."
                }
                continue
            }
        }
        } catch {
            Write-Err -What "Command '$userInput' failed unexpectedly." `
                      -Reason $_.Exception.Message `
                      -Fix "Try again, or type 'help' for the command list."
            continue
        }
    }
}


function Show-MainMenu {
    <#
    .SYNOPSIS Shows the DriverDex mode selection menu after the header.
    Returns 'auto', 'search', 'winupdate', or 'quit'.
    #>
    Write-Host "  ┌─────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │                         SELECT A MODE                                   │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [1]  Auto-Detect & Install                                            │" -ForegroundColor White
    Write-Host "  │        Scans your hardware, finds matching drivers,                     │" -ForegroundColor DarkGray
    Write-Host "  │        installs only error devices by default.                          │" -ForegroundColor DarkGray
    Write-Host "  │        Older driver updates shown as optional.                          │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [2]  Driver Search Engine                                             │" -ForegroundColor Yellow
    Write-Host "  │        Search by name, keyword, or HWID. Download or                   │" -ForegroundColor DarkGray
    Write-Host "  │        install any driver from the DriverDex database.                 │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [3]  Force Windows Update                                             │" -ForegroundColor Magenta
    Write-Host "  │        Triggers Windows Update, installs all pending patches,           │" -ForegroundColor DarkGray
    Write-Host "  │        and optional driver updates from Microsoft servers.              │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [q]  Quit                                                             │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  └─────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""

    $choice = Read-Input -Prompt 'Select mode' -Default '1' `
        -Validator { param($v) $v -match '^[123qQ]$' } `
        -ErrMsg    'Enter 1 (Auto-Detect), 2 (Search Engine), 3 (Windows Update), or q to quit.'

    if ($choice -match '^[Qq]') { return 'quit' }
    if ($choice -eq '2')        { return 'search' }
    if ($choice -eq '3')        { return 'winupdate' }
    return 'auto'
}

# ═══════════════════════════════════════════════════════════════════════════════
#  FORCE WINDOWS UPDATE
#  Triggers Windows Update via PSWindowsUpdate (auto-installed if absent) or
#  falls back to the built-in wuauclt / UsoClient native tools so the function
#  works on every Windows version from 7 SP1 through 11.
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-ForceWindowsUpdate {
    <#
    .SYNOPSIS Forces Windows Update: installs PSWindowsUpdate if needed, scans
              for all pending patches + optional driver updates, applies them, and
              reports the result.  Falls back gracefully to native WU clients
              (UsoClient / wuauclt) on systems where PowerShell Gallery is
              unavailable or the module install is blocked.
    .PARAMETER IsAdmin  $true when the session is elevated.
    #>
    param([bool]$IsAdmin)

    Write-Host ""
    Write-Divider
    Write-Host "  ▸ Force Windows Update" -ForegroundColor Magenta
    Write-Divider
    Write-Host ""

    if (-not $IsAdmin) {
        Write-Warn "Windows Update installation requires Administrator rights."
        Write-Info "Please re-run DriverDex as Administrator to use this feature."
        Write-Host ""
        return
    }

    # ── Render a compact info box ──────────────────────────────────────────
    $w = 66
    Write-Host "  ╔$('═' * ($w - 2))╗" -ForegroundColor DarkCyan
    Write-Host "  ║  This option will:$(' ' * ($w - 21))║" -ForegroundColor White
    Write-Host "  ║    • Scan for ALL pending Windows Updates$(' ' * ($w - 44))║" -ForegroundColor DarkGray
    Write-Host "  ║    • Include optional Microsoft driver updates$(' ' * ($w - 49))║" -ForegroundColor DarkGray
    Write-Host "  ║    • Download and install everything found$(' ' * ($w - 44))║" -ForegroundColor DarkGray
    Write-Host "  ║    • Prompt for reboot if required$(' ' * ($w - 37))║" -ForegroundColor DarkGray
    Write-Host "  ║$(' ' * ($w - 2))║" -ForegroundColor DarkCyan
    Write-Host "  ║  This may take several minutes depending on$(' ' * ($w - 46))║" -ForegroundColor DarkGray
    Write-Host "  ║  your internet speed and number of updates.$(' ' * ($w - 45))║" -ForegroundColor DarkGray
    Write-Host "  ╚$('═' * ($w - 2))╝" -ForegroundColor DarkCyan
    Write-Host ""

    $confirm = Read-Input -Prompt 'Proceed with Force Windows Update?' -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
    if ($confirm -notmatch '^[Yy]') {
        Write-Info "Windows Update skipped."
        Write-Host ""
        return
    }

    Write-Host ""

    # ══════════════════════════════════════════════════════════════════════════
    # STRATEGY 1: PSWindowsUpdate module (richest output, works on PS 5.1+)
    # ══════════════════════════════════════════════════════════════════════════
    $moduleAvailable = $false
    if (Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue) {
        $moduleAvailable = $true
        Write-OK "PSWindowsUpdate module already installed."
    } else {
        Write-Step "PSWindowsUpdate module not found — attempting to install from PSGallery..."
        try {
            # Ensure TLS 1.2 for Gallery
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        try {
            # Bootstrap NuGet provider silently if missing (required on fresh installs)
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Write-Sub "Installing NuGet provider..."
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            # Trust PSGallery for this session
            if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            }
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser `
                           -AllowClobber -ErrorAction Stop
            $moduleAvailable = $true
            Write-OK "PSWindowsUpdate installed successfully."
        } catch {
            Write-Warn "Could not install PSWindowsUpdate: $($_.Exception.Message)"
            Write-Info "Falling back to native Windows Update client..."
            Write-Log -Level WARN -Msg "PSWindowsUpdate install failed: $($_.Exception.Message)"
        }
    }

    if ($moduleAvailable) {
        # ── Use PSWindowsUpdate for full control ──────────────────────────
        try {
            Import-Module PSWindowsUpdate -ErrorAction Stop

            Write-Step "Scanning for available Windows Updates (including drivers)..."
            $Script:SpinIdx = 0
            Show-Spinner -Label "Checking Windows Update servers..."

            # Retrieve all updates, including optional Microsoft driver updates
            $updates = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot `
                                         -ErrorAction Stop
            Clear-SpinnerLine

            if (-not $updates -or @($updates).Count -eq 0) {
                Write-OK "Your system is fully up to date. No pending updates found."
                Write-Host ""
                return
            }

            Write-OK "Found $(@($updates).Count) pending update(s):"
            Write-Host ""
            foreach ($u in $updates) {
                $kb   = if ($u.KBArticleIDs) { " [KB$($u.KBArticleIDs -join ',KB')]" } else { '' }
                $size = if ($u.Size -gt 0) { " ($([Math]::Round($u.Size / 1MB, 1)) MB)" } else { '' }
                Write-Host "  ·  $($u.Title)$kb$size" -ForegroundColor Cyan
            }
            Write-Host ""

            $install = Read-Input -Prompt "Install all $(@($updates).Count) update(s) now?" `
                -Default 'Y' -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Y or N.'
            if ($install -notmatch '^[Yy]') {
                Write-Info "Update installation cancelled by user."
                Write-Host ""
                return
            }

            Write-Step "Installing updates — this may take a while..."
            Write-Host ""
            $results = Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot `
                                              -Verbose -ErrorAction Stop

            $rebootNeeded = $false
            foreach ($r in $results) {
                $status = if ($r.Result -eq 2) { '✔ Installed' }
                          elseif ($r.Result -eq 3) { '⟳ Reboot required' }
                          elseif ($r.Result -eq 4) { '✘ Failed' }
                          else                      { "  Result: $($r.Result)" }
                $col = switch ($r.Result) {
                    2 { 'Green' }; 3 { 'Yellow' }; 4 { 'Red' }; default { 'DarkGray' }
                }
                Write-Host "  $status  ·  $($r.Title)" -ForegroundColor $col
                if ($r.Result -eq 3) { $rebootNeeded = $true }
            }
            Write-Host ""

            if ($rebootNeeded) {
                Write-Warn "One or more updates require a reboot to complete installation."
                Write-Host ""
                $rb = Read-Input -Prompt 'Restart now?' -Default 'N' `
                    -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Y or N.'
                if ($rb -match '^[Yy]') {
                    Write-Warn "Restarting in 10 seconds... Press Ctrl+C to cancel."
                    for ($i = 10; $i -ge 1; $i--) {
                        Write-Host "`r    $i second(s) remaining...  " -NoNewline -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                    Write-Host ""
                    Restart-Computer -Force
                }
            } else {
                Write-OK "All updates installed successfully. No reboot required."
            }

        } catch {
            Write-Err -What "PSWindowsUpdate encountered an error." `
                      -Reason $_.Exception.Message `
                      -Fix    "Check the log for details or try again." `
                      -Err    $_
            Write-Info "Attempting native WU client fallback..."
            # Fall through to Strategy 2
            $moduleAvailable = $false
        }
    }

    # ══════════════════════════════════════════════════════════════════════════
    # STRATEGY 2: Native WU clients — UsoClient (Win 10/11) or wuauclt (Win 7/8)
    # ══════════════════════════════════════════════════════════════════════════
    if (-not $moduleAvailable) {
        Write-Step "Using native Windows Update client..."
        Write-Host ""

        $usoPath    = "$env:SystemRoot\System32\UsoClient.exe"
        $wuauclt    = "$env:SystemRoot\System32\wuauclt.exe"
        $triggered  = $false

        if (Test-Path $usoPath) {
            # Windows 10 / 11
            Write-Sub "Triggering scan via UsoClient (Windows 10/11)..."
            try {
                & $usoPath StartScan           2>$null
                Start-Sleep -Seconds 3
                & $usoPath StartDownload       2>$null
                Start-Sleep -Seconds 3
                & $usoPath StartInstall        2>$null
                $triggered = $true
                Write-OK "UsoClient: scan, download & install triggered."
            } catch {
                Write-Warn "UsoClient call failed: $($_.Exception.Message)"
            }
        }

        if (-not $triggered -and (Test-Path $wuauclt)) {
            # Windows 7 / 8.1
            Write-Sub "Triggering scan via wuauclt (Windows 7/8)..."
            try {
                & $wuauclt /detectnow         2>$null
                Start-Sleep -Seconds 3
                & $wuauclt /updatenow         2>$null
                $triggered = $true
                Write-OK "wuauclt: detect + update triggered."
            } catch {
                Write-Warn "wuauclt call failed: $($_.Exception.Message)"
            }
        }

        if (-not $triggered) {
            Write-Err -What "Could not trigger Windows Update." `
                      -Reason "Neither UsoClient nor wuauclt found at expected paths." `
                      -Fix    "Open Windows Settings → Windows Update → Check for updates."
            Write-Host ""
            return
        }

        Write-Host ""
        Write-Host "  ℹ  Windows Update is now running in the background." -ForegroundColor Cyan
        Write-Host "     Updates will download and install automatically." -ForegroundColor DarkGray
        Write-Host "     You can monitor progress in:" -ForegroundColor DarkGray
        Write-Host "       Settings → Windows Update   (Windows 10/11)" -ForegroundColor DarkGray
        Write-Host "       Control Panel → Windows Update   (Windows 7/8)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  ℹ  For driver-specific updates Microsoft may show as 'Optional'." -ForegroundColor Yellow
        Write-Host "     Open Windows Update > View optional updates to see them." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Log -Level INFO -Msg "Force Windows Update completed. ModuleUsed=$moduleAvailable"
}

function Main {
    Clear-Host
    Write-Header

    Write-Log -Level INFO -Msg "DriverDex v$Script:VERSION session started."

    # ── Scratch directory & cleanup guarantee ──────────────────────────────
    $Script:scratch = Join-Path $env:TEMP ("driverdex-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $Script:scratch | Out-Null

    Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
        Remove-Item $Script:scratch -Recurse -Force -ErrorAction SilentlyContinue
    } | Out-Null

    try {
        # ── Mode selection ─────────────────────────────────────────────────
        $mode = Show-MainMenu
        if ($mode -eq 'quit') {
            Write-Info "Exiting DriverDex. Goodbye."
            return
        }
        if ($mode -eq 'search') {
            Write-Host ""
            # Ensure scratch exists for search engine
            Invoke-DriverSearchEngine -IsAdmin (Test-Administrator) -ScratchDir $Script:scratch
            Write-Host ""
            Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
            Write-Info "  Session log: $Script:LOG_PATH"
            Write-Host ""
            Write-Log -Level INFO -Msg "Search Engine session complete."
            # ── Contribution prompt after Search mode ──────────────────────
            $hwidsForContrib = @()
            try { $hwidsForContrib = @(Get-AllHardwareIDs) } catch {}
            Invoke-ContributePrompt -HWIDs $hwidsForContrib -Reason 'partial' -UnmatchedLocalDrivers @()
            return
        }
        if ($mode -eq 'winupdate') {
            $isAdmin = Test-Administrator
            if (-not $isAdmin) { Request-Elevation }
            $isAdmin = Test-Administrator
            Invoke-ForceWindowsUpdate -IsAdmin $isAdmin
            Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
            Write-Info "  Session log: $Script:LOG_PATH"
            Write-Host ""
            Write-Log -Level INFO -Msg "Force Windows Update session complete."
            # ── Contribution prompt after WU mode ──────────────────────────
            $hwidsForContrib = @()
            try { $hwidsForContrib = @(Get-AllHardwareIDs) } catch {}
            Invoke-ContributePrompt -HWIDs $hwidsForContrib -Reason 'partial' -UnmatchedLocalDrivers @()
            return
        }

        # ── Auto-Detect mode ───────────────────────────────────────────────
        # Contribution-prompt state — populated as we go so the finally block
        # always has something meaningful to pass even on an early exit.
        $Script:ContribHWIDs         = @()
        $Script:ContribUnmatched     = @()
        $Script:ContribReason        = 'no_drivers'
        $Script:ContribShouldPrompt  = $true   # set to $false only on hard errors before HWIDs exist

        try {

        # ── OS / environment banner ────────────────────────────────────────
        $os      = Get-OSInfo
        $isAdmin = Test-Administrator

        Write-Step "System information"
        Write-Info "OS      : $($os.Caption) (Build $($os.Build))"
        Write-Info "Arch    : $($os.Arch)"
        Write-Info "PS      : v$($os.PSVersion)"
        Write-Info "Admin   : $(if ($isAdmin) { 'Yes ✔' } else { 'No ✘ (elevation recommended)' })"
        Write-Info "Log     : $Script:LOG_PATH"
        Write-Host ""
        Write-Log -Level INFO -Msg "OS=$($os.Caption) Build=$($os.Build) Arch=$($os.Arch) Admin=$isAdmin"

        # ── Step 1: Elevation ──────────────────────────────────────────────
        if (-not $isAdmin) { Request-Elevation }
        $isAdmin = Test-Administrator

        # ── Step 2: Network ────────────────────────────────────────────────
        Write-Divider
        if (-not (Test-NetworkConnectivity)) {
            # No network — still ask for contribution (HWIDs already known locally)
            $Script:ContribShouldPrompt = $false
            return
        }
        Write-Host ""

        # ── Step 3: Hardware scan ──────────────────────────────────────────
        Write-Divider
        $hwids        = Get-AllHardwareIDs
        $problemHWIDs = Get-ProblemDevices
        Write-OK "Found $(@($hwids).Count) hardware IDs · $(@($problemHWIDs).Count) problem device(s)"
        Write-Host ""

        # Capture HWIDs for the contribution prompt as soon as we have them
        $Script:ContribHWIDs = $hwids

        if (@($hwids).Count -eq 0) {
            Write-Err -What "No hardware IDs found." `
                      -Reason "CIM and WMI queries returned empty results." `
                      -Fix    "Ensure you have read access to WMI on this machine."
            $Script:ContribShouldPrompt = $false
            return
        }

        # ── Step 3b: Local driver inventory ─────────────────────────────────
        # Indexed ONCE here so every later "is this installed / what version"
        # question is a lookup, not a fresh WMI query buried mid-install.
        $installedSnapshot = Get-InstalledDriverSnapshot
        Write-Host ""

        # ── Step 4: API query ──────────────────────────────────────────────
        Write-Divider
        $drivers = Search-Drivers -HWIDs $hwids -SystemArch $os.Arch -InstalledSnapshot $installedSnapshot
        Write-Host ""

        # Devices with a working local driver that the DB has never seen at all —
        # the strongest, most specific contribution candidates.
        $unmatchedLocal = Get-UnmatchedLocalDrivers -AllHWIDs $hwids -MatchedDrivers @($drivers) -Snapshot $installedSnapshot
        $Script:ContribUnmatched = $unmatchedLocal

        if (@($drivers).Count -eq 0) {
            Write-Warn "No matching drivers found in the DriverDex database for your hardware."
            Write-Host ""
            $Script:ContribReason = 'no_drivers'
            return   # finally block will show the prompt
        }

        $Script:ContribReason = 'partial'

        if (@($unmatchedLocal).Count -gt 0) {
            Write-Accent "  [$(@($unmatchedLocal).Count) locally installed driver(s) have no DriverDex entry yet — more on this at the end]"
            Write-Host ""
        }

        # Category summary
        $byCat = $drivers | Group-Object Category
        $catSummary = ($byCat | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '  ·  '
        Write-OK "Found $(@($drivers).Count) matching driver(s)  [$catSummary]"
        Write-Host ""

        # ── Step 5: Driver selection ───────────────────────────────────────
        $selected = Show-DriverMenu -Drivers @($drivers) -ProblemHWIDs $problemHWIDs

        if (-not $selected -or @($selected).Count -eq 0) {
            Write-Info "No drivers selected."
            return   # finally block will still show the prompt
        }
        Write-Host ""

        # ── Step 6: Output folder ──────────────────────────────────────────
        Write-Divider
        $outRoot = Get-OutputFolder
        Write-Host ""

        # ── Estimate disk space ────────────────────────────────────────────
        # Conservative 200 MB per driver when exact size unknown
        $estMB = @($selected).Count * 200
        Write-Info "Estimated download: ~${estMB} MB (rough estimate)"

        # ── Download extractor once ────────────────────────────────────────
        Write-Divider
        Write-Step "Downloading DriverDex extractor..."
        $extractor = Join-Path $Script:scratch 'extractor.exe'
        try {
            Get-DriverFile -Url $Script:EXTRACTOR_URL -Dest $extractor -Label 'extractor.exe'
        } catch {
            Write-Err -What "Failed to download extractor." `
                      -Reason $_.Exception.Message `
                      -Fix    "Check your internet connection and re-run the script."
            return   # finally block will still show the prompt
        }
        Write-Host ""

        # ── Step 7: Per-driver processing ──────────────────────────────────
        $results = [System.Collections.Generic.List[object]]::new()
        $dIdx    = 0

        foreach ($drv in $selected) {
            $dIdx++
            Show-DriverPanel -Driver $drv -Idx $dIdx -Total @($selected).Count

            $res = Install-DriverPackage `
                        -Driver        $drv `
                        -OutputRoot    $outRoot `
                        -ScratchDir    $Script:scratch `
                        -ExtractorPath $extractor `
                        -IsAdmin       $isAdmin
            $results.Add($res)
            Write-Log -Level INFO -Msg "Driver '$($drv.DisplayName)': success=$($res.Success) partial=$($res.PartialFailure) ($($res.PackagesAdded)/$($res.PackagesTotal)) skipped=$($res.Skipped) reboot=$($res.RebootRequired)"
        }

        # ── Step 8: Summary ────────────────────────────────────────────────
        Show-Summary -Results @($results)

        # ── Step 10: Reboot prompt ─────────────────────────────────────────
        Invoke-RebootPrompt -Results @($results)

        Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
        Write-Info "  Session log: $Script:LOG_PATH"
        Write-Host ""
        Write-Log -Level INFO -Msg "Session complete."

        } catch {
            # Safety net: without this, ANY unexpected error here (a bad API
            # response shape, a null we didn't anticipate, etc.) propagates
            # all the way past Main and out of the script entirely, where it
            # surfaces as a raw, unformatted PowerShell error instead of this
            # script's own clean error report.
            Write-Err -What "Unexpected error during driver detection." `
                      -Reason $_.Exception.Message `
                      -Fix "Check the log for details, then re-run the script." `
                      -Err $_
        } finally {
            # ── Step 9: Contribution prompt — ALWAYS runs ──────────────────
            # Executes on every exit path: success, no drivers found, user
            # pressed NONE/q at selection, extractor download failed, or any
            # unhandled exception.  Only skipped on the two hard pre-HWID
            # failures (no network, no WMI access) where we have nothing useful.
            if ($Script:ContribShouldPrompt) {
                Invoke-ContributePrompt `
                    -HWIDs                $Script:ContribHWIDs `
                    -Reason               $Script:ContribReason `
                    -UnmatchedLocalDrivers $Script:ContribUnmatched
            }
        }   # end inner try/finally (auto-detect)

    } catch {
        # Final safety net for the whole session (mode selection, search
        # engine, force-update flow). Ensures nothing escapes to the host
        # as a raw, unhandled error — everything is reported through this
        # script's own format and cleanup still runs via the finally below.
        Write-Err -What "DriverDex encountered an unexpected error and had to stop." `
                  -Reason $_.Exception.Message `
                  -Fix "Check the log for details, then re-run the script." `
                  -Err $_
    } finally {
        # Outer finally: scratch-dir cleanup — runs on ALL modes and ALL exits
        Remove-Item -Recurse -Force $Script:scratch -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
Main
# ═══════════════════════════════════════════════════════════════════════════════

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUBqjvzOv2KqTtjpl9dYpHE7ZY
# nOOgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQ3DGnQfVG4o8dQjpjpEejHL3bUmDANBgkq
# hkiG9w0BAQEFAASCAQBi1ZsFRD24FUyOaxFUxdMsFYZ4S1TyizdEbwBYHEiHsAUn
# njvuszCgdAKAIVwuP7HxeiJ46AiF+DELa2FtmeoutM+EnxmeY4NzelwRhiTNz22C
# omVqbgSgdy9D3xjTfWsZATA4aIXgifql7apjUnVyLNndUtKfQ7XAK7YucumznQCX
# CNlxhADZUX5b42wdYnX2D8FsZM+boifJKcSwVj7mdqOeES4XouxAlyeXMfeKWZkw
# 5+jr+o5E5in59iq1lWc/S7/e9OoNXZCmHs6CLjqqZTP3Shmuot2AC/wXKkAY7Mtx
# IVS05YGhEamr57I60Seu4x/BzLSvQ7udNoTtICaRoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0MVowLwYJKoZIhvcNAQkEMSIEIEIKmL6URqztyeRC
# OZdi8OC6GD3hb2+3mJ1WhUsnJgfgMA0GCSqGSIb3DQEBAQUABIICADgnpVXtSQwi
# FDqdZoIB6vXxkVo862Ztt7wLmyTSihpPaoxf1uOFe0Apjmey7kw+95C/JdM6Ofb+
# bvv6vshWHZGAAEvIcSGbXjH0cBAZlRHfmLHo5MH27TSkFvFJy62iyUmc59ZocPPp
# 60sFFty+0H0X+nRGvzfuqmyjtQYqH6V2ay1vZIwm6LBl9AKzV9GIMgwN/y6lEPTR
# Z0rcNTOxF8lKtQcM+9qcbq9ne/9wJwjBkCwq1peSzvLmYRYGWc4cUJx1OhQEmETK
# hrKSPY8tv63nHdLT3CjvFduseAK3eVNGn3jEV/ifzQlWfbXu7fIdoMxrBmylZKrc
# RyxG35nlrxLIKtXM0XhkA+Opo54lQevLFtIcLnjBorRx9r0NEEm8rGDfahSHR9Bh
# GR9s0pHrVfFPg7dygTPI9f6ufBm5BKKSOUxxOK4Uq7dPVHYb4FsVDnuMdXuM/ZUl
# lRvAVqe8fDDvYIzIS4HtezjozXnG8VxnJO/IRBqRLDVNksgfY+LCGP6NXrX15F+t
# HmbpR0K2cH1PFhKjKXEsxFALVmY6FpteGrv3qaXUDLZmp4aAxIayrMh1vTWkjX5P
# doCgQEHdfRiXykqHTebwbKlmd1TCepGVMvG46fcIYzuK15Xe0bSenxWm/aQbCXNQ
# I0UKbkbeDrOUL61vCE2rWCvOoVxq613D
# SIG # End signature block
