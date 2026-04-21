#Requires -Version 5.1
<#
.SYNOPSIS
    DupReaper v1.3.0  -  Aegis Edition
.DESCRIPTION
    Intelligent, hardened duplicate file detector and eliminator for Windows.
    Automatically protects ALL critical Windows system files, hidden items, and AppData.
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
    (Join-Path $env:SystemDrive '\PerfLogs'),
    "$env:USERPROFILE\AppData",  # Protects all user application installations
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "$env:PUBLIC"
)

foreach ($_r in $_rawRoots) {
    if (-not $_r) { continue }
    $norm = $_r.TrimEnd('\').ToLowerInvariant()
    if ($norm -and -not $Script:SYS_ROOTS.Contains($norm)) {
        $Script:SYS_ROOTS.Add($norm)
    }
}
Remove-Variable _rawRoots, _r -ErrorAction SilentlyContinue

# File extensions that are ALWAYS protected (system/executable/script/registry/config)
$Script:BAD_EXT = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '.sys', '.dll', '.exe', '.msi', '.msp', '.msu', '.drv', '.ocx',
        '.cpl', '.acm', '.ax',  '.scr', '.com', '.bat', '.cmd', '.vbs',
        '.js',  '.jse', '.wsf', '.wsh', '.reg', '.inf', '.cat', '.cab',
        '.wim', '.efi', '.pdb', '.lib', '.obj', '.lnk', '.manifest',
        '.mui', '.mun', '.nls', '.ime', '.bin', '.dat', '.db',
        '.log', '.etl', '.evt', '.evtx', '.msc', '.hlp', '.chm',
        '.diagpkg', '.diagcab', '.admx', '.adml', '.mof', '.sdb',
        '.theme', '.deskthemepack', '.lock', '.tmp', '.ini', '.xml', '.json',
        '.ps1', '.psm1', '.psd1'
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
    _ctr '* Aegis File Slayer *' 'Yellow'
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
    
    # Rule 3: File has the System or Hidden attribute set by Windows
    if ($F.Attributes -band [System.IO.FileAttributes]::System) { return $true }
    if ($F.Attributes -band [System.IO.FileAttributes]::Hidden) { return $true }
    
    # Rule 4: File is too small to be meaningful duplicate data
    if ($F.Length -lt $Script:MINSIZE) { return $true }
    
    return $false
}

# ======================================================================
#  DRIVE DETECTION
# ======================================================================

