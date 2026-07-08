#Requires -Version 5.1

<#
.SYNOPSIS
    WPS Office Enterprise Removal Utility - completely and safely removes every trace of
    WPS Office (Kingsoft Office) from a Windows 10 / Windows 11 workstation.

.DESCRIPTION
    Production-grade, dependency-free PowerShell 5.1 utility designed to run either as a
    saved .ps1 file or piped directly from the web:

        iex (irm https://example.com/remove-wps.ps1)

    The utility discovers and removes WPS Office / Kingsoft Office installations (any
    version, any bitness, vendor-installed, MSI-installed, or portable) including:

        - Running processes and Windows services
        - Scheduled tasks and startup entries (Run / RunOnce / StartupApproved / Startup folder)
        - Registry remnants (HKLM, HKCU, WOW6432Node, and per-user hives, including hives
          belonging to profiles that are not currently logged on)
        - Program Files, ProgramData, and AppData (Local/Roaming) folders for every profile
        - Desktop / Start Menu / Quick Launch / Public Desktop shortcuts
        - Environment variable remnants
        - Optionally: file type associations and firewall rules created by WPS Office

    Every destructive action is gated behind positive identification of the target as
    belonging to WPS Office / Kingsoft (Test-WpsFileIdentity / Test-WpsTextIdentity).
    Known-safe software (Microsoft Office, LibreOffice, OpenOffice, user documents, fonts,
    Windows components, etc.) is protected by an explicit blacklist and is never touched.

    The script is idempotent: it can be re-run any number of times - including repeatedly in
    the same PowerShell session, which is what happens when it is re-invoked via iex/irm - and
    will simply report a clean system once nothing remains.

.PARAMETER Silent
    Quiet mode. Suppresses non-essential console output. Errors/warnings are still logged.
    Implies -Force (no interactive confirmation) so the script can run unattended.

.PARAMETER DryRun
    Performs a full detection pass and reports every action that WOULD be taken without
    modifying the system in any way. Safe to run repeatedly for auditing/change-control.

.PARAMETER Force
    Suppresses the interactive confirmation prompt before destructive actions begin.
    Required for unattended / RMM / SCCM style deployment (together with -Silent).

.PARAMETER NoRestart
    Never restarts the computer automatically. If a reboot is required to finish removing
    locked files, deletion is instead scheduled for next boot (via MoveFileEx) and reported.

.PARAMETER LogPath
    Directory that log files and the summary report are written to.
    Defaults to "$env:ProgramData\WpsRemovalUtility\Logs".

.PARAMETER JsonLog
    In addition to the plain-text log, writes a structured JSON log and JSON summary report.

.PARAMETER CleanupTemp
    Additionally removes WPS-related leftovers from %TEMP%, Windows Temp, and installer cache.

.PARAMETER CleanupFirewall
    Additionally removes Windows Firewall rules created by WPS Office.

.PARAMETER CleanupFileAssociations
    Additionally removes file type associations (ProgIDs) registered by WPS Office. Affected
    extensions are left with no default handler (normal uninstall behaviour) rather than
    being force-associated with another application.

.EXAMPLE
    iex (irm https://example.com/remove-wps.ps1)
    Interactive run with default settings (console UI + confirmation prompt).

.EXAMPLE
    & { iex (irm https://example.com/remove-wps.ps1) } -Silent -Force -JsonLog
    Fully unattended run suitable for RMM / SCCM deployment, with JSON logging.

.EXAMPLE
    .\remove-wps.ps1 -DryRun -Verbose
    Preview every action the utility would take without changing anything.

.NOTES
    Author     : rhshourav
    Repository : https://github.com/rhshourav/Windows-Scripts/
    Requires   : PowerShell 5.1+, Administrator privileges, Windows 10 / Windows 11
    Design note: This script intentionally uses functions + script-scoped state instead of
    PowerShell classes. PowerShell classes are parsed at compile time, and re-defining a class
    in the same session - which happens whenever this script is re-run via iex/irm in an
    already-open console - can throw "type already exists" errors. Because crash-free,
    idempotent re-execution via iex is a hard requirement, function-based modules (organised
    into #region blocks below) are the safer, enterprise-appropriate choice.
#>

[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoRestart,
    [string]$LogPath = $(if ($env:ProgramData) { Join-Path $env:ProgramData 'WpsRemovalUtility\Logs' } else { Join-Path $env:TEMP 'WpsRemovalUtility\Logs' }),
    [switch]$JsonLog,
    [switch]$CleanupTemp,
    [switch]$CleanupFirewall,
    [switch]$CleanupFileAssociations
)

#region ------------------------------- Environment / Strict Mode -------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Silent) { $Force = $true }
$Script:OriginalProgressPreference = $ProgressPreference
$ProgressPreference = if ($Silent) { 'SilentlyContinue' } else { 'Continue' }
#endregion

#region ------------------------------- Global Script State --------------------------------------
# Central configuration & statistics shared by every module/function in this script.
$Script:StartTime = Get-Date

$Script:Config = [ordered]@{
    Silent                  = [bool]$Silent
    DryRun                  = [bool]$DryRun
    Force                   = [bool]$Force
    NoRestart               = [bool]$NoRestart
    LogPath                 = $LogPath
    JsonLog                 = [bool]$JsonLog
    CleanupTemp             = [bool]$CleanupTemp
    CleanupFirewall         = [bool]$CleanupFirewall
    CleanupFileAssociations = [bool]$CleanupFileAssociations
    VerboseMode             = ($VerbosePreference -ne 'SilentlyContinue')
    DebugMode               = ($DebugPreference -ne 'SilentlyContinue')
}

$Script:Stats = [ordered]@{
    ProcessesTerminated   = 0
    ServicesRemoved       = 0
    ScheduledTasksRemoved = 0
    StartupEntriesRemoved = 0
    RegistryKeysRemoved   = 0
    FilesDeleted          = 0
    FoldersDeleted        = 0
    ShortcutsRemoved      = 0
    EnvEntriesRemoved     = 0
    FirewallRulesRemoved  = 0
    FileAssocRemoved      = 0
    UninstallersRun       = 0
    PendingRebootDeletes  = 0
    Warnings              = 0
    Errors                = 0
}

$Script:LogEntries    = New-Object System.Collections.Generic.List[object]
$Script:RebootRequired = $false
$Script:ExitCode       = 0

$Script:UtilityName    = 'WPS Office Enterprise Removal Utility'
$Script:UtilityVersion = '1.0.0'
$Script:Author         = 'rhshourav'
$Script:RepoUrl        = 'https://github.com/rhshourav/Windows-Scripts/'

# When this file is executed directly ("powershell.exe -File remove-wps.ps1" or ".\remove-wps.ps1")
# $PSCommandPath is populated and it is safe to call exit() at the end - only that process ends.
# When invoked via "iex (irm https://.../remove-wps.ps1)" there is no backing file, $PSCommandPath
# is empty, and the script body runs directly inside the user's *current* interactive console.
# Calling exit() in that case would silently close the user's whole PowerShell session/terminal -
# so exit() is only called when running as a real file; otherwise $LASTEXITCODE is set instead.
$Script:IsRunAsFile = -not [string]::IsNullOrEmpty($PSCommandPath)
#endregion

#region ------------------------------- Native Interop (built-in Win32 API only) -----------------
# Uses MoveFileEx from kernel32.dll (native to every Windows install - not a third-party tool)
# to schedule deletion of locked files/folders on next boot when they cannot be removed live.
# Guarded so re-running the script in the same PowerShell session (iex/irm) never throws
# "type already exists".
if (-not ('WpsRemovalUtility.NativeMethods' -as [type])) {
    Add-Type -Namespace WpsRemovalUtility -Name NativeMethods -MemberDefinition @'
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@
}
# MOVEFILE_DELAY_UNTIL_REBOOT = 0x4
$Script:MOVEFILE_DELAY_UNTIL_REBOOT = 4
#endregion

#region ------------------------------- Logger Module ---------------------------------------------
function Initialize-WpsLogger {
    <#
    .SYNOPSIS
        Prepares the log directory and log file paths. Safe to call multiple times.
    #>
    [CmdletBinding()]
    param()

    try {
        if (-not (Test-Path -LiteralPath $Script:Config.LogPath)) {
            New-Item -ItemType Directory -Path $Script:Config.LogPath -Force | Out-Null
        }
    } catch {
        # Fall back to a per-user temp location if ProgramData is not writable for any reason.
        $Script:Config.LogPath = Join-Path $env:TEMP 'WpsRemovalUtility\Logs'
        New-Item -ItemType Directory -Path $Script:Config.LogPath -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $stamp = $Script:StartTime.ToString('yyyyMMdd_HHmmss')
    $Script:TextLogPath = Join-Path $Script:Config.LogPath "WpsRemoval_$stamp.log"
    $Script:JsonLogPath = Join-Path $Script:Config.LogPath "WpsRemoval_$stamp.json"
    $Script:ReportTextPath = Join-Path $Script:Config.LogPath "WpsRemoval_Report_$stamp.txt"
    $Script:ReportJsonPath = Join-Path $Script:Config.LogPath "WpsRemoval_Report_$stamp.json"

    "===== WPS Office Removal Utility - Log started $($Script:StartTime.ToString('u')) =====" |
        Out-File -FilePath $Script:TextLogPath -Encoding utf8 -Append
}

function Write-WpsLog {
    <#
    .SYNOPSIS
        Central logging function used by every module. Records timestamp, severity, component,
        message/result and (optionally) execution time; writes to console, plain-text log, and
        (if -JsonLog was requested) a JSON Lines log, in a single call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Component,

        [Parameter(Mandatory)]
        [string]$Message,

        [Nullable[double]]$ExecutionTimeMs = $null
    )

    $timestamp = Get-Date
    $entry = [PSCustomObject]@{
        Timestamp      = $timestamp.ToString('yyyy-MM-dd HH:mm:ss')
        Level          = $Level
        Component      = $Component
        Message        = $Message
        ExecutionTimeMs = $ExecutionTimeMs
    }
    $Script:LogEntries.Add($entry) | Out-Null

    if ($Level -eq 'WARN')  { $Script:Stats.Warnings++ }
    if ($Level -eq 'ERROR') { $Script:Stats.Errors++ }

    # ---- Plain text log (always written, regardless of console verbosity) ----
    $timePart = if ($null -ne $ExecutionTimeMs) { " ({0:N0} ms)" -f $ExecutionTimeMs } else { '' }
    $line = "[{0}] {1,-7} {2,-20} {3}{4}" -f $entry.Timestamp, $Level, $Component, $Message, $timePart
    try {
        Add-Content -LiteralPath $Script:TextLogPath -Value $line -Encoding utf8
    } catch { }

    # ---- JSON Lines log (crash-safe, one JSON object per line) ----
    if ($Script:Config.JsonLog) {
        try {
            ($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Script:JsonLogPath -Encoding utf8
        } catch { }
    }

    # ---- Console output ----
    if ($Level -eq 'DEBUG' -and -not $Script:Config.DebugMode) { return }
    if ($Script:Config.Silent -and $Level -notin @('ERROR', 'WARN')) { return }

    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'DEBUG'   { 'DarkGray' }
        default   { 'White' }
    }
    Write-Host ("[{0}] " -f $entry.Timestamp) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-7} " -f $Level) -NoNewline -ForegroundColor $color
    Write-Host ("{0,-20} " -f $Component) -NoNewline -ForegroundColor White
    Write-Host $Message -ForegroundColor $color
}
#endregion

#region ------------------------------- Privilege Manager -----------------------------------------
function Test-IsElevated {
    <#
    .SYNOPSIS
        Returns $true if the current PowerShell process is running with Administrator rights.
    #>
    [CmdletBinding()]
    param()
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WpsElevation {
    <#
    .SYNOPSIS
        Ensures the script is running elevated. Exits with a clear, actionable error if not.
    .NOTES
        When invoked through "iex (irm ...)" the script has no on-disk path to relaunch itself
        from, so automatic self-elevation is not attempted; the user is instead given the exact
        remediation command to copy/paste into an elevated console.
    #>
    [CmdletBinding()]
    param()

    if (Test-IsElevated) {
        Write-WpsLog -Level 'SUCCESS' -Component 'PrivilegeManager' -Message 'Running with Administrator privileges.'
        return
    }

    Write-WpsLog -Level 'ERROR' -Component 'PrivilegeManager' -Message 'Administrator privileges are required.'
    if (-not $Script:Config.Silent) {
        Write-Host ''
        Write-Host 'This utility must be run from an elevated (Administrator) PowerShell session.' -ForegroundColor Red
        Write-Host 'Right-click PowerShell (or Windows Terminal) and choose "Run as administrator", then re-run:' -ForegroundColor Yellow
        Write-Host '    iex (irm https://example.com/remove-wps.ps1)' -ForegroundColor White
        Write-Host ''
    }
    $Script:ExitCode = 5
    Complete-WpsRemoval -Aborted
}
#endregion

#region ------------------------------- Configuration: Identity Whitelist / Blacklist -------------
# Everything the script is allowed to touch must positively match one of the "WPS identity"
# patterns below AND must NOT match the protective blacklist. This two-sided check is the core
# safety mechanism requested: "never remove unrelated software."

# Process names that are unique enough to WPS/Kingsoft branding to be trusted on name alone
# (still opportunistically verified against file metadata/path when the file is reachable).
$Script:WpsHighConfidenceProcessNames = @(
    'wpsoffice.exe', 'wpscenter.exe', 'wpscloudsvr.exe', 'wpsupdate.exe', 'wpsnotify.exe',
    'wpsmirror.exe', 'wpsservice.exe', 'ksolaunch.exe', 'kwpsupdate.exe', 'wpscloudsvrmgr.exe',
    'wpsdocer.exe', 'wpscloud.exe', 'kingsoftmonitor.exe', 'wpsstore.exe'
)

# Process names that ARE used by WPS Office but are short/generic enough that they must be
# corroborated with file metadata or install path before any action is taken.
$Script:WpsAmbiguousProcessNames = @('wps.exe', 'wpp.exe', 'et.exe', 'wpspdf.exe', 'wpsapp.exe')

# Substrings that identify a path, service, task, or registry value as belonging to WPS Office
# (case-insensitive matching is used everywhere these are consumed).
$Script:WpsPathKeywords = @(
    'kingsoft', 'wps office', 'wpsoffice', 'wps cloud', 'wpscloud', 'wps365', 'wps office365'
)

# Publisher / DisplayName substrings from Uninstall registry keys, MSI product info, or file
# version metadata that identify WPS Office.
$Script:WpsIdentityPatterns = @(
    'Kingsoft', 'WPS Office', 'WPS Office365', 'WPS Cloud', 'WPS PDF', 'WPS Presentation',
    'WPS Spreadsheet', 'WPS Writer', 'WPS Store', 'Zhuhai Kingsoft'
)

# Protective blacklist: if ANY of these match, the item is skipped even if it also matched an
# identity pattern above (defense in depth against false positives / substring collisions).
$Script:WpsBlacklistPatterns = @(
    'Microsoft Corporation', 'Microsoft Office', 'Microsoft 365', 'Microsoft Excel',
    'Microsoft Word', 'Microsoft PowerPoint', 'Microsoft Outlook', 'Microsoft Access',
    'LibreOffice', 'The Document Foundation', 'OpenOffice', 'Apache OpenOffice',
    'Adobe', 'Google LLC', 'Mozilla', 'Oracle', 'WinRAR', '7-Zip', 'Foxit',
    'NitroPDF', 'Nitro Software', 'Windows Media Player', 'Microsoft SQL Server',
    '\\Fonts\\', '\\Users\\Public\\Documents', '\\Users\\[^\\]+\\Documents\\',
    '\\Users\\[^\\]+\\Desktop\\[^\\]+\\.pdf$', 'Wi-Fi Protected Setup', 'WirelessProvisioning'
)

function Test-WpsBlacklisted {
    <#
    .SYNOPSIS
        Returns $true if the supplied text matches any protective blacklist pattern and must
        therefore never be modified or deleted, even if it also matches a WPS identity pattern.
    #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($pattern in $Script:WpsBlacklistPatterns) {
        if ($Text -imatch $pattern) { return $true }
    }
    return $false
}

function Test-WpsTextIdentity {
    <#
    .SYNOPSIS
        Returns $true only if $Text positively matches a WPS/Kingsoft identity pattern and does
        NOT match the protective blacklist.
    #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if (Test-WpsBlacklisted -Text $Text) { return $false }

    foreach ($pattern in $Script:WpsIdentityPatterns) {
        if ($Text -imatch [regex]::Escape($pattern)) { return $true }
    }
    foreach ($keyword in $Script:WpsPathKeywords) {
        if ($Text -imatch [regex]::Escape($keyword)) { return $true }
    }
    return $false
}

function Test-WpsFileIdentity {
    <#
    .SYNOPSIS
        Positively identifies whether a file on disk belongs to WPS Office / Kingsoft by
        inspecting its path plus (when readable) its FileVersionInfo CompanyName/ProductName.
        Used to safely corroborate ambiguous, generically-named executables (e.g. et.exe).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-WpsBlacklisted -Text $Path) { return $false }
    if (Test-WpsTextIdentity -Text $Path) { return $true }

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
            $meta = "$($vi.CompanyName) $($vi.ProductName) $($vi.FileDescription)"
            if (Test-WpsBlacklisted -Text $meta) { return $false }
            if (Test-WpsTextIdentity -Text $meta) { return $true }
        }
    } catch {
        # File metadata unreadable (locked, offline profile, etc.) - fall through to $false.
    }
    return $false
}
#endregion

#region ------------------------------- Core Helper Utilities --------------------------------------
function Get-WpsSafeProperty {
    <#
    .SYNOPSIS
        Strict-mode-safe property reader. Returns $DefaultValue instead of throwing when the
        named property does not exist on the given object.

    .DESCRIPTION
        Under Set-StrictMode -Version Latest (in effect for this whole script), dereferencing a
        property that doesn't exist on an object - e.g. $obj.Foo when $obj has no 'Foo' member -
        throws a terminating "The property 'Foo' cannot be found on this object" error instead of
        quietly returning $null. This bites on any object whose shape varies per-instance, most
        notably:
          - Get-ItemProperty results: only values that actually exist under a given registry key
            become NoteProperties, so optional values (Publisher, InstallLocation, the unnamed
            '(default)' value, etc.) are simply absent on many real-world entries.
          - Scheduled task action CIM instances: MSFT_TaskExecAction has Execute/Arguments, but
            MSFT_TaskComHandlerAction (ClassId/Data) and other action types do not - and Windows
            ships plenty of built-in ComHandler-action tasks, so this is hit on virtually every
            real machine, not just an edge case.
        Checking for the member via .PSObject.Properties[...] first (rather than dereferencing
        directly) is safe under strict mode and lets every call site read optional
        properties/values without needing its own try/catch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $DefaultValue }
    return $prop.Value
}

