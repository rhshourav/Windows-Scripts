#Requires -Version 5.1
<#
.SYNOPSIS
    KeyForge - Windows Keyboard Layout, Language & Region Manager.

.DESCRIPTION
    KeyForge is a single-file PowerShell administration console for inspecting
    Windows keyboard layouts, language packs, input methods, regional settings
    and locale configuration.

    THIS BUILD: "Core Foundation + UI Shell" (Phase 1 + Phase 2 of the KeyForge
    roadmap). It ships the complete framework - logging, error handling,
    validation, formatting/conversion helpers, and system-query utilities -
    together with the full terminal UI engine: live dashboard, menu system,
    tables, tree views, dialogs, spinners and progress bars.

    All screens in this build are strictly READ-ONLY. Installing or removing
    languages/keyboards, editing the registry, running repairs, and other
    state-changing operations are intentionally out of scope for this release
    and appear in the menu as clearly-labeled placeholders - they arrive with
    the Registry Handler and Management modules in the next phase.

.PARAMETER Help
    Show command-line help and exit.

.PARAMETER Version
    Show version information and exit.

.PARAMETER NoColor
    Disable colored output. Useful for redirected output, CI logs, or hosts
    without ANSI/console color support.

.PARAMETER VerboseLog
    Write verbose-level entries to the session log file in addition to the
    console. (Named to avoid colliding with the common -Verbose parameter.)

.PARAMETER DebugLog
    Write debug-level entries to the session log file (implies -VerboseLog).

.EXAMPLE
    PS> .\KeyForge.ps1
    Launches the interactive dashboard.

.EXAMPLE
    PS> irm https://raw.githubusercontent.com/rhshourav/windows-scripts/main/KeyForge.ps1 | iex
    Runs KeyForge directly from GitHub with no local file.

.EXAMPLE
    PS> powershell -ExecutionPolicy Bypass -File .\KeyForge.ps1 -NoColor -VerboseLog
    Runs KeyForge with color disabled and verbose logging enabled.

.NOTES
    Project   : KeyForge
    Tagline   : Forge. Manage. Eliminate.
    Build     : 1.0.0-phase1 (Core Foundation + UI Shell)
    License   : MIT
    Repo      : https://github.com/rhshourav/windows-scripts
    Min PS    : 5.1 (Windows PowerShell) / PowerShell 7+ (pwsh)

.LINK
    https://github.com/rhshourav/windows-scripts
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'KeyForge is an interactive console dashboard, not a pipeline component - it needs direct control over console color/cursor position that Write-Output cannot provide. This is the standard, accepted exception for TUI-style tools.')]
param(
    [switch]$Help,
    [switch]$Version,
    [switch]$NoColor,
    [switch]$VerboseLog,
    [switch]$DebugLog
)

# ---------------------------------------------------------------------------
# Strict, fail-fast execution: non-terminating errors from cmdlets are
# promoted to terminating so every risky call can be caught by try/catch.
# Individual enumeration loops opt back out locally with -ErrorAction
# SilentlyContinue where a single missing item must not abort a scan.
# ---------------------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # KeyForge renders its own progress UI

if ($DebugLog) { $VerboseLog = $true }

#region ============================== METADATA =============================

$Script:Meta = [ordered]@{
    Name         = 'KeyForge'
    Tagline      = 'Forge. Manage. Eliminate.'
    Version      = '1.0.0'
    Build        = 'phase1-2'
    BuildLabel   = 'Core Foundation + UI Shell'
    BuildDate    = '2026-07-13'
    Author       = 'KeyForge Team'
    ProjectURL   = 'https://github.com/rhshourav/windows-scripts'
    License      = 'MIT'
    MinPSVersion = [version]'5.1'
    SupportedOS  = @(10, 11)
}

$Script:Banner = @'
 ██╗  ██╗███████╗██╗   ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
 ██║ ██╔╝██╔════╝╚██╗ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
 █████╔╝ █████╗   ╚████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗
 ██╔═██╗ ██╔══╝    ╚██╔╝  ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
 ██║  ██╗███████╗   ██║   ██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
 ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
'@

$Script:BannerAscii = @'
 _  __          ______
