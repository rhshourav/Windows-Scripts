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
    param(
        [switch]$Force
    )
    Get-KFCached -Key 'lang:user' -TtlSeconds 300 -Force:$Force -Action {
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

#region ============================== REGISTRY HANDLER MODULE =================
#
# Every write-capable module in Phase 3 goes through this layer. Two
# deliberate departures from the original spec's literal wording, both
# safety-motivated:
#
#  1. "Backup-RegistryHive" in the spec really means "protect the specific
#     subtree we're about to touch." A literal hive-level save/restore
#     (reg.exe SAVE/RESTORE) needs SeBackupPrivilege/SeRestorePrivilege and
#     only works against certain loaded root keys - it's the wrong tool for
#     KeyForge, which only ever touches a handful of well-known subtrees
#     (Keyboard Layouts, Control Panel\International, Nls\Language Groups).
#     `reg export` / `reg import` against those specific paths is safe,
#     always available to an admin, and protects exactly what KeyForge is
#     about to change - so that's what Backup-KFRegistryKey/Restore-KFRegistryKey
#     do.
#
#  2. WOW64 redirection only applies to HKLM\SOFTWARE and HKEY_CLASSES_ROOT.
#     None of KeyForge's actual registry targets live under those paths -
#     they're all under HKLM\SYSTEM\CurrentControlSet\Control, which is NOT
#     redirected. Get-KFRegistryView is included for completeness/future use
#     against SOFTWARE keys, but WOW64 handling is intentionally minimal here
#     because it doesn't apply to anything KeyForge currently reads or writes.
#

function Test-KFRegistryPathSafety {
    <#
    .SYNOPSIS
        Guardrail checked before ANY write/delete operation. Rejects paths
        that are malformed, are a bare hive root, or fall under a small
        denylist of paths KeyForge must never modify regardless of caller.
    .OUTPUTS
        [pscustomobject] @{ Safe; Reason }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Safe = $false; Reason = 'Path is empty.' }
    }
    if ($Path -notmatch '^(HKLM|HKCU|HKU|HKCR|HKCC):\\') {
        return [pscustomobject]@{ Safe = $false; Reason = "Path must start with a recognized hive drive (HKLM:\, HKCU:\, HKU:\, HKCR:\, HKCC:\)." }
    }
    $depth = ($Path -split '\\' | Where-Object { $_ -ne '' }).Count
    if ($depth -le 1) {
        return [pscustomobject]@{ Safe = $false; Reason = 'Refusing to operate on a bare hive root - path must point at a specific subkey.' }
    }

    $denylist = @(
        'HKLM:\SAM'
        'HKLM:\SECURITY'
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        'HKLM:\SYSTEM\CurrentControlSet\Services'
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        'HKCU:\Software\Classes'
    )
    foreach ($denied in $denylist) {
        if ($Path -eq $denied -or $Path.StartsWith("$denied\", [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Safe = $false; Reason = "'$Path' falls under a protected path KeyForge will not modify ($denied)." }
        }
    }
    return [pscustomobject]@{ Safe = $true; Reason = 'OK' }
}

function Get-KFRegistryView {
    <#
    .SYNOPSIS
        Reports process/OS bitness. WOW64 redirection only affects
        HKLM\SOFTWARE and HKCR, which none of KeyForge's current targets use -
        see the module header. Kept for future modules that may need it.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        ProcessIs64Bit = [System.Environment]::Is64BitProcess
        OSIs64Bit      = [System.Environment]::Is64BitOperatingSystem
        IsWow64        = (-not [System.Environment]::Is64BitProcess) -and [System.Environment]::Is64BitOperatingSystem
    }
}

function Get-KFRegValue {
    <#
    .SYNOPSIS
        Reads a single registry value. Never throws - missing keys/values
        return $null via .Success = $false rather than a terminating error.
    .OUTPUTS
        [pscustomobject] @{ Success; Value; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )
    $outcome = Invoke-KFSafe -Context "Get-KFRegValue:$Path\$Name" -Silent -Action {
        Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
    [pscustomobject]@{ Success = $outcome.Success; Value = $outcome.Result; Error = $outcome.Error }
}

function Get-KFRegKey {
    <#
    .SYNOPSIS
        Lists subkeys under a path, optionally recursive and/or filtered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Recurse,

        [string]$Filter
    )
    $outcome = Invoke-KFSafe -Context "Get-KFRegKey:$Path" -Silent -Action {
        $items = Get-ChildItem -LiteralPath $Path -Recurse:$Recurse -ErrorAction Stop
        if ($Filter) { $items = $items | Where-Object { (Split-Path -Leaf $_.PSPath) -like $Filter } }
        $items
    }
    if ($outcome.Success) { return @($outcome.Result) }
    Write-LogEntry -Level 'Debug' -Message "Get-KFRegKey failed for '$Path': $($outcome.Error)"
    return @()
}

function Export-KFRegKey {
    <#
    .SYNOPSIS
        Exports a registry key tree to a .reg file via reg.exe (the only
        tool that produces the standard, re-importable .reg format).
    .OUTPUTS
        [pscustomobject] @{ Success; DestinationPath; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )
    $safety = Test-KFRegistryPathSafety -Path $Path
    if (-not $safety.Safe) {
        return [pscustomobject]@{ Success = $false; DestinationPath = $null; Error = $safety.Reason }
    }
    if (-not (Test-KFRegistryKeyExists -Path $Path)) {
        # Nothing to export is not a failure - the key simply doesn't exist
        # yet (common for e.g. per-user keys that haven't been created).
        return [pscustomobject]@{ Success = $true; DestinationPath = $null; Error = 'Key does not exist - nothing to export.' }
    }

    # reg.exe wants "HKLM\Path\To\Key" (backslash-hive, no PSDrive colon).
    $regPath = $Path -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU' -replace '^HKU:', 'HKU' -replace '^HKCR:', 'HKCR' -replace '^HKCC:', 'HKCC'

    $outcome = Invoke-KFSafe -Context "Export-KFRegKey:$Path" -Action {
        $destDir = Split-Path -Parent $DestinationPath
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $result = & reg.exe export "$regPath" "$DestinationPath" /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [RegistryAccessException]::new("reg.exe export exited with code $LASTEXITCODE for '$Path': $result")
        }
    }
    [pscustomobject]@{ Success = $outcome.Success; DestinationPath = $(if ($outcome.Success) { $DestinationPath } else { $null }); Error = $outcome.Error }
}

function Import-KFRegFile {
    <#
    .SYNOPSIS
        Imports a previously-exported .reg file via reg.exe. Internal
        primitive used by Restore-KFRegistryKey - not exposed on the menu
        directly, since importing an arbitrary .reg file bypasses KeyForge's
        own path-safety checks (the exporting side already validated them).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return [pscustomobject]@{ Success = $false; Error = "Backup file not found: $SourcePath" }
    }
    $outcome = Invoke-KFSafe -Context "Import-KFRegFile:$SourcePath" -Action {
        $result = & reg.exe import "$SourcePath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [RegistryAccessException]::new("reg.exe import exited with code $LASTEXITCODE for '$SourcePath': $result")
        }
    }
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

function Set-KFRegValue {
    <#
    .SYNOPSIS
        Creates or updates a registry value, auto-backing up the containing
        key first (via Export-KFRegKey) so the caller always has a rollback
        path. Refuses to run against anything Test-KFRegistryPathSafety flags.
    .OUTPUTS
        [pscustomobject] @{ Success; PreviousValue; BackupPath; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$Value,

        [ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'Binary', 'MultiString')]
        [string]$Type = 'String'
    )
    $safety = Test-KFRegistryPathSafety -Path $Path
    if (-not $safety.Safe) {
        return [pscustomobject]@{ Success = $false; PreviousValue = $null; BackupPath = $null; Error = $safety.Reason }
    }
    if (-not $PSCmdlet.ShouldProcess("$Path\$Name", "Set to '$Value' ($Type)")) {
        return [pscustomobject]@{ Success = $false; PreviousValue = $null; BackupPath = $null; Error = 'Cancelled (ShouldProcess).' }
    }

    $previous = Get-KFRegValue -Path $Path -Name $Name
    $backupPath = Join-Path $Script:Paths.Backups "regvalue_$(Split-Path -Leaf $Path)_$(Get-Date -Format 'yyyyMMdd-HHmmss').reg"
    $backupResult = Export-KFRegKey -Path $Path -DestinationPath $backupPath

    $outcome = Invoke-KFSafe -Context "Set-KFRegValue:$Path\$Name" -Action {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }

    [pscustomobject]@{
        Success       = $outcome.Success
        PreviousValue = $(if ($previous.Success) { $previous.Value } else { $null })
        BackupPath    = $(if ($backupResult.Success) { $backupResult.DestinationPath } else { $null })
        Error         = $outcome.Error
    }
}

function New-KFRegKey {
    <#
    .SYNOPSIS
        Creates a registry key, including any missing parent keys.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $safety = Test-KFRegistryPathSafety -Path $Path
    if (-not $safety.Safe) {
        return [pscustomobject]@{ Success = $false; Error = $safety.Reason }
    }
    if (Test-KFRegistryKeyExists -Path $Path) {
        return [pscustomobject]@{ Success = $true; Error = 'Key already exists.' }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create registry key')) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context "New-KFRegKey:$Path" -Action {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

function Remove-KFRegKey {
    <#
    .SYNOPSIS
        Deletes a registry key tree, backing it up first via Export-KFRegKey
        so it can be restored with Restore-KFRegistryKey. Refuses to run
        against anything Test-KFRegistryPathSafety flags.
    .OUTPUTS
        [pscustomobject] @{ Success; BackupPath; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $safety = Test-KFRegistryPathSafety -Path $Path
    if (-not $safety.Safe) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = $safety.Reason }
    }
    if (-not (Test-KFRegistryKeyExists -Path $Path)) {
        return [pscustomobject]@{ Success = $true; BackupPath = $null; Error = 'Key did not exist - nothing to remove.' }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete registry key tree')) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = 'Cancelled (ShouldProcess).' }
    }

    $backupPath = Join-Path $Script:Paths.Backups "regkey_$(Split-Path -Leaf $Path)_$(Get-Date -Format 'yyyyMMdd-HHmmss').reg"
    $backupResult = Export-KFRegKey -Path $Path -DestinationPath $backupPath
    if (-not $backupResult.Success) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = "Refusing to delete without a successful backup: $($backupResult.Error)" }
    }

    $outcome = Invoke-KFSafe -Context "Remove-KFRegKey:$Path" -Action {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $Path) {
            throw [OperationFailedException]::new("'$Path' still exists after deletion attempt.")
        }
    }
    [pscustomobject]@{ Success = $outcome.Success; BackupPath = $backupResult.DestinationPath; Error = $outcome.Error }
}

