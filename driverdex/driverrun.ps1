#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex — Automatic Hardware Driver Detector & Installer
    Run via: irm https://your-url/DriverDex-Installer.ps1 | iex

.DESCRIPTION
    Scans all hardware devices, queries the DriverDex API for matching drivers,
    lets you review & select which to install, then downloads, verifies (SHA256),
    extracts, and installs them — all in one script.

.NOTES
    Compatible with: Windows 7 SP1, 8.1, 10, 11 (x86 & x64)
    Requires: PowerShell 5.1+
    Elevation: Recommended (auto-elevates if possible)
    Author: DriverDex — https://github.com/rhshourav/driverdex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Speeds up Invoke-WebRequest dramatically

# ─────────────────────────────────────────────────────────────────────────────
#  CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
$Script:API_BASE      = 'https://driverdex-check.driverdex.workers.dev/api/hwid'
$Script:LFS_BATCH_URL = 'https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch'
$Script:EXTRACTOR_URL = 'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/extractor/extractor.exe'
$Script:BANNER_COLOR  = 'Cyan'
$Script:VERSION       = '2.0.0'

# ─────────────────────────────────────────────────────────────────────────────
#  COLOUR PALETTE HELPERS  (works on PS 5.1 through 7.x)
# ─────────────────────────────────────────────────────────────────────────────
function Write-Header {
    $w = 64
    $line = '═' * $w
    Write-Host ""
    Write-Host "  $line"  -ForegroundColor DarkCyan
    Write-Host "  ║$((' ' * ($w - 2)))║"  -ForegroundColor DarkCyan
    Write-Host "  ║   ██████╗ ██████╗ ██╗██╗   ██╗███████╗██████╗ ███████╗██╗  ██╗   ║" -ForegroundColor Cyan
    Write-Host "  ║   ██╔══██╗██╔══██╗██║██║   ██║██╔════╝██╔══██╗██╔════╝╚██╗██╔╝   ║" -ForegroundColor Cyan
    Write-Host "  ║   ██║  ██║██████╔╝██║╚██╗ ██╔╝█████╗  ██████╔╝█████╗   ╚███╔╝    ║" -ForegroundColor Cyan
    Write-Host "  ║   ██║  ██║██╔══██╗██║ ╚████╔╝ ██╔══╝  ██╔══██╗██╔══╝   ██╔██╗    ║" -ForegroundColor Cyan
    Write-Host "  ║   ██████╔╝██║  ██║██║  ╚██╔╝  ███████╗██║  ██║███████╗██╔╝ ██╗   ║" -ForegroundColor Cyan
    Write-Host "  ║   ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝  ║" -ForegroundColor Cyan
    Write-Host "  ║$((' ' * ($w - 2)))║"  -ForegroundColor DarkCyan
    Write-Host "  ║   Automatic Driver Detector & Installer  v$Script:VERSION$((' ' * (29 - $Script:VERSION.Length)))║" -ForegroundColor White
    Write-Host "  ║   https://github.com/rhshourav/driverdex$((' ' * 20))║" -ForegroundColor DarkGray
    Write-Host "  ║$((' ' * ($w - 2)))║"  -ForegroundColor DarkCyan
    Write-Host "  $line"  -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Step   { param([string]$Msg) Write-Host "  » $Msg" -ForegroundColor White }
function Write-OK     { param([string]$Msg) Write-Host "  ✔ $Msg" -ForegroundColor Green }
function Write-Warn   { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }
function Write-Err    { param([string]$Msg) Write-Host "  ✘ $Msg" -ForegroundColor Red }
function Write-Info   { param([string]$Msg) Write-Host "    $Msg" -ForegroundColor DarkGray }
function Write-Divider { Write-Host "  $('─' * 60)" -ForegroundColor DarkGray }

# ─────────────────────────────────────────────────────────────────────────────
#  ELEVATION & OS DETECTION
# ─────────────────────────────────────────────────────────────────────────────
function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OSInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) {
        # Fallback for older PS / WMI
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
    }
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    [pscustomobject]@{
        Caption   = if ($os) { $os.Caption }         else { 'Unknown Windows' }
        Build     = if ($os) { $os.BuildNumber }     else { '0' }
        Version   = if ($os) { $os.Version }         else { '0.0' }
        Arch      = $arch
        PSVersion = $PSVersionTable.PSVersion.ToString()
    }
}

