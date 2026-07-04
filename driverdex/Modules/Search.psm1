#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Search Module
    Weighted ranking, fuzzy search, structured filters, sorting, pagination
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# WEIGHTED SCORING ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

$Script:ScoreWeights = @{
    ExactMatch    = 100
    StartsWith    = 70
    WholeWord     = 50
    Contains      = 30
    HardwareID    = 25
    ProviderMatch = 15
    CategoryMatch = 10
    VersionMatch  = 5
}

function Get-RelevanceScore {
    <#
    .SYNOPSIS Scores a driver record against a search query using weighted matching.
    .DESCRIPTION
        Scoring:
          Exact Match (display_name == query)     +100
          Starts With (display_name starts query)  +70
          Whole Word Match in name                  +50
          Contains substring in name                +30
          Hardware ID match                         +25
          Provider match                            +15
          Category match                            +10
          Version match                              +5
    .PARAMETER Record  Driver record object
    .PARAMETER Query   Lowercased search query
    .OUTPUTS Integer score
    #>
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$Query
    )

    $score = 0
    $queryLower = $Query.ToLower().Trim()

    # Get record fields safely
    $name    = try { [string]$Record.DisplayName } catch { '' }
    $prov    = try { [string]$Record.Provider } catch { '' }
    $cat     = try { [string]$Record.Category } catch { '' }
    $ver     = try { [string]$Record.Version } catch { '' }
    $arch    = try { [string]$Record.Arch } catch { '' }
    $hwid    = try { [string]$Record.MatchedHWID } catch { '' }
    $did     = try { [string]$Record.DriverId } catch { '' }

    $nameLower = $name.ToLower().Trim()

    # ── Name scoring ───────────────────────────────────────────────────
    if ($nameLower -eq $queryLower) {
        $score += $Script:ScoreWeights.ExactMatch
    } elseif ($nameLower.StartsWith($queryLower)) {
        $score += $Script:ScoreWeights.StartsWith
    } elseif ($nameLower -match "(^|[\s\-_/\\])$([regex]::Escape($queryLower))([\s\-_/\\]|$)") {
        $score += $Script:ScoreWeights.WholeWord
    } elseif ($nameLower -like "*$queryLower*") {
        $score += $Script:ScoreWeights.Contains
    }

    # ── Provider scoring ───────────────────────────────────────────────
    $provLower = $prov.ToLower().Trim()
    if ($provLower -like "*$queryLower*") {
        $score += $Script:ScoreWeights.ProviderMatch
    }

    # ── Category scoring ───────────────────────────────────────────────
    $catLower = $cat.ToLower().Trim()
    if ($catLower -like "*$queryLower*") {
        $score += $Script:ScoreWeights.CategoryMatch
    }

    # ── Version scoring ────────────────────────────────────────────────
    if ($ver -like "*$queryLower*") {
        $score += $Script:ScoreWeights.VersionMatch
    }

    # ── Hardware ID scoring ────────────────────────────────────────────
    $hwidUpper = $hwid.ToUpper()
    $queryUpper = $Query.ToUpper()
    if ($hwidUpper -like "*$queryUpper*") {
        $score += $Script:ScoreWeights.HardwareID
    }

    # ── Driver ID scoring ──────────────────────────────────────────────
    if ($did -like "*$queryLower*") {
        $score += $Script:ScoreWeights.VersionMatch
    }

    return $score
}

# ═══════════════════════════════════════════════════════════════════════════════
# FUZZY MATCHING (character-by-character similarity)
# ═══════════════════════════════════════════════════════════════════════════════