function Backup-KFRegistryKey {
    <#
    .SYNOPSIS
        Protects a specific registry subtree before KeyForge modifies it.
        See the module header for why this targets a subtree rather than a
        literal hive.
    .OUTPUTS
        [pscustomobject] @{ Success; BackupPath; ItemCount; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Label = (Split-Path -Leaf $Path)
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeLabel = ($Label -replace '[^A-Za-z0-9_-]', '_')
    $dest = Join-Path $Script:Paths.Backups "regkey_${safeLabel}_$stamp.reg"

    $result = Export-KFRegKey -Path $Path -DestinationPath $dest
    $itemCount = (Get-KFRegKey -Path $Path -Recurse).Count

    [pscustomobject]@{
        Success    = $result.Success
        BackupPath = $result.DestinationPath
        ItemCount  = $itemCount
        Error      = $result.Error
    }
}

function Restore-KFRegistryKey {
    <#
    .SYNOPSIS
        Restores a subtree from a .reg file created by Backup-KFRegistryKey.
        Takes a safety backup of the CURRENT state first, so a bad restore
        is itself reversible, then imports and verifies.
    .OUTPUTS
        [pscustomobject] @{ Success; SafetyBackupPath; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$BackupFilePath,

        [Parameter(Mandatory)]
        [string]$TargetPath
    )
    if (-not (Test-Path -LiteralPath $BackupFilePath)) {
        return [pscustomobject]@{ Success = $false; SafetyBackupPath = $null; Error = "Backup file not found: $BackupFilePath" }
    }
    if (-not $PSCmdlet.ShouldProcess($TargetPath, "Restore from $BackupFilePath")) {
        return [pscustomobject]@{ Success = $false; SafetyBackupPath = $null; Error = 'Cancelled (ShouldProcess).' }
    }

    $safety = Backup-KFRegistryKey -Path $TargetPath -Label "prerestore_$(Split-Path -Leaf $TargetPath)"
    if (-not $safety.Success -and (Test-KFRegistryKeyExists -Path $TargetPath)) {
        return [pscustomobject]@{ Success = $false; SafetyBackupPath = $null; Error = "Refusing to restore without a pre-restore safety backup: $($safety.Error)" }
    }

    $importResult = Import-KFRegFile -SourcePath $BackupFilePath
    [pscustomobject]@{
        Success          = $importResult.Success
        SafetyBackupPath = $safety.BackupPath
        Error            = $importResult.Error
    }
}

function Get-KFRegistrySize {
    <#
    .SYNOPSIS
        Approximates the "size" of a registry subtree as (subkey count,
        value count, total string-representable value bytes). Not a byte-
        exact hive size - Windows doesn't expose one per-subtree - but a
        useful relative measure for backup/diagnostics display.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $outcome = Invoke-KFSafe -Context "Get-KFRegistrySize:$Path" -Silent -Action {
        $keys = @(Get-ChildItem -LiteralPath $Path -Recurse -ErrorAction Stop)
        $valueCount = 0
        $byteEstimate = 0L
        foreach ($k in (@($Path) + @($keys.PSPath))) {
            try {
                $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
                $names = @($props.PSObject.Properties.Name | Where-Object { $_ -notmatch '^PS(Path|ParentPath|ChildName|Provider|Drive)$' })
                $valueCount += $names.Count
                foreach ($n in $names) {
                    $v = $props.$n
                    $byteEstimate += [System.Text.Encoding]::Unicode.GetByteCount([string]$v)
                }
            } catch { continue }
        }
        [pscustomobject]@{ SubkeyCount = $keys.Count; ValueCount = $valueCount; EstimatedBytes = $byteEstimate }
    }
    if ($outcome.Success) { return $outcome.Result }
    [pscustomobject]@{ SubkeyCount = 0; ValueCount = 0; EstimatedBytes = 0L }
}

#endregion ==================================================================

#region ============================== KEYBOARD MANAGER (SAFE SUBSET) ==========
#
# Add/Remove/Replace/Duplicate keyboard layout and ghost-layout repair need
# the full Keyboard Manager module (next phase - they touch IME registration
# and orphan cleanup, which deserve dedicated review). Reordering which
# ALREADY-INSTALLED layout loads first is pure Preload-list registry work
# with no IME/capability risk, so it's safe to ship now.
#

function Set-KFDefaultKeyboard {
    <#
    .SYNOPSIS
        Makes an already-loaded keyboard layout the default (Preload entry
        "1") for the current user, shifting the others down by one slot.
        Only reorders layouts already in the user's Preload list - it does
        not add a new layout (that's Add-KeyboardLayout, next phase).
    .OUTPUTS
        [pscustomobject] @{ Success; BackupPath; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$KLID
    )
    if (-not (Test-KFKlidFormat -Klid $KLID)) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = "'$KLID' is not a valid 8-character hex KLID." }
    }

    $current = @(Get-KFInstalledKeyboards -Force)
    $target = $current | Where-Object { $_.KLID -eq $KLID } | Select-Object -First 1
    if (-not $target) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = "KLID '$KLID' was not found among installed layouts." }
    }
    if (-not $target.Loaded) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = "'$($target.Name)' is installed but not loaded for the current user - loading a new layout is a Phase 3.4 (Add-KeyboardLayout) operation, not a reorder." }
    }
    if ($target.PreloadOrder -eq 1) {
        return [pscustomobject]@{ Success = $true; BackupPath = $null; Error = "'$($target.Name)' is already the default." }
    }
    if (-not $PSCmdlet.ShouldProcess('Preload', "Make '$($target.Name)' ($KLID) the default keyboard")) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = 'Cancelled (ShouldProcess).' }
    }

    $backup = Backup-KFRegistryKey -Path $Script:RegistryPaths.Preload -Label 'preload'
    if (-not $backup.Success) {
        return [pscustomobject]@{ Success = $false; BackupPath = $null; Error = "Refusing to reorder without a successful backup: $($backup.Error)" }
    }

    $outcome = Invoke-KFSafe -Context 'Set-KFDefaultKeyboard' -Action {
        # Rebuild the ordered list with $KLID first, everything else
        # following in its existing relative order, renumbered 1..N.
        $loaded = @($current | Where-Object { $_.Loaded } | Sort-Object PreloadOrder)
        $reordered = @($target) + @($loaded | Where-Object { $_.KLID -ne $KLID })

        for ($i = 0; $i -lt $reordered.Count; $i++) {
            $slot = ($i + 1).ToString()
            Set-ItemProperty -LiteralPath $Script:RegistryPaths.Preload -Name $slot -Value $reordered[$i].KLID -Type String -ErrorAction Stop
        }
    }

    Clear-KFCache -Prefix 'kbd:'
    Clear-KFCache -Prefix 'dashboard:'
    [pscustomobject]@{ Success = $outcome.Success; BackupPath = $backup.BackupPath; Error = $outcome.Error }
}

#endregion ==================================================================

#region ============================== REGION & LOCALE MODULE (WRITE) ==========

function Get-KFAvailableRegions {
    <#
    .SYNOPSIS
        All GeoIDs/region names .NET knows about, for the region picker.
    #>
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'region:available' -TtlSeconds 3600 -Action {
        $outcome = Invoke-KFSafe -Context 'Get-KFAvailableRegions' -Silent -Action {
            [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures) |
                Where-Object { $_.Name -match '-' } |
                ForEach-Object {
                    try {
                        $ri = [System.Globalization.RegionInfo]::new($_.Name)
                        [pscustomobject]@{ GeoId = $ri.GeoId; Name = $ri.EnglishName; TwoLetterCode = $ri.TwoLetterISORegionName }
                    } catch { $null }
                } | Where-Object { $_ } | Sort-Object Name -Unique
        }
        if ($outcome.Success) { $outcome.Result } else { @() }
    }
}

function Set-KFRegion {
    <#
    .SYNOPSIS
        Sets the current user's home location (region) by GeoID, via the
        real Set-WinHomeLocation cmdlet - no registry surgery needed here,
        which is why this doesn't go through Backup-KFRegistryKey: the
        cmdlet itself is the safe, supported, atomic way to make this change.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [int]$GeoId
    )
    if (-not $PSCmdlet.ShouldProcess('User home location', "Set GeoID to $GeoId")) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context 'Set-KFRegion' -Action {
        Set-WinHomeLocation -GeoId $GeoId -ErrorAction Stop
    }
    Clear-KFCache -Prefix 'region:'
    Clear-KFCache -Prefix 'dashboard:'
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

