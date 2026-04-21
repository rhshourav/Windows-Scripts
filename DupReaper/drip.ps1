#Requires -Version 5.1
<#
.SYNOPSIS
    DupReaper v1.3.0  -  Phantom Duplicate File Slayer
.DESCRIPTION
    Intelligent, hardened duplicate file detector and eliminator for Windows.
    Automatically protects ALL critical Windows system files and directories.
    Supports Name, Hash, and Smart (Size+SHA-256) comparison methods.
    Never touches executables, drivers, registry files, or any system path.
.AUTHOR
    rhshourav
.PROJECTURI
    https://github.com/rhshourav/Windows-Scripts
.NOTES
    Compatible : Windows 10+  |  PowerShell 5.1+
    Run locally: .\DupReaper.ps1
    Run remote : iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DupReaper.ps1')
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'

# ======================================================================
#  CONSTANTS
# ======================================================================

$Script:VER     = '1.3.0'
$Script:AUTHOR  = 'rhshourav'
$Script:GITHUB  = 'https://github.com/rhshourav/Windows-Scripts'
$Script:W       = 72      # Console display width
$Script:MINSIZE = 1024    # Skip files smaller than 1 KB (1024 bytes)

# ======================================================================
#  PROTECTED PATHS  --  DupReaper will NEVER scan or touch these
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
    $norm = $_r.TrimEnd('\').ToLowerInvariant()
    if ($norm -and -not $Script:SYS_ROOTS.Contains($norm)) {
        $Script:SYS_ROOTS.Add($norm)
    }
}
Remove-Variable _rawRoots, _r -ErrorAction SilentlyContinue

# File extensions that are ALWAYS protected (system/executable/script/registry)
$Script:BAD_EXT = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '.sys', '.dll', '.exe', '.msi', '.msp', '.msu', '.drv', '.ocx',
        '.cpl', '.acm', '.ax',  '.scr', '.com', '.bat', '.cmd', '.vbs',
        '.js',  '.jse', '.wsf', '.wsh', '.reg', '.inf', '.cat', '.cab',
        '.wim', '.efi', '.pdb', '.lib', '.obj', '.lnk', '.manifest',
        '.mui', '.mun', '.nls', '.ime', '.bin', '.dat', '.db',
        '.log', '.etl', '.evt', '.evtx', '.msc', '.hlp', '.chm',
        '.diagpkg', '.diagcab', '.admx', '.adml', '.mof', '.sdb',
        '.theme', '.deskthemepack', '.lock', '.tmp'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

# ======================================================================
#  UI HELPERS
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

# ======================================================================
#  BANNER
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
    _ctr ' | |  | |_   _ _ _| |__) |___  __ _ _ __   ___ _ __      ' 'Green'
    _ctr ' | |  | | | | | _ \  _  // _ \/ _` |  _ \ / _ \  __|     ' 'Green'
    _ctr ' | |__| | |_| |  _/ | \ \  __/ (_| | |_) |  __/ |        ' 'Green'
    _ctr ' |_____/ \__,_|_| |_|  \_\___|\__,_| .__/ \___|_|        ' 'Green'
    _ctr '                                    | |                   ' 'Green'
    _ctr '                                    |_|                   ' 'Green'
    _c ''
    _ctr '* Phantom Duplicate File Slayer *' 'Yellow'
    _ctr "v$($Script:VER)  |  by $($Script:AUTHOR)" 'DarkGray'
    _ctr $Script:GITHUB 'DarkGray'
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

# ======================================================================
#  PROTECTION CHECKS
# ======================================================================

