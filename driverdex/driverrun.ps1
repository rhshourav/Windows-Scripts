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
$Script:VERSION       = '2.1.0'
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
    #>
    $w = 66
    $top = '╔' + ('═' * ($w - 2)) + '╗'
    $bot = '╚' + ('═' * ($w - 2)) + '╝'
    $pad = { param($s, $n) $s + (' ' * [Math]::Max(0, $n - $s.Length)) }

    Write-Host ""
    Write-Host "  $top"  -ForegroundColor DarkCyan
    Write-Host "  ║$(' ' * ($w - 2))║"  -ForegroundColor DarkCyan
    # ASCII art lines (Cyan for logo)
    foreach ($row in @(
        ' ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗ ',
        ' ██╔══██╗██╔══██╗██║╚██╗ ██╔╝██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝ ',
        ' ██║  ██║██████╔╝██║ ╚████╔╝ █████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝  ',
        ' ██║  ██║██╔══██╗██║  ╚██╔╝  ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗  ',
        ' ██████╔╝██║  ██║██║   ██║   ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗  ',
        ' ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝ '
    )) {
        $padded = & $pad $row ($w - 2)
        Write-Host "  ║$padded║" -ForegroundColor Cyan
    }
    Write-Host "  ║$(' ' * ($w - 2))║"  -ForegroundColor DarkCyan
    $meta1 = & $pad "  Automatic Driver Detector & Installer  v$Script:VERSION" ($w - 2)
    Write-Host "  ║$meta1║"  -ForegroundColor White
    $meta2 = & $pad "  Tagline: Hardware confidence, one script away." ($w - 2)
    Write-Host "  ║$meta2║"  -ForegroundColor DarkGray
    $meta3 = & $pad "  https://github.com/rhshourav/driverdex" ($w - 2)
    Write-Host "  ║$meta3║"  -ForegroundColor DarkGray
    Write-Host "  ║$(' ' * ($w - 2))║"  -ForegroundColor DarkCyan
    Write-Host "  $bot"  -ForegroundColor DarkCyan
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
    #>
    if (Test-Administrator) { return }

    Write-Warn 'Not running as Administrator.'
    Write-Info 'Steps requiring elevation: driver install via pnputil.'
    Write-Info 'Without elevation: files are saved but drivers will NOT be installed.'
    Write-Host ""

    $choice = Read-Input -Prompt 'Relaunch as Administrator?' -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'

    if ($choice -match '^[Yy]') {
        try {
            $exe  = if ($PSCommandPath) { $PSCommandPath } else { '' }
            if ($exe) {
                Start-Process powershell -Verb RunAs `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$exe`"" -ErrorAction Stop
            } else {
                # Invoked via irm | iex — re-download and run elevated
                Start-Process powershell -Verb RunAs `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $Script:EXTRACTOR_URL | iex`"" `
                    -ErrorAction Stop
            }
            exit 0
        } catch {
            Write-Warn "Auto-elevation failed. Continuing without admin — install step will be skipped."
            Write-Log -Level WARN -Msg "Auto-elevation failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "Continuing without elevation — driver install will be skipped (download still works)."
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
                   Where-Object { $_.HardwareID -and $_.HardwareID.Count -gt 0 }
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
                Write-Host "`r    Scanning... $($hwids.Count) IDs found so far" -NoNewline -ForegroundColor DarkGray
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

    Write-OK "Found $($hwids.Count) unique hardware IDs"
    return @($hwids)
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
    return @($problem)
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
    .PARAMETER HWIDs       Array of hardware ID strings
    .PARAMETER SystemArch  'x64' or 'x86'
    #>
    param([string[]]$HWIDs, [string]$SystemArch)

    Write-Step "Querying DriverDex API for $($HWIDs.Count) hardware IDs..."
    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $total   = $HWIDs.Count
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
        if (-not $apiResult -or -not $apiResult.matches -or $apiResult.matches.Count -eq 0) { continue }

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

            [void]$seen.Add($match.driver_id)
            $results.Add([pscustomobject]@{
                DriverId        = $match.driver_id
                DisplayName     = $match.display_name
                Provider        = $match.provider
                Category        = $match.category
                Version         = $match.version
                Arch            = $match.arch
                PrimaryUrl      = $match.primary_url
                ZipParts        = [int]$match.zip_parts
                MatchedHWID     = $id
                SupersededBy    = $match.superseded_by
                IsGeneric       = [int]$match.matched_is_generic
                IsRecommended   = $isRecommended
            })
        }
    }
    Write-Host ""   # newline after progress bar
    return $results
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DRIVER SELECTION TABLE
# ═══════════════════════════════════════════════════════════════════════════════
function Show-DriverTable {
    <#
    .SYNOPSIS Renders a formatted, numbered driver selection table.
    .PARAMETER Drivers       Array of driver PSObjects
    .PARAMETER ProblemHWIDs  Array of HWIDs with ConfigManagerErrorCode > 0
    #>
    param([object[]]$Drivers, [string[]]$ProblemHWIDs)

    Write-Host ""
    Write-Divider
    Write-Host "  Found $($Drivers.Count) matching driver package(s) for your hardware:" -ForegroundColor Cyan
    Write-Divider
    Write-Host ""

    # Column widths
    $colN   = 3; $colStar = 2; $colName = 28; $colProv = 16
    $colCat = 10; $colVer = 14; $colArch = 6; $colStat = 16

    # Header
    $h = "  {0,-$colN} │ {1,-$colStar} │ {2,-$colName} │ {3,-$colProv} │ {4,-$colCat} │ {5,-$colVer} │ {6,-$colArch} │ {7}" `
         -f '#','','Name','Provider','Category','Version','Arch','Status'
    Write-Host $h -ForegroundColor DarkGray
    $sep = '  {0}─┼─{1}─┼─{2}─┼─{3}─┼─{4}─┼─{5}─┼─{6}─┼─{7}' -f `
           ('─'*$colN),('─'*$colStar),('─'*$colName),('─'*$colProv),`
           ('─'*$colCat),('─'*$colVer),('─'*$colArch),('─'*$colStat)
    Write-Host $sep -ForegroundColor DarkGray

    $idx = 0
    foreach ($d in $Drivers) {
        $idx++
        $star    = if ($d.IsRecommended)  { '★' } else { ' ' }
        $isProblem   = $ProblemHWIDs -contains $d.MatchedHWID
        $isSuperseded = [bool]$d.SupersededBy

        $status = ''
        if ($isSuperseded) { $status = '[SUPERSEDED]' }
        elseif ($isProblem) { $status = '[PROBLEM DEV]' }

        $name = if ($d.DisplayName.Length -gt $colName) { $d.DisplayName.Substring(0,$colName-1)+'…' } else { $d.DisplayName }
        $prov = if ($d.Provider.Length -gt $colProv)    { $d.Provider.Substring(0,$colProv-1)+'…' }    else { $d.Provider }
        $row  = "  {0,-$colN} │ {1,-$colStar} │ {2,-$colName} │ {3,-$colProv} │ {4,-$colCat} │ {5,-$colVer} │ {6,-$colArch} │ {7}" `
                -f $idx, $star, $name, $prov, $d.Category, $d.Version, $d.Arch, $status

        if ($isSuperseded) {
            Write-Host $row -ForegroundColor DarkGray
        } elseif ($isProblem) {
            Write-Host $row -ForegroundColor Yellow
        } elseif ($d.IsRecommended) {
            Write-Host $row -ForegroundColor White
        } else {
            Write-Host $row -ForegroundColor Gray
        }
    }
    Write-Host ""
}