function Set-KFSystemLocale {
    <#
    .SYNOPSIS
        Sets the system locale (used for non-Unicode program language) via
        Set-WinSystemLocale. This is a machine-wide setting and typically
        requires a restart to fully take effect - callers should say so.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    $normalized = Test-KFLanguageTagFormat -Tag $LanguageTag
    if (-not $normalized) {
        return [pscustomobject]@{ Success = $false; RequiresRestart = $false; Error = "'$LanguageTag' is not a recognizable language tag." }
    }
    if (-not (Test-KFAdminPrivileges)) {
        return [pscustomobject]@{ Success = $false; RequiresRestart = $false; Error = 'Changing the system locale requires an elevated (Run as Administrator) session.' }
    }
    if (-not $PSCmdlet.ShouldProcess('System locale', "Set to $normalized")) {
        return [pscustomobject]@{ Success = $false; RequiresRestart = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context 'Set-KFSystemLocale' -Action {
        Set-WinSystemLocale -SystemLocale $normalized -ErrorAction Stop
    }
    Clear-KFCache -Prefix 'locale:'
    Clear-KFCache -Prefix 'dashboard:'
    [pscustomobject]@{ Success = $outcome.Success; RequiresRestart = $outcome.Success; Error = $outcome.Error }
}

function Set-KFUserLocale {
    <#
    .SYNOPSIS
        Sets the per-user locale (formats: dates, times, numbers, currency)
        via Set-Culture. Takes effect for new processes/after sign-out,
        immediately for KeyForge's own subsequent reads.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    $normalized = Test-KFLanguageTagFormat -Tag $LanguageTag
    if (-not $normalized) {
        return [pscustomobject]@{ Success = $false; Error = "'$LanguageTag' is not a recognizable language tag." }
    }
    if (-not $PSCmdlet.ShouldProcess('User locale (formats)', "Set to $normalized")) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context 'Set-KFUserLocale' -Action {
        Set-Culture -CultureInfo $normalized -ErrorAction Stop
    }
    Clear-KFCache -Prefix 'locale:'
    Clear-KFCache -Prefix 'region:'
    Clear-KFCache -Prefix 'dashboard:'
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

function Set-KFDisplayLanguage {
    <#
    .SYNOPSIS
        Sets the UI display language for the current user. Deliberately
        restricted to languages ALREADY present in the user's language list
        (matches the original spec: "Only safe if installed") - installing a
        new display language is a Language Manager (Phase 3, next pass)
        operation, not this function's job.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    $normalized = Test-KFLanguageTagFormat -Tag $LanguageTag
    if (-not $normalized) {
        return [pscustomobject]@{ Success = $false; Error = "'$LanguageTag' is not a recognizable language tag." }
    }
    $userLangs = @(Get-KFUserLanguages)
    $match = $userLangs | Where-Object { $_.LanguageTag -eq $normalized } | Select-Object -First 1
    if (-not $match) {
        return [pscustomobject]@{ Success = $false; Error = "'$normalized' is not in the current user's language list. Installing a new display language isn't available in this build - see 'Install New Language' in the menu for its status." }
    }
    if (-not $PSCmdlet.ShouldProcess('Display language', "Set to $normalized")) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }

    $outcome = Invoke-KFSafe -Context 'Set-KFDisplayLanguage' -Action {
        $list = Get-WinUserLanguageList -ErrorAction Stop
        $entry = $list | Where-Object { $_.LanguageTag -eq $normalized } | Select-Object -First 1
        if (-not $entry) { throw [OperationFailedException]::new("'$normalized' disappeared from the language list between check and apply.") }
        # Move the target language to the front of the list - the first
        # entry in a Set-WinUserLanguageList call becomes the display language.
        $reordered = @($entry) + @($list | Where-Object { $_.LanguageTag -ne $normalized })
        Set-WinUserLanguageList -LanguageList $reordered -Force -ErrorAction Stop
    }
    Clear-KFCache -Prefix 'lang:'
    Clear-KFCache -Prefix 'locale:'
    Clear-KFCache -Prefix 'dashboard:'
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

function Set-KFTimeZone {
    <#
    .SYNOPSIS
        Sets the system time zone via the real Set-TimeZone cmdlet.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )
    if (-not (Test-KFAdminPrivileges)) {
        return [pscustomobject]@{ Success = $false; Error = 'Changing the time zone requires an elevated (Run as Administrator) session.' }
    }
    if (-not $PSCmdlet.ShouldProcess('System time zone', "Set to $Id")) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context 'Set-KFTimeZone' -Action {
        Set-TimeZone -Id $Id -ErrorAction Stop
    }
    Clear-KFCache -Prefix 'tz:'
    Clear-KFCache -Prefix 'dashboard:'
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

function Get-KFAvailableTimeZones {
    [CmdletBinding()]
    param()
    Get-KFCached -Key 'tz:available' -TtlSeconds 3600 -Action {
        $outcome = Invoke-KFSafe -Context 'Get-KFAvailableTimeZones' -Silent -Action { Get-TimeZone -ListAvailable -ErrorAction Stop }
        if ($outcome.Success) {
            @($outcome.Result | ForEach-Object { [pscustomobject]@{ Id = $_.Id; DisplayName = $_.DisplayName } } | Sort-Object DisplayName)
        } else { @() }
    }
}

function Set-KFRegionalFormat {
    <#
    .SYNOPSIS
        Sets one custom format override (short date / long date / short
        time / decimal separator / thousands separator) for the current
        user via the documented Control Panel\International registry
        values .NET's CultureInfo reads from. Each change is backed up
        through Set-KFRegValue automatically.
    .PARAMETER Field
        One of: ShortDate, LongDate, TimeFormat, DecimalSeparator, ThousandsSeparator
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ShortDate', 'LongDate', 'TimeFormat', 'DecimalSeparator', 'ThousandsSeparator')]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$Value
    )
    $valueName = switch ($Field) {
        'ShortDate'          { 'sShortDate' }
        'LongDate'           { 'sLongDate' }
        'TimeFormat'         { 'sTimeFormat' }
        'DecimalSeparator'   { 'sDecimal' }
        'ThousandsSeparator' { 'sThousand' }
    }
    if (-not $PSCmdlet.ShouldProcess("International\$valueName", "Set to '$Value'")) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $result = Set-KFRegValue -Path $Script:RegistryPaths.IntlUserProfile -Name $valueName -Value $Value -Type String
    Clear-KFCache -Prefix 'region:detail'
    Clear-KFCache -Prefix 'locale:'
    [pscustomobject]@{ Success = $result.Success; PreviousValue = $result.PreviousValue; BackupPath = $result.BackupPath; Error = $result.Error }
}

#endregion ==================================================================

#region ============================== BACKUP & RESTORE MODULE =================
#
# A KeyForge "backup" is a folder under Backups\<id>\ containing:
#   manifest.json          - what's inside, when, KeyForge version, checksums
#   registry\*.reg          - one .reg export per protected subtree
#   state.json              - JSON snapshot of languages/keyboards/region/locale
#     (read-only data straight from the Phase 1/2 query layer, so it's
#      always accurate to what Get-KFAllInstalledLanguages etc. would show)
#
# Restoring language INSTALL state (installing missing / removing unwanted
# languages to match a snapshot) needs Install-Language/Remove-Language from
# the Language Manager module (next phase) and is flagged as such below -
# everything else in a snapshot (registry subtrees, keyboard preload order,
# region/locale/timezone settings) restores fully today.
#

$Script:BackupRegistryTargets = [ordered]@{
    KeyboardLayouts  = $Script:RegistryPaths.KeyboardLayouts
    Preload          = $Script:RegistryPaths.Preload
    Substitutes      = $Script:RegistryPaths.Substitutes
    ToggleKeys       = $Script:RegistryPaths.ToggleKeys
    IntlUserProfile  = $Script:RegistryPaths.IntlUserProfile
}

function Get-KFFileHashSafe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $outcome = Invoke-KFSafe -Context 'Get-KFFileHashSafe' -Silent -Action {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    if ($outcome.Success) { return $outcome.Result }
    return $null
}

function New-KFBackup {
    <#
    .SYNOPSIS
        Creates a new, empty, timestamped backup container and returns its
        paths. Internal primitive used by Backup-KFSystemState.
    #>
    [CmdletBinding()]
    param(
        [string]$Note = ''
    )
    $id = "backup_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $root = Join-Path $Script:Paths.Backups $id
    $regDir = Join-Path $root 'registry'
    New-Item -ItemType Directory -Path $regDir -Force -ErrorAction Stop | Out-Null
    [pscustomobject]@{
        Id           = $id
        RootPath     = $root
        RegistryPath = $regDir
        ManifestPath = Join-Path $root 'manifest.json'
        StatePath    = Join-Path $root 'state.json'
        Note         = $Note
    }
}

function Backup-KFSystemState {
    <#
    .SYNOPSIS
        Full KeyForge backup: exports every protected registry subtree and
        snapshots current language/keyboard/region/locale/timezone state,
        writing a manifest with per-file SHA-256 checksums for later
        integrity verification.
    .OUTPUTS
        [pscustomobject] @{ Success; BackupId; Path; Error }
    #>
    [CmdletBinding()]
    param(
        [string]$Note = ''
    )
    $container = New-KFBackup -Note $Note
    $registryResults = [ordered]@{}
    $allOk = $true

    foreach ($key in $Script:BackupRegistryTargets.Keys) {
        $dest = Join-Path $container.RegistryPath "$key.reg"
        $result = Export-KFRegKey -Path $Script:BackupRegistryTargets[$key] -DestinationPath $dest
        $registryResults[$key] = [ordered]@{
            Path   = $(if ($result.Success -and $result.DestinationPath) { "registry\$key.reg" } else { $null })
            Sha256 = $(if ($result.Success -and $result.DestinationPath) { Get-KFFileHashSafe -Path $result.DestinationPath } else { $null })
            Error  = $result.Error
        }
        if (-not $result.Success) { $allOk = $false }
    }

    $stateOutcome = Invoke-KFSafe -Context 'Backup-KFSystemState:state' -Action {
        [pscustomobject]@{
            CapturedAt = (Get-Date).ToString('u')
            Languages  = Get-KFAllInstalledLanguages -Force
            Keyboards  = Get-KFInstalledKeyboards -Force
            Region     = Get-KFRegionDetail
            Locale     = Get-KFLocaleInfo
            TimeZone   = Get-KFTimeZoneInfo
        }
    }
    if ($stateOutcome.Success) {
        try {
            ($stateOutcome.Result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $container.StatePath -Encoding UTF8 -ErrorAction Stop
        } catch {
            $allOk = $false
            Write-ExceptionLog -ErrorRecord $_ -Context 'Backup-KFSystemState:state-write'
        }
    } else {
        $allOk = $false
    }
    $stateHash = if (Test-Path -LiteralPath $container.StatePath) { Get-KFFileHashSafe -Path $container.StatePath } else { $null }

    $manifest = [ordered]@{
        BackupId       = $container.Id
        CreatedAt      = (Get-Date).ToString('u')
        KeyForgeVersion = $Script:Meta.Version
        Note           = $Note
        Registry       = $registryResults
        State          = [ordered]@{ Path = 'state.json'; Sha256 = $stateHash }
        AllComponentsOk = $allOk
    }
    try {
        ($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $container.ManifestPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-ExceptionLog -ErrorRecord $_ -Context 'Backup-KFSystemState:manifest-write'
        return [pscustomobject]@{ Success = $false; BackupId = $container.Id; Path = $container.RootPath; Error = "Could not write manifest: $($_.Exception.Message)" }
    }

    Write-LogEntry -Level 'Info' -Message "Backup '$($container.Id)' created (allComponentsOk=$allOk) at $($container.RootPath)"
    [pscustomobject]@{ Success = $allOk; BackupId = $container.Id; Path = $container.RootPath; Error = $(if (-not $allOk) { 'One or more components failed - see manifest.json for details.' } else { $null }) }
}

function Get-KFBackupList {
    <#
    .SYNOPSIS
        Lists available backups (newest first) with manifest metadata.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $Script:Paths.Backups)) { return @() }

    $entries = [System.Collections.Generic.List[pscustomobject]]::new()
    $dirs = Get-ChildItem -LiteralPath $Script:Paths.Backups -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        $manifestPath = Join-Path $dir.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        $parsed = Invoke-KFSafe -Context "Get-KFBackupList:$($dir.Name)" -Silent -Action {
            Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        }
        if (-not $parsed.Success) { continue }
        $size = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $entries.Add([pscustomobject]@{
            BackupId  = $parsed.Result.BackupId
            Path      = $dir.FullName
            CreatedAt = $parsed.Result.CreatedAt
            Note      = $parsed.Result.Note
            AllOk     = $parsed.Result.AllComponentsOk
            SizeBytes = $(if ($size) { $size } else { 0 })
            Manifest  = $parsed.Result
        })
    }
    return @($entries | Sort-Object CreatedAt -Descending)
}

function Test-KFBackupIntegrity {
    <#
    .SYNOPSIS
        Re-hashes every file listed in a backup's manifest and compares
        against the recorded SHA-256, catching truncated/corrupted backups
        before a restore is attempted.
    .OUTPUTS
        [pscustomobject] @{ Valid; Issues }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath
    )
    $manifestPath = Join-Path $BackupPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return [pscustomobject]@{ Valid = $false; Issues = @('manifest.json is missing.') }
    }
    $manifest = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $manifest.Registry.PSObject.Properties.Name) {
        $entry = $manifest.Registry.$key
        if ($null -eq $entry.Path) { continue }  # component legitimately absent (e.g. key didn't exist)
        $full = Join-Path $BackupPath $entry.Path
        if (-not (Test-Path -LiteralPath $full)) {
            $issues.Add("Missing file for '$key': $($entry.Path)")
            continue
        }
        $actualHash = Get-KFFileHashSafe -Path $full
        if ($actualHash -ne $entry.Sha256) {
            $issues.Add("Checksum mismatch for '$key' - file may be corrupted or was modified after backup.")
        }
    }
    if ($manifest.State.Path) {
        $statePath = Join-Path $BackupPath $manifest.State.Path
        if (-not (Test-Path -LiteralPath $statePath)) {
            $issues.Add('Missing state.json.')
        } elseif ((Get-KFFileHashSafe -Path $statePath) -ne $manifest.State.Sha256) {
            $issues.Add('Checksum mismatch for state.json.')
        }
    }
    [pscustomobject]@{ Valid = ($issues.Count -eq 0); Issues = @($issues) }
}

function Restore-KFSystemState {
    <#
    .SYNOPSIS
        Restores registry subtrees from a backup. Verifies integrity first,
        takes a fresh safety backup of current state before touching
        anything, restores each component, and reports per-component
        results so a partial failure is visible rather than silent.
    .OUTPUTS
        [pscustomobject] @{ Success; SafetyBackupId; Results; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath
    )
    $integrity = Test-KFBackupIntegrity -BackupPath $BackupPath
    if (-not $integrity.Valid) {
        return [pscustomobject]@{ Success = $false; SafetyBackupId = $null; Results = @(); Error = "Backup failed integrity check: $($integrity.Issues -join '; ')" }
    }
    if (-not $PSCmdlet.ShouldProcess($BackupPath, 'Restore system state from backup')) {
        return [pscustomobject]@{ Success = $false; SafetyBackupId = $null; Results = @(); Error = 'Cancelled (ShouldProcess).' }
    }

    $safety = Backup-KFSystemState -Note "Automatic pre-restore safety backup (before restoring from $(Split-Path -Leaf $BackupPath))"
    if (-not $safety.Success) {
        return [pscustomobject]@{ Success = $false; SafetyBackupId = $null; Results = @(); Error = "Refusing to restore without a successful pre-restore safety backup: $($safety.Error)" }
    }

    $manifest = (Get-Content -LiteralPath (Join-Path $BackupPath 'manifest.json') -Raw | ConvertFrom-Json)
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $allOk = $true

    foreach ($key in $manifest.Registry.PSObject.Properties.Name) {
        $entry = $manifest.Registry.$key
        if ($null -eq $entry.Path) {
            $results.Add([pscustomobject]@{ Component = $key; Success = $true; Detail = 'Not present in backup - skipped.' })
            continue
        }
        if (-not $Script:BackupRegistryTargets.Contains($key)) {
            $results.Add([pscustomobject]@{ Component = $key; Success = $false; Detail = 'Unknown component - no known target path, skipped for safety.' })
            $allOk = $false
            continue
        }
        $fullBackupFile = Join-Path $BackupPath $entry.Path
        $restoreResult = Restore-KFRegistryKey -BackupFilePath $fullBackupFile -TargetPath $Script:BackupRegistryTargets[$key] -Confirm:$false
        $results.Add([pscustomobject]@{ Component = $key; Success = $restoreResult.Success; Detail = $(if ($restoreResult.Success) { 'Restored.' } else { $restoreResult.Error }) })
        if (-not $restoreResult.Success) { $allOk = $false }
    }

    Clear-KFCache
    Write-LogEntry -Level 'Info' -Message "Restore from '$BackupPath' completed (allOk=$allOk); safety backup='$($safety.BackupId)'"
    [pscustomobject]@{ Success = $allOk; SafetyBackupId = $safety.BackupId; Results = @($results); Error = $(if (-not $allOk) { 'One or more components failed to restore - see Results.' } else { $null }) }
}