| |/ /___ _   _|  ____|__  _ __ __ _  ___
| ' // _ \ | | | |__ / _ \| '__/ _` |/ _ \
| . \  __/ |_| |  __| (_) | | | (_| |  __/
|_|\_\___|\__, |_|   \___/|_|  \__, |\___|
          |___/                |___/
'@

#endregion ==================================================================

#region ============================== PATHS ================================

# NOTE: When KeyForge is dot-launched via `irm ... | iex`, there is no on-disk
# script file, so $PSScriptRoot is empty. All working data therefore lives in
# a dedicated per-user AppData folder rather than next to the script. Falls
# back to $HOME if $env:LOCALAPPDATA is unset (e.g. pwsh on a non-Windows
# host) so this line can never throw during top-level script initialization -
# KeyForge's own platform check further down is what should deliver the
# "Windows only" message, not an unhandled exception at load time.
$kfAppDataRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($HOME) { $HOME } else { [System.IO.Path]::GetTempPath() }
$kfRootPath = Join-Path -Path $kfAppDataRoot -ChildPath 'KeyForge'
Remove-Variable -Name kfAppDataRoot -ErrorAction SilentlyContinue

$Script:Paths = [ordered]@{
    Root    = $kfRootPath
    Logs    = Join-Path $kfRootPath 'Logs'
    Backups = Join-Path $kfRootPath 'Backups'
    Exports = Join-Path $kfRootPath 'Exports'
    Temp    = Join-Path $kfRootPath 'Temp'
}

Remove-Variable -Name kfRootPath -ErrorAction SilentlyContinue

$Script:WinPaths = [ordered]@{
    WinDir             = $env:WINDIR
    SystemRoot         = $env:SystemRoot
    System32           = if ($env:WINDIR) { Join-Path $env:WINDIR 'System32' } else { $null }
    GlobalizationPath  = if ($env:WINDIR) { Join-Path $env:WINDIR 'Globalization' } else { $null }
    IntlDllPath        = if ($env:WINDIR) { Join-Path (Join-Path $env:WINDIR 'System32') 'Speech' } else { $null }
}

# Registry locations used by the read-only query layer in this build.
# Paths marked [VERIFY] are best-effort and should be re-validated against a
# live system matrix before any Phase 3 write operation relies on them.
$Script:RegistryPaths = [ordered]@{
    KeyboardLayouts   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
    Preload           = 'HKCU:\Keyboard Layout\Preload'
    Substitutes       = 'HKCU:\Keyboard Layout\Substitutes'
    ToggleKeys        = 'HKCU:\Keyboard Layout\Toggle'
    IntlUserProfile   = 'HKCU:\Control Panel\International'
    IntlGeo           = 'HKCU:\Control Panel\International\Geo'
    UserProfileLangs  = 'HKCU:\Control Panel\International\User Profile'
    NlsLanguageGroups = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language Groups'   # [VERIFY]
    MUICache          = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
    CurrentVersion    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    ProfileList       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
}

#endregion ==================================================================

#region ============================== UI CONSTANTS =========================

# Design note: KeyForge never overwrites the user's console background color.
# Forcing a black background is invasive on custom Windows Terminal themes,
# SSH/RDP sessions, and redirected output. Instead the palette below uses
# foreground colors only (White body text, Red accent/danger, Gray borders)
# which read correctly against any background the user already has.
$Script:Colors = [ordered]@{
    Body       = 'White'
    Muted      = 'Gray'
    Border     = 'DarkGray'
    Accent     = 'Red'
    Success    = 'Green'
    Warning    = 'Yellow'
    Danger     = 'Red'
    Info       = 'Cyan'
    Highlight  = 'White'
    Dim        = 'DarkGray'
}

$Script:BoxChars = [ordered]@{
    TopLeft     = [char]0x256D   # ╭
    TopRight    = [char]0x256E   # ╮
    BottomLeft  = [char]0x2570   # ╰
    BottomRight = [char]0x256F   # ╯
    Horizontal  = [char]0x2500   # ─
    Vertical    = [char]0x2502   # │
    TeeRight    = [char]0x251C   # ├
    TeeLeft     = [char]0x2524   # ┤
}

$Script:BoxCharsAscii = [ordered]@{
    TopLeft     = '+'
    TopRight    = '+'
    BottomLeft  = '+'
    BottomRight = '+'
    Horizontal  = '-'
    Vertical    = '|'
    TeeRight    = '+'
    TeeLeft     = '+'
}

$Script:Icons = [ordered]@{
    Success = [char]0x2713   # ✓
    Failure = [char]0x2717   # ✗
    Warning = [char]0x26A0   # ⚠
    Info    = [char]0x2139   # ℹ
    Arrow   = [char]0x2192   # →
    Bullet  = [char]0x2022   # •
    Dot     = [char]0x25CF   # ●
    Ring    = [char]0x25CB   # ○
}

$Script:IconsAscii = [ordered]@{
    Success = '[OK]'
    Failure = '[X]'
    Warning = '[!]'
    Info    = '[i]'
    Arrow   = '->'
    Bullet  = '*'
    Dot     = '*'
    Ring    = 'o'
}

$Script:SpinnerFrames      = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$Script:SpinnerFramesAscii = @('|','/','-','\')

# Populated by Initialize-KFConsole at startup; read by every rendering
# function so the whole UI degrades to ASCII together, consistently.
$Script:UIState = [ordered]@{
    UnicodeSupported = $true
    ColorSupported   = -not $NoColor
    ConsoleWidth     = 100
    LastRefresh      = $null
    CurrentScreen    = 'Dashboard'
    NavigationStack  = New-Object System.Collections.Generic.List[string]
    Settings         = [ordered]@{
        AutoRefreshSeconds = 5
        AutoRefreshEnabled = $true
        VerboseLog         = [bool]$VerboseLog
        DebugLog           = [bool]$DebugLog
    }
}

# Simple in-memory cache used by the system-query layer (see caching
# strategy in the architecture docs: 1-10 minute TTLs per data category).
$Script:Cache = @{}

# Pre-declared (rather than only created inside Initialize-KFLogFile) so
# Set-StrictMode never trips on a reference to these before logging starts -
# e.g. from the top-level fatal-error handler if something fails very early.
$Script:LogFilePath = $null
$Script:SessionId   = $null

#endregion ==================================================================

#region ============================== EXCEPTION TYPES =======================

class KeyForgeException : System.Exception {
    [string]$Category = 'General'
    KeyForgeException([string]$Message) : base($Message) {}
    KeyForgeException([string]$Message, [string]$Category) : base($Message) {
        $this.Category = $Category
    }
}

class ValidationException : KeyForgeException {
    ValidationException([string]$Message) : base($Message, 'Validation') {}
}

class RegistryAccessException : KeyForgeException {
    RegistryAccessException([string]$Message) : base($Message, 'Registry') {}
}

class OperationFailedException : KeyForgeException {
    OperationFailedException([string]$Message) : base($Message, 'Operation') {}
}

class RollbackRequiredException : KeyForgeException {
    RollbackRequiredException([string]$Message) : base($Message, 'Rollback') {}
}

#endregion ==================================================================

#region ============================== LOGGING FRAMEWORK =====================

function Initialize-KFLogFile {
    <#
    .SYNOPSIS
        Ensures the KeyForge data directories exist and starts a new session
        log file. Never throws - logging must not be able to crash the app.
    #>
    [CmdletBinding()]
    param()

    foreach ($dir in $Script:Paths.Values) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        } catch {
            # If we cannot create the data directory, fall back to Temp and
            # keep going - a missing log directory should never stop KeyForge.
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:SessionId  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $Script:LogFilePath = Join-Path $Script:Paths.Logs "KeyForge_${stamp}_$($Script:SessionId).log"

    try {
        $header = "# KeyForge v$($Script:Meta.Version) session log`r`n# Started: $(Get-Date -Format 'u')`r`n# Session: $($Script:SessionId)`r`n# User:    $env:USERNAME`r`n"
        Set-Content -LiteralPath $Script:LogFilePath -Value $header -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Non-fatal - Write-LogEntry will simply no-op if the file is unusable.
    }
}

function Get-KFLogPath {
    <#
    .SYNOPSIS
        Returns the path to the active session log file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ([string]::IsNullOrEmpty($Script:LogFilePath)) { Initialize-KFLogFile }
    return $Script:LogFilePath
}

function Write-LogEntry {
    <#
    .SYNOPSIS
        Writes a single structured entry to the session log file.
    .PARAMETER Level
        Info, Warning, Error, Debug, or Verbose.
    .PARAMETER Message
        Human-readable message. No secrets/PII beyond username are logged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Verbose')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Level -eq 'Debug' -and -not $Script:UIState.Settings.DebugLog) { return }
    if ($Level -eq 'Verbose' -and -not $Script:UIState.Settings.VerboseLog) { return }

    try {
        $path = Get-KFLogPath
        $line = '[{0}] [{1,-7}] {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Level.ToUpper(), $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Logging must never throw into the caller.
    }
}

function Write-ExceptionLog {
    <#
    .SYNOPSIS
        Logs a caught exception with category and stack context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [string]$Context = 'General'
    )
    $category = if ($ErrorRecord.Exception -is [KeyForgeException]) { $ErrorRecord.Exception.Category } else { 'Unhandled' }
    $msg = "[$Context] [$category] $($ErrorRecord.Exception.Message)"
    Write-LogEntry -Level 'Error' -Message $msg
    Write-LogEntry -Level 'Debug' -Message "[$Context] ScriptStackTrace: $($ErrorRecord.ScriptStackTrace)"
}

function Export-KFSessionLog {
    <#
    .SYNOPSIS
        Copies the current session log to the Exports folder as a shareable
        support bundle and returns the destination path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $src  = Get-KFLogPath
        $dest = Join-Path $Script:Paths.Exports (Split-Path -Leaf $src)
        Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
        return $dest
    } catch {
        Write-ExceptionLog -ErrorRecord $_ -Context 'Export-KFSessionLog'
        return $null
    }
}

function Invoke-KFSafe {
    <#
    .SYNOPSIS
        Runs a scriptblock under a standard try/catch/log envelope so callers
        never need to repeat error-handling boilerplate. Returns a result
        object rather than throwing, per KeyForge's "never crash" contract.
    .OUTPUTS
        [pscustomobject] @{ Success; Result; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [string]$Context = 'Operation',

        [switch]$Silent
    )
    try {
        $result = & $Action
        return [pscustomobject]@{ Success = $true; Result = $result; Error = $null }
    } catch {
        Write-ExceptionLog -ErrorRecord $_ -Context $Context
        if (-not $Silent) { Write-LogEntry -Level 'Warning' -Message "$Context failed: $($_.Exception.Message)" }
        return [pscustomobject]@{ Success = $false; Result = $null; Error = $_.Exception.Message }
    }
}

#endregion ==================================================================

#region ============================== VALIDATION UTILITIES ==================

function Test-KFAdminPrivileges {
    <#
    .SYNOPSIS
        Returns $true if the current process is running elevated.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-LogEntry -Level 'Warning' -Message "Test-KFAdminPrivileges failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-KFWindowsCompatibility {
    <#
    .SYNOPSIS
        Checks the running OS against KeyForge's supported version matrix.
    .OUTPUTS
        [pscustomobject] @{ Supported; Reason; Major; Build }
    #>
    [CmdletBinding()]
    param()
    try {
        $os    = [System.Environment]::OSVersion.Version
        $major = if ($os.Build -ge 22000) { 11 } elseif ($os.Major -eq 10) { 10 } else { $os.Major }

        if ($os.Major -lt 10) {
            return [pscustomobject]@{ Supported = $false; Reason = "Windows $($os.Major) is not supported (Windows 10 1909+ required)."; Major = $major; Build = $os.Build }
        }
        if ($major -eq 10 -and $os.Build -lt 18363) {
            return [pscustomobject]@{ Supported = $false; Reason = "Build $($os.Build) predates Windows 10 1909 (18363), the minimum supported build."; Major = $major; Build = $os.Build }
        }
        return [pscustomobject]@{ Supported = $true; Reason = 'OK'; Major = $major; Build = $os.Build }
    } catch {
        Write-ExceptionLog -ErrorRecord $_ -Context 'Test-KFWindowsCompatibility'
        return [pscustomobject]@{ Supported = $false; Reason = 'Unable to determine OS version.'; Major = 0; Build = 0 }
    }
}

function Test-KFPathExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try { return (Test-Path -LiteralPath $Path -ErrorAction Stop) } catch { return $false }
}

function Test-KFRegistryKeyExists {
    <#
    .SYNOPSIS
        Hive-agnostic, non-throwing registry key existence check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try { return (Test-Path -LiteralPath $Path -ErrorAction Stop) } catch { return $false }
}

function Test-KFLanguageTagFormat {
    <#
    .SYNOPSIS
        Validates a BCP-47 / RFC 5646-style language tag (e.g. en-US, fr-FR,
        zh-Hans-CN). Returns the normalized tag (lowercase language subtag,
        Title-case script subtag, uppercase region subtag) or $null if the
        tag doesn't match the expected shape.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )
    if ($Tag -notmatch '^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8}){0,3}$') { return $null }

    $subtags = $Tag -split '-'
    $normalized = for ($i = 0; $i -lt $subtags.Count; $i++) {
        $part = $subtags[$i]
        if ($i -eq 0) {
            $part.ToLowerInvariant()
        } elseif ($part.Length -eq 4 -and $part -match '^[a-zA-Z]+$') {
            # 4-letter subtag right after the language: script (e.g. Hans, Hant)
            (Get-Culture).TextInfo.ToTitleCase($part.ToLowerInvariant())
        } elseif ($part.Length -eq 2 -and $part -match '^[a-zA-Z]+$') {
            # 2-letter subtag: region (e.g. US, FR)
            $part.ToUpperInvariant()
        } else {
            $part
        }
    }
    return ($normalized -join '-')
}

function Test-KFKlidFormat {
    <#
    .SYNOPSIS
        Validates a Keyboard Layout ID: an 8-character hex string.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Klid
    )
    return [bool]($Klid -match '^[0-9A-Fa-f]{8}$')
}

#endregion ==================================================================

#region ============================== FORMAT / CONVERT UTILITIES ============

function Format-KFByteSize {
    <#
    .SYNOPSIS
        Converts a byte count into a human-readable KB/MB/GB string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )
    if ($Bytes -lt 0) { return '0 B' }
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $size  = [double]$Bytes
    $unit  = 0
    while ($size -ge 1024 -and $unit -lt ($units.Count - 1)) {
        $size /= 1024
        $unit++
    }
    if ($unit -eq 0) { return "$Bytes B" }
    return '{0:N2} {1}' -f $size, $units[$unit]
}

function Format-KFDuration {
    <#
    .SYNOPSIS
        Converts a TimeSpan or millisecond count into a readable duration.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Span')]
        [TimeSpan]$TimeSpan,

        [Parameter(Mandatory, ParameterSetName = 'Millis')]
        [long]$Milliseconds
    )
    $ts = if ($PSCmdlet.ParameterSetName -eq 'Millis') { [TimeSpan]::FromMilliseconds($Milliseconds) } else { $TimeSpan }
    if ($ts.TotalMilliseconds -lt 1000) { return "$([int]$ts.TotalMilliseconds) ms" }
    if ($ts.TotalSeconds -lt 60)        { return '{0:N1} s' -f $ts.TotalSeconds }
    if ($ts.TotalMinutes -lt 60)        { return '{0:mm\:ss}' -f $ts }
    return '{0:hh\:mm\:ss}' -f $ts
}

function Format-KFLanguageName {
    <#
    .SYNOPSIS
        Resolves a BCP-47 tag to its localized display name via CultureInfo,
        with a graceful fallback for tags .NET does not recognize.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($Tag)
        return $culture.DisplayName
    } catch {
        return "$Tag (unrecognized tag)"
    }
}

function ConvertTo-KFHexString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )
    return ('{0:X8}' -f $Value)
}

function ConvertFrom-KFHexString {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$HexString
    )
    try {
        return [Convert]::ToInt32($HexString, 16)
    } catch {
        throw [ValidationException]::new("'$HexString' is not a valid hexadecimal value.")
    }
}

function Convert-KFLcidToTag {
    <#
    .SYNOPSIS
        Resolves a decimal or hex LCID to its BCP-47 language tag. Results
        are cached for the session since the mapping is static.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Lcid
    )
    $cacheKey = "lcid:$Lcid"
    if ($Script:Cache.ContainsKey($cacheKey)) { return $Script:Cache[$cacheKey] }

    try {
        $num = if ($Lcid -match '^0x') { [Convert]::ToInt32($Lcid, 16) } else { [int]$Lcid }
        $tag = ([System.Globalization.CultureInfo]::GetCultureInfo($num)).Name
        $Script:Cache[$cacheKey] = $tag
        return $tag
    } catch {
        return $null
    }
}

#endregion ==================================================================

#region ============================== GENERAL UTILITIES ======================

function Test-KFCommandExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-KFProcessorCount {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try {
        $count = [Environment]::ProcessorCount
        if ($count -lt 1) { return 2 }
        return $count
    } catch {
        return 2
    }
}

function Test-KFOnline {
    <#
    .SYNOPSIS
        Non-blocking, short-timeout connectivity check used to decide
        whether online-only DISM/Windows Update queries should be attempted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$TimeoutMs = 800
    )
    $ping = $null
    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $reply = $ping.Send('8.8.8.8', $TimeoutMs)
        return ($reply.Status -eq 'Success')
    } catch {
        return $false
    } finally {
        if ($null -ne $ping) { $ping.Dispose() }
    }
}

function Get-KFCached {
    <#
    .SYNOPSIS
        Generic TTL cache wrapper: runs $Action and caches the result under
        $Key for $TtlSeconds, returning the cached value on subsequent calls
        within the TTL window. Pass -Force to bypass the cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [int]$TtlSeconds = 300,

        [switch]$Force
    )
    $now = Get-Date
    if (-not $Force -and $Script:Cache.ContainsKey($Key)) {
        $entry = $Script:Cache[$Key]
        if (($now - $entry.Timestamp).TotalSeconds -lt $TtlSeconds) {
            return $entry.Data
        }
    }
    $data = & $Action
    $Script:Cache[$Key] = @{ Data = $data; Timestamp = $now }
    return $data
}

function Clear-KFCache {
    [CmdletBinding()]
    param(
        [string]$Prefix
    )
    if ([string]::IsNullOrEmpty($Prefix)) {
        $Script:Cache.Clear()
        return
    }
    $keys = $Script:Cache.Keys | Where-Object { $_ -like "$Prefix*" }
    foreach ($k in $keys) { $Script:Cache.Remove($k) }
}

#endregion ==================================================================

#region ============================== SYSTEM QUERY MODULE ====================

function Get-KFOSVersion {
    <#
    .SYNOPSIS
        Resolves detailed Windows version/build/edition info, including
        Windows 11 detection (build >= 22000 even when ProductName still
        reads "Windows 10") and LTSC/Server detection.
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'os:version' -TtlSeconds 600 -Action {
        try {
            $cv = Get-ItemProperty -LiteralPath $Script:RegistryPaths.CurrentVersion -ErrorAction Stop
            $osVer = [System.Environment]::OSVersion.Version
            $buildNum = if ($cv.CurrentBuildNumber) { [int]$cv.CurrentBuildNumber } else { $osVer.Build }
            $ubr = if ($cv.PSObject.Properties.Name -contains 'UBR') { $cv.UBR } else { 0 }

            $majorName = if ($buildNum -ge 22000) { 'Windows 11' } elseif ($buildNum -ge 10240) { 'Windows 10' } else { 'Windows (legacy)' }
            $productName = if ($cv.PSObject.Properties.Name -contains 'ProductName') { $cv.ProductName } else { $majorName }
            $displayVersion = if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $cv.DisplayVersion }
                              elseif ($cv.PSObject.Properties.Name -contains 'ReleaseId') { $cv.ReleaseId }
                              else { 'Unknown' }
            $editionId = if ($cv.PSObject.Properties.Name -contains 'EditionID') { $cv.EditionID } else { 'Unknown' }
            $isLtsc = [bool]($editionId -match 'LTSC|LTSB')
            $isServer = [bool]($productName -match 'Server')

            [pscustomobject]@{
                ProductName    = $productName
                FriendlyName   = $majorName
                DisplayVersion = $displayVersion
                Build          = $buildNum
                UBR            = $ubr
                FullBuild      = "$buildNum.$ubr"
                EditionId      = $editionId
                IsLTSC         = $isLtsc
                IsServer       = $isServer
            }
        } catch {
            Write-ExceptionLog -ErrorRecord $_ -Context 'Get-KFOSVersion'
            [pscustomobject]@{
                ProductName = 'Unknown'; FriendlyName = 'Unknown'; DisplayVersion = 'Unknown'
                Build = 0; UBR = 0; FullBuild = '0.0'; EditionId = 'Unknown'; IsLTSC = $false; IsServer = $false
            }
        }
    }
}

function Get-KFWindowsEditionInfo {
    <#
    .SYNOPSIS
        Returns Home/Pro/Enterprise/Education style edition info via the
        registry. Deliberately named to avoid colliding with the real
        Get-WindowsEdition cmdlet shipped in the Dism PowerShell module,
        which targets offline images rather than the running OS.
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'os:edition' -TtlSeconds 600 -Action {
        try {
            $cv = Get-ItemProperty -LiteralPath $Script:RegistryPaths.CurrentVersion -ErrorAction Stop
            $edition = if ($cv.PSObject.Properties.Name -contains 'EditionID') { $cv.EditionID } else { 'Unknown' }
            $friendly = switch -Wildcard ($edition) {
                'Core*'          { 'Home' }
                'Professional*'  { 'Pro' }
                'Enterprise*'    { 'Enterprise' }
                'Education*'     { 'Education' }
                'ServerStandard*'{ 'Server Standard' }
                'ServerDatacenter*' { 'Server Datacenter' }
                'IoT*'           { 'IoT' }
                default          { $edition }
            }
            [pscustomobject]@{ EditionId = $edition; FriendlyName = $friendly }
        } catch {
            [pscustomobject]@{ EditionId = 'Unknown'; FriendlyName = 'Unknown' }
        }
    }
}

function Get-KFSystemArchitecture {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $arch = $env:PROCESSOR_ARCHITECTURE
        if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
        switch ($arch) {
            'AMD64' { return 'x64' }
            'ARM64' { return 'ARM64' }
            'x86'   { return 'x86' }
            default { return $arch }
        }
    } catch {
        return 'Unknown'
    }
}

#endregion ==================================================================

#region ============================== SYSTEM QUERY: LANGUAGE / KEYBOARD ======

function Get-KFUserLanguages {
    <#
    .SYNOPSIS
        Fast, current-user language list via the built-in International
        module. Used for dashboard-speed reads (no DISM round-trip).
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'lang:user' -TtlSeconds 300 -Action {
        try {
            Get-WinUserLanguageList -ErrorAction Stop
        } catch {
            Write-ExceptionLog -ErrorRecord $_ -Context 'Get-KFUserLanguages'
            @()
        }
    }
}

function Get-KFAllInstalledLanguages {
    <#
    .SYNOPSIS
        Thorough, system-wide language inventory: merges the DISM capability
        store (Language.Basic / Language.OCR / Language.Handwriting /
        Language.Speech / Language.TextToSpeech, all "Installed" states)
        with the current user's language list, so status per feature is
        visible even for languages not assigned to the active user.
        This is a multi-second operation by design (DISM is slow) - callers
        should show a spinner. Cached for 5 minutes.
    .PARAMETER Force
        Bypasses the cache and re-queries DISM.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    Get-KFCached -Key 'lang:all' -TtlSeconds 300 -Force:$Force -Action {
        $result = [System.Collections.Generic.List[pscustomobject]]::new()
        $userLangs = @(Get-KFUserLanguages)
        $userTags  = @($userLangs | ForEach-Object { $_.LanguageTag })

        $capabilities = Invoke-KFSafe -Context 'DISM capability query' -Silent -Action {
            Get-WindowsCapability -Online -Name 'Language.*' -ErrorAction Stop
        }

        if ($capabilities.Success -and $capabilities.Result) {
            $installed = @($capabilities.Result | Where-Object { $_.State -eq 'Installed' })

            # Grouping strategy: DISM capability names look like
            # "Language.Basic~~~en-US~0.0.1.0". Splitting on '~' yields
            # ["Language.Basic", "", "", "en-US", "0.0.1.0"] - three
            # tildes precede the tag, so it lands at index 3, not 2.
            $byTag = @{}
            foreach ($cap in $installed) {
                $parts = $cap.Name -split '~'
                $tag = if ($parts.Count -ge 4 -and $parts[3]) { $parts[3] } else { 'unknown' }
                $feature = ($parts[0] -replace '^Language\.', '')
                if (-not $byTag.ContainsKey($tag)) { $byTag[$tag] = [System.Collections.Generic.List[string]]::new() }
                $byTag[$tag].Add($feature)
            }

            $allTags = @($byTag.Keys) + $userTags | Select-Object -Unique
            foreach ($tag in $allTags) {
                if ($tag -eq 'unknown' -or [string]::IsNullOrWhiteSpace($tag)) { continue }
                $features = if ($byTag.ContainsKey($tag)) { $byTag[$tag] } else { @() }
                $result.Add([pscustomobject]@{
                    LanguageTag  = $tag
                    DisplayName  = Format-KFLanguageName -Tag $tag
                    InUserList   = [bool]($userTags -contains $tag)
                    Basic        = [bool]($features -contains 'Basic')
                    Speech       = [bool]($features -contains 'Speech')
                    OCR          = [bool]($features -contains 'OCR')
                    Handwriting  = [bool]($features -contains 'Handwriting')
                    TextToSpeech = [bool]($features -contains 'TextToSpeech')
                    FeatureCount = $features.Count
                })
            }
        } else {
            # DISM unavailable (offline / non-admin / restricted host) - fall
            # back to the fast user-language list so the screen still works.
            foreach ($ul in $userLangs) {
                $result.Add([pscustomobject]@{
                    LanguageTag  = $ul.LanguageTag
                    DisplayName  = Format-KFLanguageName -Tag $ul.LanguageTag
                    InUserList   = $true
                    Basic        = $true
                    Speech       = $null
                    OCR          = $null
                    Handwriting  = $null
                    TextToSpeech = $null
                    FeatureCount = -1
                })
            }
        }
        return ($result | Sort-Object DisplayName)
    }
}

function Get-KFInstalledKeyboards {
    <#
    .SYNOPSIS
        Enumerates keyboard layouts registered on the system (from the
        machine-wide layout registry hive) and cross-references which ones
        are currently loaded for the active user (Preload).
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    Get-KFCached -Key 'kbd:all' -TtlSeconds 300 -Force:$Force -Action {
        $result = [System.Collections.Generic.List[pscustomobject]]::new()

        $preload = @{}
        try {
            $preloadItems = Get-Item -LiteralPath $Script:RegistryPaths.Preload -ErrorAction Stop
            foreach ($valueName in $preloadItems.Property) {
                $preload[$preloadItems.GetValue($valueName)] = $valueName
            }
        } catch {
            Write-LogEntry -Level 'Debug' -Message "Preload enumeration skipped: $($_.Exception.Message)"
        }

        try {
            $layouts = Get-ChildItem -LiteralPath $Script:RegistryPaths.KeyboardLayouts -ErrorAction Stop
            foreach ($layout in $layouts) {
                try {
                    $klid = Split-Path -Leaf $layout.PSPath
                    $props = Get-ItemProperty -LiteralPath $layout.PSPath -ErrorAction Stop
                    $name = if ($props.PSObject.Properties.Name -contains 'Layout Text') { $props.'Layout Text' } else { '(unnamed layout)' }
                    $langTag = $null
                    try {
                        $lcidHex = $klid.Substring(4, 4)
                        $lcidNum = [Convert]::ToInt32($lcidHex, 16)
                        $langTag = Convert-KFLcidToTag -Lcid $lcidNum
                    } catch { $langTag = $null }

                    $result.Add([pscustomobject]@{
                        KLID         = $klid
                        Name         = $name
                        LanguageTag  = $langTag
                        Loaded       = [bool]$preload.ContainsKey($klid)
                        PreloadOrder = if ($preload.ContainsKey($klid)) { [int]$preload[$klid] } else { $null }
                    })
                } catch {
                    Write-LogEntry -Level 'Debug' -Message "Skipped unreadable layout key $($layout.PSPath): $($_.Exception.Message)"
                    continue
                }
            }
        } catch {
            Write-ExceptionLog -ErrorRecord $_ -Context 'Get-KFInstalledKeyboards'
        }

        return ($result | Sort-Object @{Expression = 'Loaded'; Descending = $true}, Name)
    }
}

function Get-KFCurrentKeyboardName {
    <#
    .SYNOPSIS
        Best-effort display name of the keyboard layout active in the
        current session (first Preload entry for the interactive user).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Force
    )
    try {
        $kbds = Get-KFInstalledKeyboards -Force:$Force
        $current = $kbds | Where-Object { $_.PreloadOrder -eq 1 } | Select-Object -First 1
        if ($current) { return $current.Name }
        return 'Unknown'
    } catch {
        return 'Unknown'
    }
}

function Get-KFRegionInfo {
    <#
    .SYNOPSIS
        Current home-location / region settings for the active user.
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'region:info' -TtlSeconds 300 -Action {
        try {
            $homeLocation = Get-WinHomeLocation -ErrorAction Stop
            [pscustomobject]@{
                GeoId       = $homeLocation.GeoId
                Name        = $homeLocation.HomeLocation
            }
        } catch {
            Write-ExceptionLog -ErrorRecord $_ -Context 'Get-KFRegionInfo'
            [pscustomobject]@{ GeoId = -1; Name = 'Unknown' }
        }
    }
}

function Get-KFLocaleInfo {
    <#
    .SYNOPSIS
        System locale, user locale (current culture) and UI/display language.
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'locale:info' -TtlSeconds 300 -Action {
        $sysLocale = Invoke-KFSafe -Context 'Get-WinSystemLocale' -Silent -Action { Get-WinSystemLocale -ErrorAction Stop }
        $culture   = Invoke-KFSafe -Context 'Get-Culture' -Silent -Action { Get-Culture }
        $uiCulture = Invoke-KFSafe -Context 'Get-UICulture' -Silent -Action { Get-UICulture }

        [pscustomobject]@{
            SystemLocale = if ($sysLocale.Success) { $sysLocale.Result.Name } else { 'Unknown' }
            UserLocale   = if ($culture.Success) { $culture.Result.Name } else { 'Unknown' }
            DisplayLang  = if ($uiCulture.Success) { $uiCulture.Result.Name } else { 'Unknown' }
            DisplayName  = if ($uiCulture.Success) { $uiCulture.Result.DisplayName } else { 'Unknown' }
        }
    }
}

function Get-KFTimeZoneInfo {
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'tz:info' -TtlSeconds 300 -Action {
        $tz = Invoke-KFSafe -Context 'Get-TimeZone' -Silent -Action { Get-TimeZone -ErrorAction Stop }
        if ($tz.Success) {
            [pscustomobject]@{
                Id          = $tz.Result.Id
                DisplayName = $tz.Result.DisplayName
                UtcOffset   = $tz.Result.BaseUtcOffset.ToString()
            }
        } else {
            [pscustomobject]@{ Id = 'Unknown'; DisplayName = 'Unknown'; UtcOffset = '+00:00' }
        }
    }
}

#endregion ==================================================================

#region ============================== CONFIRMATION UTILITIES =================

function Request-KFUserConfirmation {
    <#
    .SYNOPSIS
        Simple Y/N prompt. Returns $true only on an explicit 'y'/'yes'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [bool]$DefaultYes = $false
    )
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    Write-KFColor -Text "  $Message $suffix " -Color $Script:Colors.Body -NoNewline
    $response = Read-Host
    if ([string]::IsNullOrWhiteSpace($response)) { return $DefaultYes }
    return [bool]($response.Trim().ToLower() -in @('y', 'yes'))
}

function Request-KFExplicitConfirmation {
    <#
    .SYNOPSIS
        High-friction confirmation for destructive actions: the user must
        type an exact phrase (not just 'y') to proceed. Reserved for use by
        the Phase 3/4 removal modules; included now so those modules have a
        ready-made, already-tested confirmation primitive to build on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Phrase,

        [string]$Prompt = "Type '$Phrase' to confirm, or press Enter to cancel:"
    )
    Write-KFColor -Text "  $Prompt " -Color $Script:Colors.Danger -NoNewline
    $response = Read-Host
    $confirmed = [bool]($response -ceq $Phrase)
    Write-LogEntry -Level 'Info' -Message "Explicit confirmation requested (phrase='$Phrase'); confirmed=$confirmed"
    return $confirmed
}

function Wait-KFWithSpinner {
    <#
    .SYNOPSIS
        Shows a spinner + label while $Action runs, then reports elapsed time.
    .DESCRIPTION
        Deliberately synchronous: $Action executes in the CURRENT runspace,
        not via Start-Job. A background job runs in an isolated process with
        none of KeyForge's functions or $Script:-scoped state loaded, so any
        action referencing them would fail silently the moment it needed
        something beyond a bare built-in cmdlet. Running in-process trades a
        (harmless) frozen spinner frame during the blocking call for
        guaranteed correctness and zero external dependencies - the right
        trade-off for a single-file tool. True animation would require a
        second runspace and explicit state hand-off, which is unnecessary
        complexity for this phase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [string]$Label = 'Working'
    )
    $frame = if ($Script:UIState.UnicodeSupported) { $Script:SpinnerFrames[0] } else { $Script:SpinnerFramesAscii[0] }
    Write-Host "`r  $frame $Label..." -NoNewline -ForegroundColor $Script:Colors.Info

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = Invoke-KFSafe -Context "Wait-KFWithSpinner:$Label" -Action $Action
    $sw.Stop()

    $clearWidth = [Math]::Max(40, $Label.Length + 20)
    Write-Host ("`r" + (' ' * $clearWidth) + "`r") -NoNewline

    if (-not $outcome.Success) {
        Write-KFStatus -Type 'Failure' -Message "$Label failed after $(Format-KFDuration -TimeSpan $sw.Elapsed): $($outcome.Error)"
        return $null
    }
    Write-LogEntry -Level 'Debug' -Message "$Label completed in $(Format-KFDuration -TimeSpan $sw.Elapsed)"
    return $outcome.Result
}