function Show-DriverMenu {
    <#
    .SYNOPSIS Renders driver table and returns the user-selected subset.
    .PARAMETER Drivers       All available driver objects
    .PARAMETER ProblemHWIDs  HWIDs flagged as problem devices
    #>
    param([object[]]$Drivers, [string[]]$ProblemHWIDs)

    Show-DriverTable -Drivers $Drivers -ProblemHWIDs $ProblemHWIDs

    Write-Info "Selection: ALL · PROBLEMS · comma-separated numbers (e.g. 1,3,5) · q to quit"
    Write-Host ""

    $raw = Read-Input -Prompt 'Select drivers' -Default 'ALL' `
        -Validator { param($v) $v -match '^(ALL|PROBLEMS|q|[0-9, ]+)$' } `
        -ErrMsg    'Enter ALL, PROBLEMS, a list of numbers, or q to quit.'

    if ($raw -eq 'q') { return @() }
    if ($raw -eq 'ALL') {
        $sel = $Drivers
    } elseif ($raw -eq 'PROBLEMS') {
        $sel = @($Drivers | Where-Object { $ProblemHWIDs -contains $_.MatchedHWID })
        if (-not $sel -or $sel.Count -eq 0) {
            Write-Warn "No problem devices in the list. Selecting ALL."
            $sel = $Drivers
        }
    } else {
        $indices = $raw -split '[,\s]+' | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Drivers.Count) { $n }
        } | Where-Object { $_ } | Sort-Object -Unique
        $sel = @($indices | ForEach-Object { $Drivers[$_ - 1] })
    }

    # Echo selection
    $names = ($sel | ForEach-Object { $_.DisplayName }) -join ', '
    Write-OK "Selected: $names"

    # Check for superseded in selection
    $supersededPicked = @($sel | Where-Object { $_.SupersededBy })
    foreach ($s in $supersededPicked) {
        Write-Warn "'$($s.DisplayName)' is superseded by $($s.SupersededBy) — consider deselecting."
    }

    # Confirm
    Write-Host ""
    $confirm = Read-Input -Prompt "Proceed with $($sel.Count) driver(s)?" -Default 'Y' `
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
                Write-Log -Level WARN -Msg "Download retry $attempt for $Url: $reason"
                Start-Sleep -Seconds $d
            } else {
                Write-Log -Level ERROR -Msg "Download failed after $MaxRetries attempts for $Url: $reason" -Err $_
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

        # ── Already installed? ─────────────────────────────────────────────
        if (Test-DriverInstalled -Provider $Driver.Provider -Version $Driver.Version) {
            Write-Warn "v$($Driver.Version) of $($Driver.Provider) is already installed — skipping."
            Write-Info "Use prefix 'r' in selection to force reinstall."
            $result.Skipped = $true
            return $result
        }

        # ── Download all parts ─────────────────────────────────────────────
        $partUrls = Get-PartUrls -PrimaryUrl $Driver.PrimaryUrl -ZipParts $Driver.ZipParts
        $firstPart = $null

        for ($pi = 0; $pi -lt $partUrls.Count; $pi++) {
            $url      = $partUrls[$pi]
            $fileName = Split-Path $url -Leaf
            $dest     = Join-Path $pkgTemp $fileName
            if ($pi -eq 0) { $firstPart = $dest }

            Write-Sub "[$($pi+1)/$($partUrls.Count)] $fileName"
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
        $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)

        if ($infs.Count -gt 0 -and $IsAdmin) {
            Write-Step "Installing $($infs.Count) INF package(s) via pnputil..."
            $pnpArgs = '/add-driver', (Join-Path $outDir '*.inf'), '/subdirs', '/install'
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

        } elseif ($infs.Count -gt 0 -and -not $IsAdmin) {
            Write-Warn "INF found but script is not elevated. Open Device Manager and point it at:"
            Write-Host "      $outDir" -ForegroundColor Cyan
            $result.Success = $true   # files are ready, install is manual

        } else {
            # Fallback: vendor setup.exe / MSI
            $installer = Get-ChildItem -Path $outDir -Include 'setup.exe','*.msi' `
                                       -Recurse -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            if ($installer) {
                Write-Step "Vendor installer detected: $($installer.Name)"
                $run = Read-Input -Prompt "Run installer now?" -Default 'Y' `
                    -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
                if ($run -match '^[Yy]') {
                    $iArgs = if ($installer.Extension -eq '.msi') { '/i', $installer.FullName, '/qn' } else { @() }
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
    if ($needsReboot.Count -eq 0) { return }

    Write-Warn "$($needsReboot.Count) driver(s) require a reboot to activate."
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
#  MAIN  — calls everything in sequence
# ═══════════════════════════════════════════════════════════════════════════════
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
        Write-OK "Found $($hwids.Count) hardware IDs · $($problemHWIDs.Count) problem device(s)"
        Write-Host ""

        if ($hwids.Count -eq 0) {
            Write-Err -What "No hardware IDs found." `
                      -Reason "CIM and WMI queries returned empty results." `
                      -Fix    "Ensure you have read access to WMI on this machine."
            return
        }

        # ── Step 4: API query ──────────────────────────────────────────────
        Write-Divider
        $drivers = Search-Drivers -HWIDs $hwids -SystemArch $os.Arch
        Write-Host ""

        if ($drivers.Count -eq 0) {
            Write-Warn "No matching drivers found in the DriverDex database for your hardware."
            Write-Info "Check https://github.com/rhshourav/driverdex for coverage info."
            return
        }

        # Category summary
        $byCat = $drivers | Group-Object Category
        $catSummary = ($byCat | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '  ·  '
        Write-OK "Found $($drivers.Count) matching driver(s)  [$catSummary]"
        Write-Host ""

        # ── Step 5: Driver selection ───────────────────────────────────────
        $selected = Show-DriverMenu -Drivers @($drivers) -ProblemHWIDs $problemHWIDs

        if (-not $selected -or $selected.Count -eq 0) {
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
        $estMB = $selected.Count * 200
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
            Show-DriverPanel -Driver $drv -Idx $dIdx -Total $selected.Count

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

        # ── Step 9: Reboot prompt ──────────────────────────────────────────
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
