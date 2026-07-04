#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex UI Module
    Banners, menus, status messages, spinners, help screens
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# SEMANTIC OUTPUT HELPERS
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
    Write-Host   "    Log    : $(Get-LogPath)"           -ForegroundColor DarkGray
    Write-Log -Level ERROR -Msg "$What | $Reason" -Err $Err
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASCII BANNER
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Header {
    <#
    .SYNOPSIS Renders the DriverDex branded header using box-drawing characters.
    #>
    param([string]$Version = '2.3.0')

    $inner = 74

    function _Pad { param([string]$s) $s.PadRight($inner).Substring(0, $inner) }

    $top   = '╔' + ('═' * $inner) + '╗'
    $bot   = '╚' + ('═' * $inner) + '╝'
    $blank = '║' + (' ' * $inner) + '║'

    Write-Host ""
    Write-Host "  $top"    -ForegroundColor DarkCyan
    Write-Host "  $blank"  -ForegroundColor DarkCyan

    $artRows = @(
        ' ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗',
        ' ██╔══██╗██╔══██╗██║██║   ██║██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝',
        ' ██║  ██║██████╔╝██║╚██╗ ██╔╝█████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝ ',
        ' ██║  ██║██╔══██╗██║ ╚████╔╝ ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗ ',
        ' ██████╔╝██║  ██║██║  ╚██╔╝  ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗',
        ' ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝'
    )
    foreach ($row in $artRows) {
        Write-Host "  ║$(_Pad $row)║" -ForegroundColor Cyan
    }

    Write-Host "  $blank" -ForegroundColor DarkCyan

    $sepLine = '  ' + ('─' * ($inner - 4))
    Write-Host "  ║$(_Pad $sepLine)║" -ForegroundColor DarkGray

    $v   = "  Automatic Driver Detector & Installer  v$Version"
    $tag = "  Hardware confidence, one script away."
    $url = "  https://github.com/rhshourav/driverdex"
    Write-Host "  ║$(_Pad $v)║"   -ForegroundColor White
    Write-Host "  ║$(_Pad $tag)║" -ForegroundColor DarkGray
    Write-Host "  ║$(_Pad $url)║" -ForegroundColor DarkGray
    Write-Host "  $blank"         -ForegroundColor DarkCyan
    Write-Host "  $bot"           -ForegroundColor DarkCyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# SEARCH ENGINE BANNER
# ═══════════════════════════════════════════════════════════════════════════════

function Write-SearchBanner {
    <#.SYNOPSIS Renders the DriverDex Search Engine branded header.#>
    $inner = 74
    function _SPad { param([string]$s) $s.PadRight($inner).Substring(0, $inner) }

    $top   = '╔' + ('═' * $inner) + '╗'
    $bot   = '╚' + ('═' * $inner) + '╝'
    $blank = '║' + (' ' * $inner) + '║'

    Write-Host ""
    Write-Host "  $top"   -ForegroundColor DarkCyan
    Write-Host "  $blank" -ForegroundColor DarkCyan

    $art = @(
        '  ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ██████╗ ███████╗██╗  ██╗',
        '  ██╔══██╗██╔══██╗██║██║   ██║██╔════╝██╔══██╗██╔══██╗██╔════╝╚██╗██╔╝',
        '  ██║  ██║██████╔╝██║╚██╗ ██╔╝█████╗  ██████╔╝██║  ██║█████╗   ╚███╔╝ ',
        '  ██║  ██║██╔══██╗██║ ╚████╔╝ ██╔══╝  ██╔══██╗██║  ██║██╔══╝   ██╔██╗ ',
        '  ██████╔╝██║  ██║██║  ╚██╔╝  ███████╗██║  ██║██████╔╝███████╗██╔╝ ██╗',
        '  ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝'
    )
    foreach ($row in $art) {
        Write-Host "  ║$(_SPad $row)║" -ForegroundColor Cyan
    }

    Write-Host "  $blank" -ForegroundColor DarkCyan
    $tagLine = "  ◈  DRIVER SEARCH ENGINE  ◈  Search · Download · Install"
    Write-Host "  ║$(_SPad $tagLine)║" -ForegroundColor Yellow
    $sub = "  Type a keyword, device name, HWID, or category to find drivers"
    Write-Host "  ║$(_SPad $sub)║"     -ForegroundColor DarkGray
    Write-Host "  $blank"              -ForegroundColor DarkCyan
    Write-Host "  $bot"               -ForegroundColor DarkCyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════════════════════════════════════════

function Show-MainMenu {
    <#
    .SYNOPSIS Shows the DriverDex mode selection menu.
    Returns 'auto', 'search', 'winupdate', or 'quit'.
    #>
    Write-Host "  ┌─────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │                         SELECT A MODE                                   │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [1]  Auto-Detect & Install                                            │" -ForegroundColor White
    Write-Host "  │        Scans your hardware, finds matching drivers,                     │" -ForegroundColor DarkGray
    Write-Host "  │        installs only error devices by default.                          │" -ForegroundColor DarkGray
    Write-Host "  │        Older driver updates shown as optional.                          │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [2]  Driver Search Engine                                             │" -ForegroundColor Yellow
    Write-Host "  │        Search by name, keyword, or HWID. Download or                   │" -ForegroundColor DarkGray
    Write-Host "  │        install any driver from the DriverDex database.                 │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [3]  Force Windows Update                                             │" -ForegroundColor Magenta
    Write-Host "  │        Triggers Windows Update, installs all pending patches,           │" -ForegroundColor DarkGray
    Write-Host "  │        and optional driver updates from Microsoft servers.              │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [P]  Offline Packager (Generate Offline Bundle)                       │" -ForegroundColor DarkYellow
    Write-Host "  │        Reads an inventory.json from an air-gapped PC, downloads          │" -ForegroundColor DarkGray
    Write-Host "  │        matching drivers, and builds a deployable offline bundle.        │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  │   [q]  Quit                                                             │" -ForegroundColor DarkGray
    Write-Host "  │                                                                         │" -ForegroundColor DarkCyan
    Write-Host "  └─────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""

    $choice = Read-Input -Prompt 'Select mode' -Default '1' `
        -Validator { param($v) $v -match '^[123pPqQ]$' } `
        -ErrMsg    'Enter 1 (Auto-Detect), 2 (Search Engine), 3 (Windows Update), P (Offline Packager), or q to quit.'

    if ($choice -match '^[Qq]') { return 'quit' }
    if ($choice -eq '2')        { return 'search' }
    if ($choice -eq '3')        { return 'winupdate' }
    if ($choice -match '^[Pp]') { return 'packager' }
    return 'auto'
}

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVER TABLE (Auto-Detect mode)
# ═══════════════════════════════════════════════════════════════════════════════

function Show-DriverTable {
    <#
    .SYNOPSIS Renders a formatted, numbered driver selection table with install-status awareness.
    .PARAMETER Drivers       Array of driver PSObjects
    .PARAMETER ProblemHWIDs  Array of HWIDs with ConfigManagerErrorCode > 0
    #>
    param([object[]]$Drivers, [string[]]$ProblemHWIDs)

    Write-Host ""
    Write-Divider
    Write-Host "  Found $($Drivers.Count) matching driver package(s) for your hardware:" -ForegroundColor Cyan
    Write-Host "  ⚠  Default: installs PROBLEM devices only (error code > 0)  ·  Optional updates listed separately" -ForegroundColor DarkYellow
    Write-Divider
    Write-Host ""

    $rowCells = [System.Collections.Generic.List[object]]::new()
    $rowColors = [System.Collections.Generic.List[string]]::new()

    $idx = 0
    foreach ($d in $Drivers) {
        $idx++
        $star = if ($d.IsRecommended) { '★' } else { ' ' }
        $cls  = Get-DriverClassification -Driver $d -ProblemHWIDs $ProblemHWIDs

        $dName = if ($d.DisplayName) { $d.DisplayName } else { '—' }
        $dProv = if ($d.Provider)    { $d.Provider }    else { '—' }
        $inst  = if ($d.InstalledVersion) { $d.InstalledVersion } else { '—' }

        $rowCells.Add(@($idx, "$star", $dName, $dProv, $d.Category, $d.Version, $inst, $cls.Label))
        $rowColors.Add($cls.Color)
    }

    Draw-Table -Headers @('#', '*', 'Name', 'Provider', 'Category', 'DB Ver', 'Installed', 'Status') `
               -Rows $rowCells `
               -Colors $rowColors

    Write-Host "  ★ = best arch match    PROBLEM = error/missing (default install)    UPDATE = optional    INSTALLED/NEWER = already fine" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVER MENU (Auto-Detect selection)
# ═══════════════════════════════════════════════════════════════════════════════

function Show-DriverMenu {
    <#
    .SYNOPSIS Renders driver table and returns the user-selected subset.
    .PARAMETER Drivers       All available driver objects
    .PARAMETER ProblemHWIDs  HWIDs flagged as problem devices
    #>
    param([object[]]$Drivers, [string[]]$ProblemHWIDs)

    Show-DriverTable -Drivers $Drivers -ProblemHWIDs $ProblemHWIDs

    $classified = @($Drivers | ForEach-Object {
        [pscustomobject]@{
            Driver = $_
            Class  = (Get-DriverClassification -Driver $_ -ProblemHWIDs $ProblemHWIDs)
        }
    })
    $problemSet = @($Drivers | Where-Object { $ProblemHWIDs -contains $_.MatchedHWID })
    $updateSet  = @($classified | Where-Object {
        $_.Class.StatusCode -eq 'UPDATE' -and -not ($ProblemHWIDs -contains $_.Driver.MatchedHWID)
    } | ForEach-Object { $_.Driver })

    if (@($problemSet).Count -gt 0) {
        Write-OK "$(@($problemSet).Count) PROBLEM device(s) with missing/broken drivers — selected by default."
    } else {
        Write-OK "No problem devices detected. All hardware has functional drivers."
    }
    if (@($updateSet).Count -gt 0) {
        Write-Host ""
        Write-Host "  ℹ  $(@($updateSet).Count) optional driver update(s) available (older versions — not selected by default):" -ForegroundColor DarkYellow
        foreach ($u in $updateSet) {
            Write-Host "       · $($u.DisplayName)  installed v$($u.InstalledVersion) → DB v$($u.Version)" -ForegroundColor DarkGray
        }
        Write-Host "     Use 'UPDATES' or enter numbers to install these." -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Info "Selection: PROBLEMS (default, errors only) · UPDATES (optional) · ALL · NONE · numbers · q to quit"
    Write-Host ""

    $raw = Read-Input -Prompt 'Select drivers' -Default 'PROBLEMS' `
        -Validator { param($v) $v -match '^(PROBLEMS|UPDATES|ALL|NONE|q|[0-9, ]+)$' } `
        -ErrMsg    'Enter PROBLEMS, UPDATES, ALL, NONE, a list of numbers, or q to quit.'

    if ($raw -eq 'q')    { return @() }
    if ($raw -eq 'NONE') { return @() }

    if ($raw -eq 'PROBLEMS') {
        $sel = $problemSet
        if (@($sel).Count -eq 0) {
            Write-Info "No problem devices found. Use UPDATES or ALL to install/update drivers."
            return @()
        }
    } elseif ($raw -eq 'UPDATES') {
        $sel = $updateSet
        if (-not $sel -or @($sel).Count -eq 0) {
            Write-Warn "No optional updates available in the current list."
            return @()
        }
    } elseif ($raw -eq 'ALL') {
        $sel = $Drivers
    } else {
        $indices = $raw -split '[,\s]+' | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -ge 1 -and $n -le @($Drivers).Count) { $n }
        } | Where-Object { $_ } | Sort-Object -Unique
        $sel = @($indices | ForEach-Object { $Drivers[$_ - 1] })
    }

    if (-not $sel -or @($sel).Count -eq 0) { return @() }

    $names = ($sel | ForEach-Object { $_.DisplayName }) -join ', '
    Write-OK "Selected: $names"

    $supersededPicked = @($sel | Where-Object { $_.SupersededBy })
    foreach ($s in $supersededPicked) {
        Write-Warn "'$($s.DisplayName)' is superseded by $($s.SupersededBy) — consider deselecting."
    }

    $alreadyCurrent = @($sel | Where-Object { $_.InstallStatus -eq 'CURRENT' })
    foreach ($c in $alreadyCurrent) {
        Write-Info "'$($c.DisplayName)' is already at v$($c.Version) — will be force-reinstalled (repair)."
    }
    $downgrades = @($sel | Where-Object { $_.InstallStatus -eq 'NEWER' })
    foreach ($dn in $downgrades) {
        Write-Warn "'$($dn.DisplayName)': installed v$($dn.InstalledVersion) is NEWER than the DB's v$($dn.Version) — this would be a downgrade."
    }

    Write-Host ""
    $confirm = Read-Input -Prompt "Proceed with $(@($sel).Count) driver(s)?" -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
    if ($confirm -match '^[Nn]') { return @() }

    return @($sel)
}

# ═══════════════════════════════════════════════════════════════════════════════
# PER-DRIVER WORK PANEL
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
    $dash  = '─' * ([int][Math]::Max(0, $inner - $title.Length - 1))

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
# SEARCH HELP
# ═══════════════════════════════════════════════════════════════════════════════

function Show-SearchHelp {
    <#.SYNOPSIS Prints search engine help and usage examples.#>
    Write-Host ""
    Write-Host "  ┌─ SEARCH ENGINE HELP ──────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  SEARCH SYNTAX:                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │   intel                 Fuzzy keyword search                              │" -ForegroundColor White
    Write-Host "  │   intel arch:x64        Search + filter by architecture                    │" -ForegroundColor White
    Write-Host "  │   wifi provider:intel   Search + filter by provider                        │" -ForegroundColor White
    Write-Host "  │   usb category:system   Search + filter by category                        │" -ForegroundColor White
    Write-Host "  │   PCI\VEN_8086&DEV_1234 Direct hardware ID lookup                         │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  FILTERS:                                                                  │" -ForegroundColor DarkCyan
    Write-Host "  │   arch:x64 / arch:x86 / arch:any        Architecture filter              │" -ForegroundColor White
    Write-Host "  │   provider:<name>                        Provider filter                  │" -ForegroundColor White
    Write-Host "  │   category:<type>                        Category filter                  │" -ForegroundColor White
    Write-Host "  │   version:<ver>                          Version filter                   │" -ForegroundColor White
    Write-Host "  │   hardwareid:<prefix>                    HWID prefix filter               │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  SORTING:                                                                  │" -ForegroundColor DarkCyan
    Write-Host "  │   sort:name / sort:provider / sort:version / sort:date / sort:score       │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  │  NAVIGATION:                                                               │" -ForegroundColor DarkCyan
    Write-Host "  │   n / p                   Next / Previous page                            │" -ForegroundColor White
    Write-Host "  │   first / last            First / Last page                               │" -ForegroundColor White
    Write-Host "  │   g<N> / page <N>         Go to page N                                    │" -ForegroundColor White
    Write-Host "  │   d<N>                    Download only (e.g. d3)                         │" -ForegroundColor White
    Write-Host "  │   i<N>                    Download + Install (e.g. i3)                    │" -ForegroundColor White
    Write-Host "  │   det<N>                  Show full detail for a result                   │" -ForegroundColor White
    Write-Host "  │   s <query> / new <query> New search                                      │" -ForegroundColor White
    Write-Host "  │   clear                   Clear filters                                   │" -ForegroundColor White
    Write-Host "  │   back / q                Return to main menu                             │" -ForegroundColor White
    Write-Host "  │                                                                            │" -ForegroundColor DarkCyan
    Write-Host "  └────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# OUTPUT FOLDER PROMPT
# ═══════════════════════════════════════════════════════════════════════════════

function Get-OutputFolder {
    <#
    .SYNOPSIS Prompts for and validates the driver output/staging folder.
    #>
    $defaultOut = Join-Path $env:USERPROFILE 'Downloads\DriverDex'
    $path = Read-Input -Prompt 'Save drivers to' -Default $defaultOut `
        -Validator { param($v) $v.Length -gt 0 } -ErrMsg 'Path cannot be empty.'

    try {
        New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop | Out-Null
        $testFile = Join-Path $path ".driverdex_write_test"
        [System.IO.File]::WriteAllText($testFile, 'ok')
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Err -What "Cannot write to output folder." `
                  -Reason $_.Exception.Message `
                  -Fix    "Choose a different folder or check permissions."
        throw
    }

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
    } catch { <# non-fatal #> }

    Write-OK "Output folder: $path"
    return $path
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Write-Step'
    'Write-OK'
    'Write-Warn'
    'Write-Info'
    'Write-Sub'
    'Write-Accent'
    'Write-Divider'
    'Write-Err'
    'Write-Header'
    'Write-SearchBanner'
    'Show-MainMenu'
    'Show-DriverTable'
    'Show-DriverMenu'
    'Show-DriverPanel'
    'Show-SearchHelp'
    'Get-OutputFolder'
)