#endregion ==================================================================

#region ============================== TERMINAL / RENDERING CORE ==============

function Test-KFUnicodeSupport {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        if ($env:WT_SESSION) { return $true }
        if ($env:TERM_PROGRAM -eq 'vscode') { return $true }
        if ([Console]::OutputEncoding.CodePage -eq 65001) { return $true }
        return $false
    } catch {
        return $false
    }
}

function Initialize-KFConsole {
    <#
    .SYNOPSIS
        Best-effort console setup: title, encoding, minimum width. Every
        step is individually guarded - a failure here (common under ISE,
        redirected output, or non-standard hosts) must never stop KeyForge.
    #>
    [CmdletBinding()]
    param()

    $Script:UIState.UnicodeSupported = Test-KFUnicodeSupport
    $Script:UIState.ColorSupported   = -not $NoColor

    try { $Host.UI.RawUI.WindowTitle = "KeyForge v$($Script:Meta.Version) - $($Script:Meta.Tagline)" } catch {}

    try {
        if ($Script:UIState.UnicodeSupported) { [Console]::OutputEncoding = [Text.Encoding]::UTF8 }
    } catch {}

    try {
        $rawUI = $Host.UI.RawUI
        $minWidth = 100
        if ($rawUI.BufferSize.Width -lt $minWidth) {
            $newBuffer = $rawUI.BufferSize
            $newBuffer.Width = $minWidth
            $rawUI.BufferSize = $newBuffer
        }
        if ($rawUI.WindowSize.Width -lt $minWidth -and $rawUI.MaxWindowSize.Width -ge $minWidth) {
            $newWindow = $rawUI.WindowSize
            $newWindow.Width = $minWidth
            $rawUI.WindowSize = $newWindow
        }
        $Script:UIState.ConsoleWidth = $rawUI.WindowSize.Width
    } catch {
        Write-LogEntry -Level 'Debug' -Message "Console resize skipped (non-interactive or restricted host): $($_.Exception.Message)"
        $Script:UIState.ConsoleWidth = 100
    }
}

