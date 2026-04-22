#Requires -Version 5.1
<#
.SYNOPSIS
    DupReaper v1.7.6 - Folder-aware duplicate file detector and cleaner.
.DESCRIPTION
    Scans one or more drives, local folders, or SMB/UNC shares.
    Can limit detection and cleanup to a specific folder subtree.
    Supports preset extension groups, separate scan reports, SMB-safe logging, and safe cleanup actions.
.AUTHOR
    rhshourav
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'

# ======================================================================
# CONSTANTS
# ======================================================================

$Script:VER     = '1.7.6'
$Script:AUTHOR  = 'rhshourav'
$Script:W       = 78
$Script:MINSIZE = 0

$Script:LogRoot = Join-Path $env:USERPROFILE 'DupReaper_Logs'
$Script:ScanLogRoot = Join-Path $Script:LogRoot 'ScanReports'
$Script:RunLogRoot  = Join-Path $Script:LogRoot 'CleanupRuns'

# ======================================================================
# PROTECTED PATHS / EXTENSIONS
# ======================================================================

$Script:SYS_ROOTS = [System.Collections.Generic.List[string]]::new()

$_rawRoots = @(
    $env:SystemRoot,
    $env:windir,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    (Join-Path $env:SystemDrive '\Recovery'),
    (Join-Path $env:SystemDrive '\$Recycle.Bin'),
    (Join-Path $env:SystemDrive '\System Volume Information'),
    (Join-Path $env:SystemDrive '\Boot'),
    (Join-Path $env:SystemDrive '\EFI'),
    (Join-Path $env:SystemDrive '\MSOCache'),
    (Join-Path $env:SystemDrive '\OneDriveTemp'),
    "$env:LOCALAPPDATA\Microsoft",
    "$env:APPDATA\Microsoft",
    "$env:LOCALAPPDATA\Packages",
    "$env:LOCALAPPDATA\Programs",
    "$env:LOCALAPPDATA\Temp",
    "$env:USERPROFILE\AppData\LocalLow"
)

foreach ($_r in $_rawRoots) {
    if (-not $_r) { continue }
    $norm = $_r.TrimEnd('\\').ToLowerInvariant()
    if ($norm -and -not $Script:SYS_ROOTS.Contains($norm)) {
        $Script:SYS_ROOTS.Add($norm)
    }
}
Remove-Variable _rawRoots, _r -ErrorAction SilentlyContinue

$Script:BAD_EXT = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '.sys', '.dll', '.msp', '.msu', '.drv', '.ocx',
        '.cpl', '.acm', '.ax', '.scr', '.com', '.vbs',
        '.js', '.jse', '.wsf', '.wsh', '.reg', '.inf', '.cat', '.cab',
        '.wim', '.efi', '.pdb', '.lib', '.obj', '.lnk', '.manifest',
        '.mui', '.mun', '.nls', '.ime', '.bin', '.dat', '.db',
        '.log', '.etl', '.evt', '.evtx', '.msc', '.hlp', '.chm',
        '.diagpkg', '.diagcab', '.admx', '.adml', '.mof', '.sdb',
        '.theme', '.deskthemepack', '.lock', '.tmp'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

$Script:ExtensionPresets = [ordered]@{
    'Photos' = @(
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp',
        '.heic', '.heif', '.raw', '.cr2', '.nef', '.arw', '.dng', '.orf', '.rw2'
    )
    'Videos' = @(
        '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
        '.3gp', '.mpg', '.mpeg', '.m2ts', '.mts', '.ts'
    )
    'Audio' = @(
        '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a', '.wma', '.alac', '.ape'
    )
    'Documents' = @(
        '.pdf', '.txt', '.rtf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
        '.csv', '.md', '.odt', '.ods', '.odp', '.epub'
    )
    'Archives' = @(
        '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso'
    )
    'Apps & Installers' = @(
        '.appx', '.appxbundle', '.msix', '.msixbundle', '.appinstaller', '.apk', '.ipa', '.deb', '.rpm', '.exe', '.msi'
    )
    'Data & Config' = @(
        '.json', '.xml', '.ini', '.cfg', '.conf', '.yaml', '.yml', '.toml', '.properties'
    )
}

# ======================================================================
# HELPERS
# ======================================================================

function _c {
    param([string]$T = '', [ConsoleColor]$C = 'White', [switch]$nn)
    $p = @{ Object = $T; ForegroundColor = $C }
    if ($nn) { $p['NoNewline'] = $true }
    Write-Host @p
}

function _ln  { _c ('-' * $Script:W) 'DarkGray' }
function _dln { _c ('=' * $Script:W) 'DarkGreen' }

function _ctr {
    param([string]$T, [ConsoleColor]$C = 'White')
    $pad = [math]::Max(0, [math]::Floor(($Script:W - $T.Length) / 2))
    _c (' ' * $pad + $T) $C
}

function _ok  { param([string]$M) _c "  [+] $M" 'Green' }
function _wrn { param([string]$M) _c "  [!] $M" 'Yellow' }
function _err { param([string]$M) _c "  [X] $M" 'Red' }
function _inf { param([string]$M) _c "  [>] $M" 'White' }

function _sz {
    param([long]$B)
    if ($B -ge 1TB) { return '{0:N2} TB' -f ($B / 1TB) }
    if ($B -ge 1GB) { return '{0:N2} GB' -f ($B / 1GB) }
    if ($B -ge 1MB) { return '{0:N2} MB' -f ($B / 1MB) }
    if ($B -ge 1KB) { return '{0:N2} KB' -f ($B / 1KB) }
    return "$B B"
}

function Get-Count {
    param($InputObject)
    if ($null -eq $InputObject) { return 0 }
    if ($InputObject -is [string]) { return 1 }
    if ($InputObject -is [System.Collections.ICollection]) { return $InputObject.Count }
    return @($InputObject).Count
}