function Invoke-WpsAction {
    <#
    .SYNOPSIS
        Central execution wrapper: honours -DryRun, times the action, logs success/failure, and
        never lets an unhandled exception from one action abort the whole run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Component = 'General'
    )

    if ($Script:Config.DryRun) {
        Write-WpsLog -Level 'INFO' -Component $Component -Message "[DRYRUN] Would perform: $Description"
        return $true
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        $sw.Stop()
        Write-WpsLog -Level 'SUCCESS' -Component $Component -Message $Description -ExecutionTimeMs $sw.Elapsed.TotalMilliseconds
        return $true
    } catch {
        $sw.Stop()
        Write-WpsLog -Level 'ERROR' -Component $Component -Message "$Description :: $($_.Exception.Message)" -ExecutionTimeMs $sw.Elapsed.TotalMilliseconds
        return $false
    }
}

function Get-WpsUserProfiles {
    <#
    .SYNOPSIS
        Enumerates every real local user profile (loaded or not), skipping built-in service SIDs.
    #>
    [CmdletBinding()]
    param()

    $profiles = New-Object System.Collections.Generic.List[object]
    $profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    try {
        Get-ChildItem -LiteralPath $profileListKey -ErrorAction Stop | ForEach-Object {
            $sid = $_.PSChildName
            if ($sid -match '^S-1-5-(18|19|20)$') { return }
            if ($sid -match '_Classes$') { return }

            # ProfileImagePath is virtually always present, but orphaned/corrupt ProfileList SIDs
            # do exist in the wild without it - read it safely rather than risking the same
            # missing-property crash under Set-StrictMode -Version Latest.
            $profileProps = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $imagePath = Get-WpsSafeProperty -InputObject $profileProps -Name 'ProfileImagePath'
            if ([string]::IsNullOrWhiteSpace($imagePath)) { return }
            if (-not (Test-Path -LiteralPath $imagePath)) { return }

            $loaded = Test-Path -LiteralPath "Registry::HKEY_USERS\$sid"
            $profiles.Add([PSCustomObject]@{
                Sid           = $sid
                ProfilePath   = $imagePath
                Username      = Split-Path -Path $imagePath -Leaf
                Loaded        = $loaded
                NtUserDatPath = Join-Path $imagePath 'NTUSER.DAT'
            }) | Out-Null
        }
    } catch {
        Write-WpsLog -Level 'WARN' -Component 'ProfileEnum' -Message "Could not enumerate user profiles: $($_.Exception.Message)"
    }
    return $profiles
}