function Get-KFChar {
    <#
    .SYNOPSIS
        Returns a box-drawing character, or its ASCII fallback, based on the
        detected Unicode support of the current host.
    .NOTES
        Explicitly cast to [string] (not just declared via [OutputType]) -
        the underlying table stores [char] values, and PowerShell's `+`
        operator converts its RIGHT operand to the type of the LEFT operand.
        A bare [char] concatenated with a multi-character string via `+`
        throws ("string must be exactly one character long"), which would
        have broken every Write-KFBox call in the UI. Returning a real
        string here removes that trap for every caller at once.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($Script:UIState.UnicodeSupported) { return [string]$Script:BoxChars[$Name] }
    return [string]$Script:BoxCharsAscii[$Name]
}

function Get-KFIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($Script:UIState.UnicodeSupported) { return [string]$Script:Icons[$Name] }
    return [string]$Script:IconsAscii[$Name]
}

function Write-KFColor {
    <#
    .SYNOPSIS
        Color-aware Write-Host wrapper; respects -NoColor / non-color hosts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [string]$Color = 'White',

        [switch]$NoNewline
    )
    if ($Script:UIState.ColorSupported) {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    } else {
        Write-Host $Text -NoNewline:$NoNewline
    }
}

function Write-KFLine {
    <#
    .SYNOPSIS
        Draws a full-width horizontal rule using the current box-char set.
    #>
    [CmdletBinding()]
    param(
        [int]$Width = $Script:UIState.ConsoleWidth,
        [string]$Color = $Script:Colors.Border
    )
    $h = Get-KFChar -Name 'Horizontal'
    Write-KFColor -Text ($h.ToString() * [Math]::Max(10, $Width - 1)) -Color $Color
}

function Write-KFBox {
    <#
    .SYNOPSIS
        Draws a rounded box around one or more lines of pre-formatted text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines,

        [string]$Title = '',

        [string]$BorderColor = $Script:Colors.Border,

        [string]$TextColor = $Script:Colors.Body,

        [int]$Width = ($Script:UIState.ConsoleWidth - 2)
    )
    $tl = Get-KFChar 'TopLeft'; $tr = Get-KFChar 'TopRight'
    $bl = Get-KFChar 'BottomLeft'; $br = Get-KFChar 'BottomRight'
    $h  = Get-KFChar 'Horizontal'; $v = Get-KFChar 'Vertical'
    $innerWidth = [Math]::Max(20, $Width - 2)

    if ($Title) {
        $titleText = " $Title "
        $barLen = [Math]::Max(0, $innerWidth - $titleText.Length)
        Write-KFColor -Text ($tl + ($h.ToString() * 2)) -Color $BorderColor -NoNewline
        Write-KFColor -Text $titleText -Color $Script:Colors.Highlight -NoNewline
        Write-KFColor -Text (($h.ToString() * $barLen) + $tr) -Color $BorderColor
    } else {
        Write-KFColor -Text ($tl + ($h.ToString() * $innerWidth) + $tr) -Color $BorderColor
    }

    foreach ($line in $Lines) {
        $pad = $innerWidth - $line.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-KFColor -Text "$v " -Color $BorderColor -NoNewline
        Write-KFColor -Text $line -Color $TextColor -NoNewline
        Write-KFColor -Text ((' ' * $pad) + " $v") -Color $BorderColor
    }

    Write-KFColor -Text ($bl + ($h.ToString() * $innerWidth) + $br) -Color $BorderColor
}

function Write-KFStatus {
    <#
    .SYNOPSIS
        One-line icon + colored message, optionally timestamped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failure', 'Warning', 'Info')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Message,

        [switch]$Timestamp
    )
    $iconMap  = @{ Success = 'Success'; Failure = 'Failure'; Warning = 'Warning'; Info = 'Info' }
    $colorMap = @{ Success = $Script:Colors.Success; Failure = $Script:Colors.Danger; Warning = $Script:Colors.Warning; Info = $Script:Colors.Info }
    $icon = Get-KFIcon -Name $iconMap[$Type]
    $ts = if ($Timestamp) { "[$(Get-Date -Format 'HH:mm:ss')] " } else { '' }
    Write-KFColor -Text "  $ts$icon " -Color $colorMap[$Type] -NoNewline
    Write-KFColor -Text $Message -Color $Script:Colors.Body
}

function Wait-KFKeyPress {
    <#
    .SYNOPSIS
        Shared "press any key to continue" prompt used at the end of every
        screen. Centralized so the raw-console-vs-fallback handling only
        needs to be correct in one place instead of duplicated per screen.
    #>
    [CmdletBinding()]
    param(
        [string]$Message = '  Press any key to return to the menu...'
    )
    Write-KFColor -Text $Message -Color $Script:Colors.Muted
    if ($Host.Name -eq 'ConsoleHost') {
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
    } else {
        Read-Host | Out-Null
    }
}

function Write-KFAlert {
    <#
    .SYNOPSIS
        Boxed warning/danger callout for important, non-blocking notices.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Warning', 'Danger', 'Info')]
        [string]$Level = 'Warning'
    )
    $color = switch ($Level) {
        'Danger'  { $Script:Colors.Danger }
        'Warning' { $Script:Colors.Warning }
        default   { $Script:Colors.Info }
    }
    $icon = Get-KFIcon -Name (if ($Level -eq 'Info') { 'Info' } else { 'Warning' })
    $wrapped = @($Message -split "(.{1,72}(?:\s|$))" | Where-Object { $_ -ne '' } | ForEach-Object { $_.TrimEnd() })
    if ($wrapped.Count -eq 0) { $wrapped = @($Message) }
    Write-KFBox -Lines $wrapped -Title "$icon $Level" -BorderColor $color -TextColor $Script:Colors.Body
}

function Write-KFProgressBar {
    <#
    .SYNOPSIS
        Renders a single-line percentage progress bar in place (no newline).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int]$PercentComplete,

        [string]$Label = '',

        [int]$Width = 30
    )
    $filled = [Math]::Round(($PercentComplete / 100) * $Width)
    $empty  = $Width - $filled
    $fillChar  = if ($Script:UIState.UnicodeSupported) { [char]0x2588 } else { '#' }
    $emptyChar = if ($Script:UIState.UnicodeSupported) { [char]0x2591 } else { '-' }
    $bar = ($fillChar.ToString() * $filled) + ($emptyChar.ToString() * $empty)
    Write-Host "`r  $Label [" -NoNewline
    Write-KFColor -Text $bar -Color $Script:Colors.Accent -NoNewline
    Write-Host ("] {0,3}%" -f $PercentComplete) -NoNewline
    if ($PercentComplete -ge 100) { Write-Host '' }
}

#endregion ==================================================================

#region ============================== DATA DISPLAY COMPONENTS ================

