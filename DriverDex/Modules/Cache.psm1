#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Cache Module
    In-memory search index, HWID cache builder using runspace pools
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# MODULE-SCOPE STATE
# ═══════════════════════════════════════════════════════════════════════════════

$Script:HwidCache      = $null   # [object[]] all driver records from local HWIDs
$Script:HwidCacheBuilt = $false  # set to $true once cache population is complete

# Pre-built lookup indexes for O(1) filtered searches
$Script:IndexByProvider  = @{}
$Script:IndexByCategory  = @{}
$Script:IndexByArch      = @{}
$Script:IndexByName      = @{}    # lowercase display_name -> list of records
$Script:IndexByHWID      = @{}
$Script:IndexByDriverId  = @{}
$Script:IndexBuilt        = $false

function Get-HwidCache      { return $Script:HwidCache }
function Get-HwidCacheBuilt { return $Script:HwidCacheBuilt }
function Get-IndexBuilt     { return $Script:IndexBuilt }

# ═══════════════════════════════════════════════════════════════════════════════
# SEARCH INDEX BUILDER
# ═══════════════════════════════════════════════════════════════════════════════

function Build-SearchIndex {
    <#
    .SYNOPSIS Builds in-memory lookup indexes from the HWID cache for O(1) filtered lookups.
    Creates dictionaries keyed by provider, category, arch, and word tokens from names.
    .DESCRIPTION
        The index is built once per session. Subsequent searches use the dictionaries
        instead of scanning every record. For a 900+ record cache this drops search
        latency from ~50ms to <1ms for filtered queries.
    #>
    param([object[]]$Records)

    $Script:IndexByProvider  = @{}
    $Script:IndexByCategory  = @{}
    $Script:IndexByArch      = @{}
    $Script:IndexByName      = @{}
    $Script:IndexByHWID      = @{}
    $Script:IndexByDriverId  = @{}

    foreach ($record in $Records) {
        # Provider index (case-insensitive)
        $prov = try { [string]$record.Provider } catch { '' }
        if ($prov) {
            $provKey = $prov.Trim().ToLower()
            if (-not $Script:IndexByProvider.ContainsKey($provKey)) {
                $Script:IndexByProvider[$provKey] = [System.Collections.Generic.List[object]]::new()
            }
            $Script:IndexByProvider[$provKey].Add($record)
        }

        # Category index
        $cat = try { [string]$record.Category } catch { '' }
        if ($cat) {
            $catKey = $cat.Trim().ToLower()
            if (-not $Script:IndexByCategory.ContainsKey($catKey)) {
                $Script:IndexByCategory[$catKey] = [System.Collections.Generic.List[object]]::new()
            }
            $Script:IndexByCategory[$catKey].Add($record)
        }

        # Architecture index
        $arch = try { [string]$record.Arch } catch { '' }
        if ($arch) {
            $archKey = $arch.Trim().ToLower()
            if (-not $Script:IndexByArch.ContainsKey($archKey)) {
                $Script:IndexByArch[$archKey] = [System.Collections.Generic.List[object]]::new()
            }
            $Script:IndexByArch[$archKey].Add($record)
        }

        # Name index (tokenized for fuzzy search)
        $name = try { [string]$record.DisplayName } catch { '' }
        if ($name) {
            $nameLower = $name.Trim().ToLower()
            # Index the full name
            if (-not $Script:IndexByName.ContainsKey($nameLower)) {
                $Script:IndexByName[$nameLower] = [System.Collections.Generic.List[object]]::new()
            }
            $Script:IndexByName[$nameLower].Add($record)

            # Index individual tokens for word-level matching
            foreach ($token in ($nameLower -split '[\s\-_/\\,.;:]+')) {
                $t = $token.Trim()
                if ($t.Length -ge 2) {
                    if (-not $Script:IndexByName.ContainsKey($t)) {
                        $Script:IndexByName[$t] = [System.Collections.Generic.List[object]]::new()
                    }
                    $Script:IndexByName[$t].Add($record)
                }
            }
        }

        # HWID index
        $hwid = try { [string]$record.MatchedHWID } catch { '' }
        if ($hwid) {
            $hwidUpper = $hwid.Trim().ToUpper()
            if (-not $Script:IndexByHWID.ContainsKey($hwidUpper)) {
                $Script:IndexByHWID[$hwidUpper] = [System.Collections.Generic.List[object]]::new()
            }
            $Script:IndexByHWID[$hwidUpper].Add($record)
        }

        # Driver ID index
        $did = try { [string]$record.DriverId } catch { '' }
        if ($did) {
            if (-not $Script:IndexByDriverId.ContainsKey($did)) {
                $Script:IndexByDriverId[$did] = $record
            }
        }
    }

    $Script:IndexBuilt = $true
    Write-Log -Level DEBUG -Msg "Search index built: $($Records.Count) records, provider=$($Script:IndexByProvider.Count) cat=$($Script:IndexByCategory.Count) arch=$($Script:IndexByArch.Count) name=$($Script:IndexByName.Count)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HWID CACHE BUILDER (runspace pool, concurrent API queries)
# ═══════════════════════════════════════════════════════════════════════════════

function Build-HwidCache {
    <#
    .SYNOPSIS Scans all local hardware IDs against the HWID API concurrently
    via a runspace pool and stores the flattened driver list.
    .PARAMETER ApiBase          Base API URL
    .PARAMETER MaxConcurrency   Max parallel runspaces (default 16)
    .PARAMETER PerCallTimeoutSec Per-call timeout (default 5)
    .PARAMETER TotalBudgetSec   Hard wall-clock budget (default 12)
    #>
    param(
        [string]$ApiBase,
        [int]$MaxConcurrency = 16,
        [int]$PerCallTimeoutSec = 5,
        [int]$TotalBudgetSec = 12
    )

    $hwids = $null
    try {
        $hwids = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 } |
                   ForEach-Object { $_.HardwareID } |
                   Sort-Object -Unique)
    } catch {
        try {
            $hwids = @(Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.HardwareID } |
                       ForEach-Object { $_.HardwareID } |
                       Sort-Object -Unique)
        } catch { $hwids = @() }
    }
    if (-not $hwids -or $hwids.Count -eq 0) {
        $Script:HwidCache      = @()
        $Script:HwidCacheBuilt = $true
        return
    }

    $all  = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Runspace pool
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrency)
    $pool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()

    $workerScript = {
        param($Hwid, $ApiBase, $TimeoutSec)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        try {
            $url  = "$ApiBase/$([Uri]::EscapeDataString($Hwid))"
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            return [pscustomobject]@{ Hwid = $Hwid; Data = ($resp.Content | ConvertFrom-Json) }
        } catch {
            return [pscustomobject]@{ Hwid = $Hwid; Data = $null }
        }
    }

    $total = $hwids.Count
    foreach ($hwid in $hwids) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).AddArgument($hwid).AddArgument($ApiBase).AddArgument($PerCallTimeoutSec)
        $jobs.Add([pscustomobject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() })
    }

    # Poll with budget ceiling
    $barW = 24
    do {
        Start-Sleep -Milliseconds 150
        $finished = @($jobs | Where-Object { $_.Handle.IsCompleted }).Count
        $fill     = if ($total -gt 0) { [int](($finished / $total) * $barW) } else { $barW }
        $bar      = ('[' + ('█' * $fill) + ('░' * ($barW - $fill)) + ']')
        Write-Host "`r  ◈ Building search index... $bar $finished/$total  " -NoNewline -ForegroundColor DarkGray
    } while (($finished -lt $total) -and ($sw.Elapsed.TotalSeconds -lt $TotalBudgetSec))

    # Collect results
    $abandoned = @($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count
    foreach ($job in $jobs) {
        if ($job.Handle.IsCompleted) {
            try {
                $result = $job.Pipe.EndInvoke($job.Handle)
                $data   = if ($result) { $result[0].Data } else { $null }
                $matches = try { $data.matches } catch { $null }
                if ($matches) {
                    foreach ($m in @($matches)) {
                        $mEnabled = try { $m.enabled }    catch { $true }
                        $mId      = try { [string]($m.driver_id) } catch { '' }
                        if ($null -ne $mEnabled -and $mEnabled -eq $false) { continue }
                        if (-not $mId)                   { continue }
                        if ($seen.Contains($mId))         { continue }
                        [void]$seen.Add($mId)
                        $all.Add((ConvertTo-NormalizedDriverRecord -M $m -MatchedHWID $result[0].Hwid -Score 50))
                    }
                }
            } catch { }
        } else {
            try { $job.Pipe.Stop() } catch { }
        }
        $job.Pipe.Dispose()
    }
    $pool.Close()
    $pool.Dispose()

    Clear-ProgressLine

    if ($abandoned -gt 0) {
        Write-Warn "Index build hit its ${TotalBudgetSec}s budget — $abandoned/$total lookup(s) skipped. Results may be partial."
    }

    $Script:HwidCache      = $all.ToArray()
    $Script:HwidCacheBuilt = $true

    # Build secondary indexes
    if ($Script:HwidCache.Count -gt 0) {
        Build-SearchIndex -Records $Script:HwidCache
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# INDEX-AWARE LOOKUP HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function Get-CacheByProvider {
    param([string]$Provider)
    $key = $Provider.Trim().ToLower()
    if ($Script:IndexByProvider.ContainsKey($key)) { return $Script:IndexByProvider[$key] }
    return @()
}

function Get-CacheByCategory {
    param([string]$Category)
    $key = $Category.Trim().ToLower()
    if ($Script:IndexByCategory.ContainsKey($key)) { return $Script:IndexByCategory[$key] }
    return @()
}

function Get-CacheByArch {
    param([string]$Arch)
    $key = $Arch.Trim().ToLower()
    if ($Script:IndexByArch.ContainsKey($key)) { return $Script:IndexByArch[$key] }
    return @()
}

function Get-CacheByDriverId {
    param([string]$DriverId)
    if ($Script:IndexByDriverId.ContainsKey($DriverId)) { return $Script:IndexByDriverId[$DriverId] }
    return $null
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Build-HwidCache'
    'Build-SearchIndex'
    'Get-HwidCache'
    'Get-HwidCacheBuilt'
    'Get-IndexBuilt'
    'Get-CacheByProvider'
    'Get-CacheByCategory'
    'Get-CacheByArch'
    'Get-CacheByDriverId'
)