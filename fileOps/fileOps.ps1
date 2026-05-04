#Requires -Version 3.0
<#
.SYNOPSIS
    FileOps - Interactive File & Folder Delete / Move Utility
.DESCRIPTION
    Pattern-based file and folder operations.
    Preview first, then choose: Delete (default) or Move to a user-specified path.
    Supports Wildcard, Extension, Exact, and Regex pattern types.
    Auto-creates destination folder if it does not exist.

    Author  : rhshourav
    Repo    : https://github.com/rhshourav/Windows-Scripts
    Version : 1.1.0

.NOTES
    Compatible with PowerShell 3.0+ on Windows 10 and later.
    Run via:
        iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/FileOps.ps1')
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# THEME  (Dark BG / White FG / Green-Red-Yellow accents)
# ---------------------------------------------------------------------------
$C = @{
    BG     = 'Black'
    FG     = 'White'
    Green  = 'Green'
    Red    = 'Red'
    Yellow = 'Yellow'
    Cyan   = 'Cyan'
    Gray   = 'DarkGray'
}

# ---------------------------------------------------------------------------
# OUTPUT PRIMITIVES
# ---------------------------------------------------------------------------
function Write-Col {
    param(
        [string]$Text,
        [string]$FG       = $C.FG,
        [string]$BG       = $C.BG,
        [switch]$NoNewline
    )
    $p = @{ ForegroundColor = $FG; BackgroundColor = $BG }
    if ($NoNewline) { Write-Host $Text @p -NoNewline } else { Write-Host $Text @p }
}

function Write-Blank  { Write-Col '' }
function Write-OK     { param([string]$M) Write-Col "  [+] $M" -FG $C.Green  }
function Write-WARN   { param([string]$M) Write-Col "  [!] $M" -FG $C.Yellow }
function Write-ERR    { param([string]$M) Write-Col "  [X] $M" -FG $C.Red    }
function Write-INFO   { param([string]$M) Write-Col "  [-] $M" -FG $C.FG     }
function Write-DIM    { param([string]$M) Write-Col "      $M" -FG $C.Gray   }

function Write-Ruler {
    param([string]$Char = '-', [int]$Width = 72)
    Write-Col ($Char * $Width) -FG $C.Gray
}

function Write-Section {
    param([string]$Title)
    Write-Blank
    Write-Col "  [ $Title ]" -FG $C.Cyan
    Write-Ruler
}

# ---------------------------------------------------------------------------
# HEADER  (ASCII-only box)
# ---------------------------------------------------------------------------
function Write-Header {
    [Console]::Clear()
    [Console]::BackgroundColor = $C.BG
    [Console]::ForegroundColor = $C.FG
    Write-Blank
    Write-Col '  +------------------------------------------------------------------------+' -FG $C.Cyan
    Write-Col '  |                                                                        |' -FG $C.Cyan
    Write-Col '  |   ______  _  _      ____   ____   ____  ____                          |' -FG $C.Green
    Write-Col '  |   |  ___|| || |    | ___| / __ \ |  _ \/ ___|                         |' -FG $C.Green
    Write-Col '  |   | |_   | || |    | |_  | |  | || |_) \___ \                         |' -FG $C.Green
    Write-Col '  |   |  _|  | || |___ |  _| | |__| ||  __/ ___) |                        |' -FG $C.Green
    Write-Col '  |   |_|    |_||_____||_|    \____/ |_|   |____/                         |' -FG $C.Green
    Write-Col '  |                                                                        |' -FG $C.Cyan
    Write-Col '  |   Interactive Delete / Move Utility                   v1.1.0           |' -FG $C.Yellow
    Write-Col '  |   Author : rhshourav          github.com/rhshourav/Windows-Scripts     |' -FG $C.Gray
    Write-Col '  |                                                                        |' -FG $C.Cyan
    Write-Col '  |   Flow   : Pattern -> Scan -> Preview -> Action (Delete* / Move)       |' -FG $C.Gray
    Write-Col '  |   * Delete is the default action. Press Enter to accept.               |' -FG $C.Gray
    Write-Col '  |                                                                        |' -FG $C.Cyan
    Write-Col '  +------------------------------------------------------------------------+' -FG $C.Cyan
    Write-Blank
}