function Write-KFTable {
    <#
    .SYNOPSIS
        Renders a colored, column-aligned table for an array of objects.
    .PARAMETER Data
        The rows to render (array of objects / pscustomobjects).
    .PARAMETER Columns
        Ordered list of column definitions: @{ Name; Header; Width; Align }
        Align is 'Left' or 'Right'. Width is in characters; content is
        truncated with an ellipsis if it overflows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Data,

        [Parameter(Mandatory)]
        [hashtable[]]$Columns,

        [string]$Title = ''
    )
    $v = Get-KFChar 'Vertical'

    if ($Title) {
        Write-KFColor -Text "  $Title" -Color $Script:Colors.Highlight
    }

    # Header
    Write-Host '  ' -NoNewline
    foreach ($col in $Columns) {
        $header = $col.Header
        $width  = [int]$col.Width
        $text   = if ($header.Length -gt $width) { $header.Substring(0, [Math]::Max(0, $width - 1)) + '.' } else { $header }
        $padded = if ($col.Align -eq 'Right') { $text.PadLeft($width) } else { $text.PadRight($width) }
        Write-KFColor -Text "$padded " -Color $Script:Colors.Highlight -NoNewline
    }
    Write-Host ''
    Write-KFLine -Width ((($Columns | ForEach-Object { [int]$_.Width + 1 } | Measure-Object -Sum).Sum) + 2)

    if ($Data.Count -eq 0) {
        Write-KFColor -Text '  (no items)' -Color $Script:Colors.Muted
        return
    }

    $rowIndex = 0
    foreach ($row in $Data) {
        $rowColor = if ($rowIndex % 2 -eq 0) { $Script:Colors.Body } else { $Script:Colors.Muted }
        Write-Host '  ' -NoNewline
        foreach ($col in $Columns) {
            $raw = $row.($col.Name)
            $text = if ($null -eq $raw) { '-' } else { [string]$raw }
            $width = [int]$col.Width
            if ($text.Length -gt $width) { $text = $text.Substring(0, [Math]::Max(0, $width - 1)) + [char]0x2026 }
            $padded = if ($col.Align -eq 'Right') { $text.PadLeft($width) } else { $text.PadRight($width) }
            Write-KFColor -Text "$padded " -Color $rowColor -NoNewline
        }
        Write-Host ''
        $rowIndex++
    }
    Write-KFColor -Text "  ($($Data.Count) item$(if ($Data.Count -ne 1) { 's' }))" -Color $Script:Colors.Muted
}

function Write-KFTreeView {
    <#
    .SYNOPSIS
        Renders a hierarchical tree from nested nodes.
    .PARAMETER Nodes
        Array of @{ Label; Children = @(...) } hashtables.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Nodes,

        [int]$Depth = 0
    )
    $branch = if ($Script:UIState.UnicodeSupported) { "$([char]0x251C)$([char]0x2500) " } else { '+- ' }
    $last   = if ($Script:UIState.UnicodeSupported) { "$([char]0x2570)$([char]0x2500) " } else { '`- ' }
    $indent = '  ' * $Depth

    for ($i = 0; $i -lt $Nodes.Count; $i++) {
        $node = $Nodes[$i]
        $prefix = if ($i -eq ($Nodes.Count - 1)) { $last } else { $branch }
        Write-KFColor -Text "  $indent$prefix" -Color $Script:Colors.Border -NoNewline
        Write-KFColor -Text $node.Label -Color $Script:Colors.Body
        if ($node.ContainsKey('Children') -and $node.Children -and $node.Children.Count -gt 0) {
            Write-KFTreeView -Nodes $node.Children -Depth ($Depth + 1)
        }
    }
}

#endregion ==================================================================

#region ============================== INPUT DIALOGS ==========================

function Show-KFConfirmationDialog {
    <#
    .SYNOPSIS
        Boxed confirmation dialog listing affected items before a Y/N prompt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string[]]$AffectedItems = @(),

        [bool]$DefaultYes = $false
    )
    Write-Host ''
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Message)
    if ($AffectedItems.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Affected:')
        foreach ($item in $AffectedItems) { $lines.Add("  $(Get-KFIcon 'Bullet') $item") }
    }
    Write-KFBox -Lines $lines -Title "$(Get-KFIcon 'Warning') Confirm" -BorderColor $Script:Colors.Warning
    Write-Host ''
    return (Request-KFUserConfirmation -Message 'Proceed?' -DefaultYes $DefaultYes)
}

function Show-KFInfoDialog {
    <#
    .SYNOPSIS
        Boxed informational dialog; waits for any key before returning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TitleText,

        [Parameter(Mandatory)]
        [string[]]$Lines
    )
    Write-Host ''
    Write-KFBox -Lines $Lines -Title $TitleText -BorderColor $Script:Colors.Info
    Write-Host ''
    Wait-KFKeyPress -Message '  Press any key to continue...'
}

function Show-KFChoiceDialog {
    <#
    .SYNOPSIS
        Presents a numbered list of choices and returns the selected index
        (0-based), or -1 if the user cancels (blank input).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Question,

        [Parameter(Mandatory)]
        [string[]]$Options,

        [int]$DefaultIndex = 0
    )
    Write-Host ''
    Write-KFColor -Text "  $Question" -Color $Script:Colors.Highlight
    Write-Host ''
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i -eq $DefaultIndex) { Get-KFIcon 'Arrow' } else { ' ' }
        Write-KFColor -Text "   $marker $($i + 1). $($Options[$i])" -Color $Script:Colors.Body
    }
    Write-Host ''
    Write-KFColor -Text "  Choice [1-$($Options.Count), default $($DefaultIndex + 1)]: " -Color $Script:Colors.Body -NoNewline
    $response = Read-Host
    if ([string]::IsNullOrWhiteSpace($response)) { return $DefaultIndex }
    $num = 0
    if ([int]::TryParse($response.Trim(), [ref]$num) -and $num -ge 1 -and $num -le $Options.Count) {
        return ($num - 1)
    }
    return -1
}

function Request-KFTextInput {
    <#
    .SYNOPSIS
        Prompts for free text with optional validation and default value.
    .PARAMETER Validator
        Optional scriptblock receiving the raw input string; return $true to
        accept. On rejection, the prompt repeats with $ErrorText shown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$DefaultValue = '',

        [scriptblock]$Validator = $null,

        [string]$ErrorText = 'Invalid input, please try again.'
    )
    while ($true) {
        $suffix = if ($DefaultValue) { " [$DefaultValue]" } else { '' }
        Write-KFColor -Text "  ${Prompt}${suffix}: " -Color $Script:Colors.Body -NoNewline
        $userInput = Read-Host
        if ([string]::IsNullOrWhiteSpace($userInput)) { $userInput = $DefaultValue }
        if ($null -eq $Validator -or (& $Validator $userInput)) {
            return $userInput
        }
        Write-KFStatus -Type 'Failure' -Message $ErrorText
    }
}

#endregion ==================================================================

#region ============================== DASHBOARD ===============================

function Get-KFDashboardData {
    <#
    .SYNOPSIS
        Gathers everything the dashboard displays using only fast, local
        queries (registry + built-in International cmdlets). Deliberately
        avoids DISM here - a capability query can take seconds, which would
        blow the <2s startup / <500ms refresh targets. The full DISM-backed
        language inventory lives behind the dedicated "Installed Languages"
        screen instead, where a multi-second wait is expected.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    Get-KFCached -Key 'dashboard:data' -TtlSeconds 5 -Force:$Force -Action {
        $osInfo     = Get-KFOSVersion
        $edition    = Get-KFWindowsEditionInfo
        $arch       = Get-KFSystemArchitecture
        $isAdmin    = Test-KFAdminPrivileges
        $userLangs  = @(Get-KFUserLanguages)
        $keyboards  = @(Get-KFInstalledKeyboards)
        $region     = Get-KFRegionInfo
        $locale     = Get-KFLocaleInfo
        $tz         = Get-KFTimeZoneInfo
        $loadedKbds = @($keyboards | Where-Object { $_.Loaded })
        $inputTips  = @($userLangs | ForEach-Object { $_.InputMethodTips } | Where-Object { $_ })

        [pscustomobject]@{
            OS              = $osInfo
            Edition         = $edition
            Architecture    = $arch
            IsAdmin         = $isAdmin
            CurrentUser     = "$env:USERDOMAIN\$env:USERNAME"
            CurrentLanguage = if ($userLangs.Count -gt 0) { $userLangs[0].LanguageTag } else { 'Unknown' }
            CurrentKeyboard = Get-KFCurrentKeyboardName
            Region          = $region
            Locale          = $locale
            TimeZone        = $tz
            LanguageCount   = $userLangs.Count
            KeyboardCount   = $keyboards.Count
            LoadedKeyboards = $loadedKbds.Count
            InputMethods    = $inputTips.Count
            RefreshedAt     = Get-Date
        }
    }
}

function Write-KFBanner {
    [CmdletBinding()]
    param()
    $art = if ($Script:UIState.UnicodeSupported) { $Script:Banner } else { $Script:BannerAscii }
    Write-KFColor -Text $art -Color $Script:Colors.Accent
    Write-KFColor -Text "  $($Script:Meta.Name)  v$($Script:Meta.Version)  -  $($Script:Meta.Tagline)" -Color $Script:Colors.Muted
    Write-KFColor -Text "  Build: $($Script:Meta.BuildLabel)" -Color $Script:Colors.Dim
    Write-Host ''
}

function Write-KFSystemInfoGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Data
    )
    $adminBadge = if ($Data.IsAdmin) { "$(Get-KFIcon 'Success') Elevated" } else { "$(Get-KFIcon 'Warning') Standard (not elevated)" }
    $adminColor = if ($Data.IsAdmin) { $Script:Colors.Success } else { $Script:Colors.Warning }

    $lines = @(
        ('{0,-20} {1}' -f 'Windows:', "$($Data.OS.ProductName) ($($Data.Edition.FriendlyName))")
        ('{0,-20} {1}' -f 'Build:', "$($Data.OS.FullBuild)  [$($Data.OS.DisplayVersion)]")
        ('{0,-20} {1}' -f 'Architecture:', $Data.Architecture)
        ('{0,-20} {1}' -f 'User:', $Data.CurrentUser)
    )
    Write-KFBox -Lines $lines -Title 'System' -BorderColor $Script:Colors.Border

    Write-KFColor -Text "  Admin status: " -Color $Script:Colors.Muted -NoNewline
    Write-KFColor -Text $adminBadge -Color $adminColor
    Write-Host ''
}

function Write-KFCurrentSettingsGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Data
    )
    $lines = @(
        ('{0,-20} {1}' -f 'Display language:', $Data.Locale.DisplayName)
        ('{0,-20} {1}' -f 'System locale:', $Data.Locale.SystemLocale)
        ('{0,-20} {1}' -f 'User locale:', $Data.Locale.UserLocale)
        ('{0,-20} {1}' -f 'Keyboard:', $Data.CurrentKeyboard)
        ('{0,-20} {1}' -f 'Region:', "$($Data.Region.Name) (GeoID $($Data.Region.GeoId))")
        ('{0,-20} {1}' -f 'Time zone:', "$($Data.TimeZone.DisplayName)")
    )
    Write-KFBox -Lines $lines -Title 'Current Settings' -BorderColor $Script:Colors.Border
    Write-Host ''
}

function Write-KFQuickStats {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Data
    )
    $stats = @(
        "Languages: $($Data.LanguageCount)"
        "Keyboards: $($Data.KeyboardCount) ($($Data.LoadedKeyboards) loaded)"
        "Input methods: $($Data.InputMethods)"
    )
    $separator = '    ' + [char]0x2502 + '   '
    Write-KFColor -Text ('  ' + ($stats -join $separator)) -Color $Script:Colors.Info
    Write-Host ''
}

function Write-KFStatusLine {
    [CmdletBinding()]
    param()
    $refreshLabel = if ($Script:UIState.Settings.AutoRefreshEnabled) {
        "auto-refresh every $($Script:UIState.Settings.AutoRefreshSeconds)s"
    } else {
        'auto-refresh off'
    }
    Write-KFLine
    Write-KFColor -Text "  [0-22] select  " -Color $Script:Colors.Muted -NoNewline
    Write-KFColor -Text "[R] refresh  " -Color $Script:Colors.Muted -NoNewline
    Write-KFColor -Text "[Q] quit    " -Color $Script:Colors.Muted -NoNewline
    Write-KFColor -Text "$refreshLabel  |  updated $(Get-Date -Format 'HH:mm:ss')" -Color $Script:Colors.Dim
}

function Show-KFDashboard {
    <#
    .SYNOPSIS
        Renders the full dashboard screen (banner, system info, settings,
        quick stats, status line). Clears the screen first.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { Clear-Host } catch {}

    Write-KFBanner
    $data = Get-KFDashboardData -Force:$Force
    Write-KFSystemInfoGrid -Data $data
    Write-KFCurrentSettingsGrid -Data $data
    Write-KFQuickStats -Data $data
    $Script:UIState.LastRefresh = Get-Date
    $sw.Stop()
    Write-LogEntry -Level 'Debug' -Message "Dashboard rendered in $(Format-KFDuration -TimeSpan $sw.Elapsed)"
}