function Get-FuzzyScore {
    <#
    .SYNOPSIS Computes a fuzzy match score between two strings.
    .DESCRIPTION
        Uses weighted Levenshtein distance with sliding window:
        - Finds the best substring alignment of query in text
        - Computes edit distance for each window
        - Scores based on match quality and position
        Returns a score from 0.0 (no match) to 1.0 (perfect match).
    .PARAMETER Text     The text to search in (e.g., driver name)
    .PARAMETER Query    The search query
    #>
    param(
        [string]$Text,
        [string]$Query
    )

    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Query)) { return 0.0 }

    $t = $Text.ToLower().Trim()
    $q = $Query.ToLower().Trim()

    if ($t -eq $q) { return 1.0 }

    if ($t -like "*$q*") {
        $pos = $t.IndexOf($q)
        $positionBonus = [Math]::Max(0, 1.0 - ($pos / [Math]::Max(1, $t.Length) * 0.3))
        return 0.8 + ($positionBonus * 0.2)
    }

    # Sliding window: try substrings of text that approximate the query length
    $bestScore = 0.0
    $ql = $q.Length

    for ($start = 0; $start -lt $t.Length; $start++) {
        # Try window sizes from query length-2 to query length+2
        for ($winSize = [int][Math]::Max(1, $ql - 2); $winSize -le [int][Math]::Min($t.Length - $start, $ql + 2); $winSize++) {
            $window = $t.Substring($start, $winSize)

            # Quick Levenshtein distance
            $dist = Get-LevenshteinDistance -Source $window -Target $q
            $maxLen = [Math]::Max($window.Length, $q.Length)
            $sim = 1.0 - ($dist / [Math]::Max(1, $maxLen))

            # Require at least 50% similarity
            if ($sim -ge 0.5) {
                $positionPenalty = $start / [Math]::Max(1, $t.Length) * 0.15
                $lengthPenalty = [Math]::Abs($window.Length - $q.Length) * 0.02
                $score = $sim - $positionPenalty - $lengthPenalty
                if ($score -gt $bestScore) { $bestScore = $score }
            }
        }
    }

    if ($bestScore -gt 0) { return [Math]::Max(0.0, $bestScore) }

    # Word-based fallback: check if query words appear in text
    $qWords = @($q -split '\s+' | Where-Object { $_.Length -ge 2 })
    if ($qWords.Count -gt 0) {
        $wordHits = 0
        foreach ($w in $qWords) {
            if ($t -like "*$w*") { $wordHits++ }
        }
        $wordRatio = $wordHits / [Math]::Max(1, $qWords.Count)
        if ($wordRatio -gt 0) { return $wordRatio * 0.5 }
    }

    return 0.0
}