# ---------------------------------------------------------------------------
# PROGRESS BAR
# ---------------------------------------------------------------------------
function Show-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label = '',
        [int]$BarWidth = 46
    )
    if ($Total -le 0) { return }

    $pct    = [int](($Current / $Total) * 100)
    $filled = [int](($Current / $Total) * $BarWidth)
    $empty  = $BarWidth - $filled

    # Build bar string: filled portion ends with '>' head
    $barStr = ''
    if ($filled -gt 1)  { $barStr += '#' * ($filled - 1) }
    if ($filled -ge 1)  { $barStr += '>' }
    if ($empty  -gt 0)  { $barStr += '.' * $empty }

    $labelTrim = if ($Label.Length -gt 28) { $Label.Substring(0,25) + '...' } else { $Label.PadRight(28) }
    $counter   = "$Current/$Total"

    # Carriage-return overwrite
    Write-Host "`r" -NoNewline
    Write-Host '  [' -NoNewline -ForegroundColor $C.Gray   -BackgroundColor $C.BG
    # Colour filled vs empty differently
    if ($filled -gt 0) {
        Write-Host ($barStr.Substring(0, $filled)) -NoNewline -ForegroundColor $C.Green  -BackgroundColor $C.BG
    }
    if ($empty -gt 0) {
        Write-Host ($barStr.Substring($filled))    -NoNewline -ForegroundColor $C.Gray   -BackgroundColor $C.BG
    }
    Write-Host '] ' -NoNewline -ForegroundColor $C.Gray   -BackgroundColor $C.BG
    Write-Host ('{0,3}%' -f $pct) -NoNewline -ForegroundColor $C.Yellow -BackgroundColor $C.BG
    Write-Host "  ($counter)" -NoNewline -ForegroundColor $C.Gray   -BackgroundColor $C.BG
    Write-Host "  $labelTrim"  -NoNewline -ForegroundColor $C.Gray   -BackgroundColor $C.BG
}

function Complete-Progress {
    param([int]$Total, [int]$BarWidth = 46)
    $barStr = '#' * $BarWidth
    Write-Host "`r" -NoNewline
    Write-Host '  [' -NoNewline -ForegroundColor $C.Gray  -BackgroundColor $C.BG
    Write-Host $barStr -NoNewline -ForegroundColor $C.Green -BackgroundColor $C.BG
    Write-Host '] ' -NoNewline -ForegroundColor $C.Gray  -BackgroundColor $C.BG
    Write-Host '100%' -NoNewline -ForegroundColor $C.Green -BackgroundColor $C.BG
    Write-Host ("  ($Total/$Total) Done".PadRight(40)) -ForegroundColor $C.Green -BackgroundColor $C.BG
}

# ---------------------------------------------------------------------------
# INPUT HELPERS
# ---------------------------------------------------------------------------
function Read-Input {
    param([string]$Prompt, [string]$Default = '')
    Write-Col "  > $Prompt" -FG $C.Yellow -NoNewline
    if ($Default -ne '') { Write-Col " [$Default]" -FG $C.Gray -NoNewline }
    Write-Col ': ' -FG $C.FG -NoNewline
    $raw = Read-Host
    if ([string]::IsNullOrWhiteSpace($raw) -and $Default -ne '') { return $Default }
    return $raw.Trim()
}

function Read-Menu {
    param([string]$Prompt, [string[]]$Options, [int]$DefaultIdx = -1)
    Write-Blank
    Write-Col "  $Prompt" -FG $C.Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i -eq $DefaultIdx) { ' <-- default' } else { '' }
        Write-Col ("  [{0}] {1}{2}" -f ($i + 1), $Options[$i], $marker) -FG $C.FG
    }
    $defStr = if ($DefaultIdx -ge 0) { ($DefaultIdx + 1).ToString() } else { '' }
    while ($true) {
        $raw = Read-Input 'Choice' $defStr
        if ($raw -match '^\d+$') {
            $n = [int]$raw
            if ($n -ge 1 -and $n -le $Options.Count) { return ($n - 1) }
        }
        Write-ERR "Enter a number between 1 and $($Options.Count)."
    }
}

function Read-YN {
    param([string]$Prompt, [bool]$DefaultYes = $false)
    $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $r = Read-Input "$Prompt ($hint)"
        if ($r -eq '' -and $DefaultYes) { return $true  }
        if ($r -eq '' -and -not $DefaultYes) { return $false }
        if ($r -match '^[Yy]') { return $true  }
        if ($r -match '^[Nn]') { return $false }
        Write-ERR 'Please enter y or n.'
    }
}

# ---------------------------------------------------------------------------
# PATTERN TYPE SELECTION  (interactive, shown to user every run)
# ---------------------------------------------------------------------------
function Read-PatternType {
    # Returns 0-3
    return (Read-Menu 'What type of pattern will you enter?' @(
        'Wildcard   -- match by shell glob      e.g.  *.log  temp*  report?.txt'
        'Extension  -- match by file extension  e.g.  .tmp   .bak   .log'
        'Exact      -- match full name exactly  e.g.  old_data.csv   cache'
        'Regex      -- match by regular expr    e.g.  ^log\d+\.txt$  .*backup.*'
    ))
}