function Mount-WpsOfflineHive {
    <#
    .SYNOPSIS
        Loads an offline user's NTUSER.DAT under HKEY_USERS\<MountKeyName> using the built-in
        reg.exe so its registry can be scanned/cleaned even while the user is logged off.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NtUserDatPath,
        [Parameter(Mandatory)][string]$MountKeyName
    )

    if (-not (Test-Path -LiteralPath $NtUserDatPath)) { return $false }
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$MountKeyName") { return $true }

    try {
        $regExe = Join-Path $env:WINDIR 'System32\reg.exe'
        $argString = "load `"HKU\$MountKeyName`" `"$NtUserDatPath`""
        $p = Start-Process -FilePath $regExe -ArgumentList $argString -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Dismount-WpsOfflineHive {
    <#
    .SYNOPSIS
        Unloads a hive previously mounted with Mount-WpsOfflineHive. Forces garbage collection
        first so no lingering .NET registry handles cause "access denied" on unload.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountKeyName)

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 200

    try {
        $regExe = Join-Path $env:WINDIR 'System32\reg.exe'
        $p = Start-Process -FilePath $regExe -ArgumentList "unload `"HKU\$MountKeyName`"" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function ConvertTo-WpsLongPath {
    <#
    .SYNOPSIS
        Prefixes a path with \\?\ (or \\?\UNC\) when needed so file operations are not limited
        by MAX_PATH (260 chars) - handles the "Long paths" requirement without relying on any
        third-party tool.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.Length -lt 240) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.TrimStart('\') }
    return '\\?\' + $Path
}

function Clear-WpsFileAttributes {
    <#
    .SYNOPSIS
        Clears ReadOnly/System/Hidden attributes on a single file/folder so it can be deleted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $blocked = [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden
        if ([int]$item.Attributes -band [int]$blocked) {
            $item.Attributes = [System.IO.FileAttributes]($item.Attributes -band (-bnot $blocked))
        }
    } catch { }
}

function Register-WpsPendingDelete {
    <#
    .SYNOPSIS
        Schedules a locked file/folder for deletion on next boot via the native MoveFileEx API
        (kernel32.dll), recursing depth-first so child files are scheduled before their parent
        directory (required for the directory to be empty when Windows processes the queue).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Register-WpsPendingDelete -Path $_.FullName
            }
        }
        $longPath = ConvertTo-WpsLongPath -Path $Path
        [void][WpsRemovalUtility.NativeMethods]::MoveFileEx($longPath, [string]$null, $Script:MOVEFILE_DELAY_UNTIL_REBOOT)
        $Script:Stats.PendingRebootDeletes++
        $Script:RebootRequired = $true
    } catch { }
}

function Remove-WpsPathSafely {
    <#
    .SYNOPSIS
        Deletes a file or folder that has ALREADY been positively identified as WPS-owned, with
        attribute clearing, retry/backoff for transient locks, and a reboot-pending fallback
        (Register-WpsPendingDelete) for anything still locked after retries are exhausted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxRetries = 4,
        [int]$RetryDelayMs = 600
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    if ($Script:Config.DryRun) {
        Write-WpsLog -Level 'INFO' -Component 'FilesystemCleaner' -Message "[DRYRUN] Would delete: $Path"
        return $true
    }

    $isContainer = (Get-Item -LiteralPath $Path -Force).PSIsContainer

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if ($isContainer) {
                Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Sort-Object { $_.FullName.Length } -Descending |
                    ForEach-Object { Clear-WpsFileAttributes -Path $_.FullName }
                Clear-WpsFileAttributes -Path $Path
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                $Script:Stats.FoldersDeleted++
            } else {
                Clear-WpsFileAttributes -Path $Path
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                $Script:Stats.FilesDeleted++
            }
            Write-WpsLog -Level 'SUCCESS' -Component 'FilesystemCleaner' -Message "Deleted: $Path"
            return $true
        } catch {
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
                continue
            }
            Write-WpsLog -Level 'WARN' -Component 'FilesystemCleaner' `
                -Message "Locked after $MaxRetries attempts - scheduling deletion on next boot: $Path"
            Register-WpsPendingDelete -Path $Path
            return $false
        }
    }
}
#endregion

#region ------------------------------- Process Manager --------------------------------------------
function Get-WpsProcesses {
    <#
    .SYNOPSIS
        Returns all currently running processes positively identified as WPS Office / Kingsoft.
    #>
    [CmdletBinding()]
    param()

    $found = New-Object System.Collections.Generic.List[object]
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = $_
        $exeName = "$($proc.ProcessName).exe"
        $path = $null
        try { $path = $proc.Path } catch { $path = $null }

        $isMatch = $false
        if ($Script:WpsHighConfidenceProcessNames -icontains $exeName) {
            $isMatch = $true
        }
        elseif ($Script:WpsAmbiguousProcessNames -icontains $exeName) {
            if ($path -and (Test-WpsFileIdentity -Path $path)) { $isMatch = $true }
        }
        elseif ($proc.ProcessName -imatch '^(wps|kingsoft|ksolaunch|kwps)') {
            if ($path) {
                if (Test-WpsFileIdentity -Path $path) { $isMatch = $true }
            } elseif (-not (Test-WpsBlacklisted -Text $proc.ProcessName)) {
                $isMatch = $true
            }
        }

        if ($isMatch) { $found.Add($proc) | Out-Null }
    }
    return $found
}

function Stop-WpsProcesses {
    <#
    .SYNOPSIS
        Gracefully closes, then force-terminates, every WPS Office process. Re-scans up to
        -MaxPasses times in case a watchdog/updater process respawns a child.
    #>
    [CmdletBinding()]
    param([int]$MaxPasses = 3)

    $stoppedTotal = 0

    for ($pass = 1; $pass -le $MaxPasses; $pass++) {
        $procs = Get-WpsProcesses
        if ($procs.Count -eq 0) { break }

        if ($Script:Config.DryRun) {
            foreach ($proc in $procs) {
                Write-WpsLog -Level 'INFO' -Component 'ProcessManager' -Message "[DRYRUN] Would terminate $($proc.ProcessName) (PID $($proc.Id))"
            }
            return $procs.Count
        }

        # Step 1: ask nicely.
        foreach ($proc in $procs) {
            try { $null = $proc.CloseMainWindow() } catch { }
        }
        Start-Sleep -Milliseconds 1500

        # Step 2: force anything still alive.
        foreach ($proc in $procs) {
            try {
                $stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                if ($stillRunning) {
                    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                    $stillRunning.WaitForExit(5000) | Out-Null
                }
                $stoppedTotal++
                $Script:Stats.ProcessesTerminated++
                Write-WpsLog -Level 'SUCCESS' -Component 'ProcessManager' -Message "Terminated $($proc.ProcessName) (PID $($proc.Id))"
            } catch {
                Write-WpsLog -Level 'WARN' -Component 'ProcessManager' -Message "Failed to terminate $($proc.ProcessName) (PID $($proc.Id)): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Milliseconds 500
    }

    $remaining = Get-WpsProcesses
    if ($remaining.Count -gt 0) {
        Write-WpsLog -Level 'WARN' -Component 'ProcessManager' -Message "$($remaining.Count) WPS process(es) still present after $MaxPasses cleanup pass(es)."
    }
    return $stoppedTotal
}
#endregion

#region ------------------------------- Service Manager ---------------------------------------------
function Get-WpsServices {
    <#
    .SYNOPSIS
        Returns all Windows services positively identified as belonging to WPS Office/Kingsoft,
        verified against both service name/display name AND the service binary path.
    #>
    [CmdletBinding()]
    param()

    $found = New-Object System.Collections.Generic.List[object]
    try {
        $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
    } catch {
        Write-WpsLog -Level 'WARN' -Component 'ServiceManager' -Message "Could not query services via CIM: $($_.Exception.Message)"
        return $found
    }

    foreach ($svc in $services) {
        $identityText = "$($svc.Name) $($svc.DisplayName) $($svc.PathName)"
        if (Test-WpsTextIdentity -Text $identityText) {
            $found.Add($svc) | Out-Null
        }
    }
    return $found
}

function Remove-WpsServices {
    <#
    .SYNOPSIS
        Stops and deletes every WPS-related service. Uses sc.exe (built into every Windows
        install) to delete the service, since Remove-Service is not available in PS 5.1.
    #>
    [CmdletBinding()]
    param()

    $services = Get-WpsServices
    if ($services.Count -eq 0) {
        Write-WpsLog -Level 'INFO' -Component 'ServiceManager' -Message 'No WPS-related services found.'
        return 0
    }

    $removed = 0
    $scExe = Join-Path $env:WINDIR 'System32\sc.exe'

    foreach ($svc in $services) {
        $name = $svc.Name
        $result = Invoke-WpsAction -Component 'ServiceManager' -Description "Stop and remove service '$name'" -Action {
            try {
                $svcObj = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($svcObj -and $svcObj.Status -ne 'Stopped') {
                    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                    try { $svcObj.WaitForStatus('Stopped', (New-TimeSpan -Seconds 10)) } catch { }
                }
            } catch { }

            $scOutput = & $scExe delete "$name" 2>&1
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1060) {
                # 1060 = "service does not exist" - already gone, treat as idempotent success.
                throw "sc.exe delete returned exit code $LASTEXITCODE : $scOutput"
            }
        }
        if ($result) { $removed++; $Script:Stats.ServicesRemoved++ }
    }
    return $removed
}
#endregion

#region ------------------------------- Scheduled Task Cleaner --------------------------------------
function Get-WpsScheduledTasks {
    <#
    .SYNOPSIS
        Returns every scheduled task (searched recursively across all folders) whose name,
        path, or action positively identifies it as belonging to WPS Office.
    #>
    [CmdletBinding()]
    param()

    $found = New-Object System.Collections.Generic.List[object]
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop
    } catch {
        Write-WpsLog -Level 'WARN' -Component 'ScheduledTaskCleaner' -Message "Could not query scheduled tasks: $($_.Exception.Message)"
        return $found
    }

    foreach ($task in $tasks) {
        # Task actions are CIM instances and are NOT all the same type - MSFT_TaskExecAction has
        # Execute/Arguments, but MSFT_TaskComHandlerAction (ClassId/Data) and the deprecated
        # MSFT_TaskEmailAction / MSFT_TaskShowMessageAction do not. Windows ships many built-in
        # tasks (Defender, Edge/Office update tasks, etc.) using ComHandler actions, so
        # dereferencing $_.Execute directly WILL hit a non-existent property under
        # Set-StrictMode -Version Latest and throw "The property 'Execute' cannot be found on
        # this object." Get-WpsSafeProperty reads it without assuming it exists.
        $actionText = (($task.Actions | ForEach-Object {
            $exec = Get-WpsSafeProperty -InputObject $_ -Name 'Execute'   -DefaultValue ''
            $args = Get-WpsSafeProperty -InputObject $_ -Name 'Arguments' -DefaultValue ''
            "$exec $args"
        }) -join ' ')
        $identityText = "$($task.TaskName) $($task.TaskPath) $actionText"
        if (Test-WpsTextIdentity -Text $identityText) {
            $found.Add($task) | Out-Null
        }
    }
    return $found
}

