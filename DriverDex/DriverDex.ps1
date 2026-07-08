#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Drivers Module
    Hardware enumeration, driver classification, installed driver snapshot
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

$Script:API_BASE      = 'https://driverdex-check.driverdex.workers.dev/api/hwid'
$Script:LFS_BATCH_URL = 'https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch'
$Script:EXTRACTOR_URL = 'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/extractor/extractor.exe'
$Script:SEARCH_API    = 'https://driverdex-check.driverdex.workers.dev/api/search'
$Script:GITHUB_HOST   = 'github.com'
$Script:API_HOST      = 'driverdex-check.driverdex.workers.dev'

function Get-ApiBase     { return $Script:API_BASE }
function Get-LfsBatchUrl { return $Script:LFS_BATCH_URL }
function Get-ExtractorUrl { return $Script:EXTRACTOR_URL }
function Get-SearchApi   { return $Script:SEARCH_API }
function Get-GithubHost  { return $Script:GITHUB_HOST }
function Get-ApiHost     { return $Script:API_HOST }

# ═══════════════════════════════════════════════════════════════════════════════
# HARDWARE ENUMERATION
# ═══════════════════════════════════════════════════════════════════════════════

function Get-AllHardwareIDs {
    <#
    .SYNOPSIS Collects every unique hardware ID from PnP devices.
    Returns a string[] of de-duplicated, upper-cased HWID strings.
    #>
    Write-Step "Scanning hardware..."
    $hwids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $devices = $null
    try {
        $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 }
    } catch {
        Write-Warn "CIM query failed — falling back to WMI (Windows 7 mode)..."
        Write-Log -Level WARN -Msg "CIM fallback: $($_.Exception.Message)"
        try {
            $devices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.HardwareID }
        } catch {
            Write-Log -Level ERROR -Msg "WMI also failed: $($_.Exception.Message)" -Err $_
        }
    }

    if ($devices) {
        $i = 0
        foreach ($dev in $devices) {
            $i++
            if ($i % 50 -eq 0) {
                Write-Host "`r    Scanning... $($hwids.Count) IDs found so far" -NoNewline -ForegroundColor DarkGray
            }
            foreach ($id in $dev.HardwareID) {
                if ($id -match '^(PCI|USB|ACPI|HDAUDIO|HID|ROOT|SCSI|DISPLAY|IDE|STORAGE)\\') {
                    [void]$hwids.Add($id.ToUpper())
                }
            }
        }
        Write-Host "`r$(' ' * 72)`r" -NoNewline
    }

    # Supplemental: pnputil /enum-devices (Win 8+)
    try {
        $pnpBin = "$env:SystemRoot\System32\pnputil.exe"
        if (Test-Path $pnpBin) {
            $out = & $pnpBin /enum-devices 2>$null
            if ($out) {
                $out | Select-String 'Hardware IDs:\s+(.+)' | ForEach-Object {
                    $_.Matches.Groups[1].Value -split ',' | ForEach-Object {
                        $id = $_.Trim().ToUpper()
                        if ($id -match '^(PCI|USB|ACPI|HDAUDIO)\\') { [void]$hwids.Add($id) }
                    }
                }
            }
        }
    } catch { <# supplemental — non-fatal #> }

    Write-OK "Found $($hwids.Count) unique hardware IDs"
    return [array]$hwids
}

function Get-ProblemDevices {
    <#
    .SYNOPSIS Returns HWIDs of devices with non-zero ConfigManagerErrorCode.
    #>
    $problem = [System.Collections.Generic.List[string]]::new()
    $count   = 0
    try {
        $bad = $null
        try {
            $bad = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.ConfigManagerErrorCode -gt 0 -and $_.HardwareID }
        } catch {
            $bad = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.ConfigManagerErrorCode -gt 0 -and $_.HardwareID }
        }
        if ($bad) {
            foreach ($dev in $bad) {
                foreach ($id in $dev.HardwareID) { $problem.Add($id.ToUpper()); $count++ }
            }
        }
    } catch { Write-Log -Level WARN -Msg "Problem device scan error: $($_.Exception.Message)" }

    if ($count -gt 0) {
        Write-Accent "  [$count PROBLEM DEVICE(S) DETECTED — missing or broken drivers]"
    }
    return [array]$problem
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOCAL DRIVER INTELLIGENCE
# ═══════════════════════════════════════════════════════════════════════════════

