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
    param([int]$DefaultIdx = -1)
    # Returns 0-3
    return (Read-Menu 'What type of pattern will you enter?' @(
        'Wildcard   -- match by shell glob      e.g.  *.log  temp*  report?.txt'
        'Extension  -- match by file extension  e.g.  .tmp   .bak   .log'
        'Exact      -- match full name exactly  e.g.  old_data.csv   cache'
        'Regex      -- match by regular expr    e.g.  ^log\d+\.txt$  .*backup.*'
    ) -DefaultIdx $DefaultIdx)
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

    $searchRoot = (Get-Location).Path

    while ($true) {

        # ----------------------------------------------------------------
        # 1. SEARCH ROOT
        # ----------------------------------------------------------------
        Write-Section 'SEARCH ROOT'
        Write-DIM 'Enter the folder to search in. Press Enter to keep the current location.'
        $searchRoot = Read-Input 'Search path' $searchRoot

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
        ) -DefaultIdx 1) -eq 1

        # ----------------------------------------------------------------
        # 3. TARGET KIND
        # ----------------------------------------------------------------
        Write-Section 'TARGET TYPE'
        $kindIdx    = Read-Menu 'What should be matched?' @(
            'Files only'
            'Folders only'
            'Both files and folders'
        ) -DefaultIdx 2
        $targetKind = @('Files','Folders','Both')[$kindIdx]

        # ----------------------------------------------------------------
        # 4. PATTERN TYPE  (always shown interactively)
        # ----------------------------------------------------------------
        Write-Section 'PATTERN TYPE'
        $patternType = Read-PatternType -DefaultIdx 0

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
            $pattern = Read-Input 'Enter pattern' '*SamLa*'

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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUgONscdOjqQyUrD9TRoyZ8oc0
# s46gghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
# AQsFADAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzMB4XDTI2MDcwNzA4MDE1
# N1oXDTI5MDcwNzA4MTE1N1owGzEZMBcGA1UEAwwQUkhTSE9VUkFWLUlULU9wczCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALFj11KDAqN3fhbDT9fvgrLF
# VemPYmcud3qA+9Sc4RojOjElODGXyaOlBSVmDGpmCkNRC+dnkGCLB8bYb3gsnHey
# Ud99DA8tvkTgb06+B1pigTZUmhyAwyPiu77+h224c8SsZFkmgQ/Dh2Sc2ynNocZe
# 773d6a/B4DRg7/K9xV8jFap6BP1fjaM3Do40GSL+OVnXl2ssvfFk4FyP5fc8Czz5
# MJ5IJKRFrnHv3kNcmyz5mnz0LoBQs/JtHpWg3BogIalJ2tyCiZgk0xIsz5j5UjhA
# /KepfnWGpCowJ/NJWnmOZcikFlDPggI27QNc/IbxZ035ht+Zgc7b1Cf68GmL/8UC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRJ+13W7/PcqVgZXZf87/JdXvGqxjANBgkqhkiG9w0BAQsFAAOCAQEA
# MDUJsw0AephOCByoLTFSm8hnB4I7s8ddA64vDTv4QF2TcXdrd/glByhEQexUEDpw
# lPCSbzHAmRM5X71QYNoB/CDlCoAO8BQnbegqkhAx8ubRyciwsLA4ZPp+/GFbgZaV
# khkOWpL6v6fmU3kSB5px+roqOuMjmqvbtCDlC4JH25WuDEgGJQhqpgdQSZdomWjH
# le/GnQKt4Y18ysVFvgE1lRO8x6gkJ5IJbZPJ0Q//2xCvtM0WpjXmQl1RHV/7tqDS
# fqprCQxuKiTPC64VfafzeS7IUNJMgQS73H6wuaKdeT85PIxreleNwNXfbr4O/FY3
# eqlSEZAqzKtZXfNFWPmHazCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE+jCC
# BPYCAQEwLzAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzAhAQvylGgaQVhE7g
# tCp7LUPgMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBSPuEECGhoaGgc5fOAj/Zz6k2GzHDANBgkq
# hkiG9w0BAQEFAASCAQBIM3BWckOX/s7iEIvGlm6LfZLYvd768Tt9++kRSi8ptAfe
# vTnIFqiuacvaSOAwgqJvO5q4o270t0cpJqdsk1hnbL5YiX9/+338uf7t5cUfpQyR
# HmYZfR4SEWJEWBCUzFLD6/h6cljd/J6q5n8mnkP3VAKUZ5jLj1snpw8FFggZcTMb
# MJMc19pg180GSPQD8Bp9Jab6hNRWRzjJkAsxi98Vmx5CmEyGNARPicwXcJGv+uvH
# AIy21M6C8XpFAtSJuvbTVwdJ0AQC1HLZF7Ki5y9UpIuSZNCiO/HBFpTA05r8iR47
# CRUuAT309JO+aGwoQf8/pWCEJPSubYncR3bYJccMoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDUwNFowLwYJKoZIhvcNAQkEMSIEIEL3XpQE51QO6UlX
# KPRb4YjtA1UoU3f5nWyN/JFFvRoXMA0GCSqGSIb3DQEBAQUABIICAFZudjdbzJok
# zr9GL/1JoK/gtIaF/OcXVTWjHcKeTg3Q6M3G3VFU1cPbCyi0f/vzYQKCVQ0nHZY+
# xsYzhQaTsgG8Y627c3hslA/cMRrbhUDb0i+2SYqzI2vDbq7pE8OQoxZvyXlCS3o6
# sjaW04CgNr0Kao3WR0ceeonwbS6Vb2IlbVTxyqAnTgou5rBe3UG9pDBZwCwGnM8i
# ELaIGQxw1TqsLRr0g/u25XDPd/hRlivFhsxhsrRaJ3ZofquS/nizbkuyleQZnHj/
# QgeV0w6R9msltlxpUE2m7a9O+RIxFAxp8+PI357uRdGlEUIX2LghV3jF40UICyx8
# 8IuLfyutMDPq4vuSSz9x6ZawRber/lWTOyKDKk8Hle8T7LNwr7AsCqn+OcfXP01x
# lCZZ899Z25BmSO65fuWe1l+CqUab4l8fxnMdLrDd6ZJptHp1+WOwOJYw6HS2pAQx
# 73BSK/BFizryg97N3ypzX67dwkWG4FWaBZYK5QNmgTKyNYt7S4g2asKCbccG6vZm
# cH6oUJSQDQ8qDRe/8JMfQ9taeyIvEhvYS8PH74kek26PFk0mXA6p6BtDPlGt02El
# jxyRuOBtEsLvDFfJETRhDt3nHVjQW0cJ0ZaICkOiGYrz9yL1dHmpsqjqRlNxxbD9
# skwgJtmqNytY+5i9jdtq4TZnAC2MVBc7
# SIG # End signature block