function Remove-WpsScheduledTasks {
    <#
    .SYNOPSIS
        Unregisters every scheduled task identified by Get-WpsScheduledTasks. Missing entries
        are silently ignored (idempotent).
    #>
    [CmdletBinding()]
    param()

    $tasks = Get-WpsScheduledTasks
    if ($tasks.Count -eq 0) {
        Write-WpsLog -Level 'INFO' -Component 'ScheduledTaskCleaner' -Message 'No WPS-related scheduled tasks found.'
        return 0
    }

    $removed = 0
    foreach ($task in $tasks) {
        $taskName = $task.TaskName
        $taskPath = $task.TaskPath
        $result = Invoke-WpsAction -Component 'ScheduledTaskCleaner' -Description "Remove scheduled task '$taskPath$taskName'" -Action {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        }
        if ($result) { $removed++; $Script:Stats.ScheduledTasksRemoved++ }
    }
    return $removed
}
#endregion

#region ------------------------------- Startup Cleaner ----------------------------------------------
function Remove-WpsRunKeyEntries {
    <#
    .SYNOPSIS
        Removes only the WPS-identified value(s) from a Run/RunOnce-style registry key, leaving
        every unrelated autorun entry in that key completely untouched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeyPath)

    $removed = 0
    if (-not (Test-Path -LiteralPath $KeyPath)) { return 0 }

    try {
        $key = Get-Item -LiteralPath $KeyPath -ErrorAction Stop
        foreach ($valueName in @($key.GetValueNames())) {
            $data = $key.GetValue($valueName)
            if ($data -and (Test-WpsTextIdentity -Text "$valueName $data")) {
                $result = Invoke-WpsAction -Component 'StartupCleaner' -Description "Remove Run entry '$valueName' from $KeyPath" -Action {
                    Remove-ItemProperty -LiteralPath $KeyPath -Name $valueName -Force -ErrorAction Stop
                }
                if ($result) { $removed++; $Script:Stats.StartupEntriesRemoved++ }
            }
        }
    } catch {
        Write-WpsLog -Level 'WARN' -Component 'StartupCleaner' -Message "Could not scan $KeyPath : $($_.Exception.Message)"
    }
    return $removed
}

function Remove-WpsStartupApprovedEntries {
    <#
    .SYNOPSIS
        Cleans stale StartupApproved enable/disable state entries left behind after their
        matching Run value has been removed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeyPath)

    $removed = 0
    if (-not (Test-Path -LiteralPath $KeyPath)) { return 0 }

    try {
        $key = Get-Item -LiteralPath $KeyPath -ErrorAction Stop
        foreach ($valueName in @($key.GetValueNames())) {
            if (Test-WpsTextIdentity -Text $valueName) {
                $result = Invoke-WpsAction -Component 'StartupCleaner' -Description "Remove StartupApproved entry '$valueName'" -Action {
                    Remove-ItemProperty -LiteralPath $KeyPath -Name $valueName -Force -ErrorAction Stop
                }
                if ($result) { $removed++; $Script:Stats.StartupEntriesRemoved++ }
            }
        }
    } catch { }
    return $removed
}

function Remove-WpsStartupShortcuts {
    <#
    .SYNOPSIS
        Removes .lnk shortcuts from a Startup folder whose file name or resolved target
        identifies them as WPS Office.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FolderPath)

    $removed = 0
    if (-not (Test-Path -LiteralPath $FolderPath)) { return 0 }

    Get-ChildItem -LiteralPath $FolderPath -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $target = Get-WpsShortcutTarget -LnkPath $_.FullName
        if ((Test-WpsTextIdentity -Text $_.Name) -or ($target -and (Test-WpsFileIdentity -Path $target))) {
            if (Remove-WpsPathSafely -Path $_.FullName) {
                $removed++
                $Script:Stats.ShortcutsRemoved++
            }
        }
    }
    return $removed
}

function Remove-WpsStartupEntries {
    <#
    .SYNOPSIS
        Full startup cleanup pass: machine + user Run/RunOnce keys (including Group Policy
        Explorer\Run locations), StartupApproved state, and Startup-folder shortcuts for every
        profile (loaded or offline) plus the machine-wide Common Startup folder.
    #>
    [CmdletBinding()]
    param()

    $removed = 0
    $runKeyPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Policies\Microsoft\Windows\Explorer\Run',
        'HKCU:\Software\Policies\Microsoft\Windows\Explorer\Run'
    )
    foreach ($keyPath in $runKeyPaths) {
        $removed += Remove-WpsRunKeyEntries -KeyPath $keyPath
    }
    $removed += Remove-WpsStartupApprovedEntries -KeyPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $removed += Remove-WpsStartupApprovedEntries -KeyPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

    foreach ($profile in (Get-WpsUserProfiles)) {
        $mounted = $false
        $mountKey = "WpsTmp_$($profile.Sid -replace '[^A-Za-z0-9]', '')"
        $hivePrefix = "Registry::HKEY_USERS\$($profile.Sid)"

        if (-not $profile.Loaded) {
            $mounted = Mount-WpsOfflineHive -NtUserDatPath $profile.NtUserDatPath -MountKeyName $mountKey
            if ($mounted) { $hivePrefix = "Registry::HKEY_USERS\$mountKey" }
        }

        if ($profile.Loaded -or $mounted) {
            foreach ($sub in @('Run', 'RunOnce')) {
                $removed += Remove-WpsRunKeyEntries -KeyPath "$hivePrefix\Software\Microsoft\Windows\CurrentVersion\$sub"
            }
            $removed += Remove-WpsStartupApprovedEntries -KeyPath "$hivePrefix\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        }
        if ($mounted) { Dismount-WpsOfflineHive -MountKeyName $mountKey | Out-Null }

        $startupFolder = Join-Path $profile.ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $removed += Remove-WpsStartupShortcuts -FolderPath $startupFolder
    }

    $commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    $removed += Remove-WpsStartupShortcuts -FolderPath $commonStartup

    Write-WpsLog -Level 'INFO' -Component 'StartupCleaner' -Message "Startup cleanup complete - $removed entr$(if ($removed -eq 1) { 'y' } else { 'ies' }) removed."
    return $removed
}
#endregion

#region ------------------------------- Installer Detection / Registry Cleaner -----------------------
function Get-WpsUninstallEntriesUnder {
    <#
    .SYNOPSIS
        Scans a single Uninstall registry key for entries positively identified as WPS Office.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeyPath)

    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $KeyPath)) { return $results }

    Get-ChildItem -LiteralPath $KeyPath -ErrorAction SilentlyContinue | ForEach-Object {
        $itemPath = $_.PSPath
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $itemPath -ErrorAction Stop } catch { return }

        # Get-ItemProperty only creates a NoteProperty for values that actually exist under the
        # key - DisplayName/UninstallString are near-universal, but Publisher, InstallLocation,
        # QuietUninstallString, and DisplayVersion are all optional and frequently absent.
        # Dereferencing a missing one directly ($props.Publisher) throws under
        # Set-StrictMode -Version Latest, so every optional value is read via Get-WpsSafeProperty.
        $displayName = Get-WpsSafeProperty -InputObject $props -Name 'DisplayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) { return }

        $publisher       = Get-WpsSafeProperty -InputObject $props -Name 'Publisher'
        $installLocation = Get-WpsSafeProperty -InputObject $props -Name 'InstallLocation'

        $identityText = "$displayName $publisher $installLocation"
        if (Test-WpsTextIdentity -Text $identityText) {
            $results.Add([PSCustomObject]@{
                DisplayName          = $displayName
                Publisher            = $publisher
                DisplayVersion       = Get-WpsSafeProperty -InputObject $props -Name 'DisplayVersion'
                UninstallString      = Get-WpsSafeProperty -InputObject $props -Name 'UninstallString'
                QuietUninstallString = Get-WpsSafeProperty -InputObject $props -Name 'QuietUninstallString'
                InstallLocation      = $installLocation
                RegistryPath         = $itemPath
                ProductCode          = $_.PSChildName
            }) | Out-Null
        }
    }
    return $results
}

function Get-WpsUninstallEntries {
    <#
    .SYNOPSIS
        Scans every reachable (live) Uninstall registry location - HKLM, HKLM\WOW6432Node, HKCU,
        and every currently-loaded user hive - for WPS Office entries. Offline (logged-off)
        profiles are intentionally handled separately (Remove-WpsOfflineProfileRemnants) since a
        per-user vendor/MSI uninstaller cannot be meaningfully executed for a user who is not
        logged on; those profiles get direct registry+file cleanup instead of uninstaller
        invocation.
    #>
    [CmdletBinding()]
    param()

    $found = New-Object System.Collections.Generic.List[object]
    $relativeUninstallPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'

    $found.AddRange(@(Get-WpsUninstallEntriesUnder -KeyPath "HKLM:\$relativeUninstallPath"))
    $found.AddRange(@(Get-WpsUninstallEntriesUnder -KeyPath "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"))
    $found.AddRange(@(Get-WpsUninstallEntriesUnder -KeyPath "HKCU:\$relativeUninstallPath"))

    foreach ($profile in (Get-WpsUserProfiles | Where-Object { $_.Loaded })) {
        $found.AddRange(@(Get-WpsUninstallEntriesUnder -KeyPath "Registry::HKEY_USERS\$($profile.Sid)\$relativeUninstallPath"))
    }

    return $found
}

function Remove-WpsUninstallRegistryKeys {
    <#
    .SYNOPSIS
        Removes the Uninstall registry key itself for each supplied entry (run AFTER the
        Uninstall Engine has attempted the real uninstall, to mop up anything the vendor
        uninstaller left behind).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Entries)

    $removed = 0
    foreach ($entry in $Entries) {
        if (-not (Test-Path -LiteralPath $entry.RegistryPath)) { continue }
        $regPath = $entry.RegistryPath
        $result = Invoke-WpsAction -Component 'RegistryCleaner' -Description "Remove uninstall registry entry '$($entry.DisplayName)'" -Action {
            Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction Stop
        }
        if ($result) { $removed++; $Script:Stats.RegistryKeysRemoved++ }
    }
    return $removed
}