# ---------------------------------------------------------------------------
# PATTERN MATCHING
# ---------------------------------------------------------------------------
function Test-ItemMatch {
    param(
        [System.IO.FileSystemInfo]$Item,
        [int]$PatternType,
        [string]$Pattern
    )
    $name = $Item.Name
    switch ($PatternType) {
        0 { return ($name -like $Pattern)           }   # Wildcard
        1 { return ($name -like "*$Pattern")        }   # Extension
        2 { return ($name -eq   $Pattern)           }   # Exact
        3 { return ([bool]($name -match $Pattern))  }   # Regex
    }
    return $false
}

# ---------------------------------------------------------------------------
# DISCOVERY
# ---------------------------------------------------------------------------
function Find-Matches {
    param(
        [string]$SearchRoot,
        [int]$PatternType,
        [string]$Pattern,
        [string]$TargetKind,   # Files | Folders | Both
        [bool]$Recurse
    )

    $gci = @{ Path = $SearchRoot; ErrorAction = 'SilentlyContinue' }
    if ($Recurse) { $gci['Recurse'] = $true }

    $matched = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    foreach ($item in (Get-ChildItem @gci)) {
        $isDir = $item.PSIsContainer
        $ok    = switch ($TargetKind) {
            'Files'   { -not $isDir }
            'Folders' { $isDir      }
            'Both'    { $true       }
        }
        if ($ok -and (Test-ItemMatch -Item $item -PatternType $PatternType -Pattern $Pattern)) {
            $matched.Add($item)
        }
    }
    return $matched
}

# ---------------------------------------------------------------------------
# PREVIEW TABLE
# ---------------------------------------------------------------------------
function Show-Preview {
    param([System.Collections.Generic.List[System.IO.FileSystemInfo]]$Items)

    Write-Section 'PREVIEW'

    if ($Items.Count -eq 0) {
        Write-WARN 'No items matched the pattern.'
        return
    }

    Write-Col ('  {0,-4}  {1,-6}  {2,7}  {3}' -f '#','TYPE','SIZE','PATH') -FG $C.Gray
    Write-Ruler

    $cap = [Math]::Min($Items.Count, 200)
    for ($i = 0; $i -lt $cap; $i++) {
        $item  = $Items[$i]
        $kind  = if ($item.PSIsContainer) { '[DIR] ' } else { '[FILE]' }
        $size  = if ($item.PSIsContainer) {
            '    --- '
        } else {
            $b = $item.Length
            if     ($b -ge 1GB) { '{0,6:N1} G' -f ($b / 1GB) }
            elseif ($b -ge 1MB) { '{0,6:N1} M' -f ($b / 1MB) }
            elseif ($b -ge 1KB) { '{0,6:N1} K' -f ($b / 1KB) }
            else                { '{0,6} B'    -f $b          }
        }
        $fg = if ($item.PSIsContainer) { $C.Yellow } else { $C.FG }
        Write-Col ('  {0,-4}  {1}  {2}  {3}' -f ($i+1), $kind, $size, $item.FullName) -FG $fg
    }

    if ($Items.Count -gt 200) {
        Write-Blank
        Write-WARN "Display capped at 200.  $($Items.Count - 200) more item(s) not shown."
    }

    Write-Blank
    Write-Ruler
    Write-Col "  Total matched : $($Items.Count) item(s)" -FG $C.Cyan
}

# ---------------------------------------------------------------------------
# OPERATION  -  DELETE
# ---------------------------------------------------------------------------
function Invoke-Delete {
    param([System.Collections.Generic.List[System.IO.FileSystemInfo]]$Items)

    Write-Section 'DELETING'
    $ok = 0; $fail = 0; $errors = [System.Collections.Generic.List[string]]::new()
    $total = $Items.Count

    for ($i = 0; $i -lt $total; $i++) {
        $item = $Items[$i]
        Show-Progress -Current ($i + 1) -Total $total -Label $item.Name
        try {
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            }
            $ok++
        } catch {
            $fail++
            $errors.Add("$($item.FullName)  ->  $_")
        }
    }

    Complete-Progress -Total $total
    Write-Blank
    Write-OK "Deleted  : $ok item(s)"
    if ($fail -gt 0) {
        Write-ERR "Failed   : $fail item(s)"
        foreach ($e in $errors) { Write-DIM $e }
    }
}