function Remove-KFBackup {
    <#
    .SYNOPSIS
        Deletes a backup folder. Does not itself prompt - the calling
        screen is responsible for confirming with the user first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath
    )
    if (-not $BackupPath.StartsWith($Script:Paths.Backups, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Success = $false; Error = 'Refusing to delete a path outside the KeyForge Backups folder.' }
    }
    if (-not $PSCmdlet.ShouldProcess($BackupPath, 'Delete backup')) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context 'Remove-KFBackup' -Action {
        Remove-Item -LiteralPath $BackupPath -Recurse -Force -ErrorAction Stop
    }
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
}

#endregion ==================================================================

#region ============================== LANGUAGE MANAGER: VALIDATION ============
#
# Scoping note vs. the original spec: Forced/Nuclear removal originally also
# listed removing event log entries, crash dumps, and performance counters.
# Those aren't really language-management operations - they're general
# system-maintenance actions with their own dedicated tools, unrelated to a
# specific language tag, and touching them generically risks deleting
# unrelated diagnostic data for no real benefit. They're left out here for
# the same reason raw WinSxS manipulation was left out: the risk isn't
# justified by what it actually buys you. "Nuclear" is renamed "Complete"
# below to describe what it actually does rather than imply more than that.
#

function Test-KFLanguageKnownToWindows {
    <#
    .SYNOPSIS
        Confirms .NET/Windows recognizes a language tag as a real culture,
        catching typos before any DISM operation is attempted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($LanguageTag)
        return (-not $culture.IsNeutralCulture) -and ($culture.Name -ne '')
    } catch {
        return $false
    }
}

function Test-KFLanguageInstalled {
    <#
    .SYNOPSIS
        Checks whether a language tag is currently installed, either for the
        current user or (optionally) as a system capability.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    $userLangs = @(Get-KFUserLanguages)
    if ($userLangs | Where-Object { $_.LanguageTag -eq $LanguageTag }) { return $true }
    $all = @(Get-KFAllInstalledLanguages)
    return [bool]($all | Where-Object { $_.LanguageTag -eq $LanguageTag -and $_.Basic })
}

function Test-KFLanguageCanBeRemoved {
    <#
    .SYNOPSIS
        Safety gate checked before ANY removal tier runs. Blocks removing
        the last remaining language outright; flags (but doesn't block -
        the caller decides) removing the current display/system locale.
    .OUTPUTS
        [pscustomobject] @{ CanRemove; Blockers; Warnings }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    $blockers = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $userLangs = @(Get-KFUserLanguages -Force)
    if ($userLangs.Count -le 1 -and ($userLangs | Where-Object { $_.LanguageTag -eq $LanguageTag })) {
        $blockers.Add("'$LanguageTag' is the only language in the current user's language list - Windows requires at least one.")
    }

    $locale = Get-KFLocaleInfo
    if ($locale.DisplayLang -eq $LanguageTag) {
        $warnings.Add("'$LanguageTag' is the current display language. Removing it will change what language Windows menus and dialogs show.")
    }
    if ($locale.SystemLocale -eq $LanguageTag) {
        $warnings.Add("'$LanguageTag' is the current system locale (used by non-Unicode programs).")
    }

    [pscustomobject]@{
        CanRemove = ($blockers.Count -eq 0)
        Blockers  = @($blockers)
        Warnings  = @($warnings)
    }
}

#endregion ==================================================================

#region ============================== LANGUAGE MANAGER: DISCOVERY =============

function Get-KFCapabilityName {
    <#
    .SYNOPSIS
        Resolves the EXACT, currently-valid DISM capability name (including
        its version suffix, which varies by OS build and can't be safely
        hardcoded) for a given feature + language tag, by asking DISM for
        it directly rather than guessing.
    .PARAMETER Feature
        One of: Basic, OCR, Handwriting, Speech, TextToSpeech
    .OUTPUTS
        [string] the full capability name, or $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Basic', 'OCR', 'Handwriting', 'Speech', 'TextToSpeech')]
        [string]$Feature,

        [Parameter(Mandatory)]
        [string]$LanguageTag
    )
    $cacheKey = "capname:$Feature:$LanguageTag"
    Get-KFCached -Key $cacheKey -TtlSeconds 300 -Action {
        $outcome = Invoke-KFSafe -Context 'Get-KFCapabilityName' -Silent -Action {
            Get-WindowsCapability -Online -Name "Language.$Feature~~~$LanguageTag~*" -ErrorAction Stop
        }
        if ($outcome.Success -and $outcome.Result) {
            $match = @($outcome.Result) | Select-Object -First 1
            $match.Name
        } else {
            $null
        }
    }
}

function Get-KFLanguageRemovalImpact {
    <#
    .SYNOPSIS
        Preview-only: reports what a removal at the given tier WOULD affect,
        without changing anything. Used by the UI to show an accurate "here's
        what will happen" list before the user confirms.
    .OUTPUTS
        [pscustomobject] @{ Capabilities; Keyboards; Safety }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag,

        [Parameter(Mandatory)]
        [ValidateSet('Normal', 'Deep', 'Forced', 'Complete')]
        [string]$Tier
    )
    $safety = Test-KFLanguageCanBeRemoved -LanguageTag $LanguageTag

    $features = if ($Tier -eq 'Normal') { @('Basic') } else { @('Basic', 'OCR', 'Handwriting', 'Speech', 'TextToSpeech') }
    $capabilities = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $features) {
        $name = Get-KFCapabilityName -Feature $f -LanguageTag $LanguageTag
        if ($name) { $capabilities.Add($name) }
    }

    # A keyboard is flagged as affected if its associated language tag
    # matches the one being removed. (With one tag removed per call, that
    # tag can't remain in the user's language list afterward, so no extra
    # "is it still needed elsewhere" check is needed here.)
    $allKeyboards = @(Get-KFInstalledKeyboards -Force)
    $affectedKeyboards = @($allKeyboards | Where-Object { $_.LanguageTag -eq $LanguageTag })

    [pscustomobject]@{
        Capabilities = @($capabilities)
        Keyboards    = $affectedKeyboards
        Safety       = $safety
    }
}

#endregion ==================================================================

#region ============================== LANGUAGE MANAGER: INSTALLATION ==========
#
# Two install paths, chosen automatically based on what the running OS
# supports:
#   - Install-Language (LanguagePackManagement module): the modern, one-step
#     path that installs the full language experience pack. Only present on
#     newer Windows 11 builds - detected at runtime, never assumed.
#   - Add-WindowsCapability (DISM): the universal fallback available on
#     everything KeyForge claims to support back to Windows 10 1909. Installs
#     Basic plus whichever optional features are requested, then adds the
#     language to the user's language list.
#

function Install-KFLanguage {
    <#
    .SYNOPSIS
        Installs a language pack for the current user, with pre-flight
        validation (tag format, not already installed, admin, connectivity)
        and a backup taken before any change.
    .PARAMETER Features
        Additional features to install alongside Basic: any of OCR,
        Handwriting, Speech, TextToSpeech. Basic is always included.
    .OUTPUTS
        [pscustomobject] @{ Success; Method; InstalledFeatures; BackupId; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag,

        [ValidateSet('OCR', 'Handwriting', 'Speech', 'TextToSpeech')]
        [string[]]$Features = @(),

        [switch]$SetAsDisplayLanguage
    )
    $fail = { param($msg) [pscustomobject]@{ Success = $false; Method = $null; InstalledFeatures = @(); BackupId = $null; Error = $msg } }

    $normalized = Test-KFLanguageTagFormat -Tag $LanguageTag
    if (-not $normalized) { return & $fail "'$LanguageTag' is not a valid BCP-47 language tag." }
    if (-not (Test-KFLanguageKnownToWindows -LanguageTag $normalized)) { return & $fail "'$normalized' is not a language/region combination Windows recognizes." }
    if (Test-KFLanguageInstalled -LanguageTag $normalized) { return & $fail "'$normalized' is already installed." }
    if (-not (Test-KFAdminPrivileges)) { return & $fail 'Installing a language requires an elevated (Run as Administrator) session.' }
    if (-not (Test-KFOnline)) { return & $fail 'Installing a language pack needs internet access (it downloads from Windows Update) and none was detected.' }
    if (-not $PSCmdlet.ShouldProcess($normalized, 'Install language')) { return & $fail 'Cancelled (ShouldProcess).' }

    $backup = Backup-KFSystemState -Note "Automatic pre-install backup (before installing $normalized)"
    if (-not $backup.Success) { return & $fail "Refusing to install without a successful backup: $($backup.Error)" }

    $installed = [System.Collections.Generic.List[string]]::new()
    $method = $null

    if (Test-KFCommandExists -Name 'Install-Language') {
        $result = Invoke-KFSafe -Context 'Install-KFLanguage:Install-Language' -Action {
            Install-Language -Language $normalized -ErrorAction Stop
        }
        if ($result.Success) {
            $method = 'Install-Language'
            $installed.Add('Basic')
            foreach ($f in $Features) { $installed.Add($f) }  # Install-Language installs the full LXP in one step
        }
    }

    if (-not $method) {
        # Fallback: DISM capability-by-capability.
        $basicName = Get-KFCapabilityName -Feature 'Basic' -LanguageTag $normalized
        if (-not $basicName) { return & $fail "Windows doesn't list a Basic language capability for '$normalized' - it may not be installable via Windows Update on this system." }

        $basicResult = Invoke-KFSafe -Context 'Install-KFLanguage:AddCapability:Basic' -Action {
            Add-WindowsCapability -Online -Name $basicName -ErrorAction Stop
        }
        if (-not $basicResult.Success) { return & $fail "Failed to install the Basic language pack: $($basicResult.Error)" }
        $method = 'DISM'
        $installed.Add('Basic')

        foreach ($feature in $Features) {
            $capName = Get-KFCapabilityName -Feature $feature -LanguageTag $normalized
            if (-not $capName) {
                Write-LogEntry -Level 'Warning' -Message "No '$feature' capability found for '$normalized' - skipped."
                continue
            }
            $featResult = Invoke-KFSafe -Context "Install-KFLanguage:AddCapability:$feature" -Action {
                Add-WindowsCapability -Online -Name $capName -ErrorAction Stop
            }
            if ($featResult.Success) { $installed.Add($feature) }
            else { Write-LogEntry -Level 'Warning' -Message "Failed to install '$feature' for '$normalized': $($featResult.Error)" }
        }

        # Add to the user's language list so it's actually usable, not just
        # present in the capability store. Working with plain tag strings
        # (rather than trying to .Add() onto the collection
        # Get-WinUserLanguageList returns, which becomes a fixed-size array
        # once wrapped for safe iteration) avoids any ambiguity about the
        # underlying object type - Set-WinUserLanguageList accepts tags.
        $listResult = Invoke-KFSafe -Context 'Install-KFLanguage:UserLanguageList' -Action {
            $currentTags = @(Get-WinUserLanguageList -ErrorAction Stop | ForEach-Object { $_.LanguageTag })
            if ($currentTags -notcontains $normalized) {
                $newTags = $currentTags + $normalized
                Set-WinUserLanguageList -LanguageList $newTags -Force -ErrorAction Stop
            }
        }
        if (-not $listResult.Success) {
            Write-LogEntry -Level 'Warning' -Message "Language pack installed but could not be added to the user language list: $($listResult.Error)"
        }
    }

    Clear-KFCache -Prefix 'lang:'
    Clear-KFCache -Prefix 'capname:'
    Clear-KFCache -Prefix 'dashboard:'

    $verified = Test-KFLanguageInstalled -LanguageTag $normalized
    if (-not $verified) {
        return [pscustomobject]@{ Success = $false; Method = $method; InstalledFeatures = @($installed); BackupId = $backup.BackupId; Error = 'Installation commands completed without error, but the language does not verify as installed afterward.' }
    }

    if ($SetAsDisplayLanguage) {
        $displayResult = Set-KFDisplayLanguage -LanguageTag $normalized -Confirm:$false
        if (-not $displayResult.Success) {
            Write-LogEntry -Level 'Warning' -Message "Installed '$normalized' but could not set it as display language: $($displayResult.Error)"
        }
    }

    Write-LogEntry -Level 'Info' -Message "Installed language '$normalized' via $method (features: $($installed -join ', '))"
    [pscustomobject]@{ Success = $true; Method = $method; InstalledFeatures = @($installed); BackupId = $backup.BackupId; Error = $null }
}