function Get-InstalledDriverSnapshot {
    <#
    .SYNOPSIS Indexes every locally-installed signed driver by hardware ID.
    Returns a hashtable: key = uppercased HardWareID, value = {Provider, Version, DeviceName, DriverDate}.
    #>
    Write-Step "Indexing locally installed drivers..."
    $snapshot = @{}
    try {
        $signed = $null
        try {
            $signed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop
        } catch {
            $signed = Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction SilentlyContinue
        }
        foreach ($s in $signed) {
            if (-not $s.HardWareID) { continue }
            $key   = $s.HardWareID.ToUpper()
            $entry = [pscustomobject]@{
                Provider   = $s.DriverProviderName
                Version    = $s.DriverVersion
                DeviceName = $s.DeviceName
                DriverDate = $s.DriverDate
            }
            if (-not $snapshot.ContainsKey($key) -or
                (Compare-DriverVersion $entry.Version $snapshot[$key].Version) -gt 0) {
                $snapshot[$key] = $entry
            }
        }
    } catch {
        Write-Log -Level WARN -Msg "Installed driver snapshot failed: $($_.Exception.Message)"
    }
    Write-OK "Indexed $($snapshot.Count) installed driver record(s) by hardware ID."
    return $snapshot
}

function Get-UnmatchedLocalDrivers {
    <#
    .SYNOPSIS Finds hardware whose installed driver works fine, but whose
    hardware ID returned ZERO matches from the DriverDex API.
    #>
    param([string[]]$AllHWIDs, [object[]]$MatchedDrivers, [hashtable]$Snapshot)

    $matchedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $MatchedDrivers) { [void]$matchedSet.Add($d.MatchedHWID) }

    $unknown = [System.Collections.Generic.List[object]]::new()
    foreach ($hwid in $AllHWIDs) {
        if ($matchedSet.Contains($hwid)) { continue }
        $info = $Snapshot[$hwid.ToUpper()]
        if (-not $info) { continue }
        $unknown.Add([pscustomobject]@{
            HWID       = $hwid
            DeviceName = $info.DeviceName
            Provider   = $info.Provider
            Version    = $info.Version
        })
    }
    return [array]$unknown
}

