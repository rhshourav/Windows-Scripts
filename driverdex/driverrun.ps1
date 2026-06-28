#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex — Automatic Hardware Driver Detector & Installer  v2.1.0
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
#  CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════
$Script:VERSION       = '2.2.0'
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
        ' ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗ ',
        ' ██╔══██╗██╔══██╗██║╚██╗ ██╔╝██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝ ',
        ' ██║  ██║██████╔╝██║ ╚████╔╝ █████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝  ',
        ' ██║  ██║██╔══██╗██║  ╚██╔╝  ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗  ',
        ' ██████╔╝██║  ██║██║   ██║   ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗  ',
        ' ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝ '
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
            $installerUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/driverdex/driverrun.ps1'
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

        $apiResult = Invoke-ApiWithRetry -HWID $id
        if (-not $apiResult -or -not $apiResult.matches -or @($apiResult.matches).Count -eq 0) { continue }

        foreach ($match in $apiResult.matches) {
            if (-not $match.enabled)               { continue }
            if ($seen.Contains($match.driver_id))  { continue }

            # Arch filtering: include exact match, universal, and x86 on x64 (compat)
            $mArch = if ($match.arch) { $match.arch.ToLower() } else { '' }
            $sArch = $SystemArch.ToLower()
            $archOk = ($mArch -eq $sArch) -or
                      ($mArch -in @('any','noarch','')) -or
                      ($mArch -eq 'x86' -and $sArch -eq 'x64')
            if (-not $archOk) { continue }

            # Determine recommendation flag: arch-matched + non-generic
            $isRecommended = ($mArch -eq $sArch) -and ([int]$match.matched_is_generic -eq 0)

            # ── Cross-reference against what's actually installed locally ──────
            $localInfo = $InstalledSnapshot[$id.ToUpper()]
            if (-not $localInfo) {
                $installStatus    = 'NEW'
                $installedVersion = $null
            } else {
                $cmp = Compare-DriverVersion $localInfo.Version $match.version
                $installStatus    = if     ($cmp -lt 0) { 'UPDATE' }
                                     elseif ($cmp -eq 0) { 'CURRENT' }
                                     else                { 'NEWER' }
                $installedVersion = $localInfo.Version
            }

            [void]$seen.Add($match.driver_id)
            $results.Add([pscustomobject]@{
                DriverId         = $match.driver_id
                DisplayName      = $match.display_name
                Provider         = $match.provider
                Category         = $match.category
                Version          = $match.version
                Arch             = $match.arch
                PrimaryUrl       = $match.primary_url
                ZipParts         = [int]$match.zip_parts
                MatchedHWID      = $id
                SupersededBy     = $match.superseded_by
                IsGeneric        = [int]$match.matched_is_generic
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

        $name = if ($d.DisplayName.Length -gt $colName) { $d.DisplayName.Substring(0,$colName-1)+'…' } else { $d.DisplayName }
        $prov = if ($d.Provider.Length -gt $colProv)    { $d.Provider.Substring(0,$colProv-1)+'…' }    else { $d.Provider }
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
    }

    $safeName = "$($Driver.Provider)_$($Driver.Category)_$($Driver.Version)_$($Driver.Arch)" `
                -replace '[\\/:*?"<>|]', '_'
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
        $extractArgs = @('--file', $firstPart, '--output', $outDir, '--verify')
        $proc = Start-Process -FilePath $ExtractorPath -ArgumentList $extractArgs `
                              -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $pkgTemp 'extractor_stderr.txt')
        if ($proc.ExitCode -ne 0) {
            $errLines = ''
            $errFile  = Join-Path $pkgTemp 'extractor_stderr.txt'
            if (Test-Path $errFile) {
                $errLines = (Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -Last 5) -join ' | '
            }
            throw "Extractor failed (exit $($proc.ExitCode)) — $errLines"
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
            $pnpProc = Start-Process -FilePath "$env:SystemRoot\System32\pnputil.exe" `
                                     -ArgumentList $pnpArgs -Wait -PassThru -NoNewWindow
            $exitCode = $pnpProc.ExitCode

            if ($exitCode -in @(0, 3010)) {
                Write-OK "pnputil succeeded (exit $exitCode)"
                if ($exitCode -eq 3010) {
                    Write-Warn "Reboot required to complete driver installation."
                    $result.RebootRequired = $true
                }
                $result.Success = $true
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
            $manifest.install_result  = if ($result.Success) { 'success' } else { 'failed' }
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
        if     ($r.Skipped)  { $sym = '─'; $col = 'DarkGray'; $label = 'skipped (already installed)' }
        elseif ($r.Success)  { $sym = '✔'; $col = 'Green';    $label = 'installed' }
        else                 { $sym = '✘'; $col = 'Red';       $label = 'failed' }
        $rb = if ($r.RebootRequired) { ' ⟳ reboot needed' } else { '' }
        $line = "  $sym $($r.Name)$rb — $label"
        $padded = $line.PadRight($inner + 4)
        Write-Host "  ║$padded║" -ForegroundColor $col
    }

    Write-Host "  ╚$('═' * ($inner + 2))╝" -ForegroundColor DarkCyan
    Write-Host ""

    $passed  = @($Results | Where-Object { $_.Success -and -not $_.Skipped }).Count
    $skipped = @($Results | Where-Object { $_.Skipped }).Count
    $failed  = @($Results | Where-Object { -not $_.Success -and -not $_.Skipped }).Count
    Write-Info "  $passed installed  ·  $skipped skipped  ·  $failed failed"
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

$Script:SEARCH_API = 'https://driverdex-check.driverdex.workers.dev/api/search'

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
        '  ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗  ',
        '  ██╔══██╗██╔══██╗██║╚██╗ ██╔╝██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝  ',
        '  ██║  ██║██████╔╝██║ ╚████╔╝ █████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝   ',
        '  ██║  ██║██╔══██╗██║  ╚██╔╝  ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗   ',
        '  ██████╔╝██║  ██║██║   ██║   ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗   ',
        '  ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝  '
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

    # ── Detect HWID-style queries and use the HWID endpoint directly ───────
    $isHWID = $Query -match '^(PCI|USB|ACPI|HDAUDIO|HID|ROOT|SCSI|DISPLAY|IDE|STORAGE)\\'
    if ($isHWID) {
        Write-Host "  ◈ Detected hardware ID — querying HWID endpoint..." -ForegroundColor DarkGray
        try {
            $encoded = [Uri]::EscapeDataString($Query.ToUpper())
            $url     = "$Script:API_BASE/$encoded"
            $resp    = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $data    = $resp.Content | ConvertFrom-Json
            if ($data.matches) {
                foreach ($m in @($data.matches)) {
                    if (-not $m.enabled) { continue }
                    $archOk = (-not $Arch) -or ($m.arch -eq $Arch) -or ($m.arch -in @('any','noarch',''))
                    $catOk  = (-not $Category) -or ($m.category -like "*$Category*")
                    if ($archOk -and $catOk) {
                        $results.Add([pscustomobject]@{
                            DriverId    = $m.driver_id
                            DisplayName = $m.display_name
                            Provider    = $m.provider
                            Category    = $m.category
                            Version     = $m.version
                            Arch        = $m.arch
                            PrimaryUrl  = $m.primary_url
                            ZipParts    = [int]$m.zip_parts
                            MatchedHWID = $Query.ToUpper()
                            Score       = 100
                        })
                    }
                }
            }
        } catch {
            Write-Warn "HWID lookup failed: $($_.Exception.Message)"
        }
        # Always return object[] — never let PowerShell unwrap a single item
        return , [object[]]$results.ToArray()
    }

    # ── Text search endpoint ────────────────────────────────────────────────
    $encodedQ = [Uri]::EscapeDataString($Query)
    $url      = "$Script:SEARCH_API`?q=$encodedQ"
    if ($Arch)     { $url += "&arch=$Arch" }
    if ($Category) { $url += "&category=$([Uri]::EscapeDataString($Category))" }

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json

        $raw = if ($data.results) { @($data.results) } elseif ($data.matches) { @($data.matches) } else { @($data) }
        foreach ($m in $raw) {
            if ($null -eq $m) { continue }
            if ($m.enabled -eq $false) { continue }
            $results.Add([pscustomobject]@{
                DriverId    = if ($m.driver_id)    { $m.driver_id }    else { $m.id }
                DisplayName = if ($m.display_name) { $m.display_name } else { $m.name }
                Provider    = if ($m.provider)     { $m.provider }     else { '' }
                Category    = if ($m.category)     { $m.category }     else { '' }
                Version     = if ($m.version)      { $m.version }      else { '' }
                Arch        = if ($m.arch)         { $m.arch }         else { 'any' }
                PrimaryUrl  = if ($m.primary_url)  { $m.primary_url }  else { $m.url }
                ZipParts    = if ($m.zip_parts)    { [int]$m.zip_parts } else { 1 }
                MatchedHWID = if ($m.hardware_id)  { $m.hardware_id }  else { '' }
                Score       = if ($m.score)        { [int]$m.score }   else { 0 }
            })
        }
    } catch {
        # Search endpoint not available — return empty array, caller shows message
        Write-Host "  ◈ Search endpoint unavailable — no results returned." -ForegroundColor DarkGray
    }

    return , [object[]]$results.ToArray()
}