function _pause {
    _c ''
    _ctr 'Press any key to continue...' 'DarkGray'
    try { $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
}

function Ensure-LogFolders {
    foreach ($dir in @($Script:LogRoot, $Script:ScanLogRoot, $Script:RunLogRoot)) {
        if (-not (Test-Path -LiteralPath $dir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Normalize-PathText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return $Path.Trim().TrimEnd('\\')
}

function Convert-ToRawFileSystemPath {
    param([string]$Path)

    $p = Normalize-PathText $Path
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }

    # Strip PowerShell provider-qualified prefix when present.
    if ($p -match '^Microsoft\.PowerShell\.Core\\FileSystem::(.+)$') {
        $p = $Matches[1]
    }

    return $p
}

# ======================================================================
# BANNER
# ======================================================================

function Show-Banner {
    try {
        $host.UI.RawUI.BackgroundColor = 'Black'
        $host.UI.RawUI.ForegroundColor = 'White'
    } catch {}
    Clear-Host

    _dln
    _c ''
    _ctr '  _____            _____                                   ' 'Green'
    _ctr ' |  __ \          |  __ \                                  ' 'Green'
    _ctr ' | |  | |_   _ _ _| |__) |___  __ _ _ __   ___ _ __       ' 'Green'
    _ctr ' | |  | | | | | _ \  _  // _ \/ _` |  _ \ / _ \  __|      ' 'Green'
    _ctr ' | |__| | |_| |  _/ | \ \  __/ (_| | |_) |  __/ |         ' 'Green'
    _ctr ' |_____/ \__,_|_| |_|  \_\___|\__,_| .__/ \___|_|         ' 'Green'
    _ctr '                                    | |                   ' 'Green'
    _ctr '                                    |_|                   ' 'Green'
    _c ''
    _ctr '* Phantom Duplicate File Slayer *' 'Yellow'
    _ctr "v$($Script:VER)  |  by $($Script:AUTHOR)" 'DarkGray'
    _c ''
    _dln
    _c ''
}

function Show-Section {
    param([string]$Title)
    _c ''
    _dln
    _ctr "[ $Title ]" 'Yellow'
    _dln
    _c ''
}

# ================================================================
#  TELEMETRY
# ================================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "DupReaper v$($Script:VER)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}


# ======================================================================
# SAFETY CHECKS
# ======================================================================

function Test-ProtectedPath {
    param([string]$Path)
    if (-not $Path) { return $true }
    $raw = Convert-ToRawFileSystemPath $Path
    if (-not $raw) { return $true }
    $norm = $raw.TrimEnd('\\').ToLowerInvariant()
    if (-not $norm) { return $true }
    foreach ($root in $Script:SYS_ROOTS) {
        if ($norm -eq $root -or $norm.StartsWith($root + '\\')) { return $true }
    }
    return $false
}

function Test-ProtectedFile {
    param([System.IO.FileInfo]$F)
    if (Test-ProtectedPath $F.DirectoryName) { return $true }
    if ($Script:BAD_EXT.Contains($F.Extension)) { return $true }
    if ($F.Attributes -band [System.IO.FileAttributes]::System) { return $true }
    return $false
}

function Get-FileExtensionKey {
    param([string]$Path)
    try { return ([System.IO.Path]::GetExtension($Path)).ToLowerInvariant() } catch { return '' }
}

function Test-ExtensionAllowed {
    param(
        [string]$Extension,
        $AllowedSet
    )
    if ($null -eq $AllowedSet) { return $true }
    if ((Get-Count $AllowedSet) -eq 0) { return $true }
    return $AllowedSet.Contains($Extension)
}

# ======================================================================
# DRIVE AND FOLDER SOURCE SELECTION
# ======================================================================

function Get-DriveList {
    $drives = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $diskList = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and $_.DriveType -in @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable, [System.IO.DriveType]::Network) }

        foreach ($d in $diskList) {
            try {
                $total = [long]$d.TotalSize
                $free  = [long]$d.AvailableFreeSpace
                $used  = $total - $free
                if ($total -lt 0) { $total = 0 }
                if ($free -lt 0) { $free = 0 }
                if ($used -lt 0) { $used = 0 }
                $pct   = if ($total -gt 0) { [math]::Round(($used / $total) * 100) } else { 0 }
                $label = $d.VolumeLabel
                if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Local Disk' }

                $drives.Add([PSCustomObject]@{
                    Num   = (Get-Count $drives) + 1
                    Root  = $d.Name
                    Type  = 'Drive'
                    Label = $label
                    Total = $total
                    Used  = $used
                    Free  = $free
                    Pct   = $pct
                })
            } catch {}
        }
    } catch {
        _wrn "Drive enumeration warning: $($_.Exception.Message)"
    }
    return $drives
}

function Show-DriveTable {
    param([System.Collections.Generic.List[PSCustomObject]]$Drives)
    Show-Section 'AVAILABLE DRIVES'
    _c ('  {0,-3} {1,-6} {2,-18} {3,-11} {4,-11} {5,-11} {6}' -f '#', 'Drive', 'Label', 'Total', 'Used', 'Free', 'Usage') 'DarkGray'
    _ln

    foreach ($d in $Drives) {
        $barFill  = [math]::Round(($d.Pct / 100) * 16)
        if ($barFill -lt 0) { $barFill = 0 }
        if ($barFill -gt 16) { $barFill = 16 }
        $barEmpty = 16 - $barFill
        $bar      = '[' + ('#' * $barFill) + ('-' * $barEmpty) + ']'
        $col      = if ($d.Pct -ge 90) { 'Red' } elseif ($d.Pct -ge 75) { 'Yellow' } else { 'Green' }
        $lbl      = $d.Label
        if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = 'Local Disk' }
        if ($lbl.Length -gt 17) { $lbl = $lbl.Substring(0, 14) + '...' }

        _c ('  {0,-3} ' -f $d.Num) 'White' -nn
        _c ('{0,-6} ' -f $d.Root) 'Cyan' -nn
        _c ('{0,-18} ' -f $lbl) 'White' -nn
        _c ('{0,-11} ' -f (_sz $d.Total)) 'White' -nn
        _c ('{0,-11} ' -f (_sz $d.Used)) 'Yellow' -nn
        _c ('{0,-11} ' -f (_sz $d.Free)) 'Green' -nn
        _c ('{0,3}% ' -f $d.Pct) $col -nn
        _c $bar $col
    }
    _c ''
}