function Get-DriverClassification {
    <#
    .SYNOPSIS Single source of truth for how a driver row is labeled, colored,
    and whether it's selected by default.
    #>
    param([object]$Driver, [string[]]$ProblemHWIDs)

    $isProblem    = $ProblemHWIDs -contains $Driver.MatchedHWID
    $isSuperseded = [bool]$Driver.SupersededBy
    $status       = $Driver.InstallStatus

    $label = switch ($status) {
        'NEW'     { 'NEW' }
        'UPDATE'  { "UPDATE → v$($Driver.Version)" }
        'CURRENT' { 'INSTALLED ✔' }
        'NEWER'   { 'NEWER INSTALLED' }
        default   { 'NEW' }
    }
    $color = switch ($status) {
        'NEW'     { 'Green' }
        'UPDATE'  { 'Cyan' }
        'CURRENT' { 'DarkGray' }
        'NEWER'   { 'DarkGray' }
        default   { 'White' }
    }
    $code = $status

    if ($isSuperseded) {
        $code  = 'SUPERSEDED'
        $label = '[SUPERSEDED]'
        $color = 'DarkGray'
    }
    if ($isProblem) {
        $code  = 'PROBLEM'
        $label = "⚠ PROBLEM DEV · $label"
        $color = 'Yellow'
    }

    $recommended = (-not $isSuperseded) -and ($isProblem -or $status -in @('NEW', 'UPDATE'))

    return [pscustomobject]@{
        StatusCode   = $code
        Label        = $label
        Color        = $color
        Recommended  = $recommended
        IsProblem    = $isProblem
        IsSuperseded = $isSuperseded
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVER RECORD NORMALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

function ConvertTo-NormalizedDriverRecord {
    <#
    .SYNOPSIS Converts one raw API match object into the canonical PascalCase shape.
    #>
    param(
        [Parameter(Mandatory)] $M,
        [string]$MatchedHWID = '',
        [int]$Score = 50
    )
    $dn   = ConvertTo-CleanFieldString (Get-Prop $M 'display_name' (Get-Prop $M 'name' ''))
    $prov = ConvertTo-CleanFieldString (Get-Prop $M 'provider' '')
    $cat  = ConvertTo-CleanFieldString (Get-Prop $M 'category' '')
    $id   = Get-Prop $M 'driver_id' (Get-Prop $M 'id' '')
    $zip  = Get-Prop $M 'zip_parts' 1
    $arch = ConvertTo-CleanFieldString (Get-Prop $M 'arch' 'any')
    return [pscustomobject]@{
        DriverId    = $id
        DisplayName = if ($dn)            { $dn }             else { "$prov $cat".Trim() }
        Provider    = $prov
        Category    = $cat
        Version     = ConvertTo-CleanFieldString (Get-Prop $M 'version' '')
        Arch        = if ($arch) { $arch } else { 'any' }
        PrimaryUrl  = Get-Prop $M 'primary_url' ''
        ZipParts    = [int]$zip
        MatchedHWID = $MatchedHWID
        Score       = $Score
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# API QUERY
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-ApiWithRetry {
    <#
    .SYNOPSIS Calls the HWID API with up to 3 retries and exponential backoff.
    #>
    param([string]$HWID)
    $encoded = [Uri]::EscapeDataString($HWID)
    $url     = "$Script:API_BASE/$encoded"
    $delays  = @(2, 4, 8)
    for ($try = 0; $try -le 2; $try++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            return ($resp.Content | ConvertFrom-Json)
        } catch {
            if ($try -lt 2) {
                $d = $delays[$try]
                Write-Log -Level WARN -Msg "API retry $($try+1)/3 for $HWID in ${d}s: $($_.Exception.Message)"
                Start-Sleep -Seconds $d
            }
        }
    }
    return $null
}

function Invoke-ApiFast {
    <#
    .SYNOPSIS Single-shot HWID API call with a short timeout — no retries.
    #>
    param([string]$HWID, [string]$ApiBase)
    try {
        $url  = "$ApiBase/$([Uri]::EscapeDataString($HWID))"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        return ($resp.Content | ConvertFrom-Json)
    } catch { return $null }
}

function Search-Drivers {
    <#
    .SYNOPSIS Queries the API for every HWID and returns de-duplicated driver list.
    Each result is tagged with InstallStatus (NEW/UPDATE/CURRENT/NEWER) and InstalledVersion.
    #>
    param([string[]]$HWIDs, [string]$SystemArch, [hashtable]$InstalledSnapshot = @{})

    # Defense-in-depth: normalize here too, in case a caller passes a raw arch string
    # (WMI spelling, a typo'd inventory.json value, etc.) directly without routing it
    # through ConvertTo-NormalizedArch first. An un-normalized value here silently
    # discards every arch-specific match below — see ConvertTo-NormalizedArch in Utils.psm1.
    $SystemArch = ConvertTo-NormalizedArch -Value $SystemArch -Source 'Search-Drivers:SystemArch'

    Write-Step "Querying DriverDex API for $(@($HWIDs).Count) hardware IDs..."
    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $total   = @($HWIDs).Count
    $count   = 0
    $barW    = 20

    foreach ($id in $HWIDs) {
        $count++
        Show-ProgressBar -Current $count -Total $total -Label "Querying API"

        $apiResult  = Invoke-ApiWithRetry -HWID $id
        $apiMatches = Get-Prop $apiResult 'matches'
        if (-not $apiResult -or -not $apiMatches -or @($apiMatches).Count -eq 0) { continue }

        foreach ($match in $apiMatches) {
            $mEnabled  = Get-Prop $match 'enabled'
            $mDriverId = Get-Prop $match 'driver_id' ''
            if (-not $mEnabled)                { continue }
            if ($seen.Contains($mDriverId))    { continue }

            $mArchRaw = Get-Prop $match 'arch'
            $mArch    = if ($mArchRaw) { $mArchRaw.ToLower() } else { '' }
            $sArch    = $SystemArch.ToLower()
            $archOk = ($mArch -eq $sArch) -or
                      ($mArch -in @('any','noarch','')) -or
                      ($mArch -eq 'x86' -and $sArch -eq 'x64')
            if (-not $archOk) { continue }

            $mIsGenericRaw = Get-Prop $match 'matched_is_generic' 0
            $isRecommended = ($mArch -eq $sArch) -and ([int]$mIsGenericRaw -eq 0)

            $mVersion = Get-Prop $match 'version' ''

            $localInfo = $InstalledSnapshot[$id.ToUpper()]
            if (-not $localInfo) {
                $installStatus    = 'NEW'
                $installedVersion = $null
            } else {
                $cmp = Compare-DriverVersion $localInfo.Version $mVersion
                $installStatus    = if     ($cmp -lt 0) { 'UPDATE' }
                                     elseif ($cmp -eq 0) { 'CURRENT' }
                                     else                { 'NEWER' }
                $installedVersion = $localInfo.Version
            }

            [void]$seen.Add($mDriverId)
            $mProvider  = Get-Prop $match 'provider' ''
            $mCategory  = Get-Prop $match 'category' ''
            $mDispName  = Get-Prop $match 'display_name'
            $mPrimUrl   = Get-Prop $match 'primary_url' ''
            $mZipParts  = Get-Prop $match 'zip_parts' 1
            $results.Add([pscustomobject]@{
                DriverId         = $mDriverId
                DisplayName      = if ($mDispName) { $mDispName } else { "$mProvider $mCategory".Trim() }
                Provider         = $mProvider
                Category         = $mCategory
                Version          = $mVersion
                Arch             = if ($mArchRaw) { $mArchRaw } else { 'any' }
                PrimaryUrl       = $mPrimUrl
                ZipParts         = [int]$mZipParts
                MatchedHWID      = $id
                SupersededBy     = Get-Prop $match 'superseded_by'
                IsGeneric        = [int]$mIsGenericRaw
                IsRecommended    = $isRecommended
                InstallStatus    = $installStatus
                InstalledVersion = $installedVersion
            })
        }
    }
    Clear-ProgressLine
    Write-Host ""   # newline after progress bar
    return [array]$results
}

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVER INSTALLED CHECK
# ═══════════════════════════════════════════════════════════════════════════════

function Test-DriverInstalled {
    <#
    .SYNOPSIS Checks Win32_PnPSignedDriver for a matching Provider + Version.
    #>
    param([string]$Provider, [string]$Version)
    try {
        $installed = $null
        try {
            $installed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
                         Where-Object { $_.ProviderName -like "*$Provider*" -and $_.DriverVersion -eq $Version }
        } catch {
            $installed = Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                         Where-Object { $_.ProviderName -like "*$Provider*" -and $_.DriverVersion -eq $Version }
        }
        return ($installed -and @($installed).Count -gt 0)
    } catch { return $false }
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Get-AllHardwareIDs'
    'Get-ProblemDevices'
    'Get-InstalledDriverSnapshot'
    'Get-UnmatchedLocalDrivers'
    'Get-DriverClassification'
    'ConvertTo-NormalizedDriverRecord'
    'Invoke-ApiWithRetry'
    'Invoke-ApiFast'
    'Search-Drivers'
    'Test-DriverInstalled'
    'Get-ApiBase'
    'Get-LfsBatchUrl'
    'Get-ExtractorUrl'
    'Get-SearchApi'
    'Get-GithubHost'
    'Get-ApiHost'
)