function Test-ProtectedPath {
    param([string]$Path)
    if (-not $Path) { return $true }
    $norm = $Path.TrimEnd('\').ToLowerInvariant()
    if (-not $norm) { return $true }
    foreach ($root in $Script:SYS_ROOTS) {
        if ($norm -eq $root -or $norm.StartsWith($root + '\')) {
            return $true
        }
    }
    return $false
}

function Test-ProtectedFile {
    param([System.IO.FileInfo]$F)
    # Rule 1: Parent directory is a protected system root
    if (Test-ProtectedPath $F.DirectoryName) { return $true }
    # Rule 2: File extension is on the protected list
    if ($Script:BAD_EXT.Contains($F.Extension)) { return $true }
    # Rule 3: File has the System attribute set by Windows
    if ($F.Attributes -band [System.IO.FileAttributes]::System) { return $true }
    return $false
}

# ======================================================================
#  DRIVE DETECTION
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
                    Drive = $d.Name.Substring(0, 2)
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

    _c ('  {0,-3} {1,-6} {2,-18} {3,-11} {4,-11} {5,-11} {6}' -f
        '#', 'Drive', 'Label', 'Total', 'Used', 'Free', 'Usage') 'DarkGray'
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
        _c ('{0,-6} ' -f $d.Drive) 'Cyan' -nn
        _c ('{0,-18} ' -f $lbl) 'White' -nn
        _c ('{0,-11} ' -f (_sz $d.Total)) 'White' -nn
        _c ('{0,-11} ' -f (_sz $d.Used)) 'Yellow' -nn
        _c ('{0,-11} ' -f (_sz $d.Free)) 'Green' -nn
        _c ('{0,3}% ' -f $d.Pct) $col -nn
        _c $bar $col
    }
    _c ''
}

function Show-DriveTable {
    param([System.Collections.Generic.List[PSCustomObject]]$Drives)
    Show-Section 'AVAILABLE DRIVES'

    _c ('  {0,-3} {1,-6} {2,-18} {3,-11} {4,-11} {5,-11} {6}' -f
        '#', 'Drive', 'Label', 'Total', 'Used', 'Free', 'Usage') 'DarkGray'
    _ln

    foreach ($d in $Drives) {
        $barFill  = [math]::Round(($d.Pct / 100) * 16)
        $barEmpty = 16 - $barFill
        $bar      = '[' + ('#' * $barFill) + ('-' * $barEmpty) + ']'
        $col      = if ($d.Pct -ge 90) { 'Red' } elseif ($d.Pct -ge 75) { 'Yellow' } else { 'Green' }
        $lbl      = $d.Label
        if ($lbl.Length -gt 17) { $lbl = $lbl.Substring(0, 14) + '...' }

        _c ('  {0,-3} ' -f $d.Num) 'White' -nn
        _c ('{0,-6} ' -f $d.Drive) 'Cyan' -nn
        _c ('{0,-18} ' -f $lbl) 'White' -nn
        _c ('{0,-11} ' -f (_sz $d.Total)) 'White' -nn
        _c ('{0,-11} ' -f (_sz $d.Used)) 'Yellow' -nn
        _c ('{0,-11} ' -f (_sz $d.Free)) 'Green' -nn
        _c ('{0,3}% ' -f $d.Pct) $col -nn
        _c $bar $col
    }
    _c ''
}

# ======================================================================
#  DRIVE SELECTION UI
# ======================================================================

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

        $sysDrv = $env:SystemDrive + '\'
        if ($sel | Where-Object { $_.Root -eq $sysDrv }) {
            _c ''
            _wrn "System drive ($($env:SystemDrive)) selected."
            _wrn 'All protected Windows paths will be automatically skipped.'
        }

        return $sel
    }
}

# ======================================================================
#  SCAN METHOD SELECTION
# ======================================================================

function Get-ScanMethod {
    Show-Section 'DETECTION METHOD'

    _c '  How should DupReaper identify duplicate files?' 'White'
    _c ''
    _c '  [1] Name Only    ' 'Cyan' -nn
    _c 'Fast | Compare filenames | False positives possible' 'DarkGray'
    _c '  [2] Hash Only    ' 'Cyan' -nn
    _c '100%% accurate | Full SHA-256 scan | Slower on large drives' 'DarkGray'
    _c '  [3] Name + Hash  ' 'Cyan' -nn
    _c 'Same name AND same content | Strictest definition' 'DarkGray'
    _c '  [4] Smart [REC]  ' 'Green' -nn
    _c 'Size pre-filter + SHA-256 | Fastest + 100%% accurate' 'DarkGray'
    _c ''
    _c '  Smart Scan: Groups files by size first (instant), then only' 'DarkGray'
    _c '  hashes the size-matched candidates. Eliminates 90%+ of hash work.' 'DarkGray'
    _c ''
    _ln
    _c '  Choice [1-4]  (Enter = Smart): ' 'Yellow' -nn

    $ch = $null
    try { $ch = (Read-Host).Trim() } catch { return 'smart' }

    switch ($ch) {
        '1' { _ok 'Method: Name Only';   return 'name' }
        '2' { _ok 'Method: Hash Only';   return 'hash' }
        '3' { _ok 'Method: Name + Hash'; return 'both' }
        '4' { _ok 'Method: Smart Scan';  return 'smart' }
        ''  { _ok 'Method: Smart Scan';  return 'smart' }
        default { _wrn 'Invalid choice - defaulting to Smart Scan'; return 'smart' }
    }
}