function Remove-WpsKnownRegistryKeys {
    <#
    .SYNOPSIS
        Removes the fixed set of registry locations that WPS Office/Kingsoft is always known to
        create (root Kingsoft/WPS trees and their App Paths entries). Even these "known" paths
        are re-validated against the protective blacklist immediately before deletion.
    #>
    [CmdletBinding()]
    param()

    $removed = 0
    $knownPaths = @(
        'HKCU:\Software\Kingsoft', 'HKLM:\Software\Kingsoft', 'HKLM:\Software\WOW6432Node\Kingsoft',
        'HKCU:\Software\WPS', 'HKLM:\Software\WPS', 'HKLM:\Software\WOW6432Node\WPS',
        'HKCU:\Software\Classes\kwpsoffice',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\wps.exe',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\wpp.exe',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\et.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\wps.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\wpp.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\et.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\wps.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\wpp.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\et.exe'
    )

    foreach ($path in $knownPaths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (Test-WpsBlacklisted -Text $path) {
            Write-WpsLog -Level 'WARN' -Component 'RegistryCleaner' -Message "Skipped protected path: $path"
            continue
        }
        $result = Invoke-WpsAction -Component 'RegistryCleaner' -Description "Remove registry key $path" -Action {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
        if ($result) { $removed++; $Script:Stats.RegistryKeysRemoved++ }
    }
    return $removed
}

function Remove-WpsComAndShellExtensions {
    <#
    .SYNOPSIS
        Removes WPS Office shell-extension approvals and their underlying CLSID/InprocServer32
        COM registrations (context-menu handlers, preview handlers, thumbnail providers, etc.).
    #>
    [CmdletBinding()]
    param()

    $removed = 0
    $approvedPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'
    )

    foreach ($path in $approvedPaths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $key = Get-Item -LiteralPath $path -ErrorAction Stop
            foreach ($clsid in @($key.GetValueNames())) {
                $desc = $key.GetValue($clsid)
                if (-not $desc -or -not (Test-WpsTextIdentity -Text $desc)) { continue }

                $result = Invoke-WpsAction -Component 'RegistryCleaner' -Description "Remove approved shell extension '$desc' ($clsid)" -Action {
                    Remove-ItemProperty -LiteralPath $path -Name $clsid -Force -ErrorAction Stop
                }
                if ($result) { $removed++; $Script:Stats.RegistryKeysRemoved++ }

                foreach ($clsidRoot in @('HKLM:\Software\Classes\CLSID', 'HKCU:\Software\Classes\CLSID', 'HKLM:\Software\WOW6432Node\Classes\CLSID')) {
                    $clsidPath = Join-Path $clsidRoot $clsid
                    $inproc = Join-Path $clsidPath 'InprocServer32'
                    if (-not (Test-Path -LiteralPath $inproc)) { continue }
                    $dllPath = (Get-ItemProperty -LiteralPath $inproc -ErrorAction SilentlyContinue).'(default)'
                    if ($dllPath -and (Test-WpsFileIdentity -Path $dllPath)) {
                        $result2 = Invoke-WpsAction -Component 'RegistryCleaner' -Description "Remove CLSID registration $clsid ($dllPath)" -Action {
                            Remove-Item -LiteralPath $clsidPath -Recurse -Force -ErrorAction Stop
                        }
                        if ($result2) { $removed++; $Script:Stats.RegistryKeysRemoved++ }
                    }
                }
            }
        } catch {
            Write-WpsLog -Level 'WARN' -Component 'RegistryCleaner' -Message "Could not scan $path : $($_.Exception.Message)"
        }
    }
    return $removed
}

function Remove-WpsFileAssociations {
    <#
    .SYNOPSIS
        (Opt-in via -CleanupFileAssociations) Removes ProgIDs registered by WPS Office and
        clears any file-extension default handler / per-user UserChoice pinned to one of those
        ProgIDs. Extensions are left with NO default handler (standard, expected post-uninstall
        state) rather than being force-reassigned to another application.
    #>
    [CmdletBinding()]
    param()

    if (-not $Script:Config.CleanupFileAssociations) {
        Write-WpsLog -Level 'INFO' -Component 'RegistryCleaner' -Message 'File association cleanup skipped (pass -CleanupFileAssociations to enable).'
        return 0
    }

    $removed = 0
    $classRoots = @('HKLM:\Software\Classes', 'HKCU:\Software\Classes')
    $wpsProgIds = New-Object System.Collections.Generic.List[string]

    foreach ($root in $classRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSChildName.StartsWith('.') } |
            ForEach-Object {
                $progId = $_.PSChildName
                $itemPath = $_.PSPath
                try {
                    $props = Get-ItemProperty -LiteralPath $itemPath -ErrorAction Stop
                    $identityText = "$progId $($props.'(default)')"
                    if (Test-WpsTextIdentity -Text $identityText) {
                        $wpsProgIds.Add($progId) | Out-Null
                        $result = Invoke-WpsAction -Component 'RegistryCleaner' -Description "Remove file-type ProgID '$progId'" -Action {
                            Remove-Item -LiteralPath $itemPath -Recurse -Force -ErrorAction Stop
                        }
                        if ($result) { $removed++; $Script:Stats.FileAssocRemoved++ }
                    }
                } catch { }
            }
    }

    foreach ($root in $classRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName.StartsWith('.') } |
            ForEach-Object {
                $extName = $_.PSChildName
                $extPath = $_.PSPath
                try {
                    $props = Get-ItemProperty -LiteralPath $extPath -ErrorAction Stop
                    if ($props.'(default)' -and ($wpsProgIds -icontains $props.'(default)')) {
                        Invoke-WpsAction -Component 'RegistryCleaner' -Description "Clear default handler for $extName" -Action {
                            Set-ItemProperty -LiteralPath $extPath -Name '(default)' -Value '' -ErrorAction Stop
                        } | Out-Null
                    }
                } catch { }

                $userChoicePath = Join-Path $extPath 'UserChoice'
                if (Test-Path -LiteralPath $userChoicePath) {
                    try {
                        $progId = (Get-ItemProperty -LiteralPath $userChoicePath -ErrorAction Stop).ProgId
                        if ($progId -and ($wpsProgIds -icontains $progId)) {
                            Invoke-WpsAction -Component 'RegistryCleaner' -Description "Clear UserChoice default app for $extName" -Action {
                                Remove-Item -LiteralPath $userChoicePath -Recurse -Force -ErrorAction Stop
                            } | Out-Null
                        }
                    } catch { }
                }
            }
    }

    return $removed
}