#endregion ==================================================================

#region ============================== MENU SYSTEM ==============================

# Menu item catalog: Id matches the original 22-item spec numbering exactly.
# Status: 'Ready' = fully implemented read-only screen in this build.
#         'Stub'  = placeholder; ships with the write/destructive modules
#                    in the next phase (each stub names which phase).
$Script:MenuItems = @(
    [pscustomobject]@{ Id = 1;  Label = 'Installed Languages';               Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 2;  Label = 'Installed Keyboard Layouts';        Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 3;  Label = 'Install New Language';             Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 4;  Label = 'Remove Language';                  Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 5;  Label = 'Remove Keyboard Layout';           Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 6;  Label = 'Set Default Keyboard';             Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 7;  Label = 'Set Display Language';             Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 8;  Label = 'Region Settings';                  Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 9;  Label = 'Locale Settings';                  Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 10; Label = 'Time & Region';                    Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 11; Label = 'Language Features';                Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 12; Label = 'Cleanup';                          Status = 'Stub';  Phase = 'Phase 4' }
    [pscustomobject]@{ Id = 13; Label = 'Advanced Removal';                 Status = 'Stub';  Phase = 'Phase 4' }
    [pscustomobject]@{ Id = 14; Label = 'Backup';                           Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 15; Label = 'Restore';                          Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 16; Label = 'Diagnostics';                      Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 17; Label = 'Repair Windows Language Components'; Status = 'Stub'; Phase = 'Phase 4' }
    [pscustomobject]@{ Id = 18; Label = 'Export Configuration';             Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 19; Label = 'Import Configuration';             Status = 'Stub';  Phase = 'Phase 3' }
    [pscustomobject]@{ Id = 20; Label = 'Live Monitoring';                  Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 21; Label = 'Settings';                         Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 22; Label = 'About';                            Status = 'Ready'; Phase = '' }
)

function Write-KFMainMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-KFColor -Text '  MAIN MENU' -Color $Script:Colors.Highlight
    Write-KFLine
    foreach ($item in $Script:MenuItems) {
        $num = '{0,2}' -f $item.Id
        if ($item.Status -eq 'Ready') {
            Write-KFColor -Text "   $num. " -Color $Script:Colors.Accent -NoNewline
            Write-KFColor -Text $item.Label -Color $Script:Colors.Body
        } else {
            Write-KFColor -Text "   $num. " -Color $Script:Colors.Dim -NoNewline
            Write-KFColor -Text "$($item.Label) " -Color $Script:Colors.Dim -NoNewline
            Write-KFColor -Text "($($item.Phase))" -Color $Script:Colors.Dim
        }
    }
    Write-KFColor -Text '    0. ' -Color $Script:Colors.Accent -NoNewline
    Write-KFColor -Text 'Exit' -Color $Script:Colors.Body
    Write-KFStatusLine
}

function Read-KFMenuSelection {
    <#
    .SYNOPSIS
        Reads and validates a main-menu selection. Also accepts 'R'/'r' to
        force-refresh and 'Q'/'q' as a synonym for 0/Exit.
    .OUTPUTS
        [int] 0-22, or -1 for "refresh only, no navigation".
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    Write-Host ''
    Write-KFColor -Text '  Select option: ' -Color $Script:Colors.Body -NoNewline
    $raw = (Read-Host).Trim()

    if ($raw -match '^(?i:q)$') { return 0 }
    if ($raw -match '^(?i:r)$') { return -1 }

    $num = 0
    if ([int]::TryParse($raw, [ref]$num) -and $num -ge 0 -and $num -le 22) {
        return $num
    }
    Write-KFStatus -Type 'Failure' -Message "'$raw' is not a valid option (0-22, or R/Q)."
    Start-Sleep -Milliseconds 900
    return -1
}

function Show-KFStubScreen {
    <#
    .SYNOPSIS
        Placeholder screen for menu items not yet implemented in this build.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$MenuItem
    )
    try { Clear-Host } catch {}
    Write-KFBanner
    $lines = @(
        "'$($MenuItem.Label)' is part of KeyForge's write/destructive module set."
        ''
        "It ships in $($MenuItem.Phase) of the roadmap, alongside the Registry"
        'Handler and Backup/Rollback modules it depends on for safety.'
        ''
        'This build (Core Foundation + UI Shell) is intentionally read-only.'
    )
    Write-KFBox -Lines $lines -Title "$(Get-KFIcon 'Info') Coming in $($MenuItem.Phase)" -BorderColor $Script:Colors.Info
    Write-Host ''
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: LANGUAGES / KEYBOARDS ===========

function Show-KFLanguagesScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  INSTALLED LANGUAGES' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $langs = Wait-KFWithSpinner -Label 'Scanning language packs (DISM)' -Action { Get-KFAllInstalledLanguages -Force }
    if ($null -eq $langs) { $langs = @() }

    $rows = @($langs | ForEach-Object {
        [pscustomobject]@{
            Language = $_.DisplayName
            Tag      = $_.LanguageTag
            InUse    = if ($_.InUserList) { Get-KFIcon 'Success' } else { '' }
            Basic    = if ($_.Basic) { Get-KFIcon 'Success' } else { '' }
            Speech   = if ($_.Speech -eq $true) { Get-KFIcon 'Success' } elseif ($null -eq $_.Speech) { '?' } else { '' }
            OCR      = if ($_.OCR -eq $true) { Get-KFIcon 'Success' } elseif ($null -eq $_.OCR) { '?' } else { '' }
            HW       = if ($_.Handwriting -eq $true) { Get-KFIcon 'Success' } elseif ($null -eq $_.Handwriting) { '?' } else { '' }
        }
    })

    $columns = @(
        @{ Name = 'Language'; Header = 'Language';    Width = 28; Align = 'Left' }
        @{ Name = 'Tag';      Header = 'Tag';          Width = 10; Align = 'Left' }
        @{ Name = 'InUse';    Header = 'In Use';       Width = 6;  Align = 'Left' }
        @{ Name = 'Basic';    Header = 'Basic';        Width = 6;  Align = 'Left' }
        @{ Name = 'Speech';   Header = 'Speech';       Width = 7;  Align = 'Left' }
        @{ Name = 'OCR';      Header = 'OCR';          Width = 4;  Align = 'Left' }
        @{ Name = 'HW';       Header = 'HW';            Width = 4;  Align = 'Left' }
    )
    Write-KFTable -Data $rows -Columns $columns
    Write-Host ''
    Write-KFColor -Text "  '?' means feature status could not be determined without an elevated DISM query." -Color $Script:Colors.Dim
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFKeyboardsScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  INSTALLED KEYBOARD LAYOUTS' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $kbds = Get-KFInstalledKeyboards -Force
    $rows = @($kbds | ForEach-Object {
        [pscustomobject]@{
            KLID    = $_.KLID
            Name    = $_.Name
            Tag     = if ($_.LanguageTag) { $_.LanguageTag } else { '-' }
            Loaded  = if ($_.Loaded) { Get-KFIcon 'Success' } else { '' }
            Order   = if ($null -ne $_.PreloadOrder) { $_.PreloadOrder } else { '-' }
        }
    })
    $columns = @(
        @{ Name = 'KLID';   Header = 'KLID';     Width = 10; Align = 'Left' }
        @{ Name = 'Name';   Header = 'Name';     Width = 36; Align = 'Left' }
        @{ Name = 'Tag';    Header = 'Tag';      Width = 8;  Align = 'Left' }
        @{ Name = 'Loaded'; Header = 'Loaded';   Width = 7;  Align = 'Left' }
        @{ Name = 'Order';  Header = 'Preload#'; Width = 8;  Align = 'Right' }
    )
    Write-KFTable -Data $rows -Columns $columns
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFLanguageFeaturesScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  LANGUAGE FEATURES' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $langs = Wait-KFWithSpinner -Label 'Reading feature matrix (DISM)' -Action { Get-KFAllInstalledLanguages }
    if ($null -eq $langs -or @($langs).Count -eq 0) {
        Write-KFStatus -Type 'Warning' -Message 'No feature data available (DISM query failed or returned nothing).'
    } else {
        foreach ($lang in $langs) {
            $features = [System.Collections.Generic.List[string]]::new()
            foreach ($f in @('Basic', 'Speech', 'OCR', 'Handwriting', 'TextToSpeech')) {
                $val = $lang.$f
                $mark = if ($val -eq $true) { Get-KFIcon 'Success' } elseif ($val -eq $false) { Get-KFIcon 'Ring' } else { '?' }
                $features.Add("$mark $f")
            }
            Write-KFColor -Text "  $($lang.DisplayName) " -Color $Script:Colors.Body -NoNewline
            Write-KFColor -Text "($($lang.LanguageTag))" -Color $Script:Colors.Muted
            Write-KFColor -Text "    $($features -join '   ')" -Color $Script:Colors.Info
            Write-Host ''
        }
    }
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: REGION / LOCALE / TIME ==========

function Get-KFRegionDetail {
    <#
    .SYNOPSIS
        Rich, read-only region/locale detail sourced from .NET globalization
        (CultureInfo/RegionInfo) plus the International module - this is the
        actual data Windows itself uses, not an approximation.
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'region:detail' -TtlSeconds 300 -Action {
        $outcome = Invoke-KFSafe -Context 'Get-KFRegionDetail' -Action {
            $culture = Get-Culture
            $region  = [System.Globalization.RegionInfo]::new($culture.Name)
            $homeLocation = Get-WinHomeLocation -ErrorAction Stop
            [pscustomobject]@{
                CountryName     = $region.EnglishName
                GeoId           = $homeLocation.GeoId
                CurrencySymbol  = $region.CurrencySymbol
                ISOCurrency     = $region.ISOCurrencySymbol
                Measurement     = if ($region.IsMetric) { 'Metric' } else { 'US (Imperial)' }
                FirstDayOfWeek  = $culture.DateTimeFormat.FirstDayOfWeek
                Calendar        = $culture.DateTimeFormat.Calendar.GetType().Name -replace 'Calendar$', ''
                CultureName     = $culture.Name
                CultureDisplay  = $culture.DisplayName
                ShortDate       = $culture.DateTimeFormat.ShortDatePattern
                LongDate        = $culture.DateTimeFormat.LongDatePattern
                ShortTime       = $culture.DateTimeFormat.ShortTimePattern
                LongTime        = $culture.DateTimeFormat.LongTimePattern
                DecimalSep      = $culture.NumberFormat.NumberDecimalSeparator
                ThousandsSep    = $culture.NumberFormat.NumberGroupSeparator
                SampleShortDate = (Get-Date).ToString($culture.DateTimeFormat.ShortDatePattern, $culture)
                SampleNumber    = (1234567.89).ToString('N2', $culture)
            }
        }
        if ($outcome.Success) { $outcome.Result } else { $null }
    }
}