function Get-DriveList {
    $drives = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $psDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
                    Where-Object { $_.Root -and (Test-Path $_.Root -ErrorAction SilentlyContinue) }

        foreach ($d in $psDrives) {
            try {
                $used  = if ($null -ne $d.Used -and $d.Used -is [long]) { $d.Used } else { 0 }
                $free  = if ($null -ne $d.Free -and $d.Free -is [long]) { $d.Free } else { 0 }
                $total = $used + $free
                $pct   = if ($total -gt 0) { [math]::Round(($used / $total) * 100) } else { 0 }
                $drives.Add([PSCustomObject]@{
                    Num   = $drives.Count + 1
                    Root  = $d.Root
                    Drive = $d.Root.Substring(0, 2)
                    Label = if ($d.Description) { $d.Description } else { 'Local Disk' }
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

        if ($sel.Count -eq 0) {
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
    _c 'Fast | Compare filenames | HIGH FALSE POSITIVE RISK' 'DarkGray'
    _c '  [2] Hash Only    ' 'Cyan' -nn
    _c '100%% accurate | Full SHA-256 scan | Slower on large drives' 'DarkGray'
    _c '  [3] Name + Hash  ' 'Cyan' -nn
    _c 'Same name AND same content | Strictest definition' 'DarkGray'
    _c '  [4] Smart [REC]  ' 'Green' -nn
    _c 'Size pre-filter + SHA-256 | Fastest + 100%% accurate' 'DarkGray'
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
#  FILE SCANNER
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
        # FIX: Never trim the root backslash. Passing 'C:' evaluates to current directory, not root.
        $queue.Enqueue($d.Root)
    }

    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()

        if (Test-ProtectedPath $dir) { $skipped++; continue }

        try {
            $dirInfo = [System.IO.DirectoryInfo]::new($dir)

            if ($dirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $skipped++; continue
            }

            try {
                foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
                    $queue.Enqueue($sub)
                }
            } catch {}

            foreach ($fPath in [System.IO.Directory]::GetFiles($dir)) {
                try {
                    $fi = [System.IO.FileInfo]::new($fPath)
                    if (Test-ProtectedFile $fi) { $skipped++ }
                    else { $files.Add($fi) }
                } catch { $errors++ }
            }

        } catch { $errors++ }

        if (($files.Count + $skipped) % 250 -eq 0) {
            Write-Host ("`r  [>] Scannable: {0,6}  Protected/Skipped: {1,6}  Queue: {2,5}  " -f
                $files.Count, $skipped, $queue.Count) -ForegroundColor White -NoNewline
        }
    }

    Write-Host ("`r  [+] Scan done: {0} files ready | {1} protected/skipped | {2} errors        " -f
        $files.Count, $skipped, $errors) -ForegroundColor Green
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
              Where-Object { $_.Count -gt 1 }
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
                  Where-Object { $_.Count -gt 1 -and [long]$_.Name -gt 0 }

    if (-not $sizeGroups) {
        _inf 'No size-matched groups found.'
        return @()
    }

    $totalToHash = 0
    foreach ($sg in $sizeGroups) { $totalToHash += $sg.Count }

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

            $key = if ($Mode -eq 'both') { "$($f.Name.ToLowerInvariant())|$hash" } else { $hash }

            if (-not $map.ContainsKey($key)) {
                $map[$key] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $map[$key].Add($f)
        }
    }

    Write-Host "`r  [+] Hashing complete.                                              " -ForegroundColor Green
    _c ''

    return @($map.GetEnumerator() |
        Where-Object { $_.Value.Count -gt 1 } |
        ForEach-Object { [PSCustomObject]@{ Files = @($_.Value); Method = $Mode } })
}

function Find-Dupes {
    param([System.Collections.Generic.List[System.IO.FileInfo]]$Files, [string]$Method)
    switch ($Method) {
        'name'  { return @(Find-ByName $Files) }
        'hash'  { return @(Find-ByHash $Files 'hash') }
        'both'  { return @(Find-ByHash $Files 'both') }
        'smart' { return @(Find-ByHash $Files 'hash') }
        default { return @() }
    }
}

# ======================================================================
#  SMART KEEP RECOMMENDATION ENGINE
# ======================================================================

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

        $depth = ($p -split '\\').Count
        $s -= ($depth * 3)

        $ageDays = ([datetime]::Now - $f.CreationTime).TotalDays
        $s += [math]::Min($ageDays, 730)

        [PSCustomObject]@{ F = $f; S = $s }
    } | Sort-Object S -Descending

    return $scored[0].F
}

# ======================================================================
#  RESULTS DISPLAY
# ======================================================================