function Remove-WpsOfflineProfileRemnants {
    <#
    .SYNOPSIS
        For every user profile that is NOT currently logged on, mounts the offline NTUSER.DAT,
        removes WPS uninstall entries + known Kingsoft/WPS keys directly (no uninstaller is
        invoked, since there is no session context to run one in), then unmounts the hive.
    #>
    [CmdletBinding()]
    param()

    $removed = 0
    foreach ($profile in (Get-WpsUserProfiles | Where-Object { -not $_.Loaded })) {
        $mountKey = "WpsTmp_$($profile.Sid -replace '[^A-Za-z0-9]', '')"
        if (-not (Mount-WpsOfflineHive -NtUserDatPath $profile.NtUserDatPath -MountKeyName $mountKey)) {
            Write-WpsLog -Level 'WARN' -Component 'RegistryCleaner' -Message "Could not mount offline hive for profile '$($profile.Username)'."
            continue
        }

        try {
            $hiveRoot = "Registry::HKEY_USERS\$mountKey"

            $uninstallPath = "$hiveRoot\Software\Microsoft\Windows\CurrentVersion\Uninstall"
            if (Test-Path -LiteralPath $uninstallPath) {
                Get-ChildItem -LiteralPath $uninstallPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $subPath = $_.PSPath
                    try {
                        $props = Get-ItemProperty -LiteralPath $subPath -ErrorAction Stop
                        if ($props.DisplayName -and (Test-WpsTextIdentity -Text "$($props.DisplayName) $($props.Publisher)")) {
                            $r = Invoke-WpsAction -Component 'RegistryCleaner' `
                                -Description "Remove offline-profile uninstall entry '$($props.DisplayName)' ($($profile.Username))" -Action {
                                Remove-Item -LiteralPath $subPath -Recurse -Force -ErrorAction Stop
                            }
                            if ($r) { $removed++; $Script:Stats.RegistryKeysRemoved++ }
                        }
                    } catch { }
                }
            }

            foreach ($sub in @('Software\Kingsoft', 'Software\WPS')) {
                $path = "$hiveRoot\$sub"
                if (Test-Path -LiteralPath $path) {
                    $r = Invoke-WpsAction -Component 'RegistryCleaner' -Description "Remove offline-profile key $sub ($($profile.Username))" -Action {
                        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    }
                    if ($r) { $removed++; $Script:Stats.RegistryKeysRemoved++ }
                }
            }
        } finally {
            Dismount-WpsOfflineHive -MountKeyName $mountKey | Out-Null
        }
    }
    return $removed
}
#endregion

#region ------------------------------- Firewall Cleaner (opt-in) -----------------------------------
function Remove-WpsFirewallRules {
    <#
    .SYNOPSIS
        (Opt-in via -CleanupFirewall) Removes Windows Firewall rules created by WPS Office,
        matched by rule name/display name or by the rule's associated application path.
    #>
    [CmdletBinding()]
    param()

    if (-not $Script:Config.CleanupFirewall) {
        Write-WpsLog -Level 'INFO' -Component 'FirewallCleaner' -Message 'Firewall cleanup skipped (pass -CleanupFirewall to enable).'
        return 0
    }

    $removed = 0
    try {
        $rules = Get-NetFirewallRule -ErrorAction Stop
    } catch {
        Write-WpsLog -Level 'WARN' -Component 'FirewallCleaner' -Message "NetSecurity module unavailable - skipping firewall cleanup: $($_.Exception.Message)"
        return 0
    }

    foreach ($rule in $rules) {
        $appPath = $null
        try { $appPath = ($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop).Program } catch { }

        $identityText = "$($rule.DisplayName) $($rule.Name) $appPath"
        if (Test-WpsTextIdentity -Text $identityText) {
            $ruleName = $rule.Name
            $result = Invoke-WpsAction -Component 'FirewallCleaner' -Description "Remove firewall rule '$($rule.DisplayName)'" -Action {
                Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop
            }
            if ($result) { $removed++; $Script:Stats.FirewallRulesRemoved++ }
        }
    }
    return $removed
}
#endregion

#region ------------------------------- Environment Cleaner -----------------------------------------
function Remove-WpsEnvironmentRemnants {
    <#
    .SYNOPSIS
        Removes WPS-specific environment variables and strips only the WPS-owned segments from
        the Machine and User PATH variables, leaving every other entry completely untouched.
    #>
    [CmdletBinding()]
    param()

    $removed = 0
    foreach ($scope in @('Machine', 'User')) {
        $allVars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($key in @($allVars.Keys)) {
            if ($key -imatch '^(wps|kingsoft)' -and (Test-WpsTextIdentity -Text "$key $($allVars[$key])")) {
                $result = Invoke-WpsAction -Component 'EnvironmentCleaner' -Description "Remove $scope environment variable '$key'" -Action {
                    [Environment]::SetEnvironmentVariable($key, $null, $scope)
                }
                if ($result) { $removed++; $Script:Stats.EnvEntriesRemoved++ }
            }
        }

        $pathValue = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($pathValue) {
            $segments = $pathValue -split ';' | Where-Object { $_ -ne '' }
            $kept = New-Object System.Collections.Generic.List[string]
            $strippedAny = $false
            foreach ($segment in $segments) {
                if (Test-WpsTextIdentity -Text $segment) { $strippedAny = $true }
                else { $kept.Add($segment) | Out-Null }
            }
            if ($strippedAny) {
                $newPath = ($kept -join ';')
                $result = Invoke-WpsAction -Component 'EnvironmentCleaner' -Description "Strip WPS entries from $scope PATH" -Action {
                    [Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
                }
                if ($result) { $removed++; $Script:Stats.EnvEntriesRemoved++ }
            }
        }
    }
    return $removed
}
#endregion

#region ------------------------------- Shortcut Cleaner ---------------------------------------------
function Get-WpsShortcutTarget {
    <#
    .SYNOPSIS
        Resolves the target path of a .lnk shortcut using the built-in WScript.Shell COM
        automation object (no third-party tool required).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LnkPath)

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($LnkPath)
        return $shortcut.TargetPath
    } catch {
        return $null
    } finally {
        if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Remove-WpsShortcutsFromFolder {
    <#
    .SYNOPSIS
        Removes .lnk shortcuts from a single folder whose file name or resolved target
        identifies them as WPS Office.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [switch]$Recurse
    )

    $removed = 0
    if (-not (Test-Path -LiteralPath $FolderPath)) { return 0 }

    $gciParams = @{ LiteralPath = $FolderPath; Filter = '*.lnk'; Force = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recurse) { $gciParams['Recurse'] = $true }

    Get-ChildItem @gciParams | ForEach-Object {
        $target = Get-WpsShortcutTarget -LnkPath $_.FullName
        if ((Test-WpsTextIdentity -Text $_.Name) -or ($target -and (Test-WpsFileIdentity -Path $target))) {
            if (Remove-WpsPathSafely -Path $_.FullName) {
                $removed++
                $Script:Stats.ShortcutsRemoved++
            }
        }
    }
    return $removed
}

function Remove-WpsShortcuts {
    <#
    .SYNOPSIS
        Full shortcut cleanup pass across Public Desktop, the machine Start Menu, and every
        user profile's Desktop / Start Menu / Quick Launch, including OneDrive-redirected
        Desktop folders where applicable.
    #>
    [CmdletBinding()]
    param()

    $removed = 0
    if ($env:PUBLIC) {
        $removed += Remove-WpsShortcutsFromFolder -FolderPath (Join-Path $env:PUBLIC 'Desktop')
    }
    $removed += Remove-WpsShortcutsFromFolder -FolderPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') -Recurse

    foreach ($profile in (Get-WpsUserProfiles)) {
        $removed += Remove-WpsShortcutsFromFolder -FolderPath (Join-Path $profile.ProfilePath 'Desktop')
        $removed += Remove-WpsShortcutsFromFolder -FolderPath (Join-Path $profile.ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs') -Recurse
        $removed += Remove-WpsShortcutsFromFolder -FolderPath (Join-Path $profile.ProfilePath 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch')

        if ($profile.Loaded) {
            try {
                $shellFoldersKey = "Registry::HKEY_USERS\$($profile.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
                if (Test-Path -LiteralPath $shellFoldersKey) {
                    $redirectedDesktop = (Get-ItemProperty -LiteralPath $shellFoldersKey -ErrorAction SilentlyContinue).Desktop
                    if ($redirectedDesktop) {
                        $expanded = [Environment]::ExpandEnvironmentVariables($redirectedDesktop)
                        if ($expanded -and ($expanded -ine (Join-Path $profile.ProfilePath 'Desktop')) -and (Test-Path -LiteralPath $expanded)) {
                            $removed += Remove-WpsShortcutsFromFolder -FolderPath $expanded
                        }
                    }
                }
            } catch { }
        }
    }

    Write-WpsLog -Level 'INFO' -Component 'ShortcutCleaner' -Message "Removed $removed WPS shortcut(s)."
    return $removed
}
#endregion

#region ------------------------------- Filesystem Cleaner -------------------------------------------
function Get-WpsMsiSummaryInfo {
    <#
    .SYNOPSIS
        Reads the ProductName/Manufacturer summary stream from a cached .msi file using the
        built-in WindowsInstaller.Installer COM automation object (ships with every Windows
        install as part of msi.dll - not a third-party tool).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MsiPath)

    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database  = $installer.OpenDatabase($MsiPath, 0)
        $summary   = $database.SummaryInformation(0)
        $subject   = $summary.Property(3)  # PID_SUBJECT -> ProductName
        $author    = $summary.Property(4)  # PID_AUTHOR  -> Manufacturer
        return "$subject $author"
    } catch {
        return ''
    } finally {
        if ($installer) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }
}

function Get-WpsFileSystemTargets {
    <#
    .SYNOPSIS
        Builds the complete list of files/folders positively identified as WPS Office across
        Program Files, Program Files (x86), ProgramData, every user profile's AppData, and
        (when -CleanupTemp is supplied) Temp / Windows Temp / the Windows Installer cache.
    #>
    [CmdletBinding()]
    param()

    $targets = New-Object System.Collections.Generic.List[string]

    $machineRoots = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) { $machineRoots.Add($env:ProgramFiles) | Out-Null }
    if (${env:ProgramFiles(x86)}) { $machineRoots.Add(${env:ProgramFiles(x86)}) | Out-Null }
    if ($env:ProgramData) { $machineRoots.Add($env:ProgramData) | Out-Null }

    foreach ($root in $machineRoots) {
        foreach ($name in @('Kingsoft', 'WPS Office', 'WPS Office365', 'WPS Cloud')) {
            $candidate = Join-Path $root $name
            if ((Test-Path -LiteralPath $candidate) -and (Test-WpsTextIdentity -Text $candidate)) {
                $targets.Add($candidate) | Out-Null
            }
        }
    }

    foreach ($profile in (Get-WpsUserProfiles)) {
        $userPaths = @(
            (Join-Path $profile.ProfilePath 'AppData\Local\Kingsoft'),
            (Join-Path $profile.ProfilePath 'AppData\Roaming\Kingsoft'),
            (Join-Path $profile.ProfilePath 'AppData\Local\WPS Office'),
            (Join-Path $profile.ProfilePath 'AppData\Roaming\WPS Office'),
            (Join-Path $profile.ProfilePath 'AppData\LocalLow\Kingsoft')
        )
        foreach ($p in $userPaths) {
            if ((Test-Path -LiteralPath $p) -and (Test-WpsTextIdentity -Text $p)) {
                $targets.Add($p) | Out-Null
            }
        }

        if ($Script:Config.CleanupTemp) {
            $tempRoot = Join-Path $profile.ProfilePath 'AppData\Local\Temp'
            if (Test-Path -LiteralPath $tempRoot) {
                Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue |
                    Where-Object { Test-WpsTextIdentity -Text $_.Name } |
                    ForEach-Object { $targets.Add($_.FullName) | Out-Null }
            }
        }
    }

    if ($Script:Config.CleanupTemp) {
        $winTemp = Join-Path $env:WINDIR 'Temp'
        if (Test-Path -LiteralPath $winTemp) {
            Get-ChildItem -LiteralPath $winTemp -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-WpsTextIdentity -Text $_.Name } |
                ForEach-Object { $targets.Add($_.FullName) | Out-Null }
        }

        $installerCache = Join-Path $env:WINDIR 'Installer'
        if (Test-Path -LiteralPath $installerCache) {
            Get-ChildItem -LiteralPath $installerCache -Filter '*.msi' -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $info = Get-WpsMsiSummaryInfo -MsiPath $_.FullName
                if ($info -and (Test-WpsTextIdentity -Text $info)) {
                    $targets.Add($_.FullName) | Out-Null
                }
            }
        }
    }

    # De-duplicate while preserving order (a folder and a file inside it could both be queued
    # in edge cases - Remove-WpsPathSafely is idempotent either way, but this keeps logs tidy).
    $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($t in $targets) {
        if ($seen.Add($t)) { $unique.Add($t) | Out-Null }
    }
    return $unique
}

function Remove-WpsFileSystemTargets {
    <#
    .SYNOPSIS
        Deletes every file/folder returned by Get-WpsFileSystemTargets via Remove-WpsPathSafely.
    #>
    [CmdletBinding()]
    param()

    $targets = Get-WpsFileSystemTargets
    if ($targets.Count -eq 0) {
        Write-WpsLog -Level 'INFO' -Component 'FilesystemCleaner' -Message 'No WPS-related files or folders found.'
        return 0
    }

    $removed = 0
    $total = $targets.Count
    $i = 0
    foreach ($target in $targets) {
        $i++
        if (-not $Script:Config.Silent) {
            Write-Progress -Activity 'Filesystem Cleaner' -Status "Removing $target" -PercentComplete (($i / $total) * 100)
        }
        if (Remove-WpsPathSafely -Path $target) { $removed++ }
    }
    if (-not $Script:Config.Silent) { Write-Progress -Activity 'Filesystem Cleaner' -Completed }
    return $removed
}
#endregion

#region ------------------------------- Uninstall Engine ---------------------------------------------
function Split-WpsCommandLine {
    <#
    .SYNOPSIS
        Splits a registry UninstallString ("C:\Path\uninst.exe" /args or bare path /args) into
        an executable path and an argument string, handling the quoted-path case correctly.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    $trimmed = $CommandLine.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }

    if ($trimmed.StartsWith('"')) {
        $endQuote = $trimmed.IndexOf('"', 1)
        if ($endQuote -lt 0) { return $null }
        $filePath  = $trimmed.Substring(1, $endQuote - 1)
        $arguments = $trimmed.Substring($endQuote + 1).Trim()
    } else {
        $spaceIdx = $trimmed.IndexOf(' ')
        if ($spaceIdx -lt 0) {
            $filePath  = $trimmed
            $arguments = ''
        } else {
            $filePath  = $trimmed.Substring(0, $spaceIdx)
            $arguments = $trimmed.Substring($spaceIdx + 1).Trim()
        }
    }

    return [PSCustomObject]@{ FilePath = $filePath; Arguments = $arguments }
}

function Invoke-WpsUninstallCommand {
    <#
    .SYNOPSIS
        Executes a single uninstall command line, optionally retrying with a list of common
        silent/quiet switches when the vendor's own UninstallString is interactive. Recognises
        standard MSI (0, 3010) and "already removed" (1605/1614/1641) exit codes as success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$Description,
        [switch]$TrySilentSwitches
    )

    $parsed = Split-WpsCommandLine -CommandLine $CommandLine
    if (-not $parsed) { return $false }

    $candidateArgSets = New-Object System.Collections.Generic.List[string]
    if ($parsed.Arguments) { $candidateArgSets.Add($parsed.Arguments) | Out-Null }

    if ($TrySilentSwitches) {
        foreach ($switch in @('/quiet /norestart', '/S', '/SILENT /NORESTART', '/VERYSILENT /NORESTART', '-silent', '--silent', '/qn')) {
            $candidateArgSets.Add(("$($parsed.Arguments) $switch").Trim()) | Out-Null
        }
    }

    $isMsiExec = $parsed.FilePath -imatch '(^|\\)msiexec(\.exe)?$'

    foreach ($argSet in $candidateArgSets) {
        $filePath = $parsed.FilePath
        $result = Invoke-WpsAction -Component 'UninstallEngine' -Description "$Description :: $filePath $argSet" -Action {
            if (-not $isMsiExec -and -not (Test-Path -LiteralPath $filePath)) {
                throw "Uninstaller executable not found: $filePath"
            }
            $proc = Start-Process -FilePath $filePath -ArgumentList $argSet -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($proc.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
                throw "Uninstaller exited with code $($proc.ExitCode)"
            }
            if ($proc.ExitCode -eq 3010) { $Script:RebootRequired = $true }
        }
        if ($result) { return $true }
    }
    return $false
}

function Invoke-WpsUninstallEngine {
    <#
    .SYNOPSIS
        Attempts, in priority order, to run each detected WPS installation's real uninstaller:
        1) vendor QuietUninstallString  2) msiexec /X{ProductCode}  3) vendor UninstallString
        with silent switches appended. Anything left behind is mopped up by the registry and
        filesystem cleaners that run afterwards, so a failed/partial uninstall never blocks
        overall removal.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Entries)

    $ran = 0
    foreach ($entry in $Entries) {
        $verSuffix = if ($entry.DisplayVersion) { " ($($entry.DisplayVersion))" } else { '' }
        $description = "Uninstall '$($entry.DisplayName)'$verSuffix"

        if ($Script:Config.DryRun) {
            Write-WpsLog -Level 'INFO' -Component 'UninstallEngine' -Message "[DRYRUN] Would run vendor/MSI uninstall for: $description"
            continue
        }

        $success = $false

        if (-not $success -and $entry.QuietUninstallString) {
            $success = Invoke-WpsUninstallCommand -CommandLine $entry.QuietUninstallString -Description $description
        }
        if (-not $success -and $entry.ProductCode -match '^\{[0-9A-Fa-f\-]{36}\}$') {
            $success = Invoke-WpsUninstallCommand -CommandLine "msiexec.exe /X$($entry.ProductCode) /quiet /norestart" -Description $description
        }
        if (-not $success -and $entry.UninstallString) {
            $success = Invoke-WpsUninstallCommand -CommandLine $entry.UninstallString -Description $description -TrySilentSwitches
        }

        if ($success) {
            $ran++
            $Script:Stats.UninstallersRun++
        } else {
            Write-WpsLog -Level 'WARN' -Component 'UninstallEngine' `
                -Message "Vendor/MSI uninstall did not complete cleanly for '$($entry.DisplayName)' - falling back to manual registry/filesystem cleanup."
        }
    }
    return $ran
}
#endregion

#region ------------------------------- Validation Engine ---------------------------------------------
function Test-WpsResidualPresence {
    <#
    .SYNOPSIS
        Re-runs detection across every category after cleanup completes and reports whether the
        system is fully clean, plus a itemised breakdown of anything still present.
    #>
    [CmdletBinding()]
    param()

    $residual = [ordered]@{
        Processes        = @(Get-WpsProcesses)
        Services         = @(Get-WpsServices)
        ScheduledTasks   = @(Get-WpsScheduledTasks)
        UninstallEntries = @(Get-WpsUninstallEntries)
        FileSystemPaths  = @(Get-WpsFileSystemTargets)
    }

    $shortcuts = New-Object System.Collections.Generic.List[object]
    if ($env:PUBLIC) {
        $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
        if (Test-Path -LiteralPath $publicDesktop) {
            Get-ChildItem -LiteralPath $publicDesktop -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $tgt = Get-WpsShortcutTarget -LnkPath $_.FullName
                if ((Test-WpsTextIdentity -Text $_.Name) -or ($tgt -and (Test-WpsFileIdentity -Path $tgt))) {
                    $shortcuts.Add($_.FullName) | Out-Null
                }
            }
        }
    }
    foreach ($profile in (Get-WpsUserProfiles)) {
        $deskPath = Join-Path $profile.ProfilePath 'Desktop'
        if (Test-Path -LiteralPath $deskPath) {
            Get-ChildItem -LiteralPath $deskPath -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-WpsTextIdentity -Text $_.Name } |
                ForEach-Object { $shortcuts.Add($_.FullName) | Out-Null }
        }
    }
    $residual['Shortcuts'] = @($shortcuts)

    $startupResidual = New-Object System.Collections.Generic.List[string]
    foreach ($keyPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )) {
        if (-not (Test-Path -LiteralPath $keyPath)) { continue }
        try {
            $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
            foreach ($valueName in @($key.GetValueNames())) {
                $data = $key.GetValue($valueName)
                if ($data -and (Test-WpsTextIdentity -Text "$valueName $data")) {
                    $startupResidual.Add("$keyPath\$valueName") | Out-Null
                }
            }
        } catch { }
    }
    $residual['StartupEntries'] = @($startupResidual)

    $isClean = $true
    foreach ($key in $residual.Keys) {
        if (@($residual[$key]).Count -gt 0) { $isClean = $false }
    }

    return [PSCustomObject]@{ IsClean = $isClean; Details = $residual }
}
#endregion