function Show-KFRegionScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  REGION SETTINGS  (view-only)' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''
    $d = Get-KFRegionDetail
    if ($null -eq $d) {
        Write-KFStatus -Type 'Failure' -Message 'Could not read region settings.'
    } else {
        $lines = @(
            ('{0,-22} {1}' -f 'Country/Region:', $d.CountryName)
            ('{0,-22} {1}' -f 'GeoID:', $d.GeoId)
            ('{0,-22} {1}' -f 'Currency:', "$($d.CurrencySymbol)  ($($d.ISOCurrency))")
            ('{0,-22} {1}' -f 'Measurement system:', $d.Measurement)
            ('{0,-22} {1}' -f 'First day of week:', $d.FirstDayOfWeek)
            ('{0,-22} {1}' -f 'Calendar:', $d.Calendar)
        )
        Write-KFBox -Lines $lines -Title 'Region' -BorderColor $Script:Colors.Border
    }
    Write-Host ''
    Write-KFAlert -Level 'Info' -Message 'Changing region settings arrives with the Region Manager module in Phase 3.'
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFLocaleScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  LOCALE SETTINGS  (view-only)' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''
    $locale = Get-KFLocaleInfo
    $d = Get-KFRegionDetail
    $lines = @(
        ('{0,-22} {1}' -f 'System locale:', $locale.SystemLocale)
        ('{0,-22} {1}' -f 'User locale:', $locale.UserLocale)
        ('{0,-22} {1}' -f 'Display language:', $locale.DisplayName)
        ('{0,-22} {1}' -f 'Console encoding:', [Console]::OutputEncoding.WebName)
    )
    Write-KFBox -Lines $lines -Title 'Locale' -BorderColor $Script:Colors.Border
    Write-Host ''
    if ($d) {
        $fmtLines = @(
            ('{0,-22} {1}' -f 'Short date pattern:', "$($d.ShortDate)   e.g. $($d.SampleShortDate)")
            ('{0,-22} {1}' -f 'Long date pattern:', $d.LongDate)
            ('{0,-22} {1}' -f 'Short time pattern:', $d.ShortTime)
            ('{0,-22} {1}' -f 'Decimal separator:', "'$($d.DecimalSep)'")
            ('{0,-22} {1}' -f 'Thousands separator:', "'$($d.ThousandsSep)'   e.g. $($d.SampleNumber)")
        )
        Write-KFBox -Lines $fmtLines -Title 'Formats' -BorderColor $Script:Colors.Border
        Write-Host ''
    }
    Write-KFAlert -Level 'Info' -Message 'Changing locale settings arrives with the Locale Manager module in Phase 3.'
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFTimeRegionScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  TIME & REGION  (view-only)' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''
    $tz = Get-KFTimeZoneInfo
    $now = Get-Date
    $lines = @(
        ('{0,-22} {1}' -f 'Time zone:', $tz.DisplayName)
        ('{0,-22} {1}' -f 'Zone ID:', $tz.Id)
        ('{0,-22} {1}' -f 'UTC offset:', $tz.UtcOffset)
        ('{0,-22} {1}' -f 'Local time now:', $now.ToString('yyyy-MM-dd HH:mm:ss'))
        ('{0,-22} {1}' -f 'UTC time now:', $now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
    )
    Write-KFBox -Lines $lines -Title 'Time & Region' -BorderColor $Script:Colors.Border
    Write-Host ''
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: DIAGNOSTICS (LITE) ===============

function Invoke-KFDiagnostics {
    <#
    .SYNOPSIS
        Runs a set of non-destructive, read-only health checks. This is the
        "lite" diagnostics pass for the foundation build - the full 100+
        check engine (CBS/SFC/DISM log parsing, deep registry consistency)
        ships with the Repair module in a later phase.
    .OUTPUTS
        [pscustomobject[]] @{ Check; Status; Detail }
    #>
    [CmdletBinding()]
    param()
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    function Add-KFCheck([string]$Name, [string]$Status, [string]$Detail) {
        $results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
    }

    $compat = Test-KFWindowsCompatibility
    Add-KFCheck 'Windows version supported' $(if ($compat.Supported) { 'Pass' } else { 'Fail' }) $compat.Reason

    $isAdmin = Test-KFAdminPrivileges
    Add-KFCheck 'Elevation' $(if ($isAdmin) { 'Pass' } else { 'Info' }) $(if ($isAdmin) { 'Running elevated.' } else { 'Not elevated - some future write operations will require Run as Administrator.' })

    foreach ($key in 'KeyboardLayouts', 'Preload', 'IntlUserProfile') {
        $path = $Script:RegistryPaths[$key]
        $exists = Test-KFRegistryKeyExists -Path $path
        Add-KFCheck "Registry: $key" $(if ($exists) { 'Pass' } else { 'Fail' }) $path
    }

    $preloadCount = Invoke-KFSafe -Context 'Diagnostics:PreloadCount' -Silent -Action {
        (Get-Item -LiteralPath $Script:RegistryPaths.Preload -ErrorAction Stop).Property.Count
    }
    if ($preloadCount.Success -and $preloadCount.Result -gt 0) {
        Add-KFCheck 'Keyboard preload list' 'Pass' "$($preloadCount.Result) layout(s) loaded for the current user."
    } else {
        Add-KFCheck 'Keyboard preload list' 'Warn' 'No loaded keyboard layouts detected for the current user.'
    }

    $userLangs = @(Get-KFUserLanguages)
    Add-KFCheck 'User language list' $(if ($userLangs.Count -gt 0) { 'Pass' } else { 'Warn' }) "$($userLangs.Count) language(s) assigned to the current user."

    $dismCheck = Invoke-KFSafe -Context 'Diagnostics:DISM' -Silent -Action {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Get-WindowsCapability -Online -Name 'Language.Basic~~~en-US~0.0.1.0' -ErrorAction Stop
        $sw.Stop()
        [pscustomobject]@{ Elapsed = $sw.Elapsed; Result = $r }
    }
    if ($dismCheck.Success) {
        Add-KFCheck 'DISM capability query' 'Pass' "Responded in $(Format-KFDuration -TimeSpan $dismCheck.Result.Elapsed)."
    } else {
        Add-KFCheck 'DISM capability query' 'Warn' "Unavailable: $($dismCheck.Error)"
    }

    $localeCheck = Invoke-KFSafe -Context 'Diagnostics:Locale' -Silent -Action { Get-Culture }
    $localeOk = $localeCheck.Success -and $localeCheck.Result.Name -ne '' -and $localeCheck.Result.Name -ne 'iv'
    Add-KFCheck 'Culture resolution' $(if ($localeOk) { 'Pass' } else { 'Fail' }) $(if ($localeOk) { $localeCheck.Result.Name } else { 'Current culture resolved to Invariant - locale may be misconfigured.' })

    Add-KFCheck 'Log directory writable' $(if (Test-KFPathExists $Script:Paths.Logs) { 'Pass' } else { 'Fail' }) $Script:Paths.Logs

    return $results
}

function Show-KFDiagnosticsScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  DIAGNOSTICS  (lite - non-destructive checks)' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $results = Wait-KFWithSpinner -Label 'Running diagnostic checks' -Action { Invoke-KFDiagnostics }
    if ($null -eq $results) { $results = @() }

    $rows = @($results | ForEach-Object {
        $icon = switch ($_.Status) {
            'Pass' { Get-KFIcon 'Success' }
            'Warn' { Get-KFIcon 'Warning' }
            'Fail' { Get-KFIcon 'Failure' }
            default { Get-KFIcon 'Info' }
        }
        [pscustomobject]@{ S = $icon; Check = $_.Check; Detail = $_.Detail }
    })
    $columns = @(
        @{ Name = 'S';     Header = ' ';      Width = 3;  Align = 'Left' }
        @{ Name = 'Check';  Header = 'Check';  Width = 26; Align = 'Left' }
        @{ Name = 'Detail'; Header = 'Detail'; Width = 56; Align = 'Left' }
    )
    Write-KFTable -Data $rows -Columns $columns

    $failCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq 'Warn' }).Count
    Write-Host ''
    if ($failCount -eq 0 -and $warnCount -eq 0) {
        Write-KFStatus -Type 'Success' -Message 'All checks passed.'
    } else {
        Write-KFStatus -Type 'Warning' -Message "$failCount failure(s), $warnCount warning(s). See Detail column above."
    }
    Write-Host ''
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: EXPORT CONFIGURATION ============