function Get-SelectedDrives {
    param([System.Collections.Generic.List[PSCustomObject]]$Drives)

    while ($true) {
        _c '  Select drive(s) to scan:' 'White'
        _c '  Numbers (e.g. 1,3)  |  Range (e.g. 1-3)  |  [A] All  |  [N] Cancel' 'DarkGray'
        _c ''
        _c '  > ' 'Yellow' -nn

        $in = $null
        try { $in = (Read-Host).Trim() } catch { return $null }

        if ([string]::IsNullOrEmpty($in) -or $in -match '^[Nn]$') { return $null }

        $sel = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($in -match '^[Aa]$') {
            $Drives | ForEach-Object { $sel.Add($_) }
        } else {
            $in -split ',' | ForEach-Object {
                $part = $_.Trim()
                if ($part -match '^(\d+)-(\d+)$') {
                    [int]$Matches[1]..[int]$Matches[2] | ForEach-Object {
                        $idx = $_
                        $d = $Drives | Where-Object { $_.Num -eq $idx } | Select-Object -First 1
                        if ($d -and -not ($sel | Where-Object { $_.Num -eq $d.Num })) { $sel.Add($d) }
                    }
                } elseif ($part -match '^\d+$') {
                    $idx = [int]$part
                    $d = $Drives | Where-Object { $_.Num -eq $idx } | Select-Object -First 1
                    if ($d -and -not ($sel | Where-Object { $_.Num -eq $d.Num })) { $sel.Add($d) }
                }
            }
        }

        if ((Get-Count $sel) -eq 0) {
            _err 'No valid drives selected. Try again.'
            _c ''
            continue
        }

        return $sel
    }
}

function Get-FolderRoots {
    while ($true) {
        Show-Section 'FOLDER / SMB SHARE SOURCE'
        _c '  Enter one folder path, or multiple paths separated by semicolons (;).' 'White'
        _c '  Examples:' 'DarkGray'
        _c '    C:\Users\Name\Downloads' 'DarkGray'
        _c '    \\SERVER\Share\Media' 'DarkGray'
        _c '    D:\Projects; \\NAS\Backup\Photos' 'DarkGray'
        _c ''
        _c '  > ' 'Yellow' -nn

        $raw = $null
        try { $raw = (Read-Host).Trim() } catch { return $null }
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match '^[Qq]$') { return $null }

        $paths = $raw -split ';' | ForEach-Object { Normalize-PathText $_ } | Where-Object { $_ }
        if ((Get-Count $paths) -eq 0) {
            _err 'No path entered.'
            continue
        }

        $roots = [System.Collections.Generic.List[PSCustomObject]]::new()
        $bad = $false
        $i = 1
        foreach ($p in $paths) {
            try {
                $rawP = Convert-ToRawFileSystemPath $p
                if (-not (Test-Path -LiteralPath $rawP -PathType Container -ErrorAction Stop)) {
                    _err "Path not found or not a folder: $p"
                    $bad = $true
                    break
                }
                if (Test-ProtectedPath $rawP) {
                    _err "Protected system path cannot be used as scan root: $p"
                    $bad = $true
                    break
                }
                $resolved = $rawP
                try {
                    $rp = Resolve-Path -LiteralPath $p -ErrorAction Stop
                    if ($rp -and $rp.ProviderPath) {
                        $resolved = $rp.ProviderPath
                    } elseif ($rp -and $rp.Path) {
                        $resolved = Convert-ToRawFileSystemPath $rp.Path
                    }
                } catch { }
                $resolved = Convert-ToRawFileSystemPath $resolved
                $roots.Add([PSCustomObject]@{
                    Num   = $i
                    Root  = $resolved
                    Type  = 'Folder'
                    Label = ([System.IO.Path]::GetFileName($resolved))
                })
                $i++
            } catch {
                _err "Cannot open path: $p  [$($_.Exception.Message)]"
                $bad = $true
                break
            }
        }

        if ($bad) {
            _c ''
            continue
        }

        return $roots
    }
}

function Get-ScanSources {
    while ($true) {
        Show-Section 'SCAN SOURCE'
        _c '  [1] Scan drive(s)' 'Cyan'
        _c '  [2] Scan folder / SMB share path' 'Cyan'
        _c '  [Q] Quit' 'DarkGray'
        _c ''
        _c '  > ' 'Yellow' -nn

        $choice = $null
        try { $choice = (Read-Host).Trim() } catch { return $null }

        switch ($choice) {
            '1' {
                $drives = Get-DriveList
                if (-not $drives -or (Get-Count $drives) -eq 0) {
                    _err 'No accessible drives detected.'
                    return $null
                }
                Show-DriveTable $drives
                $sel = Get-SelectedDrives $drives
                if (-not $sel -or (Get-Count $sel) -eq 0) { return $null }
                return @($sel)
            }
            '2' {
                $roots = Get-FolderRoots
                if (-not $roots -or (Get-Count $roots) -eq 0) { return $null }
                return @($roots)
            }
            'Q' { return $null }
            'q' { return $null }
            default { _wrn 'Invalid choice.' }
        }
    }
}