function Install-KFLanguageFeature {
    <#
    .SYNOPSIS
        Installs one additional feature (OCR/Handwriting/Speech/TextToSpeech)
        for an already-installed language.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag,

        [Parameter(Mandatory)]
        [ValidateSet('OCR', 'Handwriting', 'Speech', 'TextToSpeech')]
        [string]$Feature
    )
    if (-not (Test-KFLanguageInstalled -LanguageTag $LanguageTag)) {
        return [pscustomobject]@{ Success = $false; Error = "'$LanguageTag' is not installed - install the language itself first." }
    }
    if (-not (Test-KFAdminPrivileges)) {
        return [pscustomobject]@{ Success = $false; Error = 'Installing a language feature requires an elevated (Run as Administrator) session.' }
    }
    $capName = Get-KFCapabilityName -Feature $Feature -LanguageTag $LanguageTag
    if (-not $capName) {
        return [pscustomobject]@{ Success = $false; Error = "No '$Feature' capability is available for '$LanguageTag' on this system." }
    }
    if (-not $PSCmdlet.ShouldProcess("$LanguageTag/$Feature", 'Install language feature')) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }

    $result = Invoke-KFSafe -Context "Install-KFLanguageFeature:$Feature" -Action {
        Add-WindowsCapability -Online -Name $capName -ErrorAction Stop
    }
    Clear-KFCache -Prefix 'lang:'
    Clear-KFCache -Prefix 'capname:'
    [pscustomobject]@{ Success = $result.Success; Error = $result.Error }
}

#endregion ==================================================================

#region ============================== LANGUAGE MANAGER: REMOVAL (TIERED) ======

function Remove-KFLanguage {
    <#
    .SYNOPSIS
        Tiered language removal. Every tier backs up first, checks
        Test-KFLanguageCanBeRemoved, and returns a per-step result list so a
        partial failure is visible rather than silent.
    .PARAMETER Tier
        Normal  - remove from the user's language list; remove the Basic
                  capability if DISM is available.
        Deep    - Normal, plus remove OCR/Handwriting/Speech/TextToSpeech
                  capabilities and clear MUI cache entries for the tag.
        Forced  - Deep, plus clean lingering registry references to the tag
                  across the paths KeyForge knows about, and remove keyboard
                  layouts exclusively tied to this language.
        Complete - Forced, plus an OPT-IN, clearly-separate offer to run
                  Windows' own supported component-store cleanup
                  (DISM /StartComponentCleanup). That's a system-wide
                  operation, not specific to this language, so it's never
                  run silently as a side effect - see
                  Invoke-KFComponentCleanup, called separately by the UI.
    .OUTPUTS
        [pscustomobject] @{ Success; Tier; Steps; BackupId; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LanguageTag,

        [Parameter(Mandatory)]
        [ValidateSet('Normal', 'Deep', 'Forced', 'Complete')]
        [string]$Tier
    )
    $steps = [System.Collections.Generic.List[pscustomobject]]::new()
    function Add-KFStep([string]$Name, [bool]$Ok, [string]$Detail) {
        $steps.Add([pscustomobject]@{ Step = $Name; Success = $Ok; Detail = $Detail })
    }

    $normalized = Test-KFLanguageTagFormat -Tag $LanguageTag
    if (-not $normalized) {
        return [pscustomobject]@{ Success = $false; Tier = $Tier; Steps = @(); BackupId = $null; Error = "'$LanguageTag' is not a valid language tag." }
    }
    if (-not (Test-KFLanguageInstalled -LanguageTag $normalized)) {
        return [pscustomobject]@{ Success = $false; Tier = $Tier; Steps = @(); BackupId = $null; Error = "'$normalized' is not currently installed." }
    }
    $safety = Test-KFLanguageCanBeRemoved -LanguageTag $normalized
    if (-not $safety.CanRemove) {
        return [pscustomobject]@{ Success = $false; Tier = $Tier; Steps = @(); BackupId = $null; Error = ($safety.Blockers -join '; ') }
    }
    if (-not (Test-KFAdminPrivileges) -and $Tier -ne 'Normal') {
        return [pscustomobject]@{ Success = $false; Tier = $Tier; Steps = @(); BackupId = $null; Error = "$Tier removal requires an elevated (Run as Administrator) session." }
    }
    if (-not $PSCmdlet.ShouldProcess($normalized, "$Tier language removal")) {
        return [pscustomobject]@{ Success = $false; Tier = $Tier; Steps = @(); BackupId = $null; Error = 'Cancelled (ShouldProcess).' }
    }

    $backup = Backup-KFSystemState -Note "Automatic pre-removal backup ($Tier removal of $normalized)"
    if (-not $backup.Success) {
        return [pscustomobject]@{ Success = $false; Tier = $Tier; Steps = @(); BackupId = $null; Error = "Refusing to remove without a successful backup: $($backup.Error)" }
    }

    # ---- Normal: remove from user language list + Basic capability -------
    $listOutcome = Invoke-KFSafe -Context 'Remove-KFLanguage:UserLanguageList' -Action {
        $currentTags = @(Get-WinUserLanguageList -ErrorAction Stop | ForEach-Object { $_.LanguageTag })
        $remainingTags = @($currentTags | Where-Object { $_ -ne $normalized })
        if ($remainingTags.Count -eq 0) {
            throw [ValidationException]::new('Refusing to leave the user language list empty.')
        }
        Set-WinUserLanguageList -LanguageList $remainingTags -Force -ErrorAction Stop
    }
    Add-KFStep 'Remove from user language list' $listOutcome.Success $(if ($listOutcome.Success) { 'Removed.' } else { $listOutcome.Error })

    if (Test-KFCommandExists -Name 'Uninstall-Language') {
        $uninstallOutcome = Invoke-KFSafe -Context 'Remove-KFLanguage:Uninstall-Language' -Silent -Action {
            Uninstall-Language -Language $normalized -ErrorAction Stop
        }
        Add-KFStep 'Uninstall-Language' $uninstallOutcome.Success $(if ($uninstallOutcome.Success) { 'Removed via LanguagePackManagement.' } else { $uninstallOutcome.Error })
    } else {
        $basicName = Get-KFCapabilityName -Feature 'Basic' -LanguageTag $normalized
        if ($basicName) {
            $basicOutcome = Invoke-KFSafe -Context 'Remove-KFLanguage:RemoveCapability:Basic' -Action {
                Remove-WindowsCapability -Online -Name $basicName -ErrorAction Stop
            }
            Add-KFStep 'Remove Basic capability' $basicOutcome.Success $(if ($basicOutcome.Success) { $basicName } else { $basicOutcome.Error })
        } else {
            Add-KFStep 'Remove Basic capability' $true 'No installed Basic capability found for this tag - nothing to remove.'
        }
    }

    # ---- Deep: additional feature capabilities + MUI cache ---------------
    if ($Tier -in @('Deep', 'Forced', 'Complete')) {
        foreach ($feature in 'OCR', 'Handwriting', 'Speech', 'TextToSpeech') {
            $capName = Get-KFCapabilityName -Feature $feature -LanguageTag $normalized
            if (-not $capName) {
                Add-KFStep "Remove $feature capability" $true 'Not installed - nothing to remove.'
                continue
            }
            $featOutcome = Invoke-KFSafe -Context "Remove-KFLanguage:RemoveCapability:$feature" -Action {
                Remove-WindowsCapability -Online -Name $capName -ErrorAction Stop
            }
            Add-KFStep "Remove $feature capability" $featOutcome.Success $(if ($featOutcome.Success) { $capName } else { $featOutcome.Error })
        }

        $muiOutcome = Invoke-KFSafe -Context 'Remove-KFLanguage:MUICache' -Action {
            # MUICache stores its data as values directly on the key, not as
            # subkeys, so this reads values via Get-ItemProperty rather than
            # enumerating child keys.
            $props = Get-ItemProperty -LiteralPath $Script:RegistryPaths.MUICache -ErrorAction SilentlyContinue
            $removed = 0
            if ($props) {
                foreach ($name in @($props.PSObject.Properties.Name)) {
                    if ($name -match [regex]::Escape($normalized)) {
                        Remove-ItemProperty -LiteralPath $Script:RegistryPaths.MUICache -Name $name -ErrorAction SilentlyContinue
                        $removed++
                    }
                }
            }
            $removed
        }
        Add-KFStep 'Clean MUI cache' $muiOutcome.Success $(if ($muiOutcome.Success) { "$($muiOutcome.Result) entrie(s) removed." } else { $muiOutcome.Error })
    }

    # ---- Forced: registry cleanup + exclusively-tied keyboards -----------
    if ($Tier -in @('Forced', 'Complete')) {
        $impact = Get-KFLanguageRemovalImpact -LanguageTag $normalized -Tier $Tier
        foreach ($kbd in $impact.Keyboards) {
            $removeResult = Remove-KFRegKey -Path "$($Script:RegistryPaths.KeyboardLayouts)\$($kbd.KLID)" -Confirm:$false
            Add-KFStep "Remove orphaned keyboard layout $($kbd.KLID)" $removeResult.Success $(if ($removeResult.Success) { $kbd.Name } else { $removeResult.Error })

            $preloadOutcome = Invoke-KFSafe -Context 'Remove-KFLanguage:PreloadCleanup' -Action {
                $preloadItem = Get-Item -LiteralPath $Script:RegistryPaths.Preload -ErrorAction Stop
                $slot = @($preloadItem.Property) | Where-Object { $preloadItem.GetValue($_) -eq $kbd.KLID } | Select-Object -First 1
                if ($slot) { Remove-ItemProperty -LiteralPath $Script:RegistryPaths.Preload -Name $slot -ErrorAction Stop }
            }
            Add-KFStep "Remove preload entry for $($kbd.KLID)" $preloadOutcome.Success $(if ($preloadOutcome.Success) { 'Done.' } else { $preloadOutcome.Error })
        }
        if ($impact.Keyboards.Count -eq 0) {
            Add-KFStep 'Orphaned keyboard cleanup' $true 'No keyboard layouts were exclusively tied to this language.'
        }
        Clear-KFCache -Prefix 'kbd:'
    }

    Clear-KFCache -Prefix 'lang:'
    Clear-KFCache -Prefix 'capname:'
    Clear-KFCache -Prefix 'dashboard:'

    $anyFail = [bool]($steps | Where-Object { -not $_.Success })
    $stillInstalled = Test-KFLanguageInstalled -LanguageTag $normalized
    if ($stillInstalled -and $Tier -eq 'Normal') {
        # Normal removal intentionally may leave the Basic capability
        # installed system-wide if it's shared - not a failure by itself.
        Add-KFStep 'Post-removal check' $true "'$normalized' removed from the user language list; the underlying capability may still be present for other users."
    } elseif ($stillInstalled) {
        Add-KFStep 'Post-removal check' $false "'$normalized' still verifies as installed after $Tier removal."
        $anyFail = $true
    } else {
        Add-KFStep 'Post-removal check' $true 'Verified not installed.'
    }

    Write-LogEntry -Level 'Info' -Message "$Tier removal of '$normalized' completed (anyFail=$anyFail); backup='$($backup.BackupId)'"
    [pscustomobject]@{
        Success  = (-not $anyFail)
        Tier     = $Tier
        Steps    = @($steps)
        BackupId = $backup.BackupId
        Error    = $(if ($anyFail) { 'One or more steps failed - see Steps for details.' } else { $null })
    }
}