#region ------------------------------- Report Generator ---------------------------------------------
function Write-WpsReport {
    <#
    .SYNOPSIS
        Prints the colorized console summary table and writes both a JSON and plain-text
        report file to the log directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Validation)

    $elapsed = (Get-Date) - $Script:StartTime
    $actionKeys = $Script:Stats.Keys | Where-Object { $_ -notin @('Warnings', 'Errors') }
    $totalActions = 0
    foreach ($k in $actionKeys) { $totalActions += $Script:Stats[$k] }
    $successRate = if (($totalActions + $Script:Stats.Errors) -gt 0) {
        [math]::Round(($totalActions / ($totalActions + $Script:Stats.Errors)) * 100, 1)
    } else { 100 }

    if (-not $Script:Config.Silent) {
        Write-Host ''
        Write-Host ('=' * 70) -ForegroundColor DarkCyan
        Write-Host '  WPS OFFICE REMOVAL - SUMMARY REPORT' -ForegroundColor White
        Write-Host ('=' * 70) -ForegroundColor DarkCyan

        $rows = [ordered]@{
            'Processes terminated'       = $Script:Stats.ProcessesTerminated
            'Services removed'           = $Script:Stats.ServicesRemoved
            'Scheduled tasks removed'    = $Script:Stats.ScheduledTasksRemoved
            'Startup entries removed'    = $Script:Stats.StartupEntriesRemoved
            'Registry keys removed'      = $Script:Stats.RegistryKeysRemoved
            'Files deleted'              = $Script:Stats.FilesDeleted
            'Folders deleted'            = $Script:Stats.FoldersDeleted
            'Shortcuts removed'          = $Script:Stats.ShortcutsRemoved
            'Environment entries removed'= $Script:Stats.EnvEntriesRemoved
            'Firewall rules removed'     = $Script:Stats.FirewallRulesRemoved
            'File associations removed'  = $Script:Stats.FileAssocRemoved
            'Vendor/MSI uninstalls run'  = $Script:Stats.UninstallersRun
            'Pending reboot deletions'   = $Script:Stats.PendingRebootDeletes
        }
        foreach ($label in $rows.Keys) {
            Write-Host ('  {0,-30} {1}' -f $label, $rows[$label]) -ForegroundColor Gray
        }
        Write-Host ('-' * 70) -ForegroundColor DarkCyan
        Write-Host ('  {0,-30} {1:N1} seconds' -f 'Time taken', $elapsed.TotalSeconds) -ForegroundColor Gray
        Write-Host ('  {0,-30} {1}%' -f 'Success rate', $successRate) -ForegroundColor Gray
        Write-Host ('  {0,-30} {1}' -f 'Warnings', $Script:Stats.Warnings) -ForegroundColor Yellow
        Write-Host ('  {0,-30} {1}' -f 'Errors', $Script:Stats.Errors) -ForegroundColor $(if ($Script:Stats.Errors -gt 0) { 'Red' } else { 'Gray' })
        Write-Host ('=' * 70) -ForegroundColor DarkCyan

        if ($Validation.IsClean) {
            Write-Host '  VALIDATION: PASS - no trace of WPS Office remains on this system.' -ForegroundColor Green
        } else {
            Write-Host '  VALIDATION: residual items were found - see details below.' -ForegroundColor Yellow
            foreach ($category in $Validation.Details.Keys) {
                $items = @($Validation.Details[$category])
                if ($items.Count -gt 0) {
                    Write-Host "    - ${category}: $($items.Count) item(s) remaining" -ForegroundColor Yellow
                }
            }
            if ($Script:RebootRequired) {
                Write-Host '  Some items are scheduled for deletion on the next restart.' -ForegroundColor Yellow
            }
        }
        Write-Host ('=' * 70) -ForegroundColor DarkCyan
        Write-Host "  Log file   : $Script:TextLogPath" -ForegroundColor DarkGray
        if ($Script:Config.JsonLog) { Write-Host "  JSON log   : $Script:JsonLogPath" -ForegroundColor DarkGray }
        Write-Host "  Report     : $Script:ReportTextPath" -ForegroundColor DarkGray
        Write-Host ''
    }

    $reportObject = [PSCustomObject]@{
        UtilityName    = $Script:UtilityName
        Version        = $Script:UtilityVersion
        Author         = $Script:Author
        Repository     = $Script:RepoUrl
        StartTime      = $Script:StartTime.ToString('u')
        EndTime        = (Get-Date).ToString('u')
        ElapsedSeconds = [math]::Round($elapsed.TotalSeconds, 2)
        DryRun         = $Script:Config.DryRun
        Stats          = $Script:Stats
        SuccessRate    = $successRate
        IsClean        = $Validation.IsClean
        ResidualCounts = @{}
        RebootRequired = $Script:RebootRequired
        ExitCode       = $Script:ExitCode
    }
    foreach ($category in $Validation.Details.Keys) {
        $reportObject.ResidualCounts[$category] = @($Validation.Details[$category]).Count
    }

    try { $reportObject | ConvertTo-Json -Depth 6 | Out-File -FilePath $Script:ReportJsonPath -Encoding utf8 } catch { }
    try { ($reportObject | Format-List | Out-String) | Out-File -FilePath $Script:ReportTextPath -Encoding utf8 } catch { }

    return $reportObject
}
#endregion