function Show-SearchResultsTable {
    <#
    .SYNOPSIS Renders a paginated, indexed results table for the search engine.
    .PARAMETER Results     Array of search result objects
    .PARAMETER Page        Current page (1-based)
    .PARAMETER PageSize    Results per page (default 10)
    #>
    param([object[]]$Results, [int]$Page = 1, [int]$PageSize = 10)

    $total     = @($Results).Count
    $totalPages= [Math]::Ceiling($total / $PageSize)
    if ($Page -lt 1) { $Page = 1 }
    if ($Page -gt $totalPages) { $Page = $totalPages }

    $startIdx  = ($Page - 1) * $PageSize
    $endIdx    = [Math]::Min($startIdx + $PageSize - 1, $total - 1)
    $pageItems = @($Results[$startIdx..$endIdx])

    # ── Header ─────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │  SEARCH RESULTS   $total result(s) found   Page $Page / $totalPages$((' ' * 30).Substring(0, [Math]::Max(0, 30 - "$total result(s) found   Page $Page / $totalPages".Length)))│" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""

    # Column widths
    $cN  = 3; $cName = 26; $cProv = 16; $cCat = 11; $cVer = 14; $cArch = 5

    $hdr = "  {0,-$cN} │ {1,-$cName} │ {2,-$cProv} │ {3,-$cCat} │ {4,-$cVer} │ {5,-$cArch}" `
           -f '#', 'Driver Name', 'Provider', 'Category', 'Version', 'Arch'
    Write-Host $hdr -ForegroundColor DarkGray
    $sep = "  {0}─┼─{1}─┼─{2}─┼─{3}─┼─{4}─┼─{5}" `
           -f ('─'*$cN),('─'*$cName),('─'*$cProv),('─'*$cCat),('─'*$cVer),('─'*$cArch)
    Write-Host $sep -ForegroundColor DarkGray

    $rowNum = $startIdx
    foreach ($item in $pageItems) {
        $rowNum++
        $name = if ($item.DisplayName.Length -gt $cName) { $item.DisplayName.Substring(0,$cName-1)+'…' } else { $item.DisplayName }
        $prov = if ($item.Provider.Length   -gt $cProv)  { $item.Provider.Substring(0,$cProv-1)+'…'   } else { $item.Provider }
        $cat  = if ($item.Category.Length   -gt $cCat)   { $item.Category.Substring(0,$cCat-1)+'…'    } else { $item.Category }
        $ver  = if ($item.Version -and $item.Version.Length -gt $cVer) { $item.Version.Substring(0,$cVer-1)+'…' } else { if ($item.Version) { $item.Version } else { '—' } }
        $arch = if ($item.Arch) { $item.Arch } else { 'any' }

        $row = "  {0,-$cN} │ {1,-$cName} │ {2,-$cProv} │ {3,-$cCat} │ {4,-$cVer} │ {5,-$cArch}" `
               -f $rowNum, $name, $prov, $cat, $ver, $arch
        Write-Host $row -ForegroundColor White
    }

    Write-Host ""
    if ($totalPages -gt 1) {
        Write-Host "  Page $Page of $totalPages  ·  n=next  p=prev  g<N>=go to page" -ForegroundColor DarkGray
    }

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
    $fields = [ordered]@{
        'Name'        = $Item.DisplayName
        'Provider'    = $Item.Provider
        'Category'    = $Item.Category
        'Version'     = $Item.Version
        'Arch'        = $Item.Arch
        'Driver ID'   = $Item.DriverId
        'Matched HWID'= if ($Item.MatchedHWID) { $Item.MatchedHWID } else { 'N/A (keyword match)' }
        'Parts'       = "$($Item.ZipParts) archive part(s)"
        'Download URL'= $Item.PrimaryUrl
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
                -replace '[\\/:*?"<>|]', '_'
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
        $proc = Start-Process -FilePath $Extractor -Wait -PassThru -NoNewWindow `
                    -ArgumentList @('--file', $firstPart, '--output', $outDir, '--verify') `
                    -RedirectStandardError (Join-Path $pkgTemp 'stderr.txt')
        if ($proc.ExitCode -ne 0) {
            $errLines = ''
            $ef = Join-Path $pkgTemp 'stderr.txt'
            if (Test-Path $ef) { $errLines = (Get-Content $ef -ErrorAction SilentlyContinue | Select-Object -Last 3) -join ' | ' }
            throw "Extractor failed (exit $($proc.ExitCode)) — $errLines"
        }
        Write-OK "Extracted to: $outDir"

        if ($InstallMode -eq 'install') {
            $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue |
                      Where-Object { $_ -ne $null })
            if (@($infs).Count -gt 0 -and $IsAdmin) {
                Write-Step "Installing via pnputil ($(@($infs).Count) INF)..."
                $pnp = Start-Process "$env:SystemRoot\System32\pnputil.exe" `
                           -ArgumentList @('/add-driver', "$outDir\*.inf", '/subdirs', '/install') `
                           -Wait -PassThru -NoNewWindow
                if ($pnp.ExitCode -in @(0,3010)) {
                    Write-OK "Driver installed successfully$(if ($pnp.ExitCode -eq 3010) { ' — reboot required' } else { '' })"
                } else {
                    Write-Warn "pnputil returned exit code $($pnp.ExitCode) — try Device Manager at: $outDir"
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
        $input = $Host.UI.ReadLine()
        if ($null -eq $input) { break }
        $input = $input.Trim()
        if (-not $input) { continue }

        # ── Command dispatch ──────────────────────────────────────────────
        switch -Regex ($input.ToLower()) {

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

            '^g(\d+)$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results."; continue }
                $gPage = [int]($Matches[1])
                $currentPage = $gPage
                $pageState = Show-SearchResultsTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^det(\d+)$' {
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    Get-SearchResultDetail -Item $currentResults[$idx]
                } else { Write-Warn "Invalid result number." }
                continue
            }

            '^d(\d+)$' {
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

            '^i(\d+)$' {
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
                $query = $input -replace '^(new|s)\s+', ''
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
                $query          = $input
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
                    Write-Info "Examples: 'realtek audio', 'intel wifi', 'PCI\\VEN_8086&DEV_1234'"
                    Write-Info "Type 'help' for full command reference."
                }
                continue
            }
        }
    }
}


function Show-MainMenu {
    <#
    .SYNOPSIS Shows the DriverDex mode selection menu after the header.
    Returns 'auto', 'search', or 'quit'.
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
    Write-Host "  │   [q]  Quit                                                             │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  └─────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""

    $choice = Read-Input -Prompt 'Select mode' -Default '1' `
        -Validator { param($v) $v -match '^[12qQ]$' } `
        -ErrMsg    'Enter 1 (Auto-Detect), 2 (Search Engine), or q to quit.'

    if ($choice -match '^[Qq]') { return 'quit' }
    if ($choice -eq '2')        { return 'search' }
    return 'auto'
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
            return
        }

        # ── Auto-Detect mode ───────────────────────────────────────────────
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
        if (-not (Test-NetworkConnectivity)) { return }
        Write-Host ""

        # ── Step 3: Hardware scan ──────────────────────────────────────────
        Write-Divider
        $hwids        = Get-AllHardwareIDs
        $problemHWIDs = Get-ProblemDevices
        Write-OK "Found $(@($hwids).Count) hardware IDs · $(@($problemHWIDs).Count) problem device(s)"
        Write-Host ""

        if (@($hwids).Count -eq 0) {
            Write-Err -What "No hardware IDs found." `
                      -Reason "CIM and WMI queries returned empty results." `
                      -Fix    "Ensure you have read access to WMI on this machine."
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

        if (@($drivers).Count -eq 0) {
            Write-Warn "No matching drivers found in the DriverDex database for your hardware."
            Write-Host ""
            Invoke-ContributePrompt -HWIDs $hwids -Reason 'no_drivers' -UnmatchedLocalDrivers $unmatchedLocal
            return
        }

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
            Write-Info "No drivers selected. Exiting."
            return
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
            return
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
            Write-Log -Level INFO -Msg "Driver '$($drv.DisplayName)': success=$($res.Success) skipped=$($res.Skipped) reboot=$($res.RebootRequired)"
        }

        # ── Step 8: Summary ────────────────────────────────────────────────
        Show-Summary -Results @($results)

        # ── Step 9: Contribution prompt ───────────────────────────────────
        $failedDrivers  = @($results | Where-Object { -not $_.Success -and -not $_.Skipped })
        if ($failedDrivers.Count -gt 0 -or @($unmatchedLocal).Count -gt 0) {
            Invoke-ContributePrompt -HWIDs $hwids -Reason 'partial' -UnmatchedLocalDrivers $unmatchedLocal
        }

        # ── Step 10: Reboot prompt ─────────────────────────────────────────
        Invoke-RebootPrompt -Results @($results)

        Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
        Write-Info "  Session log: $Script:LOG_PATH"
        Write-Host ""
        Write-Log -Level INFO -Msg "Session complete."

    } finally {
        Remove-Item -Recurse -Force $Script:scratch -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
Main
# ═══════════════════════════════════════════════════════════════════════════════