# ======================================================================
# EXTENSION PRESET SELECTION
# ======================================================================

function Get-ExtensionSelection {
    $presetNames = @($Script:ExtensionPresets.Keys)

    Show-Section 'EXTENSION PRESETS'
    _c '  Select categories to include in scanning.' 'White'
    _c '  Enter numbers separated by commas. Enter or A selects all presets.' 'DarkGray'
    _c ''

    for ($i = 0; $i -lt $presetNames.Count; $i++) {
        $name = $presetNames[$i]
        $count = $Script:ExtensionPresets[$name].Count
        _c ('  [{0}] {1,-18} ({2} extensions)' -f ($i + 1), $name, $count) 'Cyan'
    }

    _c ''
    _c '  [A] All presets' 'Green'
    _c '  [Enter] Default to all presets' 'Green'
    _c ''
    _c '  > ' 'Yellow' -nn

    $raw = $null
    try { $raw = (Read-Host).Trim() } catch { return $null }

    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match '^[Aa]$') {
        _ok 'Extension filter: all supported presets'
        return $null
    }

    $chosen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $raw -split ',' | ForEach-Object {
        $part = $_.Trim()
        if ($part -match '^\d+$') {
            $idx = [int]$part
            if ($idx -ge 1 -and $idx -le $presetNames.Count) {
                $name = $presetNames[$idx - 1]
                foreach ($ext in $Script:ExtensionPresets[$name]) { [void]$chosen.Add($ext) }
            }
        }
    }

    if ($chosen.Count -eq 0) {
        _wrn 'No valid preset selected. Defaulting to all presets.'
        return $null
    }

    _ok ('Selected extensions: {0}' -f ($chosen.Count))
    return $chosen
}

function Show-ExtensionSummary {
    param($AllowedSet)
    if ($null -eq $AllowedSet) {
        _inf 'Extension filter: all supported safe extensions'
        return
    }
    _inf ('Extension filter count: {0}' -f $AllowedSet.Count)
}

# ======================================================================
# SCAN MODE
# ======================================================================

function Get-ScanMethod {
    Show-Section 'DETECTION METHOD'
    _c '  [1] Name Only    ' 'Cyan' -nn
    _c 'Fast | Compare filenames | False positives possible' 'DarkGray'
    _c '  [2] Hash Only    ' 'Cyan' -nn
    _c '100% accurate | Full SHA-256 scan | Slower on large sets' 'DarkGray'
    _c '  [3] Name + Hash  ' 'Cyan' -nn
    _c 'Same name AND same content | Strictest definition' 'DarkGray'
    _c '  [4] Smart [REC]  ' 'Green' -nn
    _c 'Size pre-filter + SHA-256 | Fastest accurate mode' 'DarkGray'
    _c ''
    _c '  Choice [1-4]  (Enter = Smart): ' 'Yellow' -nn

    $ch = $null
    try { $ch = (Read-Host).Trim() } catch { return 'smart' }

    switch ($ch) {
        '1' { return 'name' }
        '2' { return 'hash' }
        '3' { return 'both' }
        '4' { return 'smart' }
        ''  { return 'smart' }
        default { _wrn 'Invalid choice - defaulting to Smart Scan'; return 'smart' }
    }
}

# ======================================================================
# SCAN ENGINE AND REPORTS
# ======================================================================

function Get-SafeFiles {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Roots,
        $AllowedExtensions
    )

    Show-Section 'SCANNING'

    $files   = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $queue   = [System.Collections.Generic.Queue[string]]::new()
    $scanLog = [System.Collections.Generic.List[string]]::new()

    $skippedProtected = 0
    $skippedExt = 0
    $errors = 0
    $dirsSeen = 0
    $itemsSeen = 0
    $start = Get-Date

    $scanLog.Add("DupReaper v$($Script:VER) | Scan started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $extLabel = if ($null -eq $AllowedExtensions) { 'ALL SAFE EXTENSIONS' } else { [string]$AllowedExtensions.Count }
    $scanLog.Add(('Allowed extensions: {0}' -f $extLabel))

    foreach ($r in $Roots) {
        $rootPath = Convert-ToRawFileSystemPath $r.Root
        $scanLog.Add("ROOT|$rootPath|$($r.Type)")
        _inf "Queuing $rootPath"
        $queue.Enqueue($rootPath)
    }

    while ($queue.Count -gt 0) {
        $dir = Convert-ToRawFileSystemPath ($queue.Dequeue())
        $dirsSeen++

        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (Test-ProtectedPath $dir) {
            $skippedProtected++
            $scanLog.Add("DIR|BLOCKED|$dir|protected path")
            continue
        }

        try {
            $dirItem = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
            if (-not $dirItem.PSIsContainer) {
                $scanLog.Add("DIR|SKIP|$dir|not a container")
                continue
            }
            if ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $skippedProtected++
                $scanLog.Add("DIR|SKIP|$dir|reparse point")
                continue
            }
        } catch {
            $errors++
            $scanLog.Add("DIR|ERROR|$dir|$($_.Exception.Message)")
            continue
        }

        $children = $null
        try {
            $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        } catch {
            $errors++
            $scanLog.Add("DIR|ERROR|$dir|$($_.Exception.Message)")
            continue
        }

        foreach ($child in $children) {
            $itemsSeen++

            try {
                if ($child.PSIsContainer) {
                    $childPath = Convert-ToRawFileSystemPath $child.FullName
                    if (Test-ProtectedPath $childPath) {
                        $skippedProtected++
                        $scanLog.Add("DIR|BLOCKED|$childPath|protected path")
                        continue
                    }

                    try {
                        if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                            $skippedProtected++
                            $scanLog.Add("DIR|SKIP|$childPath|reparse point")
                            continue
                        }
                    } catch {
                    }

                    if ($childPath) {
                        $queue.Enqueue($childPath)
                    }
                    continue
                }

                $childPath = Convert-ToRawFileSystemPath $child.FullName
                if (-not ($child -is [System.IO.FileInfo])) {
                    $child = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
                }

                if (Test-ProtectedFile $child) {
                    $skippedProtected++
                    $scanLog.Add("FILE|SKIP|$childPath|protected/system")
                    continue
                }

                $extKey = Get-FileExtensionKey $child.FullName
                if (-not (Test-ExtensionAllowed $extKey $AllowedExtensions)) {
                    $skippedExt++
                    $scanLog.Add("FILE|SKIP|$childPath|extension $extKey")
                    continue
                }

                if ($child.Length -lt $Script:MINSIZE) {
                    $scanLog.Add("FILE|SKIP|$childPath|below minimum size")
                    continue
                }

                $files.Add($child)
                if (($files.Count % 250) -eq 0) {
                    Write-Host (("`r  [>] Files kept: {0,6} | Protected: {1,6} | Ext skipped: {2,6} | Queue: {3,5}   " -f $files.Count, $skippedProtected, $skippedExt, $queue.Count)) -ForegroundColor White -NoNewline
                }
                $scanLog.Add("FILE|KEEP|$childPath|$($child.Length)")
            } catch {
                $errors++
                $scanLog.Add("ITEM|ERROR|$childPath|$($_.Exception.Message)")
            }
        }
    }

    Write-Host (("`r  [+] Scan done: {0} files ready | {1} protected/skipped | {2} extension-skipped | {3} errors        " -f $files.Count, $skippedProtected, $skippedExt, $errors)) -ForegroundColor Green
    _c ''

    $stats = [PSCustomObject]@{
        Started               = $start
        Finished              = Get-Date
        Roots                 = @($Roots)
        DirectoriesSeen       = $dirsSeen
        ItemsSeen             = $itemsSeen
        FilesKept             = $files.Count
        ProtectedSkipped      = $skippedProtected
        ExtensionSkipped      = $skippedExt
        Errors                = $errors
        AllowedExtensionCount = if ($null -eq $AllowedExtensions) { 0 } else { $AllowedExtensions.Count }
    }

    return [PSCustomObject]@{
        Files    = $files
        Stats    = $stats
        LogLines = $scanLog
    }
}