#region ------------------------------- Console UI / Main Orchestration ------------------------------
function Show-WpsBanner {
    <#
    .SYNOPSIS
        Prints a clean, professional console header (no ASCII art) identifying the utility,
        its author/repository, and whether this is a dry run or a live removal.
    #>
    [CmdletBinding()]
    param()

    if ($Script:Config.Silent) { return }

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $Script:UtilityName  v$Script:UtilityVersion" -ForegroundColor White
    Write-Host "  Author: $Script:Author   |   $Script:RepoUrl" -ForegroundColor DarkGray
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    $mode = if ($Script:Config.DryRun) { 'DRY RUN - no changes will be made' } else { 'LIVE - this system will be modified' }
    Write-Host "  Mode: $mode" -ForegroundColor $(if ($Script:Config.DryRun) { 'Yellow' } else { 'Cyan' })
    Write-Host ''
}

function Confirm-WpsRemoval {
    <#
    .SYNOPSIS
        Shows a detection summary and asks for interactive confirmation before any destructive
        action begins. Skipped automatically when -Force or -Silent (or -DryRun) is supplied.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Detection)

    if ($Script:Config.Force -or $Script:Config.DryRun) { return $true }

    Write-Host 'The following WPS Office components were detected on this system:' -ForegroundColor Yellow
    Write-Host ('  {0,-28} {1}' -f 'Running processes', $Detection.Processes.Count)
    Write-Host ('  {0,-28} {1}' -f 'Installed services', $Detection.Services.Count)
    Write-Host ('  {0,-28} {1}' -f 'Scheduled tasks', $Detection.ScheduledTasks.Count)
    Write-Host ('  {0,-28} {1}' -f 'Uninstall registry entries', $Detection.UninstallEntries.Count)
    Write-Host ('  {0,-28} {1}' -f 'Files / folders', $Detection.FileSystemTargets.Count)
    Write-Host ''

    $answer = Read-Host 'Proceed with complete removal? (Y/N)'
    return ($answer -imatch '^y')
}

function Complete-WpsRemoval {
    <#
    .SYNOPSIS
        Common exit path for every run (success, cancellation, or elevation failure). Restores
        the caller's original $ProgressPreference, handles reboot policy, and exits safely -
        calling exit() only when running as a real .ps1 file (see $Script:IsRunAsFile).
    #>
    [CmdletBinding()]
    param([switch]$Aborted)

    $ProgressPreference = $Script:OriginalProgressPreference

    if ($Script:RebootRequired -and -not $Aborted -and -not $Script:Config.DryRun) {
        if ($Script:Config.NoRestart) {
            Write-WpsLog -Level 'INFO' -Component 'Main' -Message 'Restart required to finish removing locked items (-NoRestart specified) - pending deletions will complete on next restart.'
        }
        elseif ($Script:Config.Force -or $Script:Config.Silent) {
            Write-WpsLog -Level 'WARN' -Component 'Main' -Message 'Restart required - restarting automatically in 15 seconds (pass -NoRestart to prevent this).'
            if (-not $Script:Config.Silent) { Write-Host 'Restarting in 15 seconds - press Ctrl+C to cancel...' -ForegroundColor Yellow }
            Start-Sleep -Seconds 15
            Restart-Computer -Force
        }
        else {
            $answer = Read-Host 'A restart is required to finish removing some locked files. Restart now? (Y/N)'
            if ($answer -imatch '^y') {
                Restart-Computer -Force
            } else {
                Write-WpsLog -Level 'INFO' -Component 'Main' -Message 'Restart deferred by user - pending deletions will complete on the next restart.'
            }
        }
    }

    if ($Script:IsRunAsFile) {
        exit $Script:ExitCode
    } else {
        $global:LASTEXITCODE = $Script:ExitCode
    }
}

function Invoke-WpsRemoval {
    <#
    .SYNOPSIS
        Top-level orchestration: initializes logging, asserts elevation, runs an initial
        detection pass, asks for confirmation, then executes every cleanup module in the safe
        order (stop processes -> uninstall -> services/tasks/startup -> registry -> filesystem),
        followed by validation and the final report.
    #>
    [CmdletBinding()]
    param()

    Initialize-WpsLogger
    Show-WpsBanner
    Write-WpsLog -Level 'INFO' -Component 'Main' -Message "$Script:UtilityName v$Script:UtilityVersion starting (DryRun=$($Script:Config.DryRun), Silent=$($Script:Config.Silent), Force=$($Script:Config.Force))."

    Assert-WpsElevation

    $initialDetection = [PSCustomObject]@{
        Processes         = @(Get-WpsProcesses)
        Services          = @(Get-WpsServices)
        ScheduledTasks    = @(Get-WpsScheduledTasks)
        UninstallEntries  = @(Get-WpsUninstallEntries)
        FileSystemTargets = @(Get-WpsFileSystemTargets)
    }
    $totalFound = $initialDetection.Processes.Count + $initialDetection.Services.Count + $initialDetection.ScheduledTasks.Count +
                  $initialDetection.UninstallEntries.Count + $initialDetection.FileSystemTargets.Count

    if ($totalFound -eq 0) {
        Write-WpsLog -Level 'SUCCESS' -Component 'Main' -Message 'No trace of WPS Office was found on this system. Nothing to do.'
        $validation = [PSCustomObject]@{ IsClean = $true; Details = [ordered]@{} }
        Write-WpsReport -Validation $validation | Out-Null
        $Script:ExitCode = 0
        Complete-WpsRemoval
        return
    }

    if (-not (Confirm-WpsRemoval -Detection $initialDetection)) {
        Write-WpsLog -Level 'INFO' -Component 'Main' -Message 'Removal cancelled by user - no changes were made.'
        $Script:ExitCode = 2
        Complete-WpsRemoval -Aborted
        return
    }

    $Script:DetectedUninstallEntries = $initialDetection.UninstallEntries

    $phases = @(
        @{ Name = 'Terminating WPS processes';          Weight = 8;  Action = { Stop-WpsProcesses | Out-Null } }
        @{ Name = 'Running vendor / MSI uninstallers';  Weight = 20; Action = { Invoke-WpsUninstallEngine -Entries $Script:DetectedUninstallEntries | Out-Null } }
        @{ Name = 'Removing services';                  Weight = 6;  Action = { Remove-WpsServices | Out-Null } }
        @{ Name = 'Removing scheduled tasks';            Weight = 4;  Action = { Remove-WpsScheduledTasks | Out-Null } }
        @{ Name = 'Cleaning startup entries';             Weight = 6;  Action = { Remove-WpsStartupEntries | Out-Null } }
        @{ Name = 'Cleaning uninstall registry keys';    Weight = 4;  Action = { Remove-WpsUninstallRegistryKeys -Entries $Script:DetectedUninstallEntries | Out-Null } }
        @{ Name = 'Cleaning known registry keys';        Weight = 6;  Action = { Remove-WpsKnownRegistryKeys | Out-Null } }
        @{ Name = 'Cleaning COM / shell extensions';     Weight = 4;  Action = { Remove-WpsComAndShellExtensions | Out-Null } }
        @{ Name = 'Cleaning offline user profiles';      Weight = 6;  Action = { Remove-WpsOfflineProfileRemnants | Out-Null } }
        @{ Name = 'Cleaning file associations';          Weight = 3;  Action = { Remove-WpsFileAssociations | Out-Null } }
        @{ Name = 'Cleaning firewall rules';              Weight = 3;  Action = { Remove-WpsFirewallRules | Out-Null } }
        @{ Name = 'Cleaning environment variables';       Weight = 3;  Action = { Remove-WpsEnvironmentRemnants | Out-Null } }
        @{ Name = 'Removing shortcuts';                   Weight = 6;  Action = { Remove-WpsShortcuts | Out-Null } }
        @{ Name = 'Removing files and folders';           Weight = 21; Action = { Remove-WpsFileSystemTargets | Out-Null } }
    )

    $totalWeight = ($phases | Measure-Object -Property Weight -Sum).Sum
    $doneWeight = 0

    foreach ($phase in $phases) {
        if (-not $Script:Config.Silent) {
            $percent = [math]::Min(99, [math]::Round(($doneWeight / $totalWeight) * 100))
            $etaText = ''
            if ($doneWeight -gt 0) {
                $elapsedSoFar = ((Get-Date) - $Script:StartTime).TotalSeconds
                $avgPerWeight = $elapsedSoFar / $doneWeight
                $etaSeconds = [math]::Round($avgPerWeight * ($totalWeight - $doneWeight), 0)
                $etaText = " (ETA ~${etaSeconds}s)"
            }
            Write-Progress -Activity $Script:UtilityName -Status "$($phase.Name)$etaText" -PercentComplete $percent
        }

        Write-WpsLog -Level 'INFO' -Component 'Main' -Message "Phase: $($phase.Name)"
        try {
            & $phase.Action
        } catch {
            Write-WpsLog -Level 'ERROR' -Component 'Main' -Message "Phase '$($phase.Name)' failed unexpectedly: $($_.Exception.Message)"
        }
        $doneWeight += $phase.Weight
    }

    if (-not $Script:Config.Silent) { Write-Progress -Activity $Script:UtilityName -Completed }

    Write-WpsLog -Level 'INFO' -Component 'ValidationEngine' -Message 'Running post-cleanup validation pass...'
    $validation = Test-WpsResidualPresence
    Write-WpsReport -Validation $validation | Out-Null

    $Script:ExitCode = if ($validation.IsClean) { 0 } elseif ($Script:Stats.Errors -gt 0) { 1 } else { 3 }
    Complete-WpsRemoval
}
#endregion

#region ------------------------------- Entry Point ----------------------------------------------------
try {
    Invoke-WpsRemoval
} catch {
    $Script:ExitCode = 99
    try {
        Write-WpsLog -Level 'ERROR' -Component 'Main' -Message "Unhandled exception: $($_.Exception.Message)"
    } catch {
        Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    }
    if (-not $Script:Config.Silent) {
        Write-Host ''
        Write-Host 'The removal utility encountered an unexpected error and stopped.' -ForegroundColor Red
        Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
    }
    $ProgressPreference = $Script:OriginalProgressPreference
    if ($Script:IsRunAsFile) { exit $Script:ExitCode } else { $global:LASTEXITCODE = $Script:ExitCode }
}
#endregion
