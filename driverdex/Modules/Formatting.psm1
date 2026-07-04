#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Formatting Module
    Unicode box-drawing tables, dynamic column widths, truncation, ANSI-aware rendering
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# COLUMN SIZING HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function Get-SafeString {
    <#
    .SYNOPSIS Safely converts any value to a display string, handling nulls and arrays.
    #>
    param(
        $Value,
        [string]$Fallback = '—'
    )
    if ($null -eq $Value) { return $Fallback }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $joined = ($Value | Sort-Object -Unique) -join ', '
        if ([string]::IsNullOrWhiteSpace($joined)) { return $Fallback }
        return $joined
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $Fallback }
    return $s.Trim()
}

function Get-DisplayWidth {
    <#
    .SYNOPSIS Returns the display width of a string, accounting for CJK wide characters.
    .DESCRIPTION
        CJK (Chinese/Japanese/Korean) characters and certain Unicode symbols take
        2 columns in a monospace terminal. This function counts them correctly.
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $width = 0
    foreach ($char in $Text.ToCharArray()) {
        $cp = [int]$char
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or
            ($cp -ge 0x2E80 -and $cp -le 0x303E) -or
            ($cp -ge 0x3040 -and $cp -le 0x33BF) -or
            ($cp -ge 0x3400 -and $cp -le 0x4DBF) -or
            ($cp -ge 0x4E00 -and $cp -le 0x9FFF) -or
            ($cp -ge 0xA000 -and $cp -le 0xA4CF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7AF) -or
            ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE6F) -or
            ($cp -ge 0xFF01 -and $cp -le 0xFF60) -or
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Truncate-Text {
    <#
    .SYNOPSIS Truncates text to a maximum display width, appending ellipsis if truncated.
    #>
    param(
        [string]$Text,
        [int]$MaxWidth
    )
    if ($null -eq $Text) { $Text = '' }
    if ($MaxWidth -le 0) { return '' }
    if ((Get-DisplayWidth $Text) -le $MaxWidth) { return $Text }
    if ($MaxWidth -le 1) { return $Text.Substring(0, [Math]::Min(1, $Text.Length)) }
    $ellipsis = '...'
    $target = $MaxWidth - 3
    $sb = [System.Text.StringBuilder]::new()
    $w = 0
    foreach ($char in $Text.ToCharArray()) {
        $cw = if (([int]$char -ge 0x1100 -and [int]$char -le 0x115F) -or
                  ([int]$char -ge 0x2E80 -and [int]$char -le 0x9FFF) -or
                  ([int]$char -ge 0xAC00 -and [int]$char -le 0xD7AF) -or
                  ([int]$char -ge 0xF900 -and [int]$char -le 0xFAFF) -or
                  ([int]$char -ge 0xFE30 -and [int]$char -le 0xFE6F) -or
                  ([int]$char -ge 0xFF01 -and [int]$char -le 0xFF60)) { 2 } else { 1 }
        if ($w + $cw -gt $target) { break }
        [void]$sb.Append($char)
        $w += $cw
    }
    [void]$sb.Append($ellipsis)
    return $sb.ToString()
}

function Get-ColumnWidths {
    <#
    .SYNOPSIS Computes optimal column widths for a set of rows, respecting console width.
    .PARAMETER Headers     Array of column header strings
    .PARAMETER Rows        Array of arrays (each inner array = one row's cell values)
    .PARAMETER MinWidths   Optional array of minimum column widths
    .PARAMETER MaxTotal    Maximum total width (defaults to console width - margins)
    #>
    param(
        [string[]]$Headers,
        [object[]]$Rows,
        [int[]]$MinWidths = @(),
        [int]$MaxTotal = 0
    )

    $consoleW = Get-ConsoleWidth
    if ($MaxTotal -le 0) { $MaxTotal = $consoleW - 4 }

    $colCount = $Headers.Count
    $widths   = New-Object int[] $colCount

    # Start with header widths
    for ($c = 0; $c -lt $colCount; $c++) {
        $w = Get-DisplayWidth $Headers[$c]
        if ($c -lt $MinWidths.Count -and $w -lt $MinWidths[$c]) { $w = $MinWidths[$c] }
        $widths[$c] = $w
    }

    # Measure data rows (sample up to 50 for speed)
    $sampleSize = [Math]::Min(50, $Rows.Count)
    for ($r = 0; $r -lt $sampleSize; $r++) {
        $row = $Rows[$r]
        for ($c = 0; $c -lt $colCount -and $c -lt @($row).Count; $c++) {
            $cellText = Get-SafeString $row[$c] -Fallback '—'
            $w = Get-DisplayWidth $cellText
            if ($w -gt $widths[$c]) { $widths[$c] = $w }
        }
    }

    # Apply caps: max 45 chars for name columns, 20 for others
    for ($c = 0; $c -lt $colCount; $c++) {
        $cap = if ($c -eq 0) { 3 } elseif ($c -eq 1) { 45 } else { 20 }
        if ($widths[$c] -gt $cap) { $widths[$c] = $cap }
    }

    # Shrink if total exceeds max (proportionally)
    $total = ($widths | Measure-Object -Sum).Sum + ($colCount * 3) + ($colCount - 1)
    if ($total -gt $MaxTotal) {
        $ratio = $MaxTotal / $total
        for ($c = 0; $c -lt $colCount; $c++) {
            $min = if ($c -lt $MinWidths.Count) { $MinWidths[$c] } else { 3 }
            $widths[$c] = [int][Math]::Max($min, [int]($widths[$c] * $ratio))
        }
    }

    return $widths
}

# ═══════════════════════════════════════════════════════════════════════════════
# BOX-DRAWING TABLE RENDERER
# ═══════════════════════════════════════════════════════════════════════════════

function Draw-Table {
    <#
    .SYNOPSIS Renders a Unicode box-drawing table with auto-sizing columns.
    .DESCRIPTION
        Produces tables like:
        ┌────┬──────────────────────┬──────────────┐
        │ #  │ Driver Name          │ Provider     │
        ├────┼──────────────────────┼──────────────┤
        │ 1  │ Intel Chipset Device │ Intel Corp   │
        │ 2  │ Realtek Audio        │ Realtek      │
        └────┴──────────────────────┴──────────────┘
    .PARAMETER Title      Optional header title row
    .PARAMETER Headers    Array of column header strings
    .PARAMETER Rows       Array of arrays (cell values)
    .PARAMETER Colors     Optional array of per-row ForegroundColor names
    .PARAMETER IndexColumn If $true, first column is auto-numbered
    .PARAMETER MaxTotalWidth  Max total width (0 = auto-detect console width)
    #>
    param(
        [string]$Title = '',
        [string[]]$Headers,
        [object[]]$Rows,
        [string[]]$Colors = @(),
        [bool]$IndexColumn = $false,
        [int]$MaxTotalWidth = 0
    )

    if ($MaxTotalWidth -le 0) { $MaxTotalWidth = (Get-ConsoleWidth) - 2 }

    $colCount = $Headers.Count
    if ($colCount -eq 0) { return }

    # Compute column widths
    $widths = Get-ColumnWidths -Headers $Headers -Rows $Rows -MaxTotal $MaxTotalWidth

    # Box characters (as strings, not chars, to support string multiplication in PS 5.1)
    $tl = [string][char]0x250C  # ┌
    $tr = [string][char]0x2510  # ┐
    $bl = [string][char]0x2514  # └
    $br = [string][char]0x2518  # ┘
    $ht = [string][char]0x2500  # ─
    $vt = [string][char]0x2502  # │
    $lt = [string][char]0x251C  # ├
    $rt = [string][char]0x2524  # ┤
    $cr = [string][char]0x253C  # ┼

    $indent = '  '

    # Helper: build a horizontal separator line
    function New-HLine($left, $mid, $right) {
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add($left)
        foreach ($w in $widths) { $parts.Add($ht * ($w + 2)) }
        $parts.Add($right)
        # Rebuild with junctions
        $sb = [System.Text.StringBuilder]::new($indent)
        [void]$sb.Append($left)
        for ($c = 0; $c -lt $colCount; $c++) {
            [void]$sb.Append($ht * ($widths[$c] + 2))
            if ($c -lt ($colCount - 1)) {
                [void]$sb.Append($mid)
            } else {
                [void]$sb.Append($right)
            }
        }
        return $sb.ToString()
    }

    # Helper: format one data row
    function Format-DataRow($cells, $idx, $color) {
        $sb = [System.Text.StringBuilder]::new($indent)
        [void]$sb.Append($vt)
        for ($c = 0; $c -lt $colCount; $c++) {
            $cellVal = if ($c -lt @($cells).Count) { Get-SafeString $cells[$c] -Fallback '—' } else { '—' }
            # Auto-number first column if requested
            if ($c -eq 0 -and $IndexColumn -and $null -ne $idx) {
                $cellVal = [string]($idx + 1)
            }
            $truncated = Truncate-Text -Text $cellVal -MaxWidth $widths[$c]
            $padded    = $truncated.PadRight($widths[$c])
            [void]$sb.Append(" $padded ")
            [void]$sb.Append($vt)
        }
        $line = $sb.ToString()
        if ($color) {
            Write-Host $line -ForegroundColor $color
        } else {
            Write-Host $line -ForegroundColor White
        }
    }

    # ── Title bar ──────────────────────────────────────────────────────
    Write-Host ""
    if ($Title) {
        $titleText = " $Title "
        $totalInner = ($widths | ForEach-Object { $_ + 2 }) -join '+'
        $sumW = [int](($widths | Measure-Object -Sum).Sum + ($colCount * 3))
        $padLeft  = [int][Math]::Max(0, [int](($sumW - (Get-DisplayWidth $titleText)) / 2))
        $padRight = [int][Math]::Max(0, $sumW - $padLeft - (Get-DisplayWidth $titleText))
        Write-Host "$indent$tl$($ht * $sumW)$tr" -ForegroundColor DarkCyan
        Write-Host "$indent$vt$(' ' * $padLeft)$titleText$(' ' * $padRight)$vt" -ForegroundColor Cyan
    }

    # ── Top border ─────────────────────────────────────────────────────
    Write-Host (New-HLine $tl $cr $tr) -ForegroundColor DarkCyan

    # ── Header row ─────────────────────────────────────────────────────
    $sb = [System.Text.StringBuilder]::new($indent)
    [void]$sb.Append($vt)
    for ($c = 0; $c -lt $colCount; $c++) {
        $hText = Truncate-Text -Text $Headers[$c] -MaxWidth $widths[$c]
        $padded = $hText.PadRight($widths[$c])
        [void]$sb.Append(" $padded ")
        [void]$sb.Append($vt)
    }
    Write-Host $sb.ToString() -ForegroundColor DarkGray

    # ── Header separator ───────────────────────────────────────────────
    Write-Host (New-HLine $lt $cr $rt) -ForegroundColor DarkCyan

    # ── Data rows ──────────────────────────────────────────────────────
    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $color = if ($r -lt $Colors.Count -and $Colors[$r]) { $Colors[$r] } else { 'White' }
        Format-DataRow -cells $Rows[$r] -idx $r -color $color
    }

    # ── Bottom border ──────────────────────────────────────────────────
    Write-Host (New-HLine $bl $cr $br) -ForegroundColor DarkCyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# BORDERED BOX RENDERER (for panels, summaries, detail views)
# ═══════════════════════════════════════════════════════════════════════════════

function Draw-BorderedBox {
    <#
    .SYNOPSIS Renders a single-line or multi-line bordered box.
    .PARAMETER Lines      Array of strings (content lines)
    .PARAMETER Width      Inner width of the box
    .PARAMETER Title      Optional centered title in the top border
    .PARAMETER Color      Border color
    .PARAMETER Indent     Left indent string
    #>
    param(
        [string[]]$Lines,
        [int]$Width = 66,
        [string]$Title = '',
        [string]$Color = 'DarkCyan',
        [string]$Indent = '  '
    )

    $tl = [string][char]0x250C; $tr = [string][char]0x2510
    $bl = [string][char]0x2514; $br = [string][char]0x2518
    $vt = [string][char]0x2502; $ht = [string][char]0x2500

    if ($Title) {
        $top = "$Indent$tl$ht$ht $Title $(' ' * [int][Math]::Max(0, $Width - $Title.Length - 4))$ht$ht$tr"
    } else {
        $top = "$Indent$tl$($ht * ($Width + 2))$tr"
    }
    $bot = "$Indent$bl$($ht * ($Width + 2))$br"

    Write-Host $top -ForegroundColor $Color
    foreach ($line in $Lines) {
        $padded = if ($line.Length -gt $Width) { $line.Substring(0, $Width) } else { $line.PadRight($Width) }
        Write-Host "$Indent$vt $($padded) $vt" -ForegroundColor $Color
    }
    Write-Host $bot -ForegroundColor $Color
}

# ═══════════════════════════════════════════════════════════════════════════════
# PAGINATION BAR
# ═══════════════════════════════════════════════════════════════════════════════

function Get-PaginationBar {
    <#
    .SYNOPSIS Generates a compact pagination bar: << < 4 5 [6] 7 8 > >>
    .PARAMETER CurrentPage   Current page number (1-based)
    .PARAMETER TotalPages    Total number of pages
    .PARAMETER WindowSize    Pages visible around current page (default 2)
    .OUTPUTS String for display
    #>
    param(
        [int]$CurrentPage,
        [int]$TotalPages,
        [int]$WindowSize = 2
    )

    if ($TotalPages -le 1) { return '' }

    $parts = [System.Collections.Generic.List[string]]::new()

    # First page
    if ($CurrentPage -gt 1) {
        $parts.Add('«')    # « = first
        $parts.Add('‹')    # ‹ = prev
    }

    # Page window
    $startPage = [Math]::Max(1, $CurrentPage - $WindowSize)
    $endPage   = [Math]::Min($TotalPages, $CurrentPage + $WindowSize)

    # Leading ellipsis
    if ($startPage -gt 1) { $parts.Add('…') }

    for ($p = $startPage; $p -le $endPage; $p++) {
        if ($p -eq $CurrentPage) {
            $parts.Add("[$p]")
        } else {
            $parts.Add([string]$p)
        }
    }

    # Trailing ellipsis
    if ($endPage -lt $TotalPages) { $parts.Add('…') }

    # Last page
    if ($CurrentPage -lt $TotalPages) {
        $parts.Add('›')    # › = next
        $parts.Add('»')    # » = last
    }

    return $parts -join ' '
}

# ═══════════════════════════════════════════════════════════════════════════════
# SEARCH RESULTS TABLE (dedicated renderer with pagination header)
# ═══════════════════════════════════════════════════════════════════════════════

function Show-SearchTable {
    <#
    .SYNOPSIS Renders a paginated search results table with Unicode box drawing.
    .PARAMETER Results      Full result array
    .PARAMETER Page         Current page (1-based)
    .PARAMETER PageSize     Items per page (default 25)
    #>
    param(
        [object[]]$Results,
        [int]$Page = 1,
        [int]$PageSize = 25
    )

    $total = @($Results).Count
    if ($total -eq 0) {
        Write-Host ""
        Write-Host "  No results to display." -ForegroundColor DarkGray
        Write-Host ""
        return [pscustomobject]@{ Page = 1; TotalPages = 0; StartIdx = 0 }
    }

    $totalPages = [int][Math]::Ceiling($total / $PageSize)
    if ($Page -lt 1)           { $Page = 1 }
    if ($Page -gt $totalPages) { $Page = $totalPages }

    $startIdx = ($Page - 1) * $PageSize
    $endIdx   = [int][Math]::Min($startIdx + $PageSize - 1, $total - 1)
    $pageItems = @($Results[$startIdx..$endIdx])

    # Build row data
    $rowCells = [System.Collections.Generic.List[object]]::new()
    $rowColors = [System.Collections.Generic.List[string]]::new()

    $idx = $startIdx
    foreach ($item in $pageItems) {
        $idx++
        $name = Get-SafeString (Get-Prop $item 'DisplayName' (Get-Prop $item 'display_name' '')) -Fallback '—'
        $prov = Get-SafeString (Get-Prop $item 'Provider' (Get-Prop $item 'provider' '')) -Fallback '—'
        $cat  = Get-SafeString (Get-Prop $item 'Category' (Get-Prop $item 'category' '')) -Fallback '—'
        $ver  = Get-SafeString (Get-Prop $item 'Version' (Get-Prop $item 'version' '')) -Fallback '—'
        $arch = Get-SafeString (Get-Prop $item 'Arch' (Get-Prop $item 'arch' '')) -Fallback 'any'

        $rowCells.Add(@($idx, $name, $prov, $cat, $ver, $arch))
        $rowColors.Add('White')
    }

    # Title bar
    $showFrom = $startIdx + 1
    $showTo   = $endIdx + 1
    $title = "SEARCH RESULTS  $showFrom–$showTo of $total  Page $Page/$totalPages"

    Draw-Table -Title $title `
               -Headers @('#', 'Driver Name', 'Provider', 'Category', 'Version', 'Arch') `
               -Rows $rowCells `
               -Colors $rowColors `
               -IndexColumn $false

    # Pagination controls
    if ($totalPages -gt 1) {
        $bar = Get-PaginationBar -CurrentPage $Page -TotalPages $totalPages -WindowSize 2
        $navHint = "  $bar     « first  › next  ‹ prev  » last"
        Write-Host $navHint -ForegroundColor DarkCyan
        Write-Host "  d<N> download  i<N> install  det<N> details  s <query> search  q quit" -ForegroundColor DarkGray
    } else {
        Write-Host "  d<N> download  i<N> install  det<N> details  s <query> search  q quit" -ForegroundColor DarkGray
    }
    Write-Host ""

    return [pscustomobject]@{ Page = $Page; TotalPages = $totalPages; StartIdx = $startIdx }
}

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVER DETAIL VIEW
# ═══════════════════════════════════════════════════════════════════════════════

function Show-DriverDetail {
    <#
    .SYNOPSIS Shows full details for a single driver result in a bordered box.
    .PARAMETER Item  Driver result object
    #>
    param([object]$Item)

    $fields = @(
        @('Name',        (Get-SafeString (Get-Prop $Item 'DisplayName' (Get-Prop $Item 'display_name' '')) -Fallback '—')),
        @('Provider',    (Get-SafeString (Get-Prop $Item 'Provider' (Get-Prop $Item 'provider' '')) -Fallback '—')),
        @('Category',    (Get-SafeString (Get-Prop $Item 'Category' (Get-Prop $Item 'category' '')) -Fallback '—')),
        @('Version',     (Get-SafeString (Get-Prop $Item 'Version' (Get-Prop $Item 'version' '')) -Fallback '—')),
        @('Arch',        (Get-SafeString (Get-Prop $Item 'Arch' (Get-Prop $Item 'arch' '')) -Fallback 'any')),
        @('Driver ID',   (Get-SafeString (Get-Prop $Item 'DriverId' (Get-Prop $Item 'driver_id' '')) -Fallback '—')),
        @('Matched HWID',(Get-SafeString (Get-Prop $Item 'MatchedHWID' '') -Fallback 'N/A (keyword match)')),
        @('Parts',       "$((Get-Prop $Item 'ZipParts' 1)) archive part(s)"),
        @('Download URL', (Get-SafeString (Get-Prop $Item 'PrimaryUrl' (Get-Prop $Item 'primary_url' '')) -Fallback '—'))
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $fields) {
        $label = $f[0].PadRight(14)
        $val   = $f[1]
        if ($val.Length -gt 52) { $val = $val.Substring(0, 49) + '...' }
        $lines.Add("$label : $val")
    }

    Draw-BorderedBox -Lines $lines -Width 70 -Title 'DRIVER DETAILS' -Color 'DarkCyan'
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTALLATION SUMMARY BOX
# ═══════════════════════════════════════════════════════════════════════════════

function Show-InstallSummary {
    <#
    .SYNOPSIS Renders a bordered installation summary box after all drivers are processed.
    .PARAMETER Results  Array of driver result PSObjects
    #>
    param([object[]]$Results)

    $lines = [System.Collections.Generic.List[string]]::new()
    $colors = [System.Collections.Generic.List[string]]::new()

    foreach ($r in $Results) {
        if ($r.Skipped)        { $sym = '─'; $col = 'DarkGray'; $label = 'skipped (already installed)' }
        elseif ($r.PartialFailure) { $sym = '⚠'; $col = 'Yellow';   $label = "installed (partial — $($r.PackagesAdded)/$($r.PackagesTotal) packages)" }
        elseif ($r.Success)        { $sym = '✔'; $col = 'Green';    $label = 'installed' }
        else                        { $sym = '✘'; $col = 'Red';      $label = 'failed' }
        $rb = if ($r.RebootRequired) { ' ⟳ reboot needed' } else { '' }
        $lines.Add("$sym $($r.Name)$rb — $label")
        $colors.Add($col)
    }

    Write-Host ""
    Write-Host "  ╔══ Installation Summary ═══════════════════════════════════════╗" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $padded = $lines[$i].PadRight(60)
        Write-Host "  ║  $padded║" -ForegroundColor $colors[$i]
    }
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""

    $passed  = @($Results | Where-Object { $_.Success -and -not $_.Skipped -and -not $_.PartialFailure }).Count
    $partial = @($Results | Where-Object { $_.PartialFailure }).Count
    $skipped = @($Results | Where-Object { $_.Skipped }).Count
    $failed  = @($Results | Where-Object { -not $_.Success -and -not $_.Skipped }).Count
    Write-Host "  $passed installed  ·  $partial partial  ·  $skipped skipped  ·  $failed failed" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROGRESS BAR
# ═══════════════════════════════════════════════════════════════════════════════

function Show-ProgressBar {
    <#
    .SYNOPSIS Renders an inline progress bar.
    .PARAMETER Current  Current value
    .PARAMETER Total    Total value
    .PARAMETER Label    Text label
    .PARAMETER Width    Bar width in characters (default 20)
    #>
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label = '',
        [int]$Width = 20
    )

    $pct  = if ($Total -gt 0) { [int](($Current / $Total) * 100) } else { 0 }
    $fill = if ($Total -gt 0) { [int](($Current / $Total) * $Width) } else { 0 }
    $bar  = ('█' * $fill) + ('░' * ($Width - $fill))
    $text = if ($Label) { "  $Label  [$bar] $Current / $Total  ($pct%)" } else { "  [$bar] $Current / $Total  ($pct%)" }
    Write-Host "`r$($text.PadRight(80))" -NoNewline -ForegroundColor White
}

function Clear-ProgressLine {
    Write-Host "`r$(' ' * 80)`r" -NoNewline
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Get-SafeString'
    'Get-DisplayWidth'
    'Truncate-Text'
    'Get-ColumnWidths'
    'Draw-Table'
    'Draw-BorderedBox'
    'Get-PaginationBar'
    'Show-SearchTable'
    'Show-DriverDetail'
    'Show-InstallSummary'
    'Show-ProgressBar'
    'Clear-ProgressLine'
)