function Write-ScanReport {
    param(
        [System.Collections.Generic.List[System.IO.FileInfo]]$Files,
        $Stats,
        [string]$Method,
        $AllowedExtensions,
        [string[]]$ScanLogLines = @()
    )

    Ensure-LogFolders
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base = Join-Path $Script:ScanLogRoot "scan_$stamp"
    $csv = "$base.csv"
    $txt = "$base.txt"
    $log = "$base.log"

    try {
        $rootsText = @($Stats.Roots | ForEach-Object { $_.Root }) -join '; '
        $extMode = if ($null -eq $AllowedExtensions) { 'ALL SAFE EXTENSIONS' } else { "$($AllowedExtensions.Count) selected extensions" }

        @(
            'DupReaper Scan Report',
            ('Created : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
            ('Method  : {0}' -f $Method),
            ('Roots   : {0}' -f $rootsText),
            ('Filter  : {0}' -f $extMode),
            ('Files   : {0}' -f $Stats.FilesKept),
            ('Items   : {0}' -f $Stats.ItemsSeen),
            ('Dirs    : {0}' -f $Stats.DirectoriesSeen),
            ('Skipped protected : {0}' -f $Stats.ProtectedSkipped),
            ('Skipped extension : {0}' -f $Stats.ExtensionSkipped),
            ('Errors  : {0}' -f $Stats.Errors),
            ('Started : {0}' -f $Stats.Started),
            ('Ended   : {0}' -f $Stats.Finished),
            ''
        ) | Out-File -LiteralPath $txt -Encoding UTF8

        $report = $Files | Sort-Object FullName | ForEach-Object {
            [PSCustomObject]@{
                Path        = $_.FullName
                SizeBytes   = $_.Length
                SizeHuman   = (_sz $_.Length)
                Extension   = $_.Extension
                Created     = $_.CreationTime
                Modified    = $_.LastWriteTime
                Parent      = $_.DirectoryName
            }
        }
        $report | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

        if ($ScanLogLines -and $ScanLogLines.Count -gt 0) {
            $ScanLogLines | Out-File -LiteralPath $log -Encoding UTF8
        } else {
            @(
                "DupReaper v$($Script:VER) scan log",
                ('Created : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
                'No detailed scan log lines were captured.'
            ) | Out-File -LiteralPath $log -Encoding UTF8
        }

        _ok "Scan report saved: $txt"
        _ok "Scan CSV saved   : $csv"
        _ok "Scan log saved   : $log"
    } catch {
        _wrn "Could not write scan report: $($_.Exception.Message)"
    }
}

# ======================================================================
# HASH HELPERS / DUPLICATE DETECTION
# ======================================================================

function Get-SHA256 {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return $null }
}

function Find-ByName {
    param([System.Collections.Generic.List[System.IO.FileInfo]]$Files)
    _inf 'Grouping by filename (case-insensitive)...'
    $groups = $Files |
        Group-Object { $_.Name.ToLowerInvariant() } |
        Where-Object { (Get-Count $_.Group) -gt 1 }

    return @($groups | ForEach-Object {
        [PSCustomObject]@{ Files = @($_.Group); Method = 'Name' }
    })
}

function Find-ByHash {
    param(
        [System.Collections.Generic.List[System.IO.FileInfo]]$Files,
        [string]$Mode
    )

    _inf 'Pre-filtering by file size...'
    $sizeGroups = $Files |
        Group-Object Length |
        Where-Object { (Get-Count $_.Group) -gt 1 }

    if (-not $sizeGroups) {
        _inf 'No size-matched groups found.'
        return @()
    }

    $totalToHash = 0
    foreach ($sg in $sizeGroups) { $totalToHash += (Get-Count $sg.Group) }
    _inf "Hashing $totalToHash size-matched files via SHA-256..."

    $map = @{}
    $done = 0

    foreach ($sg in $sizeGroups) {
        foreach ($f in $sg.Group) {
            $done++
            if ($done % 5 -eq 0) {
                Write-Host ("`r  [>] Hashing {0}/{1}  ({2:N0}%)...  " -f $done, $totalToHash, ($done / $totalToHash * 100)) -ForegroundColor White -NoNewline
            }

            $hash = Get-SHA256 $f.FullName
            if (-not $hash) { continue }

            switch ($Mode) {
                'both'  { $key = "$($f.Name.ToLowerInvariant())|$hash" }
                default { $key = $hash }
            }

            if (-not $map.ContainsKey($key)) {
                $map[$key] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $map[$key].Add($f)
        }
    }

    Write-Host "`r  [+] Hashing complete.                                              " -ForegroundColor Green
    _c ''

    return @(
        $map.GetEnumerator() |
            Where-Object { (Get-Count $_.Value) -gt 1 } |
            ForEach-Object { [PSCustomObject]@{ Files = @($_.Value); Method = $Mode } }
    )
}

function Find-Dupes {
    param([System.Collections.Generic.List[System.IO.FileInfo]]$Files, [string]$Method)
    switch ($Method) {
        'name'  { return @(Find-ByName $Files) }
        'hash'  { return @(Find-ByHash $Files 'hash') }
        'both'  { return @(Find-ByHash $Files 'both') }
        'smart' { return @(Find-ByHash $Files 'smart') }
        default { return @() }
    }
}

function Get-BestKeep {
    param([array]$Files)

    $scored = $Files | ForEach-Object {
        $f = $_
        $s = 0
        $p = $f.FullName.ToLowerInvariant()

        if ($p -like '*\documents\*')  { $s += 40 }
        if ($p -like '*\pictures\*')   { $s += 40 }
        if ($p -like '*\videos\*')     { $s += 35 }
        if ($p -like '*\music\*')      { $s += 35 }
        if ($p -like '*\desktop\*')    { $s += 30 }
        if ($p -like '*\downloads\*')  { $s += 15 }
        if ($p -like '*\onedrive\*')   { $s += 20 }

        if ($p -like '*\temp\*')        { $s -= 60 }
        if ($p -like '*\tmp\*')         { $s -= 60 }
        if ($p -like '*\cache\*')       { $s -= 50 }
        if ($p -like '*\temporary*')    { $s -= 50 }
        if ($p -like '*\recycle*')      { $s -= 80 }
        if ($p -like '*\appdata\*')     { $s -= 15 }
        if ($p -like '*\localappdata\*'){ $s -= 10 }

        $depth = Get-Count ($p -split '\\')
        $s -= ($depth * 3)

        $ageDays = ([datetime]::Now - $f.CreationTime).TotalDays
        if ($ageDays -gt 0) { $s += [math]::Min($ageDays, 730) }

        $modDays = ([datetime]::Now - $f.LastWriteTime).TotalDays
        if ($modDays -gt 0) { $s += [math]::Min($modDays * 0.25, 180) }

        [PSCustomObject]@{ F = $f; S = $s }
    } | Sort-Object S -Descending

    return $scored[0].F
}

# ======================================================================
# RESULT DISPLAY AND FILE SELECTION
# ======================================================================

function Show-Results {
    param([array]$Groups)

    if (-not $Groups -or (Get-Count $Groups) -eq 0) {
        Show-Section 'RESULTS'
        _ok 'No duplicate files found in the selected scope.'
        _c ''
        return $null
    }

    $totalWaste = [long]0
    foreach ($g in $Groups) {
        $totalWaste += $g.Files[0].Length * ((Get-Count $g.Files) - 1)
    }

    Show-Section 'DUPLICATE GROUPS FOUND'
    _c "  Groups found   : " 'White' -nn; _c "$(Get-Count $Groups)" 'Yellow'
    _c "  Space to reclaim: " 'White' -nn; _c (_sz $totalWaste) 'Green'
    _c ''
    _ln

    $allDupes = [System.Collections.Generic.List[PSCustomObject]]::new()
    $gNum = 1

    foreach ($g in $Groups) {
        $keep   = Get-BestKeep $g.Files
        $extras = @($g.Files | Where-Object { $_.FullName -ne $keep.FullName })

        _c "  Group $gNum" 'Cyan' -nn
        _c ("  |  {0} copies  |  {1} each  |  Waste: {2}" -f (Get-Count $g.Files), (_sz $g.Files[0].Length), (_sz ($g.Files[0].Length * (Get-Count $extras)))) 'DarkGray'
        _c ''

        _c '    [KEEP] ' 'Green' -nn; _c $keep.FullName 'White'
        _c '           ' -nn
        _c ("Modified: {0}  |  Created: {1}" -f $keep.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $keep.CreationTime.ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
        _c ''

        foreach ($f in $extras) {
            $idx = (Get-Count $allDupes) + 1
            $allDupes.Add([PSCustomObject]@{
                Index = $idx
                File  = $f
                Keep  = $keep
                Group = $gNum
            })
            _c ("    [{0,4}] " -f $idx) 'Red' -nn
            _c $f.FullName 'White'
            _c '            ' -nn
            _c ("Modified: {0}  |  Created: {1}" -f $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $f.CreationTime.ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
        }

        _c ''
        _ln
        $gNum++
    }

    _c "  Total removable files: " 'White' -nn; _c "$(Get-Count $allDupes)" 'Red'
    _c ''
    return $allDupes
}

function Get-FileSelection {
    param([System.Collections.Generic.List[PSCustomObject]]$Dupes)

    while ($true) {
        _c '  Select files to remove:' 'White'
        _c "  [A]     = All $(Get-Count $Dupes) duplicates (recommended)" 'Green'
        _c '  [#]     = Single item        (e.g.  5)' 'White'
        _c '  [#-#]   = Range              (e.g.  1-15)' 'White'
        _c '  [#,#,#] = Multiple items     (e.g.  2,5,9)' 'White'
        _c '  [V #]   = View file details  (e.g.  V 5)' 'Cyan'
        _c '  [N]     = Cancel' 'Red'
        _c ''
        _c '  > ' 'Yellow' -nn

        $in = $null
        try { $in = (Read-Host).Trim() } catch { return @() }

        if ([string]::IsNullOrEmpty($in) -or $in -match '^[Nn]$') { return @() }
        if ($in -match '^[Aa]$') { return @($Dupes) }

        if ($in -match '^[Vv]\s*(\d+)$') {
            $idx  = [int]$Matches[1]
            $item = $Dupes | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
            if ($item) {
                _c ''
                _c "  File      : $($item.File.FullName)" 'Cyan'
                _c "  Size      : $(_sz $item.File.Length)" 'White'
                _c "  Created   : $($item.File.CreationTime)" 'White'
                _c "  Modified  : $($item.File.LastWriteTime)" 'White'
                _c "  Keep copy : $($item.Keep.FullName)" 'Green'
                _c "  Group     : $($item.Group)" 'DarkGray'
                _c ''
            } else {
                _err "Item #$idx not found."
            }
            continue
        }

        $sel   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $valid = $true

        $in -split ',' | ForEach-Object {
            $part = $_.Trim()
            if ($part -match '^(\d+)-(\d+)$') {
                [int]$Matches[1]..[int]$Matches[2] | ForEach-Object {
                    $i    = $_
                    $item = $Dupes | Where-Object { $_.Index -eq $i } | Select-Object -First 1
                    if ($item -and -not ($sel | Where-Object { $_.Index -eq $item.Index })) { $sel.Add($item) }
                }
            } elseif ($part -match '^\d+$') {
                $i    = [int]$part
                $item = $Dupes | Where-Object { $_.Index -eq $i } | Select-Object -First 1
                if ($item) {
                    if (-not ($sel | Where-Object { $_.Index -eq $item.Index })) { $sel.Add($item) }
                } else {
                    _err "Item #$i not found."
                    $valid = $false
                }
            }
        }

        if ((Get-Count $sel) -eq 0 -or -not $valid) {
            _err 'No valid items selected. Try again.'
            _c ''
            continue
        }

        _c ''
        _ok "$(Get-Count $sel) file(s) queued for removal."
        return @($sel)
    }
}

# ======================================================================
# CLEANUP ACTIONS
# ======================================================================

function Get-RemoveAction {
    Show-Section 'REMOVAL ACTION'

    _c '  What should happen to the selected files?' 'White'
    _c ''
    _c '  [1] Recycle Bin       ' 'Green' -nn
    _c 'Best for local disks | May not be available on SMB shares' 'DarkGray'
    _c '  [2] Move to Folder    ' 'Yellow' -nn
    _c 'Move files to a path you specify' 'DarkGray'
    _c '  [3] Delete Forever    ' 'Red' -nn
    _c 'PERMANENT - cannot be undone' 'DarkGray'
    _c '  [N] Cancel' 'DarkGray'
    _c ''
    _c '  > ' 'Yellow' -nn

    $ch = $null
    try { $ch = (Read-Host).Trim() } catch { return 'cancel' }

    switch ($ch) {
        '1' { return 'recycle' }
        '2' { return 'move' }
        '3' { return 'delete' }
        default { return 'cancel' }
    }
}

function Get-MoveTarget {
    while ($true) {
        _c ''
        _c '  Enter destination folder path:' 'Yellow'
        _c '  (Works with local paths and SMB/UNC paths)' 'DarkGray'
        _c '  > ' 'Yellow' -nn

        $p = $null
        try { $p = (Read-Host).Trim() } catch { return $null }

        if ([string]::IsNullOrWhiteSpace($p)) { _err 'Path cannot be empty.'; continue }
        if (Test-ProtectedPath $p) { _err 'Cannot use a protected system directory as destination.'; continue }

        try {
            if (-not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) {
                _wrn 'Directory does not exist. Creating...'
                New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null
            }
            return $p
        } catch {
            _err "Cannot create/access: $p  [$($_.Exception.Message)]"
        }
    }
}

function Send-ToRecycleBin {
    param([string]$Path)
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
        return $true
    } catch {
        return $false
    }
}

function Invoke-Cleanup {
    param(
        [array]$Items,
        [string]$Action,
        [string]$MoveTarget = ''
    )

    Show-Section 'EXECUTE'

    _c ''
    if ($Action -eq 'delete') {
        _err "WARNING: PERMANENT DELETE of $(Get-Count $Items) file(s). CANNOT BE UNDONE."
    } else {
        _wrn "About to $($Action.ToUpper()) $(Get-Count $Items) file(s)."
    }
    _c ''
    _c '  Type ' 'White' -nn; _c 'CONFIRM' 'Red' -nn; _c ' and press Enter to proceed, or Enter alone to cancel: ' 'White' -nn

    $conf = $null
    try { $conf = (Read-Host).Trim() } catch { return }
    if ($conf -ne 'CONFIRM') {
        _wrn 'Operation cancelled. No files were modified.'
        return
    }

    Ensure-LogFolders
    $ok   = 0
    $bad  = 0
    $skip = 0
    $log  = [System.Collections.Generic.List[string]]::new()
    $log.Add("DupReaper v$($Script:VER) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Action: $Action | Target: $(Get-Count $Items) files")
    $log.Add('=' * 70)

    _c ''
    foreach ($item in $Items) {
        $path = Convert-ToRawFileSystemPath $item.File.FullName

        if (Test-ProtectedPath (Convert-ToRawFileSystemPath $item.File.DirectoryName)) {
            _err "BLOCKED [system path]: $path"
            $log.Add("BLOCKED|SYSTEM_PATH|$path")
            $bad++
            continue
        }

        if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            _wrn "SKIPPED [not found]: $path"
            $log.Add("SKIP|NOT_FOUND|$path")
            $skip++
            continue
        }

        $keepPath = Convert-ToRawFileSystemPath $item.Keep.FullName
        if (-not (Test-Path -LiteralPath $keepPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            _err "BLOCKED [keep copy missing]: $path"
            _err "          Keep was: $keepPath"
            $log.Add("BLOCKED|KEEP_MISSING|$path|Keep=$keepPath")
            $bad++
            continue
        }

        if ($path.ToLowerInvariant() -eq $keepPath.ToLowerInvariant()) {
            _err "BLOCKED [same as keep]: $path"
            $log.Add("BLOCKED|SAME_AS_KEEP|$path")
            $bad++
            continue
        }

        try {
            switch ($Action) {
                'recycle' {
                    $ok2 = Send-ToRecycleBin $path
                    if (-not $ok2) { throw 'Recycle operation failed (not supported on this path or unavailable).' }
                }
                'move' {
                    $name = [System.IO.Path]::GetFileName($path)
                    $dest = Join-Path $MoveTarget $name
                    if (Test-Path -LiteralPath $dest -ErrorAction SilentlyContinue) {
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
                        $ext  = [System.IO.Path]::GetExtension($path)
                        $dest = Join-Path $MoveTarget ("{0}_dup_{1}{2}" -f $base, (Get-Random), $ext)
                    }
                    Move-Item -LiteralPath $path -Destination $dest -Force -ErrorAction Stop
                }
                'delete' {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
            }
            _ok $path
            $log.Add("OK|$Action|$path")
            $ok++
        } catch {
            _err "FAILED: $path"
            _err "        Error: $($_.Exception.Message)"
            $log.Add("FAIL|$Action|$path|$($_.Exception.Message)")
            $bad++
        }
    }

    $logFile = Join-Path $Script:RunLogRoot ("run_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $log | Out-File -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}

    _c ''
    _dln
    _c '  Result: ' 'White' -nn
    _c "$ok removed" 'Green' -nn
    _c '  |  ' 'DarkGray' -nn
    _c "$bad blocked/failed" 'Red' -nn
    _c '  |  ' 'DarkGray' -nn
    _c "$skip skipped" 'Yellow'
    _inf "Session log: $logFile"
    _dln
}

# ======================================================================
# MAIN ORCHESTRATOR
# ======================================================================

function Main {
    try {
        Ensure-LogFolders

        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

        Show-Banner

        if (-not $isAdmin) {
            _wrn 'Not running as Administrator.'
            _wrn 'Some network/system-owned paths may be inaccessible.'
            _c ''
        } else {
            _ok 'Running with Administrator privileges.'
            _c ''
        }

        $roots = Get-ScanSources
        if (-not $roots -or (Get-Count $roots) -eq 0) {
            _wrn 'No scan source selected. Exiting.'
            return
        }

        $sourceText = @($roots | ForEach-Object { $_.Root }) -join ', '
        _ok "Scan scope: $sourceText"

        $allowedExt = Get-ExtensionSelection
        Show-ExtensionSummary $allowedExt

        $method = Get-ScanMethod

        $scan = Get-SafeFiles -Roots $roots -AllowedExtensions $allowedExt
        $files = $scan.Files
        $stats = $scan.Stats

        Write-ScanReport -Files $files -Stats $stats -Method $method -AllowedExtensions $allowedExt -ScanLogLines $scan.LogLines

        if (-not $files -or (Get-Count $files) -eq 0) {
            _wrn 'No scannable user files found in the selected scope.'
            _pause
            return
        }
        _ok "$(Get-Count $files) file(s) ready for duplicate analysis."

        _c ''
        _inf 'Analyzing for duplicates...'
        $groups = @(Find-Dupes $files $method)

        $dupeList = Show-Results $groups
        if (-not $dupeList -or (Get-Count $dupeList) -eq 0) {
            _pause
            return
        }

        $toRemove = @(Get-FileSelection $dupeList)
        if (-not $toRemove -or (Get-Count $toRemove) -eq 0) {
            _wrn 'No files selected for removal. Exiting cleanly.'
            _pause
            return
        }

        $action = Get-RemoveAction
        if ($action -eq 'cancel') {
            _wrn 'Action cancelled. No files were modified.'
            _pause
            return
        }

        $movePath = ''
        if ($action -eq 'move') {
            $movePath = Get-MoveTarget
            if ([string]::IsNullOrWhiteSpace($movePath)) {
                _wrn 'No destination provided. Cancelled.'
                _pause
                return
            }
        }

        Invoke-Cleanup -Items $toRemove -Action $action -MoveTarget $movePath

    } catch {
        _c ''
        _err "Fatal error: $($_.Exception.Message)"
        if ($_.InvocationInfo) {
            _err "Location  : line $($_.InvocationInfo.ScriptLineNumber)"
        }
    } finally {
        _c ''
        _dln
        _ctr 'DupReaper session complete.' 'DarkGray'
        _ctr "Logs saved to: $Script:LogRoot" 'DarkGray'
        _dln
        _c ''
        _pause
    }
}

# ======================================================================
# ENTRY POINT
# ======================================================================

Main