# ======================================================================
#  FILE SCANNER  (BFS with protected directory pruning)
#  Directories are checked BEFORE their contents are ever read.
#  This is the critical fix that prevents touching system files.
# ======================================================================

function Get-SafeFiles {
    param([System.Collections.Generic.List[PSCustomObject]]$Drives)

    Show-Section 'SCANNING'

    $files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $queue    = [System.Collections.Generic.Queue[string]]::new()
    $skipped  = 0
    $errors   = 0

    foreach ($d in $Drives) {
        _inf "Queuing $($d.Root) ..."
        $queue.Enqueue($d.Root.TrimEnd('\'))
    }

    while ((Get-Count $queue) -gt 0) {
        $dir = $queue.Dequeue()

        # ---- CRITICAL GATE: skip entire protected directory trees ----
        if (Test-ProtectedPath $dir) { $skipped++; continue }

        try {
            $dirInfo = [System.IO.DirectoryInfo]::new($dir)

            # Skip reparse points (junctions/symlinks) to prevent loops
            if ($dirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $skipped++; continue
            }

            # Enqueue subdirectories for scanning
            try {
                foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
                    $queue.Enqueue($sub)
                }
            } catch {}

            # Evaluate files in this directory
            foreach ($fPath in [System.IO.Directory]::GetFiles($dir)) {
                try {
                    $fi = [System.IO.FileInfo]::new($fPath)
                    if (Test-ProtectedFile $fi) { $skipped++ }
                    else { $files.Add($fi) }
                } catch { $errors++ }
            }

        } catch { $errors++ }

        if (((Get-Count $files) + $skipped) % 250 -eq 0) {
            Write-Host ("`r  [>] Scannable: {0,6}  Protected/Skipped: {1,6}  Queue: {2,5}  " -f
                (Get-Count $files), $skipped, (Get-Count $queue)) -ForegroundColor White -NoNewline
        }
    }

    Write-Host ("`r  [+] Scan done: {0} files ready | {1} protected/skipped | {2} errors        " -f
        (Get-Count $files), $skipped, $errors) -ForegroundColor Green
    _c ''
    return $files
}

# ======================================================================
#  HASH HELPER
# ======================================================================

function Get-SHA256 {
    param([string]$Path)
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch { return $null }
}

# ======================================================================
#  DUPLICATE DETECTION ENGINES
# ======================================================================

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
        [string]$Mode  # 'hash' | 'both'
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

    $map  = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[System.IO.FileInfo]]]::new(
                [StringComparer]::Ordinal)
    $done = 0

    foreach ($sg in $sizeGroups) {
        foreach ($f in $sg.Group) {
            $done++
            if ($done % 5 -eq 0) {
                Write-Host ("`r  [>] Hashing {0}/{1}  ({2:N0}%%)...  " -f
                    $done, $totalToHash, ($done / $totalToHash * 100)) -ForegroundColor White -NoNewline
            }

            $hash = Get-SHA256 $f.FullName
            if (-not $hash) { continue }

            $key = if ($Mode -eq 'both') { "$($f.Name.ToLowerInvariant())|$hash" }
                    elseif ($Mode -eq 'smart') { "$($f.Length)|$hash" }
                    else { $hash }

            if (-not $map.ContainsKey($key)) {
                $map[$key] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $map[$key].Add($f)
        }
    }

    Write-Host "`r  [+] Hashing complete.                                              " -ForegroundColor Green
    _c ''

    return @($map.GetEnumerator() |
        Where-Object { (Get-Count $_.Value) -gt 1 } |
        ForEach-Object { [PSCustomObject]@{ Files = @($_.Value); Method = $Mode } })
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

# ======================================================================
#  SMART KEEP RECOMMENDATION ENGINE
#  Scores each copy and recommends the most "intentional" original.
# ======================================================================

function Get-BestKeep {
    param([array]$Files)

    $scored = $Files | ForEach-Object {
        $f = $_
        $s = 0
        $p = $f.FullName.ToLowerInvariant()

        # Reward: standard user data locations
        if ($p -like '*\documents\*')  { $s += 40 }
        if ($p -like '*\pictures\*')   { $s += 40 }
        if ($p -like '*\videos\*')     { $s += 35 }
        if ($p -like '*\music\*')      { $s += 35 }
        if ($p -like '*\desktop\*')    { $s += 30 }
        if ($p -like '*\downloads\*')  { $s += 15 }
        if ($p -like '*\onedrive\*')   { $s += 20 }

        # Penalize: temp / cache / junk locations
        if ($p -like '*\temp\*')        { $s -= 60 }
        if ($p -like '*\tmp\*')         { $s -= 60 }
        if ($p -like '*\cache\*')       { $s -= 50 }
        if ($p -like '*\temporary*')    { $s -= 50 }
        if ($p -like '*\recycle*')      { $s -= 80 }
        if ($p -like '*\appdata\*')     { $s -= 15 }
        if ($p -like '*\localappdata\*'){ $s -= 10 }

        # Reward: shallower path depth (intentional placement)
        $depth = Get-Count ($p -split '\\')
        $s -= ($depth * 3)

        # Reward: older creation time (original is usually older)
        $ageDays = ([datetime]::Now - $f.CreationTime).TotalDays
        if ($ageDays -gt 0) { $s += [math]::Min($ageDays, 730) }   # Cap at 2 years

        # Reward: older modification time as a secondary signal
        $modDays = ([datetime]::Now - $f.LastWriteTime).TotalDays
        if ($modDays -gt 0) { $s += [math]::Min($modDays * 0.25, 180) }

        [PSCustomObject]@{ F = $f; S = $s }
    } | Sort-Object S -Descending

    return $scored[0].F
}

# ======================================================================
#  RESULTS DISPLAY
# ======================================================================

function Show-Results {
    param([array]$Groups)

    if (-not $Groups -or (Get-Count $Groups) -eq 0) {
        Show-Section 'RESULTS'
        _ok 'No duplicate files found. Your selected drives are clean.'
        _c ''
        return $null
    }

    $totalWaste = [long]0
    foreach ($g in $Groups) {
        $totalWaste += $g.Files[0].Length * ((Get-Count $g.Files) - 1)
    }

    Show-Section 'DUPLICATE GROUPS FOUND'
    _c "  Groups found  : " 'White' -nn; _c "$(Get-Count $Groups)" 'Yellow'
    _c "  Space to reclaim: " 'White' -nn; _c (_sz $totalWaste) 'Green'
    _c ''
    _ln

    $allDupes = [System.Collections.Generic.List[PSCustomObject]]::new()
    $gNum = 1

    foreach ($g in $Groups) {
        $keep   = Get-BestKeep $g.Files
        $extras = @($g.Files | Where-Object { $_.FullName -ne $keep.FullName })

        _c "  Group $gNum" 'Cyan' -nn
        _c ("  |  {0} copies  |  {1} each  |  Waste: {2}" -f
            (Get-Count $g.Files), (_sz $g.Files[0].Length), (_sz ($g.Files[0].Length * (Get-Count $extras)))) 'DarkGray'
        _c ''

        _c '    [KEEP] ' 'Green' -nn; _c $keep.FullName 'White'
        _c '           ' -nn
        _c ("Modified: {0}  |  Created: {1}" -f
            $keep.LastWriteTime.ToString('yyyy-MM-dd HH:mm'),
            $keep.CreationTime.ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
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
            _c ("Modified: {0}  |  Created: {1}" -f
                $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'),
                $f.CreationTime.ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
        }

        _c ''
        _ln
        $gNum++
    }

    _c "  Total removable files: " 'White' -nn; _c "$(Get-Count $allDupes)" 'Red'
    _c ''
    return $allDupes
}

# ======================================================================
#  FILE SELECTION UI
# ======================================================================

function Get-FileSelection {
    param([System.Collections.Generic.List[PSCustomObject]]$Dupes)

    while ($true) {
        _c '  Select files to remove:' 'White'
        _c "  [A]     = All $(Get-Count $Dupes) duplicates (DupReaper recommended)" 'Green'
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

        # View detail command
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
                    if ($item -and -not ($sel | Where-Object { $_.Index -eq $item.Index })) {
                        $sel.Add($item)
                    }
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
#  ACTION SELECTION
# ======================================================================

function Get-RemoveAction {
    Show-Section 'REMOVAL ACTION'

    _c '  What should happen to the selected files?' 'White'
    _c ''
    _c '  [1] Recycle Bin       ' 'Green' -nn
    _c 'Safe | Files go to Recycle Bin | Easily recoverable' 'DarkGray'
    _c '  [2] Move to Folder    ' 'Yellow' -nn
    _c 'Move files to a path you specify' 'DarkGray'
    _c '  [3] Delete Forever    ' 'Red' -nn
    _c 'PERMANENT - cannot be undone - no recovery possible' 'DarkGray'
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
        _c '  Enter destination folder path: ' 'Yellow' -nn
        $p = $null
        try { $p = (Read-Host).Trim() } catch { return $null }

        if ([string]::IsNullOrEmpty($p)) { _err 'Path cannot be empty.'; continue }

        if (Test-ProtectedPath $p) {
            _err 'Cannot use a protected system directory as destination.'
            continue
        }

        try {
            if (-not (Test-Path $p -ErrorAction SilentlyContinue)) {
                _wrn 'Directory does not exist. Creating...'
                New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null
                _ok "Created: $p"
            }
            return $p
        } catch {
            _err "Cannot create/access: $p  [$($_.Exception.Message)]"
        }
    }
}

# ======================================================================
#  RECYCLE BIN  (dual-method with fallback)
# ======================================================================

function Send-ToRecycleBin {
    param([string]$Path)

    # Method 1: Microsoft.VisualBasic (preferred - no UI dialog)
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
        return $true
    } catch {}

    # Method 2: Shell.Application COM fallback
    try {
        $shell  = New-Object -ComObject Shell.Application -ErrorAction Stop
        $folder = $shell.NameSpace([System.IO.Path]::GetDirectoryName($Path))
        if ($folder) {
            $item = $folder.ParseName([System.IO.Path]::GetFileName($Path))
            if ($item) { $item.InvokeVerb('delete'); return $true }
        }
    } catch {}

    return $false
}

# ======================================================================
#  EXECUTION ENGINE
# ======================================================================

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

    $ok   = 0
    $bad  = 0
    $skip = 0
    $log  = [System.Collections.Generic.List[string]]::new()
    $log.Add("DupReaper v$($Script:VER) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Action: $Action | Target: $(Get-Count $Items) files")
    $log.Add('=' * 70)

    _c ''
    foreach ($item in $Items) {
        $path = $item.File.FullName

        # ---- CRITICAL SAFETY GATE (executed again before every operation) ----

        # Gate 1: Re-check protected path
        if (Test-ProtectedPath $item.File.DirectoryName) {
            _err "BLOCKED [system path]: $path"
            $log.Add("BLOCKED|SYSTEM_PATH|$path")
            $bad++
            continue
        }

        # Gate 2: Re-check file still exists
        if (-not (Test-Path $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            _wrn "SKIPPED [not found]: $path"
            $log.Add("SKIP|NOT_FOUND|$path")
            $skip++
            continue
        }

        # Gate 3: Verify the "keep" copy still exists before removing the duplicate
        if (-not (Test-Path $item.Keep.FullName -PathType Leaf -ErrorAction SilentlyContinue)) {
            _err "BLOCKED [keep copy missing]: $path"
            _err "          Keep was: $($item.Keep.FullName)"
            $log.Add("BLOCKED|KEEP_MISSING|$path|Keep=$($item.Keep.FullName)")
            $bad++
            continue
        }

        # Gate 4: Do not allow removing the same file that is the keep copy
        if ($path.ToLowerInvariant() -eq $item.Keep.FullName.ToLowerInvariant()) {
            _err "BLOCKED [same as keep]: $path"
            $log.Add("BLOCKED|SAME_AS_KEEP|$path")
            $bad++
            continue
        }

        # ---- EXECUTE ----
        try {
            switch ($Action) {
                'recycle' {
                    $ok2 = Send-ToRecycleBin $path
                    if (-not $ok2) { throw 'Both recycle methods failed' }
                }
                'move' {
                    $name = [System.IO.Path]::GetFileName($path)
                    $dest = Join-Path $MoveTarget $name
                    if (Test-Path $dest -ErrorAction SilentlyContinue) {
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
                        $ext  = [System.IO.Path]::GetExtension($path)
                        $dest = Join-Path $MoveTarget "$($base)_dup_$(Get-Random)$ext"
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

    # Write log
    $logDir  = Join-Path $env:USERPROFILE 'DupReaper_Logs'
    $logFile = Join-Path $logDir ("run_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        if (-not (Test-Path $logDir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $log | Out-File $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}

    _c ''
    _dln
    _c '  Result: ' 'White' -nn
    _c "$ok removed" 'Green' -nn
    _c '  |  ' 'DarkGray' -nn
    _c "$bad blocked/failed" 'Red' -nn
    _c '  |  ' 'DarkGray' -nn
    _c "$skip skipped" 'Yellow'
    if (Test-Path $logFile -ErrorAction SilentlyContinue) {
        _inf "Session log: $logFile"
    }
    _dln
}

# ======================================================================
#  MAIN ORCHESTRATOR
# ======================================================================

function Main {
    try {
        # Admin check (non-blocking - just advisory)
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

        # ---- STEP 1: Drives ----
        $drives = Get-DriveList
        if (-not $drives -or (Get-Count $drives) -eq 0) {
            _err 'No accessible drives detected. Exiting.'
            return
        }
        Show-DriveTable $drives

        $selDrives = Get-SelectedDrives $drives
        if (-not $selDrives -or (Get-Count $selDrives) -eq 0) {
            _wrn 'No drives selected. Exiting.'
            return
        }
        _ok "Drives selected: $(($selDrives | ForEach-Object { $_.Drive }) -join ', ')"

        # ---- STEP 2: Method ----
        $method = Get-ScanMethod

        # ---- STEP 3: Scan ----
        $files = Get-SafeFiles $selDrives
        if (-not $files -or (Get-Count $files) -eq 0) {
            _wrn 'No scannable user files found in selected drives.'
            _pause
            return
        }
        _ok "$(Get-Count $files) user files ready for duplicate analysis."

        # ---- STEP 4: Find duplicates ----
        _c ''
        _inf 'Analyzing for duplicates...'
        $groups = @(Find-Dupes $files $method)

        # ---- STEP 5: Display results ----
        $dupeList = Show-Results $groups
        if (-not $dupeList -or (Get-Count $dupeList) -eq 0) {
            _pause
            return
        }

        # ---- STEP 6: User selects files to remove ----
        $toRemove = @(Get-FileSelection $dupeList)
        if (-not $toRemove -or (Get-Count $toRemove) -eq 0) {
            _wrn 'No files selected for removal. Exiting cleanly.'
            _pause
            return
        }

        # ---- STEP 7: Choose action ----
        $action = Get-RemoveAction
        if ($action -eq 'cancel') {
            _wrn 'Action cancelled. No files were modified.'
            _pause
            return
        }

        $movePath = ''
        if ($action -eq 'move') {
            $movePath = Get-MoveTarget
            if ([string]::IsNullOrEmpty($movePath)) {
                _wrn 'No destination provided. Cancelled.'
                _pause
                return
            }
        }

        # ---- STEP 8: Execute ----
        Invoke-Cleanup $toRemove $action $movePath

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
        _ctr "Logs saved to: $env:USERPROFILE\DupReaper_Logs\" 'DarkGray'
        _dln
        _c ''
        _pause
    }
}

# ======================================================================
#  ENTRY POINT
# ======================================================================

Main