# ---------------------------------------------------------------------------
# OPERATION  -  MOVE
# ---------------------------------------------------------------------------
function Invoke-Move {
    param(
        [System.Collections.Generic.List[System.IO.FileSystemInfo]]$Items,
        [string]$Destination
    )

    # Auto-create destination if missing
    if (-not (Test-Path -LiteralPath $Destination)) {
        Write-WARN "Destination does not exist. Creating: $Destination"
        try {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Write-OK "Created: $Destination"
        } catch {
            Write-ERR "Could not create destination folder: $_"
            return
        }
    }

    Write-Section 'MOVING'
    $ok = 0; $fail = 0; $errors = [System.Collections.Generic.List[string]]::new()
    $total = $Items.Count

    for ($i = 0; $i -lt $total; $i++) {
        $item = $Items[$i]
        Show-Progress -Current ($i + 1) -Total $total -Label $item.Name

        # Resolve destination path, handle collisions with timestamp suffix
        $destPath = Join-Path $Destination $item.Name
        if (Test-Path -LiteralPath $destPath) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $base  = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
            $ext   = [System.IO.Path]::GetExtension($item.Name)
            $destPath = Join-Path $Destination ($base + "_$stamp" + $ext)
        }

        try {
            Move-Item -LiteralPath $item.FullName -Destination $destPath -Force -ErrorAction Stop
            $ok++
        } catch {
            $fail++
            $errors.Add("$($item.FullName)  ->  $_")
        }
    }

    Complete-Progress -Total $total
    Write-Blank
    Write-OK "Moved    : $ok item(s)  -->  $Destination"
    if ($fail -gt 0) {
        Write-ERR "Failed   : $fail item(s)"
        foreach ($e in $errors) { Write-DIM $e }
    }
}