function Get-LevenshteinDistance {
    <#
    .SYNOPSIS Computes Levenshtein edit distance between two strings.
    #>
    param([string]$Source, [string]$Target)

    $sLen = $Source.Length; $tLen = $Target.Length
    if ($sLen -eq 0) { return $tLen }
    if ($tLen -eq 0) { return $sLen }

    # Use two-row DP for memory efficiency
    $prev = New-Object int[] ($tLen + 1)
    $curr = New-Object int[] ($tLen + 1)

    for ($j = 0; $j -le $tLen; $j++) { $prev[$j] = $j }

    for ($i = 1; $i -le $sLen; $i++) {
        $curr[0] = $i
        for ($j = 1; $j -le $tLen; $j++) {
            $cost = if ($Source[$i - 1] -eq $Target[$j - 1]) { 0 } else { 1 }
            $del  = $prev[$j] + 1
            $ins  = $curr[$j - 1] + 1
            $sub  = $prev[$j - 1] + $cost
            $curr[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
        $temp = $prev; $prev = $curr; $curr = $temp
    }

    return $prev[$tLen]
}

# ═══════════════════════════════════════════════════════════════════════════════
# QUERY PARSER (filters, sort commands, raw query)
# ═══════════════════════════════════════════════════════════════════════════════

function Parse-SearchQuery {
    <#
    .SYNOPSIS Parses a user search string into structured components.
    .DESCRIPTION
        Extracts filter commands like:
          provider:intel  arch:x64  category:system  version:10  hardwareid:PCI  name:intel
        and sort commands like:
          sort:name  sort:provider  sort:version  sort:date  sort:score
        Returns a PSObject with Query, Filters, SortBy fields.
    .PARAMETER InputText  Raw user input string
    .OUTPUTS PSObject { Query, Filters (hashtable), SortBy (string) }
    #>
    param([string]$InputText)

    $result = [pscustomobject]@{
        Query  = ''
        Filters = @{}
        SortBy  = ''
    }

    if ([string]::IsNullOrWhiteSpace($InputText)) { return $result }

    $remaining = $InputText.Trim()

    # ── Extract sort commands ──────────────────────────────────────────
    if ($remaining -match '(?i)\bsort:(name|provider|version|date|score|arch|category)\b') {
        $result.SortBy = $Matches[1].ToLower()
        $remaining = $remaining -replace '(?i)\bsort:(name|provider|version|date|score|arch|category)\b', ''
    }

    # ── Extract structured filters ─────────────────────────────────────
    $filterPattern = '(?i)(provider|arch|category|version|hardwareid|name|publisher):(\S+)'
    while ($remaining -match $filterPattern) {
        $filterKey   = $Matches[1].ToLower()
        $filterValue = $Matches[2]
        $result.Filters[$filterKey] = $filterValue
        $remaining = $remaining -replace [regex]::Escape($Matches[0]), ''
    }

    # ── Clean remaining text as the keyword query ──────────────────────
    $result.Query = $remaining.Trim() -replace '\s+', ' '

    return $result
}

# ═══════════════════════════════════════════════════════════════════════════════
# FILTER ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

function Test-RecordFilter {
    <#
    .SYNOPSIS Tests whether a driver record passes all structured filters.
    .PARAMETER Record   Driver record object
    .PARAMETER Filters  Hashtable of filter key/value pairs
    #>
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][hashtable]$Filters
    )

    foreach ($key in $Filters.Keys) {
        $value = $Filters[$key].ToLower()

        switch ($key) {
            'provider' {
                $prov = try { [string]$Record.Provider } catch { '' }
                if ($prov -notlike "*$value*") { return $false }
            }
            'arch' {
                $arch = try { [string]$Record.Arch } catch { '' }
                $archL = $arch.ToLower()
                if ($archL -ne $value -and $archL -notin @('any','noarch','')) { return $false }
            }
            'category' {
                $cat = try { [string]$Record.Category } catch { '' }
                if ($cat -notlike "*$value*") { return $false }
            }
            'version' {
                $ver = try { [string]$Record.Version } catch { '' }
                if ($ver -notlike "*$value*") { return $false }
            }
            'hardwareid' {
                $hwid = try { [string]$Record.MatchedHWID } catch { '' }
                if ($hwid -notlike "*$value*") { return $false }
            }
            'name' {
                $name = try { [string]$Record.DisplayName } catch { '' }
                if ($name -notlike "*$value*") { return $false }
            }
            'publisher' {
                $prov = try { [string]$Record.Provider } catch { '' }
                if ($prov -notlike "*$value*") { return $false }
            }
        }
    }

    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
# SORT ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

function Sort-SearchResults {
    <#
    .SYNOPSIS Sorts search results by the specified field.
    .PARAMETER Results  Array of driver records
    .PARAMETER SortBy   Sort field: name, provider, version, date, score, arch, category
    .PARAMETER Descending  Sort descending (default $false)
    #>
    param(
        [object[]]$Results,
        [string]$SortBy = 'score',
        [bool]$Descending = $false
    )

    if (-not $Results -or @($Results).Count -eq 0) { return @() }

    $sorted = switch ($SortBy) {
        'name'     { $Results | Sort-Object -Property { try { [string]$_.DisplayName } catch { '' } } -Descending:$Descending }
        'provider' { $Results | Sort-Object -Property { try { [string]$_.Provider } catch { '' } } -Descending:$Descending }
        'version'  { $Results | Sort-Object -Property {
                        $v = try { [string]$_.Version } catch { '' }
                        $parts = $v -split '[.\-]'
                        $num = 0
                        if ($parts.Count -gt 0) { [void][long]::TryParse($parts[0], [ref]$num) }
                        return $num
                    } -Descending:$Descending }
        'date'     { $Results | Sort-Object -Property {
                        $d = try { [string]$_.DriverDate } catch { '' }
                        if ($d) { try { [datetime]$d } catch { [datetime]::MinValue } } else { [datetime]::MinValue }
                    } -Descending:$Descending }
        'score'    { $Results | Sort-Object -Property { try { [int]$_.Score } catch { 0 } } -Descending:$true }
        'arch'     { $Results | Sort-Object -Property { try { [string]$_.Arch } catch { '' } } -Descending:$Descending }
        'category' { $Results | Sort-Object -Property { try { [string]$_.Category } catch { '' } } -Descending:$Descending }
        default    { $Results | Sort-Object -Property { try { [int]$_.Score } catch { 0 } } -Descending:$true }
    }

    return $sorted
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN SEARCH FUNCTION (weighted + fuzzy + filters + sort)
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-WeightedSearch {
    <#
    .SYNOPSIS Searches driver records with weighted scoring, fuzzy matching, and filters.
    .DESCRIPTION
        Combines:
        1. API search (search endpoint + HWID fallback)
        2. Cache-based in-memory search with weighted scoring
        3. Fuzzy matching for typos (intell -> intel, atml -> Atmel)
        4. Structured filters (provider:intel arch:x64 etc)
        5. Sort commands
    .PARAMETER Query    User search string
    .PARAMETER Arch     Optional arch filter
    .PARAMETER Category Optional category filter
    .OUTPUTS [object[]] scored and sorted driver records
    #>
    param(
        [string]$Query,
        [string]$Arch     = '',
        [string]$Category = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # ── Parse structured query ─────────────────────────────────────────
    $parsed = Parse-SearchQuery -InputText $Query

    # Merge any structured filters into the explicit Arch/Category params
    $allFilters = $parsed.Filters
    if ($Arch -and -not $allFilters.ContainsKey('arch')) { $allFilters['arch'] = $Arch }
    if ($Category -and -not $allFilters.ContainsKey('category')) { $allFilters['category'] = $Category }

    $keywordQuery = $parsed.Query
    if ([string]::IsNullOrWhiteSpace($keywordQuery) -and $allFilters.Count -gt 0) {
        # Filter-only search (e.g., "provider:intel" with no keyword)
        $keywordQuery = '*'
    }

    $sortField = $parsed.SortBy
    if (-not $sortField) { $sortField = 'score' }

    # ── Detect HWID-style queries ──────────────────────────────────────
    $isHWID = $Query -match '\\'
    if ($isHWID) {
        Write-Host "  ◈ Detected hardware ID — querying HWID endpoint..." -ForegroundColor DarkGray
        try {
            $apiBase = (Get-Command -Name 'Get-ApiBase' -ErrorAction SilentlyContinue)
            $base = if ($apiBase) { & Get-ApiBase } else { 'https://driverdex-check.driverdex.workers.dev/api/hwid' }
            $encoded = [Uri]::EscapeDataString($Query.ToUpper())
            $resp    = Invoke-WebRequest -Uri "$base/$encoded" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $data    = $resp.Content | ConvertFrom-Json

            $rawItems = try { $data.matches } catch { $null }
            if ($rawItems) {
                foreach ($m in @($rawItems)) {
                    if ($null -eq $m) { continue }
                    $mEnabled = try { $m.enabled } catch { $true }
                    if ($null -ne $mEnabled -and $mEnabled -eq $false) { continue }

                    $rec = ConvertTo-NormalizedDriverRecord -M $m -MatchedHWID $Query.ToUpper() -Score 100

                    # Apply filters
                    if ($allFilters.Count -gt 0 -and -not (Test-RecordFilter -Record $rec -Filters $allFilters)) { continue }

                    $rid = $rec.DriverId
                    if ($rid -and $seen.Contains($rid)) { continue }
                    if ($rid) { [void]$seen.Add($rid) }
                    $results.Add($rec)
                }
            }

            if ($results.Count -eq 0) {
                Write-Host "  ◈ Hardware ID recognized but no driver package available." -ForegroundColor DarkGray
            }
        } catch {
            Write-Warn "HWID lookup failed: $($_.Exception.Message)"
        }

        return Sort-SearchResults -Results @($results.ToArray()) -SortBy $sortField
    }

    # ── Text / keyword search via API ──────────────────────────────────
    $searchApi = 'https://driverdex-check.driverdex.workers.dev/api/search'
    $searchUrl = "$searchApi`?q=$([Uri]::EscapeDataString($Query))"
    if ($Arch)     { $searchUrl += "&arch=$Arch" }
    if ($Category) { $searchUrl += "&category=$([Uri]::EscapeDataString($Category))" }

    try {
        $resp = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json

        $rawItems = try { $data.results } catch { $null }
        if (-not $rawItems) { $rawItems = try { $data.matches } catch { $null } }
        if (-not $rawItems) { $rawItems = $data }

        if ($rawItems) {
            foreach ($m in @($rawItems)) {
                if ($null -eq $m) { continue }
                $mEnabled = try { $m.enabled } catch { $true }
                if ($null -ne $mEnabled -and $mEnabled -eq $false) { continue }

                $scoreRaw = try { [string]($m.score) } catch { '0' }
                $score    = 0; [void][int]::TryParse($scoreRaw, [ref]$score)

                $rec = ConvertTo-NormalizedDriverRecord -M $m -Score $score

                # Apply filters
                if ($allFilters.Count -gt 0 -and -not (Test-RecordFilter -Record $rec -Filters $allFilters)) { continue }

                $rid = $rec.DriverId
                if ($rid -and $seen.Contains($rid)) { continue }
                if ($rid) { [void]$seen.Add($rid) }
                $results.Add($rec)
            }
        }
    } catch {
        Write-Host "  ◈ Search endpoint unavailable — using local index..." -ForegroundColor DarkGray
    }

    # ── Cache-based keyword fallback with weighted scoring ──────────────
    if ($results.Count -eq 0 -and $keywordQuery -and $keywordQuery -ne '*') {
        $cacheBuilt = $false
        try { $cacheBuilt = Get-HwidCacheBuilt } catch { $cacheBuilt = $false }

        if (-not $cacheBuilt) {
            Write-Host "  ◈ Building local driver index (one-time, ~30s on live API)..." -ForegroundColor DarkGray
            try {
                $apiBase = 'https://driverdex-check.driverdex.workers.dev/api/hwid'
                Build-HwidCache -ApiBase $apiBase
            } catch {
                Write-Log -Level WARN -Msg "Cache build failed: $($_.Exception.Message)"
            }
            $cacheData = Get-HwidCache
            if ($cacheData -and $cacheData.Count -gt 0) {
                Write-OK "Index ready — $($cacheData.Count) driver record(s) indexed."
            }
        }

        $cacheData = $null
        try { $cacheData = Get-HwidCache } catch {}
        if ($cacheData -and $cacheData.Count -gt 0) {
            foreach ($entry in $cacheData) {
                # Apply filters first (cheap)
                if ($allFilters.Count -gt 0 -and -not (Test-RecordFilter -Record $entry -Filters $allFilters)) { continue }

                # Compute weighted relevance score
                $score = Get-RelevanceScore -Record $entry -Query $keywordQuery

                # Fuzzy match bonus (for typos)
                $name = try { [string]$entry.DisplayName } catch { '' }
                $fuzzyScore = Get-FuzzyScore -Text $name -Query $keywordQuery
                if ($fuzzyScore -gt 0.5) {
                    $score += [int]($fuzzyScore * 20)  # up to +20 bonus for fuzzy match
                }

                if ($score -le 0) { continue }

                $rec = $entry.PSObject.Copy()
                $rec.Score = $score

                $rid = try { [string]$rec.DriverId } catch { '' }
                if ($rid -and $seen.Contains($rid)) { continue }
                if ($rid) { [void]$seen.Add($rid) }
                $results.Add($rec)
            }
        }
    }

    # ── Filter-only search with no keyword (e.g., "provider:intel") ────
    if ($results.Count -eq 0 -and $allFilters.Count -gt 0 -and ($keywordQuery -eq '*' -or [string]::IsNullOrWhiteSpace($keywordQuery))) {
        $cacheData = $null
        try { $cacheData = Get-HwidCache } catch {}
        if ($cacheData -and $cacheData.Count -gt 0) {
            foreach ($entry in $cacheData) {
                if (Test-RecordFilter -Record $entry -Filters $allFilters) {
                    $entry.Score = 50  # base score for filter matches
                    $rid = try { [string]$entry.DriverId } catch { '' }
                    if ($rid -and $seen.Contains($rid)) { continue }
                    if ($rid) { [void]$seen.Add($rid) }
                    $results.Add($entry)
                }
            }
        }
    }

    return Sort-SearchResults -Results @($results.ToArray()) -SortBy $sortField
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Get-RelevanceScore'
    'Get-FuzzyScore'
    'Parse-SearchQuery'
    'Test-RecordFilter'
    'Sort-SearchResults'
    'Invoke-WeightedSearch'
)