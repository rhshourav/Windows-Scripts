#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Utilities Module
    Common utilities, logging, ANSI detection, safe property access, array handling
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# MODULE-SCOPE VARIABLES
# ═══════════════════════════════════════════════════════════════════════════════

$Script:SpinnerFrames = [char[]]@(0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
                                 0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
$Script:SpinIdx = 0
$Script:LogPath = Join-Path $env:TEMP "DriverDex-$(Get-Date -Format 'yyyyMMdd').log"
$Script:AnsiSupported = $null
$Script:ConsoleWidth = 120

# ═══════════════════════════════════════════════════════════════════════════════
# SAFE PROPERTY ACCESS (handles PSCustomObject + Newtonsoft JObject on PS 5.1)
# ═══════════════════════════════════════════════════════════════════════════════

function Get-Prop {
    <#
    .SYNOPSIS Reads a property safely under Set-StrictMode -Version Latest.
             Handles BOTH PSCustomObject (PS 6+) and Newtonsoft JObject (PS 5.1).
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

    # PS 5.1: ConvertFrom-Json returns Newtonsoft JObject/JArray
    $typeName = $Obj.GetType().FullName
    if ($typeName -like 'Newtonsoft.Json.Linq.*') {
        try {
            $token = $Obj[$Name]
            if ($null -eq $token) { return $Default }
            if ($token.Type.ToString() -eq 'Null') { return $Default }
            $val = $token.ToObject([object])
            if ($null -eq $val) { return $Default }
            return $val
        } catch { return $Default }
    }

    # PS 6+ / PSCustomObject: reflection-based lookup
    $member = $Obj.PSObject.Properties[$Name]
    if ($null -eq $member) { return $Default }
    $val = $member.Value
    if ($null -eq $val) { return $Default }
    return $val
}

# ═══════════════════════════════════════════════════════════════════════════════
# ARRAY-SAFE FIELD FLATTENING (prevents duplicate display bugs)
# ═══════════════════════════════════════════════════════════════════════════════

function ConvertTo-CleanFieldString {
    <#
    .SYNOPSIS Normalizes a raw API field into a short, readable string.
    .DESCRIPTION
        Handles both real arrays and space-delimited strings from the API.
        De-duplicates case-insensitively while preserving order.
        Returns original string unchanged if no duplicates found (preserves "Atmel Corp" etc).
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

    # No duplicates collapsed and it wasn't a true array -> ordinary human-readable value
    if (-not $isRealArray -and $unique.Count -eq $rawTokens.Count) {
        return ([string]$Value).Trim()
    }

    if ($unique.Count -le $MaxItems) { return ($unique -join $Separator) }
    return "$($unique[0..($MaxItems-1)] -join $Separator) +$($unique.Count - $MaxItems) more"
}

function Join-Unique {
    <#
    .SYNOPSIS Joins array elements with deduplication and optional sorting.
    .PARAMETER InputArray     Input array
    .PARAMETER Separator      Separator (default ', ')
    .PARAMETER Sort           Sort before joining (default $true)
    .PARAMETER MaxItems       Max items before truncation (default 0 = no limit)
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object[]]$InputArray,
        [string]$Separator = ', ',
        [bool]$Sort = $true,
        [int]$MaxItems = 0
    )
    process {
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $InputArray) {
            if ($null -eq $item) { continue }
            $s = [string]$item
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $list.Add($s.Trim())
        }
        $unique = $list | Sort-Object -Unique
        if ($MaxItems -gt 0 -and $unique.Count -gt $MaxItems) {
            $unique = $unique[0..($MaxItems-1)]
            return ($unique -join $Separator) + " +$($list.Count - $MaxItems) more"
        }
        return ($unique -join $Separator)
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Log {
    <#
    .SYNOPSIS Appends a timestamped line to the session log file.
    .PARAMETER Level  Severity label: INFO / WARN / ERROR / DEBUG
    .PARAMETER Msg    Message text
    .PARAMETER Err    Optional ErrorRecord for stack-trace capture
    #>
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [string]$Msg,
        [System.Management.Automation.ErrorRecord]$Err = $null
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts] [$Level] $Msg"
    try { Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    if ($Err) {
        try { Add-Content -LiteralPath $Script:LogPath -Value $Err.ScriptStackTrace -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
}

function Get-LogPath {
    return $Script:LogPath
}

# ═══════════════════════════════════════════════════════════════════════════════════
# ANSI & CONSOLE DETECTION
# ════════════════════════════════════════════════════════════════════════════════

function Get-AnsiSupported {
    <#
    .SYNOPSIS Detects ANSI/VT sequence support in the current terminal.
    .DESCRIPTION
        Checks for Windows 10+ with VT enabled, WT_SESSION, TERM, ConEmu, etc.
        Caches result after first call.
    #>
    if ($null -ne $Script:AnsiSupported) { return $Script:AnsiSupported }

    # Check for known ANSI-supporting environments
    if ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuPID -or $env:ANSICON) {
        $Script:AnsiSupported = $true
        return $true
    }

    # Windows 10+ with VT enabled
    if ([Environment]::OSVersion.Version.Major -ge 10) {
        try {
            $mode = [Console]::CursorVisible  # forces console init
            $Script:AnsiSupported = $true
            return $true
        } catch {
            $Script:AnsiSupported = $false
            return $false
        }
    }

    $Script:AnsiSupported = $false
    return $false
}

function Get-ConsoleWidth {
    <#
    .SYNOPSIS Gets the current console buffer width, clamped to reasonable bounds.
    #>
    try {
        $w = $Host.UI.RawUI.BufferSize.Width
        if ($w -lt 60) { $w = 120 }
        if ($w -gt 300) { $w = 300 }
        $Script:ConsoleWidth = $w
        return $w
    } catch {
        return $Script:ConsoleWidth
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# TLS BOOTSTRAP
# ═══════════════════════════════════════════════════════════════════════════════

function Initialize-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor
            [Net.SecurityProtocolType]::Tls13
    } catch {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# VERSION COMPARISON
# ═══════════════════════════════════════════════════════════════════════════════

function Compare-DriverVersion {
    <#
    .SYNOPSIS Numerically compares two dotted version strings, part by part.
    Returns -1 if A is older than B, 0 if equal, 1 if A is newer than B.
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
    return [string]::Compare($A, $B)
}

# ═══════════════════════════════════════════════════════════════════════════════
# SPINNER
# ═══════════════════════════════════════════════════════════════════════════════

function Show-Spinner {
    param([string]$Label)
    $f = $Script:SpinnerFrames[$Script:SpinIdx % $Script:SpinnerFrames.Count]
    $Script:SpinIdx++
    Write-Host "`r  $f $Label   " -NoNewline -ForegroundColor Cyan
}

function Clear-SpinnerLine {
    Write-Host "`r$(' ' * 80)`r" -NoNewline
}

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATED INPUT
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
# ELEVATION & OS DETECTION
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

    if ($choice -notmatch '^[Yy]') {
        Write-Warn "Continuing without elevation — driver install will be skipped (download still works)."
        return
    }

    try {
        $scriptPath = $PSCommandPath

        if (-not $scriptPath) {
            $scriptPath = Join-Path $env:TEMP 'DriverDex-elevated.ps1'
            $installerUrl = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/driverdex/DriverDex.ps1'
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

        exit 0

    } catch {
        Write-Warn "Auto-elevation failed. Continuing without admin — install step will be skipped."
        Write-Log -Level WARN -Msg "Auto-elevation failed: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK CHECK
# ═══════════════════════════════════════════════════════════════════════════════

function Test-NetworkConnectivity {
    <#
    .SYNOPSIS DNS-resolves known hosts to verify internet access before API calls.
    Returns $true if both resolve successfully.
    #>
    $Script:SpinIdx = 0
    $ok = $true
    foreach ($host_ in @('github.com', 'driverdex-check.driverdex.workers.dev')) {
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
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Get-Prop'
    'ConvertTo-CleanFieldString'
    'Join-Unique'
    'Write-Log'
    'Get-LogPath'
    'Get-AnsiSupported'
    'Get-ConsoleWidth'
    'Initialize-Tls'
    'Compare-DriverVersion'
    'Show-Spinner'
    'Clear-SpinnerLine'
    'Read-Input'
    'Test-Administrator'
    'Get-OSInfo'
    'Request-Elevation'
    'Test-NetworkConnectivity'
)