function Show-KFExportScreen {
    <#
    .SYNOPSIS
        Exports the currently-visible read-only state (dashboard + languages
        + keyboards + region/locale) to a timestamped JSON snapshot. This is
        a data export only - it does not capture registry hives and is not
        the full Backup module, which arrives with the Registry Handler in
        Phase 3.
    #>
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  EXPORT CONFIGURATION' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destPath = Join-Path $Script:Paths.Exports "KeyForge-Snapshot_$stamp.json"

    Write-KFColor -Text "  This exports a read-only JSON snapshot of the current dashboard," -Color $Script:Colors.Body
    Write-KFColor -Text "  language, keyboard, and region/locale data (not a full registry" -Color $Script:Colors.Body
    Write-KFColor -Text "  backup) to:" -Color $Script:Colors.Body
    Write-KFColor -Text "    $destPath" -Color $Script:Colors.Info
    Write-Host ''

    if (-not (Request-KFUserConfirmation -Message 'Write this snapshot?' -DefaultYes $true)) {
        Write-KFStatus -Type 'Info' -Message 'Export cancelled.'
        Start-Sleep -Milliseconds 900
        return
    }

    $snapshot = Wait-KFWithSpinner -Label 'Building snapshot' -Action {
        [pscustomobject]@{
            ExportedAt = (Get-Date).ToString('u')
            KeyForgeVersion = $Script:Meta.Version
            Dashboard  = Get-KFDashboardData -Force
            Languages  = Get-KFAllInstalledLanguages -Force
            Keyboards  = Get-KFInstalledKeyboards -Force
            Region     = Get-KFRegionDetail
        }
    }

    if ($null -eq $snapshot) {
        Write-KFStatus -Type 'Failure' -Message 'Snapshot build failed - see the session log for details.'
    } else {
        $writeResult = Invoke-KFSafe -Context 'Export snapshot write' -Action {
            $json = $snapshot | ConvertTo-Json -Depth 8
            Set-Content -LiteralPath $destPath -Value $json -Encoding UTF8 -ErrorAction Stop
        }
        if ($writeResult.Success) {
            Write-KFStatus -Type 'Success' -Message "Snapshot saved to $destPath"
        } else {
            Write-KFStatus -Type 'Failure' -Message "Could not write snapshot: $($writeResult.Error)"
        }
    }
    Write-Host ''
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: LIVE MONITORING (LITE) ==========

function Show-KFLiveMonitorScreen {
    <#
    .SYNOPSIS
        Polls keyboard/language/locale every ~2s and prints only the values
        that changed since the last sample (differential rendering - avoids
        redrawing/flickering the whole screen every tick). Read-only. Stops
        on any keypress or after a 5-minute safety cap.
    #>
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  LIVE MONITORING  (read-only, press any key to stop)' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $canReadKey = ($Host.Name -eq 'ConsoleHost')
    if (-not $canReadKey) {
        Write-KFAlert -Level 'Warning' -Message 'This host does not support key-press interrupts; monitoring will run for a fixed number of cycles instead.'
    }

    $previous = $null
    $iterations = 0
    $maxIterations = 150   # ~5 minutes at 2s/cycle - safety cap, never runs unbounded

    while ($iterations -lt $maxIterations) {
        if ($canReadKey -and $Host.UI.RawUI.KeyAvailable) {
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown,IncludeKeyUp')
            break
        }

        $current = [pscustomobject]@{
            Keyboard = Get-KFCurrentKeyboardName -Force
            Locale   = (Invoke-KFSafe -Silent -Context 'Monitor:Locale' -Action { (Get-Culture).Name }).Result
            TimeZone = (Invoke-KFSafe -Silent -Context 'Monitor:TZ' -Action { (Get-TimeZone).Id }).Result
        }

        if ($null -eq $previous) {
            Write-KFColor -Text "  [$(Get-Date -Format 'HH:mm:ss')] baseline  " -Color $Script:Colors.Muted -NoNewline
            Write-KFColor -Text "keyboard=$($current.Keyboard)  locale=$($current.Locale)  tz=$($current.TimeZone)" -Color $Script:Colors.Body
        } else {
            $changes = [System.Collections.Generic.List[string]]::new()
            foreach ($prop in 'Keyboard', 'Locale', 'TimeZone') {
                if ($current.$prop -ne $previous.$prop) {
                    $changes.Add("$prop`: $($previous.$prop) $(Get-KFIcon 'Arrow') $($current.$prop)")
                }
            }
            if ($changes.Count -gt 0) {
                Write-KFColor -Text "  [$(Get-Date -Format 'HH:mm:ss')] CHANGE    " -Color $Script:Colors.Accent -NoNewline
                Write-KFColor -Text ($changes -join '   ') -Color $Script:Colors.Warning
            }
        }

        $previous = $current
        $iterations++

        # Sleep in short slices so a keypress is noticed within ~100ms
        # instead of waiting out the full 2s sample interval.
        $slept = 0
        $stopRequested = $false
        while ($slept -lt 2000) {
            if ($canReadKey -and $Host.UI.RawUI.KeyAvailable) {
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown,IncludeKeyUp')
                $stopRequested = $true
                break
            }
            Start-Sleep -Milliseconds 100
            $slept += 100
        }
        if ($stopRequested) { break }
    }

    Write-Host ''
    Write-KFStatus -Type 'Info' -Message 'Monitoring stopped.'
    Write-Host ''
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: SETTINGS / ABOUT =================

function Show-KFSettingsScreen {
    <#
    .SYNOPSIS
        Session-scoped preference toggles. Nothing here is persisted to disk
        or changes Windows configuration - it only affects how KeyForge
        itself behaves for the rest of this run.
    #>
    [CmdletBinding()]
    param()
    while ($true) {
        try { Clear-Host } catch {}
        Write-KFBanner
        Write-KFColor -Text '  SETTINGS  (this session only)' -Color $Script:Colors.Highlight
        Write-KFLine
        Write-Host ''

        $s = $Script:UIState.Settings
        $lines = @(
            ('{0,-24} {1}' -f '1. Color output:', $(if ($Script:UIState.ColorSupported) { 'On' } else { 'Off' }))
            ('{0,-24} {1}' -f '2. Verbose logging:', $(if ($s.VerboseLog) { 'On' } else { 'Off' }))
            ('{0,-24} {1}' -f '3. Debug logging:', $(if ($s.DebugLog) { 'On' } else { 'Off' }))
            ('{0,-24} {1}' -f '4. Auto-refresh:', $(if ($s.AutoRefreshEnabled) { "On ($($s.AutoRefreshSeconds)s)" } else { 'Off' }))
            ('{0,-24} {1}' -f '5. Log file:', (Get-KFLogPath))
            ('{0,-24} {1}' -f '6. Data folder:', $Script:Paths.Root)
        )
        Write-KFBox -Lines $lines -Title 'Preferences' -BorderColor $Script:Colors.Border
        Write-Host ''
        Write-KFColor -Text '  Enter a number to toggle it, E to export the session log, or 0 to go back: ' -Color $Script:Colors.Body -NoNewline
        $choice = (Read-Host).Trim()

        switch -Regex ($choice) {
            '^1$' { $Script:UIState.ColorSupported = -not $Script:UIState.ColorSupported }
            '^2$' { $s.VerboseLog = -not $s.VerboseLog }
            '^3$' { $s.DebugLog = -not $s.DebugLog; if ($s.DebugLog) { $s.VerboseLog = $true } }
            '^4$' { $s.AutoRefreshEnabled = -not $s.AutoRefreshEnabled }
            '^(?i:e)$' {
                $dest = Export-KFSessionLog
                if ($dest) { Write-KFStatus -Type 'Success' -Message "Log exported to $dest" }
                else { Write-KFStatus -Type 'Failure' -Message 'Could not export the log.' }
                Start-Sleep -Milliseconds 1200
            }
            '^0$' { return }
            default {
                Write-KFStatus -Type 'Failure' -Message "'$choice' is not a valid option."
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

function Show-KFAboutScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    $lines = @(
        "$($Script:Meta.Name) v$($Script:Meta.Version)  ($($Script:Meta.BuildLabel))"
        $Script:Meta.Tagline
        ''
        "License:      $($Script:Meta.License)"
        "Repository:   $($Script:Meta.ProjectURL)"
        "PowerShell:   $($PSVersionTable.PSVersion)  ($($PSVersionTable.PSEdition))"
        "Host:         $($Host.Name)"
        ''
        'Roadmap:'
        '  Phase 1-2 (this build): Core foundation + full UI shell, read-only'
        '  Phase 3:                Registry handler, install/remove, backup/restore'
        '  Phase 4:                Cleanup, advanced removal, repair, live watch'
    )
    Write-KFBox -Lines $lines -Title 'About' -BorderColor $Script:Colors.Border
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFHelp {
    [CmdletBinding()]
    param()
    Write-KFBanner
    $lines = @(
        'USAGE'
        '  .\KeyForge.ps1 [-NoColor] [-VerboseLog] [-DebugLog] [-Help] [-Version]'
        ''
        '  irm https://raw.githubusercontent.com/rhshourav/windows-scripts/main/KeyForge.ps1 | iex'
        ''
        'PARAMETERS'
        '  -Help         Show this help and exit.'
        '  -Version      Show version information and exit.'
        '  -NoColor      Disable colored output.'
        '  -VerboseLog   Write verbose entries to the session log file.'
        '  -DebugLog     Write debug entries to the session log file (implies -VerboseLog).'
        ''
        "Full comment-based help is also available via 'Get-Help .\KeyForge.ps1 -Full'"
        'when running from a saved file (not available under irm | iex, since there'
        'is no file on disk for Get-Help to parse in that mode).'
    )
    Write-KFBox -Lines $lines -Title "$($Script:Meta.Name) Help" -BorderColor $Script:Colors.Border
}

#endregion ==================================================================

#region ============================== RESPONSIVE INPUT / MAIN DISPATCH =========

function Read-KFMenuSelectionResponsive {
    <#
    .SYNOPSIS
        Like Read-KFMenuSelection, but polls for keystrokes so the dashboard
        can auto-refresh while idle - WITHOUT ever interrupting a keystroke
        the user has already started typing. Falls back to a plain blocking
        read on hosts that don't support raw console key polling (ISE, some
        integrated terminals) or when auto-refresh is disabled in Settings.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $canReadKey = ($Host.Name -eq 'ConsoleHost')
    if (-not $canReadKey -or -not $Script:UIState.Settings.AutoRefreshEnabled) {
        return Read-KFMenuSelection
    }

    Write-Host ''
    Write-KFColor -Text '  Select option: ' -Color $Script:Colors.Body -NoNewline

    $buffer = ''
    $deadline = (Get-Date).AddSeconds($Script:UIState.Settings.AutoRefreshSeconds)

    while ($true) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.VirtualKeyCode -eq 13) {
                Write-Host ''
                break
            } elseif ($key.VirtualKeyCode -eq 8) {
                if ($buffer.Length -gt 0) {
                    $buffer = $buffer.Substring(0, $buffer.Length - 1)
                    Write-Host "`b `b" -NoNewline
                }
            } elseif ($key.Character -and -not [char]::IsControl($key.Character)) {
                $buffer += $key.Character
                Write-Host $key.Character -NoNewline
            }
            # Any keystroke pushes the auto-refresh deadline back so a
            # partially-typed selection is never wiped out by a refresh.
            $deadline = (Get-Date).AddSeconds($Script:UIState.Settings.AutoRefreshSeconds)
        } elseif ((Get-Date) -ge $deadline -and $buffer -eq '') {
            Write-Host ''
            return -1
        } else {
            Start-Sleep -Milliseconds 80
        }
    }

    $raw = $buffer.Trim()
    if ($raw -eq '' -or $raw -match '^(?i:r)$') { return -1 }
    if ($raw -match '^(?i:q)$') { return 0 }
    $num = 0
    if ([int]::TryParse($raw, [ref]$num) -and $num -ge 0 -and $num -le 22) { return $num }
    Write-KFStatus -Type 'Failure' -Message "'$raw' is not a valid option (0-22, or R/Q)."
    Start-Sleep -Milliseconds 900
    return -1
}

function Invoke-KFMenuDispatch {
    <#
    .SYNOPSIS
        Routes a validated menu selection (1-22) to its screen function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Selection
    )
    switch ($Selection) {
        1  { Show-KFLanguagesScreen }
        2  { Show-KFKeyboardsScreen }
        8  { Show-KFRegionScreen }
        9  { Show-KFLocaleScreen }
        10 { Show-KFTimeRegionScreen }
        11 { Show-KFLanguageFeaturesScreen }
        16 { Show-KFDiagnosticsScreen }
        18 { Show-KFExportScreen }
        20 { Show-KFLiveMonitorScreen }
        21 { Show-KFSettingsScreen }
        22 { Show-KFAboutScreen }
        default {
            $item = $Script:MenuItems | Where-Object { $_.Id -eq $Selection }
            if ($item) { Show-KFStubScreen -MenuItem $item }
        }
    }
}

#endregion ==================================================================

#region ============================== APPLICATION LOOP =========================

function Start-KeyForge {
    <#
    .SYNOPSIS
        KeyForge's main application loop: initializes logging/console, checks
        platform compatibility, then renders the dashboard + menu and
        dispatches selections until the user exits.
    #>
    [CmdletBinding()]
    param()

    Initialize-KFLogFile
    Write-LogEntry -Level 'Info' -Message "KeyForge v$($Script:Meta.Version) ($($Script:Meta.BuildLabel)) starting. PS $($PSVersionTable.PSVersion) [$($PSVersionTable.PSEdition)], Host=$($Host.Name), User=$env:USERNAME"
    Initialize-KFConsole

    $isWindowsPlatform = $true
    if (Test-Path -LiteralPath 'Variable:\IsWindows') { $isWindowsPlatform = $IsWindows }
    if (-not $isWindowsPlatform) {
        Write-KFBanner
        Write-KFAlert -Level 'Danger' -Message 'KeyForge reads and manages Windows-specific language, keyboard, and locale settings and cannot run on this platform.'
        return
    }

    $compat = Test-KFWindowsCompatibility
    if (-not $compat.Supported) {
        Write-KFBanner
        Write-KFAlert -Level 'Danger' -Message $compat.Reason
        Write-Host ''
        if (-not (Request-KFUserConfirmation -Message 'Continue anyway? Some features may not work correctly.' -DefaultYes $false)) {
            Write-KFStatus -Type 'Info' -Message 'Exiting.'
            return
        }
    }
    Write-LogEntry -Level 'Info' -Message "Platform check: $($compat.Reason)"

    $running = $true
    while ($running) {
        $renderOutcome = Invoke-KFSafe -Context 'MainLoop:Render' -Action {
            Show-KFDashboard
            Write-KFMainMenu
        }
        if (-not $renderOutcome.Success) {
            Write-KFStatus -Type 'Failure' -Message 'A rendering error occurred; see the session log. Continuing.'
        }

        $selection = Read-KFMenuSelectionResponsive
        if ($selection -eq -1) { continue }
        if ($selection -eq 0) { $running = $false; continue }

        $dispatchOutcome = Invoke-KFSafe -Context "MainLoop:Dispatch($selection)" -Action {
            Invoke-KFMenuDispatch -Selection $selection
        }
        if (-not $dispatchOutcome.Success) {
            Write-KFStatus -Type 'Failure' -Message 'That screen hit an error; see the session log. Returning to the menu.'
            Start-Sleep -Milliseconds 1200
        }
    }

    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text "  Thanks for using KeyForge. Session log: $(Get-KFLogPath)" -Color $Script:Colors.Muted
    Write-Host ''
    Write-LogEntry -Level 'Info' -Message 'KeyForge session ended normally.'
}

#endregion ==================================================================

#region ============================== ENTRY POINT ===============================

if ($Help) {
    $Script:UIState.UnicodeSupported = Test-KFUnicodeSupport
    $Script:UIState.ColorSupported   = -not $NoColor
    Show-KFHelp
    return
}

if ($Version) {
    Write-Host "$($Script:Meta.Name) v$($Script:Meta.Version) ($($Script:Meta.BuildLabel))"
    return
}

try {
    Start-KeyForge
} catch {
    # Last-resort safety net for anything that escaped every internal
    # try/catch. KeyForge's contract is "never crash with a raw stack
    # trace" - this is the backstop that guarantees it.
    try { Write-ExceptionLog -ErrorRecord $_ -Context 'FatalUnhandled' } catch {}
    Write-Host ''
    Write-Host '  KeyForge hit an unexpected error and needs to stop:' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    if ($Script:LogFilePath) {
        Write-Host "  Details were written to: $($Script:LogFilePath)" -ForegroundColor Gray
    }
} finally {
    try { $Host.UI.RawUI.WindowTitle = 'Windows PowerShell' } catch {}
}

#endregion ==================================================================