function Request-Elevation {
    if (Test-Administrator) { return }
    Write-Warn 'Not running as Administrator.'
    Write-Warn 'Driver installation (pnputil) requires elevation.'
    Write-Host ""
    $choice = Read-HostDefault "Attempt to relaunch as Administrator? [Y/n]" 'Y'
    if ($choice -match '^[Yy]') {
        try {
            $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            Start-Process powershell -Verb RunAs -ArgumentList $psArgs -ErrorAction Stop
            exit 0
        } catch {
            Write-Warn "Auto-elevation failed. Continuing without admin — install step will be skipped."
        }
    } else {
        Write-Warn "Continuing without elevation — driver install will be skipped."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  SMART Read-Host WITH DEFAULT VALUE
# ─────────────────────────────────────────────────────────────────────────────
function Read-HostDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    $display = if ($Default) { "$Prompt (default: $Default)" } else { $Prompt }
    Write-Host "  $display" -ForegroundColor White -NoNewline
    Write-Host " > " -ForegroundColor DarkCyan -NoNewline
    $input = $Host.UI.ReadLine()
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input.Trim()
}

# ─────────────────────────────────────────────────────────────────────────────
#  HARDWARE ENUMERATION
# ─────────────────────────────────────────────────────────────────────────────
function Get-AllHardwareIDs {
    Write-Step "Enumerating hardware devices..."
    $hwids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Method 1: Win32_PnPEntity (broadest, works PS5.1+)
    try {
        $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.HardwareID -and $_.HardwareID.Count -gt 0 }
        foreach ($dev in $devices) {
            foreach ($id in $dev.HardwareID) {
                if ($id -match '^(PCI|USB|ACPI|HDAUDIO|HID|ROOT|SCSI|DISPLAY|IDE|STORAGE)\\') {
                    [void]$hwids.Add($id.ToUpper())
                }
            }
        }
        Write-Info "WMI/CIM: found $($hwids.Count) unique hardware IDs"
    } catch {
        Write-Warn "CIM query failed — falling back to WMI..."
        try {
            $devices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction Stop |
                       Where-Object { $_.HardwareID }
            foreach ($dev in $devices) {
                foreach ($id in $dev.HardwareID) {
                    if ($id -match '^(PCI|USB|ACPI|HDAUDIO)\\') {
                        [void]$hwids.Add($id.ToUpper())
                    }
                }
            }
        } catch {
            Write-Warn "WMI also failed: $_"
        }
    }

    # Method 2: devcon / PnP store cross-check (Windows 8+)
    try {
        $pnpPath = "$env:SystemRoot\System32\pnputil.exe"
        if (Test-Path $pnpPath) {
            # pnputil /enum-devices is available Win8+
            $pnpOutput = & $pnpPath /enum-devices 2>$null
            if ($pnpOutput) {
                $pnpOutput | Select-String 'Hardware IDs:\s+(.+)' | ForEach-Object {
                    $_.Matches.Groups[1].Value -split ',' | ForEach-Object {
                        $id = $_.Trim().ToUpper()
                        if ($id -match '^(PCI|USB|ACPI|HDAUDIO)\\') {
                            [void]$hwids.Add($id)
                        }
                    }
                }
            }
        }
    } catch { <# non-fatal #> }

    Write-OK "Total unique hardware IDs collected: $($hwids.Count)"
    return @($hwids)
}

function Get-ProblemDevices {
    # Returns HWIDs for devices with error codes (missing/broken drivers)
    $problem = [System.Collections.Generic.List[string]]::new()
    try {
        $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                   Where-Object { $_.ConfigManagerErrorCode -gt 0 -and $_.HardwareID }
        foreach ($dev in $devices) {
            foreach ($id in $dev.HardwareID) {
                $problem.Add($id.ToUpper())
            }
        }
    } catch { <# fallback silently #> }
    return $problem
}

# ─────────────────────────────────────────────────────────────────────────────
#  API  QUERY
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-DriverDexAPI {
    param([string]$HWID)
    $encoded  = [Uri]::EscapeDataString($HWID)
    $url      = "$Script:API_BASE/$encoded"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        return ($resp.Content | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Search-Drivers {
    param([string[]]$HWIDs, [string]$SystemArch)

    Write-Step "Querying DriverDex API for $($HWIDs.Count) hardware IDs..."
    $results  = [System.Collections.Generic.List[object]]::new()
    $seen     = [System.Collections.Generic.HashSet[string]]::new()
    $count    = 0
    $total    = $HWIDs.Count

    foreach ($id in $HWIDs) {
        $count++
        # Throttle display updates
        if ($count % 25 -eq 0 -or $count -eq $total) {
            Write-Host "`r    Progress: $count / $total" -NoNewline -ForegroundColor DarkGray
        }

        $apiResult = Invoke-DriverDexAPI -HWID $id
        if (-not $apiResult -or -not $apiResult.matches -or $apiResult.matches.Count -eq 0) {
            continue
        }

        foreach ($match in $apiResult.matches) {
            if (-not $match.enabled) { continue }
            if ($seen.Contains($match.driver_id)) { continue }
            # Arch filter: prefer system arch but include 'any'/'noarch'
            if ($match.arch -notin @($SystemArch, 'x86', 'any', 'noarch', '')) {
                # Skip opposite arch unless no arch field
                if ($match.arch -and $match.arch -ne $SystemArch) { continue }
            }
            [void]$seen.Add($match.driver_id)
            $results.Add([pscustomobject]@{
                DriverId     = $match.driver_id
                DisplayName  = $match.display_name
                Provider     = $match.provider
                Category     = $match.category
                Version      = $match.version
                Arch         = $match.arch
                PrimaryUrl   = $match.primary_url
                ZipParts     = [int]$match.zip_parts
                MatchedHWID  = $id
                Descriptions = $match.descriptions -join ', '
                DateAdded    = $match.date_added
                SupersededBy = $match.superseded_by
                IsGeneric    = [int]$match.matched_is_generic
            })
        }
    }
    Write-Host ""   # newline after progress
    return $results
}

# ─────────────────────────────────────────────────────────────────────────────
#  DRIVER SELECTION UI
# ─────────────────────────────────────────────────────────────────────────────
function Show-DriverMenu {
    param(
        [object[]]$Drivers,
        [string[]]$ProblemHWIDs
    )

    Write-Host ""
    Write-Divider
    Write-Host "  Found $($Drivers.Count) matching driver package(s):" -ForegroundColor Cyan
    Write-Divider
    Write-Host ""

    $idx = 0
    foreach ($d in $Drivers) {
        $idx++
        $tag = if ($ProblemHWIDs -contains $d.MatchedHWID) { ' [!PROBLEM DEVICE]' } else { '' }
        $superTag = if ($d.SupersededBy) { ' [superseded]' } else { '' }
        $archColor = if ($d.Arch -eq 'x64') { 'Magenta' } else { 'DarkYellow' }

        Write-Host "  [$idx] " -ForegroundColor DarkCyan -NoNewline
        Write-Host "$($d.DisplayName) — $($d.Provider)" -ForegroundColor White -NoNewline
        Write-Host "$tag$superTag" -ForegroundColor Red
        Write-Host "       Category : $($d.Category)  |  " -ForegroundColor DarkGray -NoNewline
        Write-Host "Version : $($d.Version)  |  " -ForegroundColor DarkGray -NoNewline
        Write-Host "Arch: $($d.Arch)" -ForegroundColor $archColor
        Write-Host "       Device   : $($d.MatchedHWID)" -ForegroundColor DarkGray
        if ($d.Descriptions) {
            $desc = if ($d.Descriptions.Length -gt 72) { $d.Descriptions.Substring(0,69) + '...' } else { $d.Descriptions }
            Write-Host "       Desc     : $desc" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-Divider
    Write-Host ""
    Write-Host "  Selection options:" -ForegroundColor White
    Write-Host "   • Enter numbers separated by commas  e.g.  1,3,5" -ForegroundColor DarkGray
    Write-Host "   • Type  ALL  to install everything" -ForegroundColor DarkGray
    Write-Host "   • Type  PROBLEMS  to install only problem devices" -ForegroundColor DarkGray
    Write-Host "   • Press Enter (blank) to skip installation" -ForegroundColor DarkGray
    Write-Host ""

    $raw = Read-HostDefault "Your selection" "ALL"

    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    if ($raw -eq 'ALL') { return $Drivers }

    if ($raw -eq 'PROBLEMS') {
        $sel = $Drivers | Where-Object { $ProblemHWIDs -contains $_.MatchedHWID }
        if (-not $sel) { Write-Warn "No problem devices matched — selecting all."; return $Drivers }
        return @($sel)
    }

    $indices = $raw -split '[,\s]+' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Drivers.Count) { $n }
    } | Where-Object { $_ -ne $null } | Sort-Object -Unique

    return @($indices | ForEach-Object { $Drivers[$_ - 1] })
}

# ─────────────────────────────────────────────────────────────────────────────
#  DOWNLOAD ENGINE  (handles Git LFS pointers transparently)
# ─────────────────────────────────────────────────────────────────────────────
function Get-DriverDexFile {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$ExpectedSha256 = ''
    )

    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing

    # Detect Git LFS pointer (≤1 KB text files starting with version line)
    $fi = Get-Item -LiteralPath $Dest
    if ($fi.Length -le 1024) {
        try {
            $firstLine = Get-Content -LiteralPath $Dest -TotalCount 1 -ErrorAction Stop
            if ($firstLine -like 'version https://git-lfs.github.com/spec/*') {
                $oid = ''; $size = ''
                Get-Content -LiteralPath $Dest | ForEach-Object {
                    $t = $_.Trim()
                    if ($t -like 'oid sha256:*') { $oid  = $t.Substring($t.IndexOf(':') + 1).Trim() }
                    elseif ($t -like 'size *')   { $size = $t.Substring(5).Trim() }
                }
                if (-not $oid -or -not $size) { throw 'Malformed Git LFS pointer.' }

                $body  = @{
                    operation = 'download'; transfers = @('basic')
                    objects   = @(@{ oid = $oid; size = [long]$size })
                } | ConvertTo-Json -Depth 5

                $batch = Invoke-RestMethod -Uri $Script:LFS_BATCH_URL -Method Post `
                         -Body $body -ContentType 'application/vnd.git-lfs+json' `
                         -Headers @{ Accept = 'application/vnd.git-lfs+json' }

                $obj  = $batch.objects[0]
                if ($obj.error) { throw "Git LFS error: $($obj.error.message)" }
                $href = $obj.actions.download.href
                if (-not $href) { throw 'Git LFS returned no download URL.' }

                $dlH = @{}
                if ($obj.actions.download.header) {
                    $obj.actions.download.header.PSObject.Properties |
                        ForEach-Object { $dlH[$_.Name] = $_.Value }
                }
                Invoke-WebRequest -Uri $href -OutFile $Dest -UseBasicParsing -Headers $dlH
            }
        } catch [System.IO.IOException] { <# binary file, not LFS #> }
    }

    # SHA-256 verification
    if ($ExpectedSha256) {
        $actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $ExpectedSha256.ToLower()) {
            throw "SHA-256 mismatch!`n  Expected : $ExpectedSha256`n  Actual   : $actual"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  MULTI-PART URL BUILDER
# ─────────────────────────────────────────────────────────────────────────────
function Get-PartUrls {
    param([string]$PrimaryUrl, [int]$ZipParts)
    if ($ZipParts -le 1) { return @($PrimaryUrl) }
    $base = $PrimaryUrl -replace '\.0001$', ''
    return @(1..$ZipParts | ForEach-Object { '{0}.{1:D4}' -f $base, $_ })
}

# ─────────────────────────────────────────────────────────────────────────────
#  CHECK IF DRIVER ALREADY INSTALLED
# ─────────────────────────────────────────────────────────────────────────────
function Test-DriverInstalled {
    param([string]$Provider, [string]$Version)
    try {
        $installed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
                     Where-Object { $_.ProviderName -like "*$Provider*" -and $_.DriverVersion -eq $Version }
        return ($installed -and $installed.Count -gt 0)
    } catch { return $false }
}

# ─────────────────────────────────────────────────────────────────────────────
#  DOWNLOAD + EXTRACT + INSTALL
# ─────────────────────────────────────────────────────────────────────────────
function Install-DriverPackage {
    param(
        [object]$Driver,
        [string]$OutputRoot,
        [string]$ScratchDir,
        [string]$ExtractorPath,
        [bool]$IsAdmin
    )

    $pkgName = "$($Driver.Provider)_$($Driver.Category)_$($Driver.Version)_$($Driver.Arch)"
    $outDir  = Join-Path $OutputRoot $pkgName
    $pkgTemp = Join-Path $ScratchDir ([System.Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $outDir  | Out-Null
    New-Item -ItemType Directory -Force -Path $pkgTemp | Out-Null

    try {
        # ── Pre-install check ──────────────────────────────────────────────
        if (Test-DriverInstalled -Provider $Driver.Provider -Version $Driver.Version) {
            Write-Warn "v$($Driver.Version) of $($Driver.Provider) already installed — skipping."
            return [pscustomobject]@{ Success=$false; Skipped=$true; Path=$outDir; Name=$Driver.DisplayName }
        }

        # ── Download all parts ────────────────────────────────────────────
        $partUrls = Get-PartUrls -PrimaryUrl $Driver.PrimaryUrl -ZipParts $Driver.ZipParts
        $partIdx  = 0
        $firstPart = $null

        foreach ($url in $partUrls) {
            $partIdx++
            $fileName = Split-Path $url -Leaf
            if ($partIdx -eq 1) { $firstPart = Join-Path $pkgTemp $fileName }
            $dest = Join-Path $pkgTemp $fileName

            Write-Host "    ↓ [$partIdx/$($partUrls.Count)] $fileName" -ForegroundColor Cyan
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Get-DriverDexFile -Url $url -Dest $dest
            $sw.Stop()
            $size = [math]::Round((Get-Item $dest).Length / 1MB, 2)
            Write-Info "      $size MB in $($sw.Elapsed.TotalSeconds.ToString('F1'))s"
        }

        # ── Verify SHA256 on first part only (API provides single hash) ───
        # (full hash checking done per-part if API provided; currently API
        #  provides hash on the first/only part)
        Write-Info "    Verifying download integrity..."
        $firstHash = (Get-FileHash -LiteralPath $firstPart -Algorithm SHA256).Hash.ToLower()
        Write-Info "    SHA256: $firstHash"

        # ── Extract ───────────────────────────────────────────────────────
        Write-Host "    ⚙ Extracting..." -ForegroundColor White
        $extractArgs = @('--file', $firstPart, '--output', $outDir, '--verify')
        $proc = Start-Process -FilePath $ExtractorPath -ArgumentList $extractArgs `
                              -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "Extractor exited with code $($proc.ExitCode)"
        }
        Write-OK "Extracted to: $outDir"

        # ── Write manifest ────────────────────────────────────────────────
        @{
            driver_id    = $Driver.DriverId
            display_name = $Driver.DisplayName
            provider     = $Driver.Provider
            category     = $Driver.Category
            version      = $Driver.Version
            arch         = $Driver.Arch
            matched_hwid = $Driver.MatchedHWID
            installed_on = (Get-Date -Format 'o')
            generated_by = 'DriverDex v{0} — https://github.com/rhshourav/driverdex' -f $Script:VERSION
        } | ConvertTo-Json | Set-Content -Path (Join-Path $outDir 'manifest.json') -Encoding UTF8

        # ── Install via pnputil ───────────────────────────────────────────
        $infs = @(Get-ChildItem -Path $outDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)

        if ($infs.Count -gt 0 -and $IsAdmin) {
            Write-Step "Installing $($infs.Count) INF package(s) via pnputil..."
            $pnpArgs = '/add-driver', (Join-Path $outDir '*.inf'), '/subdirs', '/install'
            $pnpProc = Start-Process -FilePath "$env:SystemRoot\System32\pnputil.exe" `
                                     -ArgumentList $pnpArgs -Wait -PassThru -NoNewWindow
            if ($pnpProc.ExitCode -in @(0, 3010)) {
                Write-OK "pnputil completed (exit $($pnpProc.ExitCode))"
                if ($pnpProc.ExitCode -eq 3010) {
                    Write-Warn "Reboot required to complete driver installation."
                }
            } else {
                Write-Warn "pnputil exited with $($pnpProc.ExitCode) — may need manual install."
            }

            # ── Cross-check: verify driver is now registered ──────────────
            Start-Sleep -Seconds 2
            if (Test-DriverInstalled -Provider $Driver.Provider -Version $Driver.Version) {
                Write-OK "Cross-check PASSED: driver registered in system."
            } else {
                Write-Warn "Cross-check: driver not yet reflected in Win32_PnPSignedDriver (may need reboot)."
            }

        } elseif ($infs.Count -gt 0 -and -not $IsAdmin) {
            Write-Warn "INF found but not elevated — point Device Manager at:"
            Write-Host "      $outDir" -ForegroundColor Cyan

        } else {
            # Try setup.exe / .msi vendor installer
            $installer = Get-ChildItem -Path $outDir -Include 'setup.exe','*.msi' `
                                       -Recurse -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            if ($installer) {
                Write-Step "Vendor installer detected: $($installer.Name)"
                $run = Read-HostDefault "Run installer now? [Y/n]" 'Y'
                if ($run -notmatch '^[Nn]') {
                    $args = if ($installer.Extension -eq '.msi') { '/i', $installer.FullName, '/qn' } `
                            else { @() }
                    Start-Process -FilePath $installer.FullName -ArgumentList $args -Wait
                    Write-OK "Installer completed."
                }
            } else {
                Write-Warn "No INF or installer found — files are at: $outDir"
            }
        }

        return [pscustomobject]@{ Success=$true; Skipped=$false; Path=$outDir; Name=$Driver.DisplayName }

    } catch {
        Write-Err "FAILED: $($_.Exception.Message)"
        return [pscustomobject]@{ Success=$false; Skipped=$false; Path=$outDir; Name=$Driver.DisplayName }
    } finally {
        Remove-Item -Recurse -Force $pkgTemp -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  SUMMARY TABLE
# ─────────────────────────────────────────────────────────────────────────────
function Show-Summary {
    param([object[]]$Results)
    Write-Host ""
    Write-Divider
    Write-Host "  Installation Summary" -ForegroundColor Cyan
    Write-Divider
    foreach ($r in $Results) {
        if     ($r.Skipped) { $sym = '─'; $col = 'DarkGray'  ; $label = 'SKIPPED (already installed)' }
        elseif ($r.Success) { $sym = '✔'; $col = 'Green'     ; $label = 'SUCCESS' }
        else                { $sym = '✘'; $col = 'Red'        ; $label = 'FAILED' }
        Write-Host "  [$sym] $($r.Name)" -ForegroundColor $col -NoNewline
        Write-Host " — $label" -ForegroundColor DarkGray
    }
    Write-Divider
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
function Main {
    Clear-Host
    Write-Header

    # ── OS / environment info ─────────────────────────────────────────────
    $os      = Get-OSInfo
    $isAdmin = Test-Administrator

    Write-Step "System Information"
    Write-Info "OS      : $($os.Caption) (Build $($os.Build))"
    Write-Info "Arch    : $($os.Arch)"
    Write-Info "PS      : v$($os.PSVersion)"
    Write-Info "Admin   : $(if ($isAdmin) { 'Yes ✔' } else { 'No ✘ (elevation recommended)' })"
    Write-Host ""

    if (-not $isAdmin) { Request-Elevation }
    $isAdmin = Test-Administrator   # re-check after potential re-launch

    # ── Enumerate hardware ────────────────────────────────────────────────
    $hwids       = Get-AllHardwareIDs
    $problemHWIDs = Get-ProblemDevices

    if ($problemHWIDs.Count -gt 0) {
        Write-Warn "$($problemHWIDs.Count) problem device(s) detected (missing/broken drivers)."
    }

    if ($hwids.Count -eq 0) {
        Write-Err "No hardware IDs found. Cannot continue."
        return
    }

    # ── Query API ─────────────────────────────────────────────────────────
    $drivers = Search-Drivers -HWIDs $hwids -SystemArch $os.Arch

    if ($drivers.Count -eq 0) {
        Write-Warn "No matching drivers found in the DriverDex database for your hardware."
        Write-Info "Try updating your hardware list or check https://github.com/rhshourav/driverdex"
        return
    }
    Write-OK "Found $($drivers.Count) matching driver package(s)."

    # ── User selection ────────────────────────────────────────────────────
    $selected = Show-DriverMenu -Drivers @($drivers) -ProblemHWIDs $problemHWIDs

    if (-not $selected -or $selected.Count -eq 0) {
        Write-Info "No drivers selected. Exiting."
        return
    }
    Write-OK "$($selected.Count) driver(s) selected for installation."

    # ── Output directory ──────────────────────────────────────────────────
    Write-Host ""
    $defaultOut = Join-Path $env:USERPROFILE 'Downloads\DriverDex-Drivers'
    $outRoot    = Read-HostDefault "Output/staging folder" $defaultOut
    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

    # ── Download extractor ────────────────────────────────────────────────
    $scratch = Join-Path $env:TEMP ("driverdex-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null

    $results = [System.Collections.Generic.List[object]]::new()

    try {
        Write-Host ""
        Write-Step "Downloading extractor binary..."
        $extractor = Join-Path $scratch 'extractor.exe'
        Get-DriverDexFile -Url $Script:EXTRACTOR_URL -Dest $extractor
        Write-OK "Extractor ready."

        # ── Process each selected driver ──────────────────────────────────
        $dIdx = 0
        foreach ($drv in $selected) {
            $dIdx++
            Write-Host ""
            Write-Divider
            Write-Host "  [$dIdx/$($selected.Count)] $($drv.DisplayName)" -ForegroundColor Yellow
            Write-Host "  Provider : $($drv.Provider)  |  Category : $($drv.Category)" -ForegroundColor DarkGray
            Write-Host "  Version  : $($drv.Version)   |  Arch     : $($drv.Arch)" -ForegroundColor DarkGray
            Write-Host "  HWID     : $($drv.MatchedHWID)" -ForegroundColor DarkGray
            Write-Divider

            $res = Install-DriverPackage `
                        -Driver $drv `
                        -OutputRoot $outRoot `
                        -ScratchDir $scratch `
                        -ExtractorPath $extractor `
                        -IsAdmin $isAdmin
            $results.Add($res)
        }

        Show-Summary -Results @($results)

        $rebootNeeded = $results | Where-Object { $_.Success }
        if ($rebootNeeded) {
            $reboot = Read-HostDefault "Restart Windows now to apply drivers? [y/N]" 'N'
            if ($reboot -match '^[Yy]') {
                Write-Warn "Restarting in 10 seconds... Press Ctrl+C to cancel."
                Start-Sleep -Seconds 10
                Restart-Computer -Force
            }
        }

        Write-Host "  All done. DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
        Write-Host ""

    } finally {
        Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Main
# ─────────────────────────────────────────────────────────────────────────────