function Invoke-KFComponentCleanup {
    <#
    .SYNOPSIS
        Runs Windows' own supported component-store cleanup
        (DISM /Online /Cleanup-Image /StartComponentCleanup). This is a
        SYSTEM-WIDE operation that reclaims space from any fully-superseded
        component, not specific to any one language - it is never run as an
        automatic side effect of removing a language. The UI offers it
        separately, with that scope explained, after a Complete-tier removal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-KFAdminPrivileges)) {
        return [pscustomobject]@{ Success = $false; Error = 'Component cleanup requires an elevated (Run as Administrator) session.' }
    }
    if (-not $PSCmdlet.ShouldProcess('Windows component store', 'Run StartComponentCleanup')) {
        return [pscustomobject]@{ Success = $false; Error = 'Cancelled (ShouldProcess).' }
    }
    $outcome = Invoke-KFSafe -Context 'Invoke-KFComponentCleanup' -Action {
        $result = & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [OperationFailedException]::new("DISM exited with code $LASTEXITCODE: $result")
        }
        $result
    }
    [pscustomobject]@{ Success = $outcome.Success; Error = $outcome.Error }
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
# Status: 'Ready' = fully implemented screen in this build (read or write).
#         'Stub'  = placeholder; ships with the Language/Keyboard install-
#                    remove modules in the next phase (each stub names it).
$Script:MenuItems = @(
    [pscustomobject]@{ Id = 1;  Label = 'Installed Languages';               Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 2;  Label = 'Installed Keyboard Layouts';        Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 3;  Label = 'Install New Language';             Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 4;  Label = 'Remove Language';                  Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 5;  Label = 'Remove Keyboard Layout';           Status = 'Stub';  Phase = 'Phase 5' }
    [pscustomobject]@{ Id = 6;  Label = 'Set Default Keyboard';             Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 7;  Label = 'Set Display Language';             Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 8;  Label = 'Region Settings';                  Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 9;  Label = 'Locale Settings';                  Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 10; Label = 'Time & Region';                    Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 11; Label = 'Language Features';                Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 12; Label = 'Cleanup';                          Status = 'Stub';  Phase = 'Phase 5' }
    [pscustomobject]@{ Id = 13; Label = 'Advanced Removal';                 Status = 'Stub';  Phase = 'Phase 5' }
    [pscustomobject]@{ Id = 14; Label = 'Backup';                           Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 15; Label = 'Restore';                          Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 16; Label = 'Diagnostics';                      Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 17; Label = 'Repair Windows Language Components'; Status = 'Stub'; Phase = 'Phase 5' }
    [pscustomobject]@{ Id = 18; Label = 'Export Configuration';             Status = 'Ready'; Phase = '' }
    [pscustomobject]@{ Id = 19; Label = 'Import Configuration';             Status = 'Stub';  Phase = 'Phase 5' }
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
    Write-KFColor -Text "  Tip: use menu option 6 (Set Default Keyboard) to change which loaded layout is active first." -Color $Script:Colors.Dim
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFSetDefaultKeyboardScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  SET DEFAULT KEYBOARD' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $kbds = @(Get-KFInstalledKeyboards -Force | Where-Object { $_.Loaded } | Sort-Object PreloadOrder)
    if ($kbds.Count -eq 0) {
        Write-KFStatus -Type 'Warning' -Message 'No loaded keyboard layouts were found for the current user.'
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $rows = @($kbds | ForEach-Object {
        [pscustomobject]@{ Order = $_.PreloadOrder; KLID = $_.KLID; Name = $_.Name; Tag = $(if ($_.LanguageTag) { $_.LanguageTag } else { '-' }) }
    })
    $columns = @(
        @{ Name = 'Order'; Header = '#';    Width = 3;  Align = 'Right' }
        @{ Name = 'KLID';  Header = 'KLID'; Width = 10; Align = 'Left' }
        @{ Name = 'Name';  Header = 'Name'; Width = 36; Align = 'Left' }
        @{ Name = 'Tag';   Header = 'Tag';  Width = 8;  Align = 'Left' }
    )
    Write-KFTable -Data $rows -Columns $columns
    Write-Host ''

    if ($kbds.Count -eq 1) {
        Write-KFStatus -Type 'Info' -Message "'$($kbds[0].Name)' is the only loaded layout - nothing to reorder."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $klid = Request-KFTextInput -Prompt 'Enter the KLID to make default (blank to cancel)' -Validator {
        param($v) [string]::IsNullOrWhiteSpace($v) -or (Test-KFKlidFormat -Klid $v)
    } -ErrorText 'Enter an 8-character hex KLID from the table above, or leave blank to cancel.'

    if ([string]::IsNullOrWhiteSpace($klid)) {
        Write-KFStatus -Type 'Info' -Message 'Cancelled.'
        Start-Sleep -Milliseconds 800
        return
    }

    $target = $kbds | Where-Object { $_.KLID -eq $klid } | Select-Object -First 1
    if (-not $target) {
        Write-KFStatus -Type 'Failure' -Message "'$klid' isn't one of the loaded layouts listed above."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    if (-not (Show-KFConfirmationDialog -Message "Make '$($target.Name)' the default keyboard?" -AffectedItems @("HKCU:\Keyboard Layout\Preload will be reordered ($($kbds.Count) entries)") -DefaultYes $true)) {
        Write-KFStatus -Type 'Info' -Message 'Cancelled.'
        Start-Sleep -Milliseconds 800
        return
    }

    $result = Set-KFDefaultKeyboard -KLID $target.KLID -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "'$($target.Name)' is now the default keyboard."
        if ($result.BackupPath) { Write-KFColor -Text "  Preload list backed up to: $($result.BackupPath)" -Color $Script:Colors.Dim }
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not change the default keyboard: $($result.Error)"
    }
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
        Write-Host ''
        Wait-KFKeyPress
        return
    }

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

    Write-Host ''
    Write-KFColor -Text '  [I] Install a missing feature   [0] Back' -Color $Script:Colors.Muted
    Write-Host ''
    Write-KFColor -Text '  Choice: ' -Color $Script:Colors.Body -NoNewline
    $choice = (Read-Host).Trim()
    if ($choice -notmatch '^(?i:i)$') { return }

    Write-Host ''
    $tag = Request-KFTextInput -Prompt 'Language tag to add a feature to (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($tag)) { return }
    $normalized = Test-KFLanguageTagFormat -Tag $tag
    if (-not $normalized -or -not (Test-KFLanguageInstalled -LanguageTag $normalized)) {
        Write-KFStatus -Type 'Failure' -Message "'$tag' isn't currently installed."
        Write-Host ''
        Wait-KFKeyPress
        return
    }
    $featureIndex = Show-KFChoiceDialog -Question 'Which feature?' -Options @('OCR', 'Handwriting', 'Speech', 'TextToSpeech', 'Cancel') -DefaultIndex 4
    if ($featureIndex -lt 0 -or $featureIndex -eq 4) { return }
    $feature = @('OCR', 'Handwriting', 'Speech', 'TextToSpeech')[$featureIndex]

    if (-not (Show-KFConfirmationDialog -Message "Install the $feature feature for '$normalized'?" -DefaultYes $true)) { return }

    $result = Wait-KFWithSpinner -Label "Installing $feature for $normalized" -Action {
        Install-KFLanguageFeature -LanguageTag $normalized -Feature $feature -Confirm:$false
    }
    Write-Host ''
    if ($result -and $result.Success) {
        Write-KFStatus -Type 'Success' -Message "$feature installed for '$normalized'."
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not install ${feature}: $(if ($result) { $result.Error } else { 'see the session log' })"
    }
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFSetDisplayLanguageScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  SET DISPLAY LANGUAGE' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''
    Write-KFColor -Text "  Only languages already in the current user's language list can be set" -Color $Script:Colors.Body
    Write-KFColor -Text "  as the display language here. Installing a new one is a Language" -Color $Script:Colors.Body
    Write-KFColor -Text "  Manager operation (menu option 3), landing in the next build." -Color $Script:Colors.Body
    Write-Host ''

    $userLangs = @(Get-KFUserLanguages -Force)
    if ($userLangs.Count -eq 0) {
        Write-KFStatus -Type 'Warning' -Message 'No languages found in the current user language list.'
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $rows = @($userLangs | ForEach-Object { [pscustomobject]@{ Tag = $_.LanguageTag; Name = Format-KFLanguageName -Tag $_.LanguageTag } })
    Write-KFTable -Data $rows -Columns @(
        @{ Name = 'Tag'; Header = 'Tag'; Width = 10; Align = 'Left' }
        @{ Name = 'Name'; Header = 'Language'; Width = 40; Align = 'Left' }
    )
    Write-Host ''

    $tag = Request-KFTextInput -Prompt 'Enter the tag to set as display language (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($tag)) { return }

    if (-not (Show-KFConfirmationDialog -Message "Set display language to '$tag'?" -DefaultYes $true)) { return }

    $result = Set-KFDisplayLanguage -LanguageTag $tag -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "Display language set to '$tag'. Sign out and back in for it to fully apply everywhere."
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not set display language: $($result.Error)"
    }
    Write-Host ''
    Wait-KFKeyPress
}

#endregion ==================================================================

#region ============================== SCREEN: INSTALL / REMOVE LANGUAGE =======

function Show-KFInstallLanguageScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  INSTALL NEW LANGUAGE' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    if (-not (Test-KFAdminPrivileges)) {
        Write-KFAlert -Level 'Warning' -Message 'Installing a language requires an elevated (Run as Administrator) session. Restart KeyForge as Administrator to use this.'
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $tag = Request-KFTextInput -Prompt "Language tag to install, e.g. 'es-MX' or 'ja-JP' (blank to cancel)" -Validator {
        param($v) [string]::IsNullOrWhiteSpace($v) -or (Test-KFLanguageTagFormat -Tag $v)
    } -ErrorText "Enter a valid BCP-47 tag like 'es-MX', or leave blank to cancel."
    if ([string]::IsNullOrWhiteSpace($tag)) { return }

    $normalized = Test-KFLanguageTagFormat -Tag $tag
    if (-not (Test-KFLanguageKnownToWindows -LanguageTag $normalized)) {
        Write-Host ''
        Write-KFStatus -Type 'Failure' -Message "'$normalized' isn't a language/region combination Windows recognizes."
        Write-Host ''
        Wait-KFKeyPress
        return
    }
    if (Test-KFLanguageInstalled -LanguageTag $normalized) {
        Write-Host ''
        Write-KFStatus -Type 'Info' -Message "'$normalized' is already installed."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    Write-Host ''
    $featureInput = Request-KFTextInput -Prompt 'Additional features - comma-separated (OCR, Handwriting, Speech, TextToSpeech), or blank for Basic only'
    $features = @()
    if (-not [string]::IsNullOrWhiteSpace($featureInput)) {
        $valid = 'OCR', 'Handwriting', 'Speech', 'TextToSpeech'
        $requested = @($featureInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $features = @($requested | Where-Object { $_ -in $valid })
        $unknown = @($requested | Where-Object { $_ -notin $valid })
        if ($unknown.Count -gt 0) {
            Write-KFStatus -Type 'Warning' -Message "Ignoring unrecognized feature(s): $($unknown -join ', ')"
        }
    }

    $setDisplay = Request-KFUserConfirmation -Message 'Also set this as the display language once installed?' -DefaultYes $false

    $affected = @("Download and install the Basic language pack for '$normalized'" ) + @($features | ForEach-Object { "Install the $_ feature" })
    if (-not (Show-KFConfirmationDialog -Message "Install '$normalized'? This downloads from Windows Update and may take several minutes." -AffectedItems $affected -DefaultYes $true)) {
        return
    }

    $result = Wait-KFWithSpinner -Label "Installing $normalized (this can take a while)" -Action {
        Install-KFLanguage -LanguageTag $normalized -Features $features -SetAsDisplayLanguage:$setDisplay -Confirm:$false
    }
    Write-Host ''
    if ($null -eq $result) {
        Write-KFStatus -Type 'Failure' -Message 'Install failed - see the session log for details.'
    } elseif ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "'$normalized' installed via $($result.Method). Features: $($result.InstalledFeatures -join ', ')"
        if ($result.BackupId) { Write-KFColor -Text "  Pre-install backup: $($result.BackupId)" -Color $Script:Colors.Dim }
    } else {
        Write-KFStatus -Type 'Failure' -Message "Install failed: $($result.Error)"
    }
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFRemoveLanguageScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  REMOVE LANGUAGE' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $userLangs = @(Get-KFUserLanguages -Force)
    if ($userLangs.Count -eq 0) {
        Write-KFStatus -Type 'Warning' -Message 'No languages found in the current user language list.'
        Write-Host ''
        Wait-KFKeyPress
        return
    }
    $rows = @($userLangs | ForEach-Object { [pscustomobject]@{ Tag = $_.LanguageTag; Name = Format-KFLanguageName -Tag $_.LanguageTag } })
    Write-KFTable -Data $rows -Columns @(
        @{ Name = 'Tag'; Header = 'Tag'; Width = 10; Align = 'Left' }
        @{ Name = 'Name'; Header = 'Language'; Width = 40; Align = 'Left' }
    )
    Write-Host ''

    $tag = Request-KFTextInput -Prompt 'Enter the tag to remove (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($tag)) { return }
    $normalized = Test-KFLanguageTagFormat -Tag $tag
    if (-not $normalized -or -not (Test-KFLanguageInstalled -LanguageTag $normalized)) {
        Write-Host ''
        Write-KFStatus -Type 'Failure' -Message "'$tag' isn't currently installed for this user."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $safety = Test-KFLanguageCanBeRemoved -LanguageTag $normalized
    if (-not $safety.CanRemove) {
        Write-Host ''
        Write-KFAlert -Level 'Danger' -Message ($safety.Blockers -join ' ')
        Write-Host ''
        Wait-KFKeyPress
        return
    }
    foreach ($w in $safety.Warnings) { Write-KFStatus -Type 'Warning' -Message $w }

    $tierOptions = @(
        'Normal   - remove from your language list; remove the Basic pack if unshared'
        'Deep     - Normal, plus OCR/Handwriting/Speech/TextToSpeech and MUI cache cleanup'
        'Forced   - Deep, plus registry cleanup and any keyboard layouts exclusive to this language'
        'Complete - Forced, plus an optional Windows-wide component-store cleanup afterward'
        'Cancel'
    )
    $tierIndex = Show-KFChoiceDialog -Question "Removal depth for '$normalized'?" -Options $tierOptions -DefaultIndex 0
    if ($tierIndex -lt 0 -or $tierIndex -eq 4) { return }
    $tier = @('Normal', 'Deep', 'Forced', 'Complete')[$tierIndex]

    if ($tier -ne 'Normal' -and -not (Test-KFAdminPrivileges)) {
        Write-Host ''
        Write-KFStatus -Type 'Warning' -Message "$tier removal requires an elevated (Run as Administrator) session."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    Write-Host ''
    $impact = Wait-KFWithSpinner -Label 'Checking what this will affect' -Action { Get-KFLanguageRemovalImpact -LanguageTag $normalized -Tier $tier }
    $affected = [System.Collections.Generic.List[string]]::new()
    if ($impact) {
        foreach ($c in $impact.Capabilities) { $affected.Add("Remove capability: $c") }
        foreach ($k in $impact.Keyboards) { $affected.Add("Remove keyboard layout: $($k.Name) ($($k.KLID))") }
    }
    if ($affected.Count -eq 0) { $affected.Add('Remove from the user language list.') }

    if (-not (Show-KFConfirmationDialog -Message "$tier removal of '$normalized'. A backup is taken automatically first." -AffectedItems $affected -DefaultYes $false)) {
        return
    }
    if ($tier -in @('Forced', 'Complete')) {
        if (-not (Request-KFExplicitConfirmation -Phrase $normalized -Prompt "This is a $tier removal. Type the language tag ('$normalized') to confirm:")) {
            Write-KFStatus -Type 'Info' -Message 'Cancelled.'
            Start-Sleep -Milliseconds 900
            return
        }
    }

    $result = Wait-KFWithSpinner -Label "Running $tier removal of $normalized" -Action {
        Remove-KFLanguage -LanguageTag $normalized -Tier $tier -Confirm:$false
    }
    Write-Host ''
    if ($null -eq $result) {
        Write-KFStatus -Type 'Failure' -Message 'Removal failed - see the session log for details.'
    } else {
        foreach ($step in $result.Steps) {
            Write-KFStatus -Type $(if ($step.Success) { 'Success' } else { 'Failure' }) -Message "$($step.Step): $($step.Detail)"
        }
        Write-Host ''
        if ($result.Success) { Write-KFStatus -Type 'Success' -Message "$tier removal of '$normalized' complete." }
        else { Write-KFStatus -Type 'Warning' -Message "Removal finished with issues: $($result.Error)" }
        if ($result.BackupId) { Write-KFColor -Text "  Pre-removal backup: $($result.BackupId)" -Color $Script:Colors.Dim }

        if ($result.Success -and $tier -eq 'Complete') {
            Write-Host ''
            if (Show-KFConfirmationDialog -Message 'Also run Windows component-store cleanup now? This reclaims disk space SYSTEM-WIDE (not specific to this language) and can take several minutes.' -DefaultYes $false) {
                $cleanupResult = Wait-KFWithSpinner -Label 'Running component-store cleanup' -Action { Invoke-KFComponentCleanup -Confirm:$false }
                Write-Host ''
                if ($cleanupResult -and $cleanupResult.Success) { Write-KFStatus -Type 'Success' -Message 'Component-store cleanup complete.' }
                else { Write-KFStatus -Type 'Failure' -Message "Component-store cleanup failed: $($cleanupResult.Error)" }
            }
        }
    }
    Write-Host ''
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
    while ($true) {
        try { Clear-Host } catch {}
        Write-KFBanner
        Write-KFColor -Text '  REGION SETTINGS' -Color $Script:Colors.Highlight
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
        Write-KFColor -Text '  [C] Change region   [0] Back' -Color $Script:Colors.Muted
        Write-Host ''
        Write-KFColor -Text '  Choice: ' -Color $Script:Colors.Body -NoNewline
        $choice = (Read-Host).Trim()

        switch -Regex ($choice) {
            '^(?i:c)$' { Invoke-KFChangeRegionFlow }
            default    { return }
        }
    }
}

function Invoke-KFChangeRegionFlow {
    [CmdletBinding()]
    param()
    Write-Host ''
    $search = Request-KFTextInput -Prompt 'Search for a country/region name (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($search)) { return }

    $regionMatches = Wait-KFWithSpinner -Label 'Searching regions' -Action {
        @(Get-KFAvailableRegions | Where-Object { $_.Name -like "*$search*" } | Select-Object -First 12)
    }
    if ($null -eq $regionMatches -or $regionMatches.Count -eq 0) {
        Write-KFStatus -Type 'Warning' -Message "No regions matched '$search'."
        Start-Sleep -Milliseconds 1200
        return
    }

    $labels = @($regionMatches | ForEach-Object { "$($_.Name)  (GeoID $($_.GeoId))" })
    $index = Show-KFChoiceDialog -Question 'Which region?' -Options $labels -DefaultIndex 0
    if ($index -lt 0) { return }
    $selected = $regionMatches[$index]

    if (-not (Show-KFConfirmationDialog -Message "Set region to '$($selected.Name)'?" -AffectedItems @("Current user's home location (GeoID $($selected.GeoId))") -DefaultYes $true)) {
        return
    }

    $result = Set-KFRegion -GeoId $selected.GeoId -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "Region set to '$($selected.Name)'."
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not set region: $($result.Error)"
    }
    Start-Sleep -Milliseconds 1200
}

function Show-KFLocaleScreen {
    [CmdletBinding()]
    param()
    while ($true) {
        try { Clear-Host } catch {}
        Write-KFBanner
        Write-KFColor -Text '  LOCALE SETTINGS' -Color $Script:Colors.Highlight
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
                ('{0,-22} {1}' -f 'Time pattern:', $d.ShortTime)
                ('{0,-22} {1}' -f 'Decimal separator:', "'$($d.DecimalSep)'")
                ('{0,-22} {1}' -f 'Thousands separator:', "'$($d.ThousandsSep)'   e.g. $($d.SampleNumber)")
            )
            Write-KFBox -Lines $fmtLines -Title 'Formats' -BorderColor $Script:Colors.Border
            Write-Host ''
        }
        Write-KFColor -Text '  [S] System locale  [U] User locale  [F] Edit a format  [0] Back' -Color $Script:Colors.Muted
        Write-Host ''
        Write-KFColor -Text '  Choice: ' -Color $Script:Colors.Body -NoNewline
        $choice = (Read-Host).Trim()

        switch -Regex ($choice) {
            '^(?i:s)$' { Invoke-KFChangeSystemLocaleFlow }
            '^(?i:u)$' { Invoke-KFChangeUserLocaleFlow }
            '^(?i:f)$' { Invoke-KFChangeFormatFlow }
            default    { return }
        }
    }
}