# ---------------------------------------------------------------------------
# ASK FOR DESTINATION PATH  (Move flow)
# ---------------------------------------------------------------------------
function Read-Destination {
    Write-Section 'DESTINATION'
    Write-DIM 'Enter the folder path to move items into.'
    Write-DIM 'If the folder does not exist it will be created automatically.'
    Write-Blank
    while ($true) {
        $dest = Read-Input 'Destination path'
        if ([string]::IsNullOrWhiteSpace($dest)) {
            Write-ERR 'Destination cannot be empty.'
            continue
        }
        # Warn if it looks like a file path
        if ($dest -match '\.\w{1,6}$') {
            Write-WARN "That looks like a file name, not a folder. Double-check your path."
        }
        return $dest
    }
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------
function Start-FileOps {

    Write-Header

    while ($true) {

        # ----------------------------------------------------------------
        # 1. SEARCH ROOT
        # ----------------------------------------------------------------
        Write-Section 'SEARCH ROOT'
        Write-DIM 'Enter the folder to search in. Press Enter to use the current directory.'
        $searchRoot = Read-Input 'Search path' ((Get-Location).Path)

        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
            Write-ERR "Not found or not a folder: $searchRoot"
            Start-Sleep -Seconds 2
            Write-Header
            continue
        }

        # ----------------------------------------------------------------
        # 2. RECURSION
        # ----------------------------------------------------------------
        Write-Section 'SEARCH DEPTH'
        $recurse = (Read-Menu 'How deep should the search go?' @(
            'Current folder only  (non-recursive)'
            'All subdirectories   (recursive)'
        )) -eq 1

        # ----------------------------------------------------------------
        # 3. TARGET KIND
        # ----------------------------------------------------------------
        Write-Section 'TARGET TYPE'
        $kindIdx    = Read-Menu 'What should be matched?' @(
            'Files only'
            'Folders only'
            'Both files and folders'
        )
        $targetKind = @('Files','Folders','Both')[$kindIdx]

        # ----------------------------------------------------------------
        # 4. PATTERN TYPE  (always shown interactively)
        # ----------------------------------------------------------------
        Write-Section 'PATTERN TYPE'
        $patternType = Read-PatternType

        # ----------------------------------------------------------------
        # 5. PATTERN INPUT  (validated per type)
        # ----------------------------------------------------------------
        Write-Section 'PATTERN'
        $examples = @(
            '*.log        temp*        report?.txt'
            '.tmp         .bak         .log'
            'old_data.csv    cache     Thumbs.db'
            '^log\d+\.txt$   .*backup.*   ^~'
        )
        Write-DIM "Examples for this type:"
        Write-DIM "  $($examples[$patternType])"
        Write-Blank

        $pattern = ''
        while ($true) {
            $pattern = Read-Input 'Enter pattern'

            if ([string]::IsNullOrWhiteSpace($pattern)) {
                Write-ERR 'Pattern cannot be empty.'
                continue
            }
            if ($patternType -eq 1) {            # Extension
                if (-not $pattern.StartsWith('.')) {
                    Write-ERR 'Extension pattern must start with a dot  (e.g. .log)'
                    continue
                }
                if ($pattern.Length -lt 2) {
                    Write-ERR 'Extension too short.'
                    continue
                }
            }
            if ($patternType -eq 3) {            # Regex
                try { $null = [regex]$pattern }
                catch {
                    Write-ERR "Invalid regular expression: $_"
                    continue
                }
            }
            break
        }

        # ----------------------------------------------------------------
        # 6. SCAN
        # ----------------------------------------------------------------
        Write-Section 'SCANNING'
        Write-INFO "Root      : $searchRoot"
        Write-INFO "Recursive : $(if ($recurse) { 'Yes' } else { 'No' })"
        Write-INFO "Target    : $targetKind"
        Write-INFO "Type      : $(@('Wildcard','Extension','Exact','Regex')[$patternType])"
        Write-INFO "Pattern   : $pattern"
        Write-Blank
        Write-Col '  Searching ...' -FG $C.Gray

        $matched = $null
        try {
            $matched = Find-Matches `
                -SearchRoot  $searchRoot `
                -PatternType $patternType `
                -Pattern     $pattern `
                -TargetKind  $targetKind `
                -Recurse     $recurse
        } catch {
            Write-ERR "Scan error: $_"
            if (-not (Read-YN 'Try a new search?')) { break }
            Write-Header
            continue
        }

        # ----------------------------------------------------------------
        # 7. PREVIEW  (always shown before any action)
        # ----------------------------------------------------------------
        Show-Preview -Items $matched

        if ($matched.Count -eq 0) {
            Write-Blank
            if (-not (Read-YN 'Run a new search?' $true)) { break }
            Write-Header
            continue
        }

        # ----------------------------------------------------------------
        # 8. CHOOSE ACTION  (Delete is default)
        # ----------------------------------------------------------------
        Write-Section 'ACTION'
        Write-WARN "The following action will affect $($matched.Count) item(s)."
        Write-Blank

        $actionIdx = Read-Menu 'Choose an action for the matched items:' @(
            'DELETE  -- permanently remove all matched items'
            'MOVE    -- relocate all matched items to another folder'
            'Cancel  -- go back and run a new search'
        ) -DefaultIdx 0   # Delete is default (index 0)

        if ($actionIdx -eq 2) {
            Write-INFO 'Cancelled. Starting a new search.'
            Start-Sleep -Milliseconds 800
            Write-Header
            continue
        }

        # ----------------------------------------------------------------
        # 9. DESTINATION  (Move only)
        # ----------------------------------------------------------------
        $destination = ''
        if ($actionIdx -eq 1) {
            $destination = Read-Destination
        }

        # ----------------------------------------------------------------
        # 10. FINAL CONFIRMATION
        # ----------------------------------------------------------------
        Write-Blank
        Write-Ruler '='
        if ($actionIdx -eq 0) {
            Write-WARN "About to DELETE $($matched.Count) item(s). This CANNOT be undone."
        } else {
            Write-WARN "About to MOVE $($matched.Count) item(s) to: $destination"
        }
        Write-Ruler '='
        Write-Blank

        if (-not (Read-YN 'Confirm and proceed?')) {
            Write-INFO 'Cancelled. No files were changed.'
            Start-Sleep -Milliseconds 800
            Write-Header
            continue
        }

        # ----------------------------------------------------------------
        # 11. EXECUTE
        # ----------------------------------------------------------------
        if ($actionIdx -eq 0) {
            Invoke-Delete -Items $matched
        } else {
            Invoke-Move -Items $matched -Destination $destination
        }

        # ----------------------------------------------------------------
        # 12. RESULT FOOTER
        # ----------------------------------------------------------------
        Write-Blank
        Write-Ruler '='
        Write-OK 'Operation complete.'
        Write-Ruler '='
        Write-Blank

        if (-not (Read-YN 'Run another operation?' $false)) { break }
        Write-Header
    }

    Write-Blank
    Write-Ruler '='
    Write-Col '  Session ended. Goodbye.' -FG $C.Cyan
    Write-Ruler '='
    Write-Blank
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------
try {
    Start-FileOps
} catch {
    Write-Host ''
    Write-Host "  [FATAL ERROR]  $_" -ForegroundColor Red -BackgroundColor Black
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray -BackgroundColor Black
    Write-Host ''
    exit 1
}