function Show-Results {
    param([array]$Groups)

    if (-not $Groups -or $Groups.Count -eq 0) {
        Show-Section 'RESULTS'
        _ok 'No duplicate files found. Your selected drives are clean.'
        _c ''
        return $null
    }

    $totalWaste = [long]0
    foreach ($g in $Groups) {
        $totalWaste += $g.Files[0].Length * ($g.Files.Count - 1)
    }

    Show-Section 'DUPLICATE GROUPS FOUND'
    _c "  Groups found  : " 'White' -nn; _c "$($Groups.Count)" 'Yellow'
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
            $g.Files.Count, (_sz $g.Files[0].Length), (_sz ($g.Files[0].Length * $extras.Count))) 'DarkGray'
        _c ''

        _c '    [KEEP] ' 'Green' -nn; _c $keep.FullName 'White'
        _c '           ' -nn
        _c ("Modified: {0}  |  Created: {1}" -f
            $keep.LastWriteTime.ToString('yyyy-MM-dd HH:mm'),
            $keep.CreationTime.ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
        _c ''

        foreach ($f in $extras) {
            $idx = $allDupes.Count + 1
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

    _c "  Total removable files: " 'White' -nn; _c "$($allDupes.Count)" 'Red'
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
        _c "  [A]     = All $($Dupes.Count) duplicates (DupReaper recommended)" 'Green'
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

        if ($sel.Count -eq 0 -or -not $valid) {
            _err 'No valid items selected. Try again.'
            _c ''
            continue
        }

        _c ''
        _ok "$($sel.Count) file(s) queued for removal."
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
#  RECYCLE BIN
# ======================================================================

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
    } catch {}

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
        _err "WARNING: PERMANENT DELETE of $($Items.Count) file(s). CANNOT BE UNDONE."
    } else {
        _wrn "About to $($Action.ToUpper()) $($Items.Count) file(s)."
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
    $log.Add("DupReaper v$($Script:VER) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Action: $Action | Target: $($Items.Count) files")
    $log.Add('=' * 70)

    _c ''
    foreach ($item in $Items) {
        $path = $item.File.FullName

        if (Test-ProtectedPath $item.File.DirectoryName) {
            _err "BLOCKED [system path]: $path"
            $log.Add("BLOCKED|SYSTEM_PATH|$path")
            $bad++
            continue
        }

        if (-not (Test-Path $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            _wrn "SKIPPED [not found]: $path"
            $log.Add("SKIP|NOT_FOUND|$path")
            $skip++
            continue
        }

        if (-not (Test-Path $item.Keep.FullName -PathType Leaf -ErrorAction SilentlyContinue)) {
            _err "BLOCKED [keep copy missing]: $path"
            _err "          Keep was: $($item.Keep.FullName)"
            $log.Add("BLOCKED|KEEP_MISSING|$path|Keep=$($item.Keep.FullName)")
            $bad++
            continue
        }

        if ($path.ToLowerInvariant() -eq $item.Keep.FullName.ToLowerInvariant()) {
            _err "BLOCKED [same as keep]: $path"
            $log.Add("BLOCKED|SAME_AS_KEEP|$path")
            $bad++
            continue
        }

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
        # FIX: Broken multiline execution separated into safe variables
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        Show-Banner

        if (-not $isAdmin) {
            _wrn 'Not running as Administrator.'
            _wrn 'Some network/system-owned paths may be inaccessible.'
            _c ''
        } else {
            _ok 'Running with Administrator privileges.'
            _c ''
        }

        $drives = Get-DriveList
        if (-not $drives -or $drives.Count -eq 0) {
            _err 'No accessible drives detected. Exiting.'
            return
        }
        Show-DriveTable $drives

        $selDrives = Get-SelectedDrives $drives
        if (-not $selDrives -or $selDrives.Count -eq 0) {
            _wrn 'No drives selected. Exiting.'
            return
        }
        _ok "Drives selected: $(($selDrives | ForEach-Object { $_.Drive }) -join ', ')"

        $method = Get-ScanMethod

        $files = Get-SafeFiles $selDrives
        if (-not $files -or $files.Count -eq 0) {
            _wrn 'No scannable user files found in selected drives.'
            _pause
            return
        }
        _ok "$($files.Count) user files ready for duplicate analysis."

        _c ''
        _inf 'Analyzing for duplicates...'
        $groups = @(Find-Dupes $files $method)

        $dupeList = Show-Results $groups
        if (-not $dupeList -or $dupeList.Count -eq 0) {
            _pause
            return
        }

        $toRemove = @(Get-FileSelection $dupeList)
        if (-not $toRemove -or $toRemove.Count -eq 0) {
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
            if ([string]::IsNullOrEmpty($movePath)) {
                _wrn 'No destination provided. Cancelled.'
                _pause
                return
            }
        }

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