function Invoke-KFChangeSystemLocaleFlow {
    [CmdletBinding()]
    param()
    Write-Host ''
    if (-not (Test-KFAdminPrivileges)) {
        Write-KFStatus -Type 'Warning' -Message 'Changing the system locale requires Run as Administrator.'
        Start-Sleep -Milliseconds 1500
        return
    }
    $tag = Request-KFTextInput -Prompt "Language tag for the new system locale, e.g. 'en-US' (blank to cancel)" -Validator {
        param($v) [string]::IsNullOrWhiteSpace($v) -or (Test-KFLanguageTagFormat -Tag $v)
    } -ErrorText "Enter a valid BCP-47 tag like 'en-US' or 'fr-FR', or leave blank to cancel."
    if ([string]::IsNullOrWhiteSpace($tag)) { return }

    if (-not (Show-KFConfirmationDialog -Message "Set system locale to '$tag'? This is machine-wide and needs a restart to fully apply." -DefaultYes $false)) { return }

    $result = Set-KFSystemLocale -LanguageTag $tag -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "System locale set to '$tag'. Restart Windows for it to fully apply."
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not set system locale: $($result.Error)"
    }
    Start-Sleep -Milliseconds 1500
}

function Invoke-KFChangeUserLocaleFlow {
    [CmdletBinding()]
    param()
    Write-Host ''
    $tag = Request-KFTextInput -Prompt "Language tag for the new user locale/formats, e.g. 'en-GB' (blank to cancel)" -Validator {
        param($v) [string]::IsNullOrWhiteSpace($v) -or (Test-KFLanguageTagFormat -Tag $v)
    } -ErrorText "Enter a valid BCP-47 tag like 'en-GB' or 'de-DE', or leave blank to cancel."
    if ([string]::IsNullOrWhiteSpace($tag)) { return }

    if (-not (Show-KFConfirmationDialog -Message "Set user locale (date/time/number formats) to '$tag'?" -DefaultYes $true)) { return }

    $result = Set-KFUserLocale -LanguageTag $tag -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "User locale set to '$tag'."
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not set user locale: $($result.Error)"
    }
    Start-Sleep -Milliseconds 1500
}

function Invoke-KFChangeFormatFlow {
    [CmdletBinding()]
    param()
    Write-Host ''
    $options = @('Short date pattern', 'Long date pattern', 'Time pattern', 'Decimal separator', 'Thousands separator', 'Cancel')
    $index = Show-KFChoiceDialog -Question 'Which format?' -Options $options -DefaultIndex 5
    if ($index -lt 0 -or $index -eq 5) { return }

    $fieldMap = @('ShortDate', 'LongDate', 'TimeFormat', 'DecimalSeparator', 'ThousandsSeparator')
    $field = $fieldMap[$index]
    $exampleMap = @{
        ShortDate = 'e.g. M/d/yyyy'; LongDate = 'e.g. dddd, MMMM d, yyyy'; TimeFormat = 'e.g. h:mm:ss tt'
        DecimalSeparator = "e.g. '.'"; ThousandsSeparator = "e.g. ','"
    }
    $value = Request-KFTextInput -Prompt "New value for $($options[$index]) ($($exampleMap[$field]), blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($value)) { return }

    if (-not (Show-KFConfirmationDialog -Message "Set $($options[$index]) to '$value'?" -DefaultYes $true)) { return }

    $result = Set-KFRegionalFormat -Field $field -Value $value -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "$($options[$index]) updated."
        if ($result.BackupPath) { Write-KFColor -Text "  Previous value backed up to: $($result.BackupPath)" -Color $Script:Colors.Dim }
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not update format: $($result.Error)"
    }
    Start-Sleep -Milliseconds 1500
}

function Show-KFTimeRegionScreen {
    [CmdletBinding()]
    param()
    while ($true) {
        try { Clear-Host } catch {}
        Write-KFBanner
        Write-KFColor -Text '  TIME & REGION' -Color $Script:Colors.Highlight
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
        Write-KFColor -Text '  [C] Change time zone   [0] Back' -Color $Script:Colors.Muted
        Write-Host ''
        Write-KFColor -Text '  Choice: ' -Color $Script:Colors.Body -NoNewline
        $choice = (Read-Host).Trim()

        switch -Regex ($choice) {
            '^(?i:c)$' { Invoke-KFChangeTimeZoneFlow }
            default    { return }
        }
    }
}

function Invoke-KFChangeTimeZoneFlow {
    [CmdletBinding()]
    param()
    Write-Host ''
    if (-not (Test-KFAdminPrivileges)) {
        Write-KFStatus -Type 'Warning' -Message 'Changing the time zone requires Run as Administrator.'
        Start-Sleep -Milliseconds 1500
        return
    }
    $search = Request-KFTextInput -Prompt "Search time zones, e.g. 'Tokyo' or 'Eastern' (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($search)) { return }

    $tzMatches = @(Get-KFAvailableTimeZones | Where-Object { $_.DisplayName -like "*$search*" -or $_.Id -like "*$search*" } | Select-Object -First 12)
    if ($tzMatches.Count -eq 0) {
        Write-KFStatus -Type 'Warning' -Message "No time zones matched '$search'."
        Start-Sleep -Milliseconds 1200
        return
    }

    $labels = @($tzMatches | ForEach-Object { $_.DisplayName })
    $index = Show-KFChoiceDialog -Question 'Which time zone?' -Options $labels -DefaultIndex 0
    if ($index -lt 0) { return }
    $selected = $tzMatches[$index]

    if (-not (Show-KFConfirmationDialog -Message "Set the system time zone to '$($selected.DisplayName)'?" -DefaultYes $true)) { return }

    $result = Set-KFTimeZone -Id $selected.Id -Confirm:$false
    Write-Host ''
    if ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "Time zone set to '$($selected.DisplayName)'."
    } else {
        Write-KFStatus -Type 'Failure' -Message "Could not set time zone: $($result.Error)"
    }
    Start-Sleep -Milliseconds 1500
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

#region ============================== SCREEN: BACKUP & RESTORE ================

function Show-KFBackupScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  BACKUP' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''
    Write-KFColor -Text '  Captures the Keyboard Layouts, Preload/Substitutes/Toggle, and' -Color $Script:Colors.Body
    Write-KFColor -Text '  Control Panel\International registry subtrees (as .reg exports),' -Color $Script:Colors.Body
    Write-KFColor -Text '  plus a JSON snapshot of current languages/keyboards/region/locale.' -Color $Script:Colors.Body
    Write-Host ''

    $note = Request-KFTextInput -Prompt 'Optional note for this backup (blank is fine)'

    $result = Wait-KFWithSpinner -Label 'Creating backup' -Action { Backup-KFSystemState -Note $note }
    Write-Host ''
    if ($null -eq $result) {
        Write-KFStatus -Type 'Failure' -Message 'Backup failed - see the session log for details.'
    } elseif ($result.Success) {
        Write-KFStatus -Type 'Success' -Message "Backup '$($result.BackupId)' created."
        Write-KFColor -Text "  Saved to: $($result.Path)" -Color $Script:Colors.Dim
    } else {
        Write-KFStatus -Type 'Warning' -Message "Backup '$($result.BackupId)' created but one or more components had issues: $($result.Error)"
        Write-KFColor -Text "  Saved to: $($result.Path)" -Color $Script:Colors.Dim
    }
    Write-Host ''
    Wait-KFKeyPress
}

function Show-KFRestoreScreen {
    [CmdletBinding()]
    param()
    try { Clear-Host } catch {}
    Write-KFBanner
    Write-KFColor -Text '  RESTORE' -Color $Script:Colors.Highlight
    Write-KFLine
    Write-Host ''

    $backups = Get-KFBackupList
    if ($backups.Count -eq 0) {
        Write-KFStatus -Type 'Info' -Message "No backups found yet - create one from menu option 14 first."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $rows = @($backups | ForEach-Object {
        [pscustomobject]@{
            Id      = $_.BackupId
            Created = $_.CreatedAt
            Ok      = if ($_.AllOk) { Get-KFIcon 'Success' } else { Get-KFIcon 'Warning' }
            Size    = Format-KFByteSize -Bytes $_.SizeBytes
            Note    = $(if ($_.Note) { $_.Note } else { '-' })
        }
    })
    Write-KFTable -Data $rows -Columns @(
        @{ Name = 'Id';      Header = 'Backup ID';  Width = 24; Align = 'Left' }
        @{ Name = 'Created'; Header = 'Created';    Width = 20; Align = 'Left' }
        @{ Name = 'Ok';      Header = 'OK';         Width = 3;  Align = 'Left' }
        @{ Name = 'Size';    Header = 'Size';       Width = 10; Align = 'Right' }
        @{ Name = 'Note';    Header = 'Note';       Width = 26; Align = 'Left' }
    )
    Write-Host ''
    Write-KFColor -Text '  Note: restoring re-applies registry state. Installed languages themselves' -Color $Script:Colors.Dim
    Write-KFColor -Text '  are not installed/removed to match a snapshot yet - that needs the' -Color $Script:Colors.Dim
    Write-KFColor -Text '  Language Manager module (next build).' -Color $Script:Colors.Dim
    Write-Host ''

    $id = Request-KFTextInput -Prompt 'Enter a Backup ID to restore, or D<id> to delete one (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($id)) { return }

    if ($id -match '^(?i:d)(.+)$') {
        $deleteId = $Matches[1].Trim()
        $target = $backups | Where-Object { $_.BackupId -eq $deleteId } | Select-Object -First 1
        if (-not $target) {
            Write-KFStatus -Type 'Failure' -Message "'$deleteId' is not one of the backup IDs listed above."
            Write-Host ''
            Wait-KFKeyPress
            return
        }
        if (Show-KFConfirmationDialog -Message "Permanently delete backup '$deleteId'?" -DefaultYes $false) {
            $delResult = Remove-KFBackup -BackupPath $target.Path -Confirm:$false
            Write-Host ''
            if ($delResult.Success) { Write-KFStatus -Type 'Success' -Message "Backup '$deleteId' deleted." }
            else { Write-KFStatus -Type 'Failure' -Message "Could not delete: $($delResult.Error)" }
            Write-Host ''
            Wait-KFKeyPress
        }
        return
    }

    $target = $backups | Where-Object { $_.BackupId -eq $id } | Select-Object -First 1
    if (-not $target) {
        Write-KFStatus -Type 'Failure' -Message "'$id' is not one of the backup IDs listed above."
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $integrity = Test-KFBackupIntegrity -BackupPath $target.Path
    if (-not $integrity.Valid) {
        Write-KFAlert -Level 'Danger' -Message "This backup failed integrity verification and will not be restored: $($integrity.Issues -join '; ')"
        Write-Host ''
        Wait-KFKeyPress
        return
    }

    $affected = @($Script:BackupRegistryTargets.Keys)
    if (-not (Show-KFConfirmationDialog -Message "Restore registry state from backup '$id'? A fresh safety backup of the CURRENT state will be taken first." -AffectedItems $affected -DefaultYes $false)) {
        return
    }
    if (-not (Request-KFExplicitConfirmation -Phrase $id -Prompt "Type the backup ID ('$id') to confirm the restore:")) {
        Write-KFStatus -Type 'Info' -Message 'Cancelled.'
        Start-Sleep -Milliseconds 900
        return
    }

    $result = Wait-KFWithSpinner -Label 'Restoring' -Action { Restore-KFSystemState -BackupPath $target.Path -Confirm:$false }
    Write-Host ''
    if ($null -eq $result) {
        Write-KFStatus -Type 'Failure' -Message 'Restore failed - see the session log for details.'
    } else {
        foreach ($r in $result.Results) {
            Write-KFStatus -Type $(if ($r.Success) { 'Success' } else { 'Failure' }) -Message "$($r.Component): $($r.Detail)"
        }
        Write-Host ''
        if ($result.Success) {
            Write-KFStatus -Type 'Success' -Message "Restore complete. Safety backup of the prior state: '$($result.SafetyBackupId)'."
        } else {
            Write-KFStatus -Type 'Warning' -Message "Restore finished with issues. Safety backup of the prior state: '$($result.SafetyBackupId)'."
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
        3  { Show-KFInstallLanguageScreen }
        4  { Show-KFRemoveLanguageScreen }
        6  { Show-KFSetDefaultKeyboardScreen }
        7  { Show-KFSetDisplayLanguageScreen }
        8  { Show-KFRegionScreen }
        9  { Show-KFLocaleScreen }
        10 { Show-KFTimeRegionScreen }
        11 { Show-KFLanguageFeaturesScreen }
        14 { Show-KFBackupScreen }
        15 { Show-KFRestoreScreen }
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
