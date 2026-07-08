#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex — Automatic Hardware Driver Detector & Installer  v2.3.1
    Run via: irm https://your-url/DriverDex-Installer.ps1 | iex

.DESCRIPTION
    Scans all PnP hardware devices, queries the DriverDex REST API for matching
    drivers, lets the user review and select packages, then downloads (with
    real-time progress + SHA-256 verification), extracts, and installs via
    pnputil — all in a single self-contained file. Git LFS pointers are
    resolved transparently. Multi-part archives are reassembled automatically.

.NOTES
    Compatible : Windows 7 SP1 · 8.1 · 10 (incl. 1909/19H2) · 11  (x86 & x64)
    Bootstrap  : TLS 1.2+ is forced and PowerShell version is verified BEFORE any
                 network call, so `irm <url> | iex` works the same on old and new builds.
    Requires   : PowerShell 5.1+
    Elevation  : Recommended (auto-elevates on request)
    Author     : DriverDex — https://github.com/rhshourav/driverdex
#>

# Capture the caller's original preferences so that when this script is run
# via `irm <url> | iex` (which executes in the CALLER's scope, not a child
# scope like a saved .ps1 file would), we can restore them on exit instead of
# permanently changing the user's interactive shell.
$Script:__DDxPriorEAP      = $ErrorActionPreference
$Script:__DDxPriorProgress = $ProgressPreference

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ═════════════════════════════════════════════════════════════════════════════
#  COMPATIBILITY BOOTSTRAP — must run before ANY network call
# ═════════════════════════════════════════════════════════════════════════════
# Fixes "works on Windows 11 / newer 10 builds but fails on Windows 10 1909
# (19H2) and earlier when launched via `irm <url> | iex`":
#
#   1. #Requires is silently IGNORED when script text is piped into
#      Invoke-Expression (it only works for a saved .ps1 file launched
#      directly), so the PowerShell version is checked by hand below and the
#      script exits cleanly with a clear message instead of failing with a
#      confusing parser/runtime error partway through.
#
#   2. Older Windows builds (7 SP1 / 8.1 / 10 pre-2004) commonly have the
#      .NET Framework's default SecurityProtocol set to SSL3/TLS 1.0 only.
#      GitHub requires TLS 1.2+, so the very FIRST download below (the module
#      bootstrap) would fail with "Could not create SSL/TLS secure channel"
#      unless TLS 1.2 is forced here — doing it later inside Main() (as the
#      previous version did) is too late, since the modules are fetched
#      before Main() ever runs.
# ═════════════════════════════════════════════════════════════════════════════

$Script:__DDxPSVer = $PSVersionTable.PSVersion
if ($Script:__DDxPSVer.Major -lt 5 -or ($Script:__DDxPSVer.Major -eq 5 -and $Script:__DDxPSVer.Minor -lt 1)) {
    Write-Host ""
    Write-Host "  DriverDex requires PowerShell 5.1 or later." -ForegroundColor Red
    Write-Host "  Detected: PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Install Windows Management Framework 5.1, then try again:" -ForegroundColor Yellow
    Write-Host "  https://www.microsoft.com/download/details.aspx?id=54616" -ForegroundColor Cyan
    Write-Host ""
    return
}

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Host "  ⚠ Could not enable TLS 1.2 on this system — downloads below may fail." -ForegroundColor Yellow
        Write-Host "    Consider installing .NET Framework 4.7.2+ or the WMF 5.1 update." -ForegroundColor Yellow
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ENCODING SELF-HEAL (bootstrap-scope copy)
# ═══════════════════════════════════════════════════════════════════════════════
# Windows PowerShell 5.1 only recognizes a script file as UTF-8 automatically when
# a byte-order-mark (BOM) is present. Without one it falls back to the system's
# ANSI code page (commonly Windows-1252), which mangles this tool's box-drawing
# banners, em-dashes, and checkmarks — and some of those mangled bytes decode to
# Unicode "smart quotes" that PowerShell's tokenizer accepts as real string
# delimiters, silently closing a string mid-file and desyncing the parser for
# everything after it ("Unexpected token '}'" far from the real cause).
#
# This is a standalone copy (not a call into Utils.psm1's Repair-ScriptEncoding)
# because it has to run on every module file — including Utils.psm1 itself —
# BEFORE any module is imported, so Utils.psm1 isn't available to call yet.
# Utils.psm1 exports its own copy for use everywhere else in the codebase.
function Repair-DDxModuleEncoding {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch { return }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return  # already has a BOM
    }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)  # throw on invalid bytes
        [void]$strict.GetString($bytes)
    } catch {
        return  # not valid UTF-8 — leave it alone rather than risk corrupting it
    }
    try {
        $withBom = New-Object byte[] ($bytes.Length + 3)
        [Array]::Copy(([byte[]](0xEF,0xBB,0xBF)), 0, $withBom, 0, 3)
        [Array]::Copy($bytes, 0, $withBom, 3, $bytes.Length)
        [System.IO.File]::WriteAllBytes($Path, $withBom)
    } catch {}
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MODULE IMPORT
# ═══════════════════════════════════════════════════════════════════════════════

$Script:VERSION = '2.3.1'
$Script:GITHUB_RAW = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex'
$Script:ModulePath = $PSScriptRoot

if (-not $Script:ModulePath -or -not (Test-Path "$Script:ModulePath\Modules")) {
    $Script:ModulePath = Split-Path -Parent $PSCommandPath
}

# Ensure TEMP is always available
if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
    $candidates = @(
        $env:LOCALAPPDATA,
        $env:USERPROFILE,
        $env:SystemRoot,
        'C:\Temp'
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($candidates.Count -gt 0) {
        $env:TEMP = Join-Path $candidates[0] 'Temp'
    } else {
        $env:TEMP = Join-Path ([System.IO.Path]::GetTempPath()) 'DriverDex'
    }
    if (-not (Test-Path $env:TEMP)) {
        New-Item -ItemType Directory -Path $env:TEMP -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$modulesDir = if ($Script:ModulePath -and (Test-Path "$Script:ModulePath\Modules")) {
    Join-Path $Script:ModulePath 'Modules'
} else {
    # Running via irm|iex — download modules from GitHub into a temp directory
    $tempDir = Join-Path $env:TEMP ("driverdex-modules-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $modDir = Join-Path $tempDir 'Modules'
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null
    Write-Host "  Downloading DriverDex modules from GitHub..." -ForegroundColor Cyan
    $Script:__DDxBootstrapFailed = $false
    foreach ($mod in @('Utils','Formatting','UI','Drivers','Download','Install','Cache','Search')) {
        $url  = "$Script:GITHUB_RAW/Modules/$mod.psm1"
        $dest = Join-Path $modDir "$mod.psm1"

        $lastError = $null
        $ok = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                $ok = $true
                break
            } catch {
                $lastError = $_
                if ($attempt -lt 3) { Start-Sleep -Milliseconds (500 * $attempt) }
            }
        }

        if (-not $ok) {
            Write-Host "  ✘ Failed to download module '$mod.psm1' after 3 attempts: $($lastError.Exception.Message)" -ForegroundColor Red
            Write-Host "    This is usually caused by one of:" -ForegroundColor Yellow
            Write-Host "      • No internet connection, or a proxy/firewall blocking raw.githubusercontent.com" -ForegroundColor Yellow
            Write-Host "      • TLS 1.2 unavailable on this system (see .NOTES in the script header for a fix)" -ForegroundColor Yellow
            Write-Host "      • GitHub is temporarily unreachable — try again in a moment" -ForegroundColor Yellow
            $Script:__DDxBootstrapFailed = $true
            break
        }
    }

    if ($Script:__DDxBootstrapFailed) {
        # 'return' (not 'exit') so a script run via `irm <url> | iex` doesn't
        # close the user's whole PowerShell window/session — it just stops here.
        return
    }

    Write-Host "  ✅ Modules downloaded." -ForegroundColor Green
    $modDir
}


# Import all modules
$Script:__DDxImportFailed = $false
foreach ($mod in @('Utils','Formatting','UI','Drivers','Download','Install','Cache','Search')) {
    $modPath = Join-Path $modulesDir "$mod.psm1"
    if (Test-Path $modPath) {
        Repair-DDxModuleEncoding -Path $modPath
        Import-Module $modPath -Force -DisableNameChecking -ErrorAction Stop
    } else {
        Write-Host "  ✘ Required module '$mod.psm1' not found at: $modPath" -ForegroundColor Red
        Write-Host "  Ensure the Modules/ folder is in the same directory as DriverDex.ps1" -ForegroundColor Yellow
        $Script:__DDxImportFailed = $true
        break
    }
}
if ($Script:__DDxImportFailed) {
    # Same reasoning as above: never use 'exit' in code that may run via iex.
    return
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SEARCH ENGINE — Standalone search, download, and install menu
# ═══════════════════════════════════════════════════════════════════════════════

function Set-BlackBackground {
    <#
    .SYNOPSIS Forces the terminal background to black for the Search Engine UI.
    #>
    param([switch]$Restore)
    if (-not $Restore) {
        try {
            $Host.UI.RawUI.BackgroundColor = [System.ConsoleColor]::Black
            $Host.UI.RawUI.ForegroundColor = [System.ConsoleColor]::White
            Clear-Host
        } catch { <# non-fatal #> }
    } else {
        try {
            $Host.UI.RawUI.BackgroundColor = [System.ConsoleColor]::Black
        } catch {}
    }
}

function Invoke-SearchEngine {
    <#
    .SYNOPSIS Entry point for the DriverDex Search Engine.
    .PARAMETER IsAdmin     Whether the session is elevated
    .PARAMETER ScratchDir  Temp directory for staging downloads
    #>
    param([bool]$IsAdmin, [string]$ScratchDir)

    Set-BlackBackground
    Write-SearchBanner

    # ── Output folder ───────────────────────────────────────────────────
    $defaultOut = Join-Path $env:USERPROFILE 'Downloads\DriverDex'
    $outRoot    = Read-Input -Prompt 'Save drivers to' -Default $defaultOut `
                      -Validator { param($v) $v.Length -gt 0 } -ErrMsg 'Path cannot be empty.'
    try {
        New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
        Write-OK "Output folder: $outRoot"
    } catch {
        Write-Err -What "Cannot create output folder" -Reason $_.Exception.Message -Fix "Choose a different path."
        $outRoot = $env:TEMP
    }

    # ── Ensure extractor ────────────────────────────────────────────────
    $extractor = Join-Path $ScratchDir 'extractor.exe'
    if (-not (Test-Path $extractor)) {
        Write-Step "Downloading extractor utility..."
        try {
            Get-DriverFile -Url (Get-ExtractorUrl) -Dest $extractor -Label 'extractor.exe'
            Write-OK "Extractor ready."
        } catch {
            Write-Warn "Extractor download failed — install mode will be unavailable."
            $extractor = $null
        }
    }

    # ── Session state ───────────────────────────────────────────────────
    $currentResults = @()
    $currentPage    = 1
    $pageSize       = 25
    $currentQuery   = ''
    $filterArch     = ''
    $filterCategory = ''

    Write-Host ""
    Write-Host "  Type a search query to find drivers. Type 'help' for usage." -ForegroundColor DarkGray
    Write-Host ""

    # ── Main search REPL ────────────────────────────────────────────────
    while ($true) {
        $filterStr  = ''
        if ($filterArch)     { $filterStr += " [arch:$filterArch]" }
        if ($filterCategory) { $filterStr += " [cat:$filterCategory]" }
        $promptText = "Search$filterStr"

        Write-Host "  ▸ $promptText" -ForegroundColor White -NoNewline
        Write-Host " > " -ForegroundColor DarkCyan -NoNewline
        $userInput = $Host.UI.ReadLine()
        if ($null -eq $userInput) { break }
        $userInput = $userInput.Trim()
        if (-not $userInput) { continue }

        try {
        switch -Regex ($userInput.ToLower()) {

            '^(back|q|quit|exit)$' {
                Write-Host ""
                Write-Host "  Returning to main menu..." -ForegroundColor DarkGray
                Set-BlackBackground -Restore
                return
            }

            '^help$' {
                Show-SearchHelp
                continue
            }

            '^clear$' {
                $filterArch = ''; $filterCategory = ''
                Write-OK "Filters cleared."
                continue
            }

            '^filter$' {
                Write-Host "  Arch filter  (x64/x86/any, blank=all) > " -ForegroundColor White -NoNewline
                $fa = $Host.UI.ReadLine()
                Write-Host "  Category filter (audio/network/display/storage/bluetooth/chipset, blank=all) > " -ForegroundColor White -NoNewline
                $fc = $Host.UI.ReadLine()
                $filterArch     = $fa.Trim().ToLower()
                $filterCategory = $fc.Trim().ToLower()
                Write-OK "Filter set: arch='$filterArch'  category='$filterCategory'"
                if ($currentQuery) {
                    Write-Step "Re-searching '$currentQuery' with new filters..."
                    $currentResults = @(Invoke-WeightedSearch -Query $currentQuery -Arch $filterArch -Category $filterCategory)
                    $currentPage    = 1
                    if (@($currentResults).Count -gt 0) {
                        $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                        $currentPage = $pageState.Page
                    } else {
                        Write-Warn "No results with current filters."
                    }
                }
                continue
            }

            '^n(ext)?$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results. Run a search first."; continue }
                $currentPage++
                $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^p(rev)?$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results. Run a search first."; continue }
                $currentPage = [Math]::Max(1, $currentPage - 1)
                $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^first$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results."; continue }
                $currentPage = 1
                $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^last$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results."; continue }
                $totalPages = [Math]::Ceiling(@($currentResults).Count / $pageSize)
                $currentPage = $totalPages
                $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^(g|page)\s*(\d+)$' {
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results."; continue }
                $currentPage = [int]($Matches[2])
                $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                continue
            }

            '^det\s*(\d+)$' {
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    Show-DriverDetail -Item $currentResults[$idx]
                } else { Write-Warn "Invalid result number." }
                continue
            }

            '^d\s*(\d+)$' {
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    $item = $currentResults[$idx]
                    Show-DriverDetail -Item $item
                    Write-Step "Downloading: $($item.DisplayName)"
                    if (-not $extractor) { Write-Warn "Extractor unavailable — download will be raw parts only."; continue }
                    Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                         -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'download'
                } else { Write-Warn "Invalid result number. Valid range: 1–$(@($currentResults).Count)" }
                continue
            }

            '^i\s*(\d+)$' {
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    $item = $currentResults[$idx]
                    Show-DriverDetail -Item $item
                    if (-not $IsAdmin) {
                        Write-Warn "Not running as Administrator. Driver install may require elevation."
                    }
                    $confirm = Read-Input -Prompt "Download and INSTALL '$($item.DisplayName)'?" -Default 'Y' `
                                   -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Y or N'
                    if ($confirm -match '^[Yy]') {
                        if (-not $extractor) { Write-Err -What "Extractor not available" -Reason "Download failed earlier" -Fix "Check internet and retry."; continue }
                        Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                             -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'install'
                    }
                } else { Write-Warn "Invalid result number. Valid range: 1–$(@($currentResults).Count)" }
                continue
            }

            '^(\d+)$' {
                $idx = [int]($Matches[1]) - 1
                if ($idx -ge 0 -and $idx -lt @($currentResults).Count) {
                    $item = $currentResults[$idx]
                    Show-DriverDetail -Item $item
                    Write-Host "  What would you like to do?" -ForegroundColor White
                    Write-Host "   [d] Download only     [i] Download + Install     [x] Cancel" -ForegroundColor DarkGray
                    Write-Host "  > " -ForegroundColor DarkCyan -NoNewline
                    $act = $Host.UI.ReadLine()
                    if ($act -match '^[Dd]') {
                        if (-not $extractor) { Write-Warn "Extractor unavailable."; continue }
                        Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                             -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'download'
                    } elseif ($act -match '^[Ii]') {
                        if (-not $extractor) { Write-Err -What "Extractor not available" -Reason "Earlier download failed" -Fix "Retry."; continue }
                        if (-not $IsAdmin) { Write-Warn "Not elevated — install may be incomplete." }
                        Invoke-SearchDownload -Item $item -OutRoot $outRoot -ScratchDir $ScratchDir `
                                             -Extractor $extractor -IsAdmin $IsAdmin -InstallMode 'install'
                    }
                } else { Write-Warn "Invalid result number. Valid range: 1–$(@($currentResults).Count)" }
                continue
            }

            '^(new|s )(.+)$' {
                $query = $userInput -replace '^(new|s)\s+', ''
                $currentQuery   = $query
                $currentPage    = 1
                $currentResults = @()
                Write-Host ""
                Write-Step "Searching for '$query'..."
                $Script:SpinIdx = 0
                Show-Spinner -Label "Querying DriverDex..."
                $currentResults = @(Invoke-WeightedSearch -Query $query -Arch $filterArch -Category $filterCategory)
                Clear-SpinnerLine
                if (@($currentResults).Count -gt 0) {
                    $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                    $currentPage = $pageState.Page
                    Write-Host ""
                    Write-Host "  Use d<N> to download, i<N> to install, det<N> for details, n/p to page." -ForegroundColor DarkGray
                } else {
                    Write-Warn "No drivers found for '$query'. Try a different keyword."
                    Write-Info "Examples: 'realtek audio', 'intel wifi', 'PCI\\VEN_8086&DEV_1234'"
                }
                continue
            }

            '^sort:(name|provider|version|date|score|arch|category)$' {
                $sortField = $Matches[1]
                if (@($currentResults).Count -eq 0) { Write-Warn "No search results to sort."; continue }
                $currentResults = @(Sort-SearchResults -Results $currentResults -SortBy $sortField)
                $currentPage = 1
                $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                $currentPage = $pageState.Page
                Write-OK "Sorted by $sortField"
                continue
            }

            default {
                # Treat anything else as a new search query (supports filters inline)
                $query          = $userInput
                $currentQuery   = $query
                $currentPage    = 1
                $currentResults = @()
                Write-Host ""
                Write-Step "Searching for '$query'..."
                $Script:SpinIdx = 0
                Show-Spinner -Label "Querying DriverDex..."
                $currentResults = @(Invoke-WeightedSearch -Query $query -Arch $filterArch -Category $filterCategory)
                Clear-SpinnerLine
                if (@($currentResults).Count -gt 0) {
                    $pageState = Show-SearchTable -Results $currentResults -Page $currentPage -PageSize $pageSize
                    $currentPage = $pageState.Page
                    Write-Host ""
                    Write-Host "  Use d<N> to download, i<N> to install, det<N> for details, n/p to page." -ForegroundColor DarkGray
                } else {
                    Write-Warn "No drivers found for '$query'. Try a different keyword or HWID."
                    Write-Info "Examples: 'realtek audio', 'intel wifi', 'nvidia gpu'"
                    Write-Info "Filters: 'intel arch:x64', 'wifi provider:intel', 'usb category:system'"
                    Write-Info "Sort: 'sort:name', 'sort:provider', 'sort:score'"
                    Write-Info "Type 'help' for full command reference."
                }
                continue
            }
        }
        } catch {
            Write-Err -What "Command '$userInput' failed unexpectedly." `
                      -Reason $_.Exception.Message `
                      -Fix "Try again, or type 'help' for the command list."
            continue
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CONTRIBUTION PROMPT
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-ContributePrompt {
    <#
    .SYNOPSIS Invites the user to contribute their driver data to the DriverDex community database.
    #>
    param(
        [string[]]$HWIDs,
        [string]  $Reason = 'no_drivers',
        [object[]]$UnmatchedLocalDrivers = @()
    )

    $w = 66
    $top = '╔' + ('═' * ($w - 2)) + '╗'
    $bot = '╚' + ('═' * ($w - 2)) + '╝'
    $mid = { param($s) "  ║  $($s.PadRight($w - 6))  ║" }

    Write-Host ""
    Write-Host "  $top" -ForegroundColor Magenta

    if ($Reason -eq 'no_drivers') {
        Write-Host (& $mid "  DriverDex has no drivers for your hardware — yet.") -ForegroundColor White
    } elseif (@($UnmatchedLocalDrivers).Count -gt 0) {
        Write-Host (& $mid "  $(@($UnmatchedLocalDrivers).Count) working driver(s) on this PC aren't in our database.") -ForegroundColor White
    } else {
        Write-Host (& $mid "  Some of your devices aren't in the DriverDex database yet.") -ForegroundColor White
    }
    Write-Host (& $mid "") -ForegroundColor Magenta
    Write-Host (& $mid "  You can change that.") -ForegroundColor Cyan
    Write-Host (& $mid "") -ForegroundColor Magenta
    Write-Host "  $bot" -ForegroundColor Magenta
    Write-Host ""

    Write-Host "  DriverDex is 100% community-driven." -ForegroundColor White
    Write-Host "  Every hardware profile submitted makes the database smarter" -ForegroundColor DarkGray
    Write-Host "  for the next person with the same machine." -ForegroundColor DarkGray
    Write-Host ""

    if (@($UnmatchedLocalDrivers).Count -gt 0) {
        Write-Host "  Here's the thing: these drivers already work, right now, on" -ForegroundColor White
        Write-Host "  YOUR machine. Nobody has to write anything new — we just need" -ForegroundColor DarkGray
        Write-Host "  a copy of what Windows already installed." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Specifically, these devices have NO entry in DriverDex at all:" -ForegroundColor Cyan
        $shown = @($UnmatchedLocalDrivers | Select-Object -First 6)
        foreach ($u in $shown) {
            $dn = if ($u.DeviceName) { $u.DeviceName } else { $u.HWID }
            $vr = if ($u.Version)    { "v$($u.Version)" } else { 'version unknown' }
            Write-Host "    · $dn  ($vr)" -ForegroundColor White
        }
        if (@($UnmatchedLocalDrivers).Count -gt 6) {
            Write-Host "    · ... and $(@($UnmatchedLocalDrivers).Count - 6) more" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-Host "  Contributing takes under a minute and requires no account." -ForegroundColor White
    Write-Host ""

    Write-Host "  What the contribution tool collects:" -ForegroundColor Cyan
    Write-Host "    ✔  Hardware IDs (PCI\VEN_..., USB\VID_... strings)" -ForegroundColor Green
    Write-Host "    ✔  Device categories and friendly names from Windows" -ForegroundColor Green
    Write-Host "    ✔  Currently installed driver versions (Provider, Version, Date)" -ForegroundColor Green
    Write-Host "    ✔  Windows version and architecture (to flag driver compatibility)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  What it does NOT collect:" -ForegroundColor Yellow
    Write-Host "    ✘  Your name, username, or any account information" -ForegroundColor DarkGray
    Write-Host "    ✘  IP address or location (submissions are anonymised server-side)" -ForegroundColor DarkGray
    Write-Host "    ✘  Files, documents, browsing data, or anything personal" -ForegroundColor DarkGray
    Write-Host "    ✘  Serial numbers, MAC addresses, or unique device identifiers" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Submissions are reviewed by maintainers before entering the database." -ForegroundColor DarkGray
    Write-Host "  https://github.com/rhshourav/driverdex/blob/main/PRIVACY.md" -ForegroundColor Cyan
    Write-Host ""

    if (@($UnmatchedLocalDrivers).Count -eq 0) {
        Write-Host "  Preview — hardware IDs that would be submitted from this machine:" -ForegroundColor White
        $preview = @($HWIDs | Select-Object -First 6)
        foreach ($id in $preview) {
            Write-Host "    · $id" -ForegroundColor DarkGray
        }
        if (@($HWIDs).Count -gt 6) {
            Write-Host "    · ... and $(@($HWIDs).Count - 6) more hardware ID(s)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    $contrib = Read-Input `
        -Prompt  'Contribute your hardware profile to the DriverDex community?' `
        -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } `
        -ErrMsg  'Enter Y or N.'

    if ($contrib -notmatch '^[Yy]') {
        Write-Info "No problem — you can always contribute later by re-running this script."
        Write-Info "Or visit: https://github.com/rhshourav/driverdex"
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "  Thank you! You're helping build something genuinely useful" -ForegroundColor Green
    Write-Host "  for everyone who has the same hardware as you." -ForegroundColor Green
    Write-Host ""

    Write-Divider
    Write-Host "  How would you like to run the contribution tool?" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1]  TUI mode    — interactive, step-by-step walkthrough" -ForegroundColor Cyan
    Write-Host "  [2]  Background  — silent, zero-click, runs in under 30 seconds" -ForegroundColor Cyan
    Write-Host ""

    $mode = Read-Input `
        -Prompt  'Choose contribution mode' `
        -Default '1' `
        -Validator { param($v) $v -match '^[12]$' } `
        -ErrMsg  'Enter 1 (TUI) or 2 (Background).'

    Write-Host ""

    if ($mode -eq '1') {
        Write-Step "Launching DriverDex Contribution Tool (TUI)..."
        try {
            Invoke-Expression (Invoke-RestMethod `
                'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/run.ps1')
        } catch {
            Write-Err -What "Could not launch the TUI contribution tool." `
                      -Reason $_.Exception.Message `
                      -Fix    "Run manually: irm https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/run.ps1 | iex"
        }
    } else {
        Write-Step "Launching DriverDex Contribution Tool (Background)..."
        try {
            Invoke-Expression (Invoke-RestMethod `
                'https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/bg/run_bg.ps1')
        } catch {
            Write-Err -What "Could not launch the background contribution tool." `
                      -Reason $_.Exception.Message `
                      -Fix    "Run manually: irm https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/bg/run_bg.ps1 | iex"
        }
    }

    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  FORCE WINDOWS UPDATE
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-ForceWindowsUpdate {
    <#
    .SYNOPSIS Forces Windows Update: installs PSWindowsUpdate if needed, scans
              for all pending patches + optional driver updates, applies them.
    #>
    param([bool]$IsAdmin)

    Write-Host ""
    Write-Divider
    Write-Host "  ▸ Force Windows Update" -ForegroundColor Magenta
    Write-Divider
    Write-Host ""

    if (-not $IsAdmin) {
        Write-Warn "Windows Update installation requires Administrator rights."
        Write-Info "Please re-run DriverDex as Administrator to use this feature."
        Write-Host ""
        return
    }

    $w = 66
    Write-Host "  ╔$('═' * ($w - 2))╗" -ForegroundColor DarkCyan
    Write-Host "  ║  This option will:$(' ' * ($w - 21))║" -ForegroundColor White
    Write-Host "  ║    • Scan for ALL pending Windows Updates$(' ' * ($w - 44))║" -ForegroundColor DarkGray
    Write-Host "  ║    • Include optional Microsoft driver updates$(' ' * ($w - 49))║" -ForegroundColor DarkGray
    Write-Host "  ║    • Download and install everything found$(' ' * ($w - 44))║" -ForegroundColor DarkGray
    Write-Host "  ║    • Prompt for reboot if required$(' ' * ($w - 37))║" -ForegroundColor DarkGray
    Write-Host "  ╚$('═' * ($w - 2))╝" -ForegroundColor DarkCyan
    Write-Host ""

    $confirm = Read-Input -Prompt 'Proceed with Force Windows Update?' -Default 'Y' `
        -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Enter Y or N.'
    if ($confirm -notmatch '^[Yy]') {
        Write-Info "Windows Update skipped."
        Write-Host ""
        return
    }

    Write-Host ""

    # Strategy 1: PSWindowsUpdate module
    $moduleAvailable = $false
    if (Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue) {
        $moduleAvailable = $true
        Write-OK "PSWindowsUpdate module already installed."
    } else {
        Write-Step "PSWindowsUpdate module not found — attempting to install from PSGallery..."
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Write-Sub "Installing NuGet provider..."
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            }
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser `
                           -AllowClobber -ErrorAction Stop
            $moduleAvailable = $true
            Write-OK "PSWindowsUpdate installed successfully."
        } catch {
            Write-Warn "Could not install PSWindowsUpdate: $($_.Exception.Message)"
            Write-Info "Falling back to native Windows Update client..."
            Write-Log -Level WARN -Msg "PSWindowsUpdate install failed: $($_.Exception.Message)"
        }
    }

    if ($moduleAvailable) {
        try {
            Import-Module PSWindowsUpdate -ErrorAction Stop

            Write-Step "Scanning for available Windows Updates (including drivers)..."
            $Script:SpinIdx = 0
            Show-Spinner -Label "Checking Windows Update servers..."

            $updates = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot `
                                         -ErrorAction Stop
            Clear-SpinnerLine

            if (-not $updates -or @($updates).Count -eq 0) {
                Write-OK "Your system is fully up to date. No pending updates found."
                Write-Host ""
                return
            }

            Write-OK "Found $(@($updates).Count) pending update(s):"
            Write-Host ""
            foreach ($u in $updates) {
                $kb   = if ($u.KBArticleIDs) { " [KB$($u.KBArticleIDs -join ',KB')]" } else { '' }
                $size = if ($u.Size -gt 0) { " ($([Math]::Round($u.Size / 1MB, 1)) MB)" } else { '' }
                Write-Host "  ·  $($u.Title)$kb$size" -ForegroundColor Cyan
            }
            Write-Host ""

            $install = Read-Input -Prompt "Install all $(@($updates).Count) update(s) now?" `
                -Default 'Y' -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Y or N.'
            if ($install -notmatch '^[Yy]') {
                Write-Info "Update installation cancelled by user."
                Write-Host ""
                return
            }

            Write-Step "Installing updates — this may take a while..."
            Write-Host ""
            $results = Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot `
                                              -Verbose -ErrorAction Stop

            $rebootNeeded = $false
            foreach ($r in $results) {
                $status = if ($r.Result -eq 2) { '✔ Installed' }
                          elseif ($r.Result -eq 3) { '⟳ Reboot required' }
                          elseif ($r.Result -eq 4) { '✘ Failed' }
                          else                      { "  Result: $($r.Result)" }
                $col = switch ($r.Result) {
                    2 { 'Green' }; 3 { 'Yellow' }; 4 { 'Red' }; default { 'DarkGray' }
                }
                Write-Host "  $status  ·  $($r.Title)" -ForegroundColor $col
                if ($r.Result -eq 3) { $rebootNeeded = $true }
            }
            Write-Host ""

            if ($rebootNeeded) {
                Write-Warn "One or more updates require a reboot to complete installation."
                Write-Host ""
                $rb = Read-Input -Prompt 'Restart now?' -Default 'N' `
                    -Validator { param($v) $v -match '^[YyNn]$' } -ErrMsg 'Y or N.'
                if ($rb -match '^[Yy]') {
                    Write-Warn "Restarting in 10 seconds... Press Ctrl+C to cancel."
                    for ($i = 10; $i -ge 1; $i--) {
                        Write-Host "`r    $i second(s) remaining...  " -NoNewline -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                    Write-Host ""
                    Restart-Computer -Force
                }
            } else {
                Write-OK "All updates installed successfully. No reboot required."
            }

        } catch {
            Write-Err -What "PSWindowsUpdate encountered an error." `
                      -Reason $_.Exception.Message `
                      -Fix    "Check the log for details or try again." `
                      -Err    $_
            Write-Info "Attempting native WU client fallback..."
            $moduleAvailable = $false
        }
    }

    # Strategy 2: Native WU clients
    if (-not $moduleAvailable) {
        Write-Step "Using native Windows Update client..."
        Write-Host ""

        $usoPath    = "$env:SystemRoot\System32\UsoClient.exe"
        $wuauclt    = "$env:SystemRoot\System32\wuauclt.exe"
        $triggered  = $false

        if (Test-Path $usoPath) {
            Write-Sub "Triggering scan via UsoClient (Windows 10/11)..."
            try {
                & $usoPath StartScan           2>$null
                Start-Sleep -Seconds 3
                & $usoPath StartDownload       2>$null
                Start-Sleep -Seconds 3
                & $usoPath StartInstall        2>$null
                $triggered = $true
                Write-OK "UsoClient: scan, download & install triggered."
            } catch {
                Write-Warn "UsoClient call failed: $($_.Exception.Message)"
            }
        }

        if (-not $triggered -and (Test-Path $wuauclt)) {
            Write-Sub "Triggering scan via wuauclt (Windows 7/8)..."
            try {
                & $wuauclt /detectnow         2>$null
                Start-Sleep -Seconds 3
                & $wuauclt /updatenow         2>$null
                $triggered = $true
                Write-OK "wuauclt: detect + update triggered."
            } catch {
                Write-Warn "wuauclt call failed: $($_.Exception.Message)"
            }
        }

        if (-not $triggered) {
            Write-Err -What "Could not trigger Windows Update." `
                      -Reason "Neither UsoClient nor wuauclt found at expected paths." `
                      -Fix    "Open Windows Settings → Windows Update → Check for updates."
            Write-Host ""
            return
        }

        Write-Host ""
        Write-Host "  ℹ  Windows Update is now running in the background." -ForegroundColor Cyan
        Write-Host "     Updates will download and install automatically." -ForegroundColor DarkGray
        Write-Host "     You can monitor progress in Settings → Windows Update." -ForegroundColor DarkGray
        Write-Host ""
    }

    Write-Host ""
    Write-Log -Level INFO -Msg "Force Windows Update completed. ModuleUsed=$moduleAvailable"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  OFFLINE PACKAGER
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-OfflinePackager {
    <#
    .SYNOPSIS Reads an inventory.json from an air-gapped machine, downloads matching
    drivers, and builds a self-contained offline driver bundle with an installer.
    #>

    Write-Host ""
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor DarkYellow
    Write-Host "  |  OFFLINE PACKAGER                                            |" -ForegroundColor Yellow
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  This tool builds an offline driver bundle for an air-gapped PC." -ForegroundColor DarkGray
    Write-Host ""

    # ── Step 1: Choose workflow ─────────────────────────────────────────
    Write-Host "  How would you like to proceed?" -ForegroundColor White
    Write-Host ""
    Write-Host "    [1]  I already have inventory.json" -ForegroundColor Cyan
    Write-Host "         Provide the path to your inventory.json file" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    [2]  Prepare a USB for an air-gapped PC" -ForegroundColor Cyan
    Write-Host "         Copy scanner files to USB, get instructions," -ForegroundColor DarkGray
    Write-Host "         then come back with the inventory.json" -ForegroundColor DarkGray
    Write-Host ""

    $workflow = Read-Input -Prompt 'Select option' -Default '1' `
        -Validator { param($v) $v -match '^[12]$' } `
        -ErrMsg    'Enter 1 or 2.'

    # ── Option 2: USB preparation flow ──────────────────────────────────
    if ($workflow -eq '2') {
        Write-Host ""
        Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |  USB PREPARATION                                             |" -ForegroundColor Cyan
        Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Plug in your USB drive now." -ForegroundColor White
        Write-Host "  I will scan for it with a 25-second countdown." -ForegroundColor DarkGray
        Write-Host "  You can press any key to skip waiting." -ForegroundColor DarkGray
        Write-Host ""

        # ── Countdown with early skip and live USB detection ────────────
        $usbDrives = @()
        $countdown = 25
        $skipCountdown = $false

        while ($countdown -gt 0) {
            # Check for USB drives
            $usbDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue |
                           Where-Object { $_.DeviceID })

            # If USB detected, skip countdown
            if (@($usbDrives).Count -gt 0) {
                Write-Host ""
                Write-Host "  [+] USB drive(s) detected!" -ForegroundColor Green
                break
            }

            # Show countdown
            Write-Host "`r  Scanning... $countdown seconds remaining " -NoNewline -ForegroundColor DarkGray

            # Check for keypress (non-blocking)
            if ($Host.UI.RawUI.KeyAvailable) {
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                $skipCountdown = $true
                break
            }

            Start-Sleep -Seconds 1
            $countdown--
        }

        Write-Host "`r$(' ' * 60)`r" -NoNewline

        # ── If no USB detected after countdown ──────────────────────────
        if (@($usbDrives).Count -eq 0) {
            Write-Host ""
            Write-Warn "No USB drives detected."
            Write-Host ""
            Write-Host "  You can:" -ForegroundColor White
            Write-Host "    [1]  Plug in a USB and retry detection" -ForegroundColor Cyan
            Write-Host "    [2]  Save scanner files to a folder on this PC" -ForegroundColor Cyan
            Write-Host "    [3]  Go back and provide inventory.json directly" -ForegroundColor Cyan
            Write-Host ""

            $fallback = Read-Input -Prompt 'Select option' -Default '1' `
                -Validator { param($v) $v -match '^[123]$' } `
                -ErrMsg    'Enter 1, 2, or 3.'

            if ($fallback -eq '3') {
                # Go back to main prompt
                Write-Host ""
            } elseif ($fallback -eq '2') {
                # Save to any folder
                Write-Host ""
                $savePath = Read-Input -Prompt 'Folder to save scanner files' `
                    -Default (Join-Path $env:USERPROFILE 'Documents') `
                    -Validator { param($v) $v -match '^[A-Za-z]:\\' } `
                    -ErrMsg    'Enter a valid folder path like C:\Users\You\Documents'

                if (-not (Test-Path $savePath)) {
                    try {
                        New-Item -ItemType Directory -Path $savePath -Force | Out-Null
                    } catch {
                        Write-Err -What "Cannot create folder" `
                                  -Reason $_.Exception.Message `
                                  -Fix    "Choose a different location."
                        return
                    }
                }

                $scanSource = Join-Path $PSScriptRoot 'offline-packager'
                $scanDest   = Join-Path $savePath 'DriverDex-Scanner'

                Write-Step "Copying scanner files to $scanDest..."
                try {
                    New-Item -ItemType Directory -Path $scanDest -Force | Out-Null
                    if (Test-Path (Join-Path $scanSource 'scan.cmd')) {
                        Copy-Item -Path (Join-Path $scanSource 'scan.cmd')  -Destination $scanDest -Force
                        Copy-Item -Path (Join-Path $scanSource 'scan.ps1')  -Destination $scanDest -Force
                    } else {
                        $githubBase = "$Script:GITHUB_RAW/offline-packager"
                        Invoke-WebRequest -Uri "$githubBase/scan.cmd" -OutFile (Join-Path $scanDest 'scan.cmd') -UseBasicParsing
                        Invoke-WebRequest -Uri "$githubBase/scan.ps1" -OutFile (Join-Path $scanDest 'scan.ps1') -UseBasicParsing
                    }
                    # scan.ps1 runs unattended on the (possibly air-gapped) target PC — this
                    # script won't be there to fix it later, so fix it now, before handoff.
                    Repair-ScriptEncoding -Path (Join-Path $scanDest 'scan.ps1') | Out-Null
                    Write-OK "Scanner files saved to: $scanDest"
                } catch {
                    Write-Err -What "Failed to copy scanner files" `
                              -Reason $_.Exception.Message `
                              -Fix    "Check that the folder is writable."
                    return
                }

                # Show instructions for local save
                Write-Host ""
                Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
                Write-Host "  |  INSTRUCTIONS                                                |" -ForegroundColor Green
                Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
                Write-Host ""
                Write-Host "  Copy the DriverDex-Scanner folder to the air-gapped PC." -ForegroundColor White
                Write-Host "  (Use a USB drive, network share, or any transfer method)" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  Then on the air-gapped PC:" -ForegroundColor White
                Write-Host "    1. Open the DriverDex-Scanner folder" -ForegroundColor DarkGray
                Write-Host "    2. Double-click scan.cmd" -ForegroundColor DarkGray
                Write-Host "    3. Wait for inventory.json to be created" -ForegroundColor DarkGray
                Write-Host "    4. Bring inventory.json back here" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
                Write-Host ""
                Write-Host "  Press Enter when you have the inventory.json ready..." -ForegroundColor DarkGray
                $null = Read-Host
            } else {
                # Retry USB detection
                Write-Host ""
                Write-Step "Re-scanning for USB drives..."
                Start-Sleep -Seconds 2
                $usbDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue |
                               Where-Object { $_.DeviceID })

                if (@($usbDrives).Count -eq 0) {
                    Write-Warn "Still no USB drives detected."
                    Write-Host "  Choose option 2 (save to folder) or option 3 (provide path) instead." -ForegroundColor DarkGray
                    Write-Host ""
                }
            }
        }

        # ── If USB detected, let user choose which one ──────────────────
        if (@($usbDrives).Count -gt 0) {
            Write-Host ""
            if (@($usbDrives).Count -eq 1) {
                $d = $usbDrives[0]
                $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                Write-Host "  Found: $($d.DeviceID) $($d.VolumeName)  (${freeGB} GB free)" -ForegroundColor Green
                $targetRoot = $d.DeviceID
                if (-not $targetRoot.EndsWith('\')) { $targetRoot += '\' }
            } else {
                Write-Host "  Detected USB drive(s):" -ForegroundColor Green
                for ($i = 0; $i -lt @($usbDrives).Count; $i++) {
                    $d = $usbDrives[$i]
                    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                    Write-Host "    [$($i+1)] $($d.DeviceID) $($d.VolumeName)  (${freeGB} GB free)" -ForegroundColor White
                }
                Write-Host "    [0]  Enter path manually" -ForegroundColor DarkGray
                Write-Host ""

                $driveChoice = Read-Input -Prompt 'Select USB drive' -Default '1' `
                    -Validator { param($v) $v -match '^\d+$' -and [int]$v -le @($usbDrives).Count } `
                    -ErrMsg    'Enter a valid drive number.'

                if ($driveChoice -eq '0') {
                    $targetRoot = Read-Input -Prompt 'Enter path (e.g. E:\)' `
                        -Validator { param($v) $v -match '^[A-Za-z]:\\?$' -and (Test-Path $v) } `
                        -ErrMsg    'Enter a valid path like E:\'
                } else {
                    $targetRoot = $usbDrives[[int]$driveChoice - 1].DeviceID
                    if (-not $targetRoot.EndsWith('\')) { $targetRoot += '\' }
                }
            }

            # Copy scanner files
            $scanSource = Join-Path $PSScriptRoot 'offline-packager'
            $scanDest   = Join-Path $targetRoot 'DriverDex-Scanner'

            Write-Host ""
            Write-Step "Copying scanner files to $scanDest..."
            try {
                New-Item -ItemType Directory -Path $scanDest -Force | Out-Null
                if (Test-Path (Join-Path $scanSource 'scan.cmd')) {
                    Copy-Item -Path (Join-Path $scanSource 'scan.cmd')  -Destination $scanDest -Force
                    Copy-Item -Path (Join-Path $scanSource 'scan.ps1')  -Destination $scanDest -Force
                } else {
                    $githubBase = "$Script:GITHUB_RAW/offline-packager"
                    Invoke-WebRequest -Uri "$githubBase/scan.cmd" -OutFile (Join-Path $scanDest 'scan.cmd') -UseBasicParsing
                    Invoke-WebRequest -Uri "$githubBase/scan.ps1" -OutFile (Join-Path $scanDest 'scan.ps1') -UseBasicParsing
                }
                # Same reasoning as the local-save path above: fix it now, before it's
                # carried off to a machine this script has no way to reach afterward.
                Repair-ScriptEncoding -Path (Join-Path $scanDest 'scan.ps1') | Out-Null
                Write-OK "Scanner files copied to: $scanDest"
            } catch {
                Write-Err -What "Failed to copy scanner files to USB" `
                          -Reason $_.Exception.Message `
                          -Fix    "Check that the USB drive is writable."
                return
            }

            # Show instructions
            Write-Host ""
            Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
            Write-Host "  |  INSTRUCTIONS FOR THE AIR-GAPPED PC                          |" -ForegroundColor Green
            Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
            Write-Host ""
            Write-Host "  1. Safely eject this USB drive" -ForegroundColor White
            Write-Host ""
            Write-Host "  2. Plug it into the AIR-GAPPED (offline) PC" -ForegroundColor White
            Write-Host ""
            Write-Host "  3. Open the USB drive in File Explorer" -ForegroundColor White
            Write-Host "     -> Navigate to: DriverDex-Scanner" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  4. Double-click scan.cmd" -ForegroundColor White
            Write-Host "     -> A PowerShell window will open" -ForegroundColor DarkGray
            Write-Host "     -> It scans all hardware and creates inventory.json" -ForegroundColor DarkGray
            Write-Host "     -> Wait for it to complete (about 10-30 seconds)" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  5. When done, inventory.json will be in the same folder" -ForegroundColor White
            Write-Host "     -> You will see: scan.cmd, scan.ps1, inventory.json" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  6. Safely eject the USB and bring it back here" -ForegroundColor White
            Write-Host ""
            Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Press Enter when you have the inventory.json ready..." -ForegroundColor DarkGray
            $null = Read-Host
        }
    }

    # ── Prompt for inventory.json path ──────────────────────────────────
    Write-Host ""
    Write-Host "  Where is your inventory.json?" -ForegroundColor White
    Write-Host "    - Type the full path to the file (e.g. E:\DriverDex-Scanner\inventory.json)" -ForegroundColor DarkGray
    Write-Host "    - Or type the folder path containing it (e.g. E:\DriverDex-Scanner)" -ForegroundColor DarkGray
    Write-Host ""

    $inventoryInput = Read-Input -Prompt 'Path to inventory.json or folder' `
        -Default (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'inventory.json')

    # Resolve: if user gave a folder, look for inventory.json inside
    $inventoryPath = $null
    if (Test-Path $inventoryInput -PathType Container) {
        # It's a folder - look for inventory.json inside
        $inventoryPath = Join-Path $inventoryInput 'inventory.json'
    } elseif (Test-Path $inventoryInput -PathType Leaf) {
        # It's a file - use directly
        $inventoryPath = $inventoryInput
    } else {
        # Try as-is, maybe they typed a partial path
        Write-Err -What "Path not found" `
                  -Reason "The path '$inventoryInput' does not exist." `
                  -Fix    "Check the path and try again. Use the full path like E:\DriverDex-Scanner\inventory.json"
        return
    }

    if (-not (Test-Path $inventoryPath)) {
        # If folder was given but no inventory.json inside
        if (Test-Path $inventoryInput -PathType Container) {
            Write-Err -What "inventory.json not found in folder" `
                      -Reason "The folder '$inventoryInput' does not contain inventory.json." `
                      -Fix    "Make sure scan.cmd was run on the target PC."
        } else {
            Write-Err -What "File not found" `
                      -Reason "The file '$inventoryPath' does not exist." `
                      -Fix    "Check the path and try again."
        }
        return
    }

    if ($inventoryPath -notlike '*.json') {
        Write-Err -What "Not a JSON file" `
                  -Reason "The file '$inventoryPath' does not have a .json extension." `
                  -Fix    "Point to the inventory.json file created by scan.ps1."
        return
    }

    Write-Step "Reading inventory from: $inventoryPath"

    try {
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Err -What "Failed to parse inventory.json" `
                  -Reason $_.Exception.Message `
                  -Fix    "Ensure the file is valid JSON produced by scan.ps1."
        return
    }

    # Safely cast HWIDs to array (prevents single-item unwrapping on PS 5.1)
    $targetHWIDs = @()
    if ($inventory.HWIDs -is [array]) {
        $targetHWIDs = @($inventory.HWIDs)
    } elseif ($inventory.HWIDs) {
        $targetHWIDs = @($inventory.HWIDs)
    }

    $rawArch    = if ($inventory.Architecture) { $inventory.Architecture } else { 'x64' }
    $targetArch = ConvertTo-NormalizedArch -Value $rawArch -Source 'inventory.json'

    if (@($targetHWIDs).Count -eq 0) {
        Write-Err -What "No hardware IDs found in inventory.json" `
                  -Reason "The HWIDs array is empty or missing." `
                  -Fix    "Re-run scan.ps1 on the target machine."
        return
    }

    Write-OK "Loaded $(@($targetHWIDs).Count) hardware ID(s) · Arch: $targetArch"
    Write-Host ""

    # ── Network check ───────────────────────────────────────────────────
    Write-Divider
    if (-not (Test-NetworkConnectivity)) { return }
    Write-Host ""

    # ── Query API for matching drivers ──────────────────────────────────
    Write-Divider
    Write-Step "Querying DriverDex API for $(@($targetHWIDs).Count) hardware ID(s)..."
    $drivers = Search-Drivers -HWIDs $targetHWIDs -SystemArch $targetArch -InstalledSnapshot @{}
    Write-Host ""

    if (@($drivers).Count -eq 0) {
        Write-Warn "No matching drivers found in the DriverDex database for this inventory. (Searched arch: $targetArch)"
        Write-Host ""
        return
    }

    $byCat = $drivers | Group-Object Category
    $catSummary = ($byCat | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '  ·  '
    Write-OK "Found $(@($drivers).Count) matching driver(s)  [$catSummary]"
    Write-Host ""

    # ── Output folder ───────────────────────────────────────────────────
    Write-Divider
    $outRoot = Get-OutputFolder
    Write-Host ""

    $estMB = @($drivers).Count * 200
    Write-Info "Estimated download: ~${estMB} MB (rough estimate)"

    # ── Download extractor ──────────────────────────────────────────────
    Write-Divider
    Write-Step "Downloading DriverDex extractor..."
    $extractor = Join-Path $Script:scratch 'extractor.exe'
    try {
        Get-DriverFile -Url (Get-ExtractorUrl) -Dest $extractor -Label 'extractor.exe'
    } catch {
        Write-Err -What "Failed to download extractor." `
                  -Reason $_.Exception.Message `
                  -Fix    "Check your internet connection and re-run."
        return
    }
    Write-Host ""

    # ── Download and extract each driver ────────────────────────────────
    Write-Divider
    Write-Step "Downloading and extracting driver packages..."
    Write-Host ""

    $results = [System.Collections.Generic.List[object]]::new()
    $dIdx    = 0

    foreach ($drv in @($drivers)) {
        $dIdx++
        $name = $drv.DisplayName
        Write-Host "  [$dIdx/$(@($drivers).Count)] $name" -ForegroundColor Cyan

        try {
            $res = Invoke-SearchDownload `
                        -Item        $drv `
                        -OutRoot     $outRoot `
                        -ScratchDir  $Script:scratch `
                        -Extractor   $extractor `
                        -IsAdmin     (Test-Administrator) `
                        -InstallMode $false
            $results.Add($res)
            if ($res.Success) {
                Write-OK "Downloaded: $name"
            } else {
                Write-Warn "Partial failure for: $name"
            }
        } catch {
            Write-Warn "Failed to process ${name}: $($_.Exception.Message)"
            Write-Log -Level WARN -Msg "Offline packager download failed for '$name': $($_.Exception.Message)"
        }
        Write-Host ""
    }

    # ── Generate deployer scripts ───────────────────────────────────────
    Write-Step "Generating offline installer scripts..."
    $deployerCmd  = Join-Path $outRoot 'Install-Offline.cmd'
    $deployerPs1  = Join-Path $outRoot 'install_offline.ps1'

    $cmdContent = @'
@echo off
:: DriverDex Offline Installer - Double-click to install all drivers
:: Elevates to Admin if needed
NET SESSION >nul 2>&1
if %errorLevel% NEQ 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'am_admin' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_offline.ps1"
pause
'@

    $ps1Content = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    DriverDex Offline Installer - Installs all drivers from the bundle directory.
.DESCRIPTION
    Recursively scans for .inf files and installs them via pnputil.
    Run Install-Offline.cmd for automatic elevation, or run this script directly.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'White'
    try { $Host.UI.RawUI.WindowTitle = 'DriverDex Offline Installer' } catch {}
    Clear-Host
} catch {}

Write-Host ""
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  DriverDex Offline Installer                                 |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# ── Locate all .inf files recursively ───────────────────────────────────
Write-Host "  [>] Scanning for driver packages..." -ForegroundColor Gray
$infs = @(Get-ChildItem -Path $PSScriptRoot -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)

if (@($infs).Count -eq 0) {
    Write-Host "  [!] No .inf files found in this directory." -ForegroundColor Red
    Write-Host "      Make sure the driver folders are in the same location as this script." -ForegroundColor DarkGray
    Write-Host ""
    return
}

Write-Host "  [+] Found $(@($infs).Count) INF file(s) across driver packages" -ForegroundColor Green
Write-Host ""

# ── Group INFs by parent directory (driver package) ─────────────────────
$packages = $infs | Group-Object -Property DirectoryName
$totalPackages = @($packages).Count
$installedCount = 0
$failedCount    = 0

Write-Host "  Installing $totalPackages driver package(s)..." -ForegroundColor Cyan
Write-Host ""

$pkgIdx = 0
foreach ($pkg in $packages) {
    $pkgIdx++
    $pkgName = Split-Path $pkg.Name -Leaf
    Write-Host "  [$pkgIdx/$totalPackages] $pkgName" -ForegroundColor White -NoNewline
    Write-Host "  ($(@($pkg.Group).Count) INF(s))" -ForegroundColor DarkGray

    $infPaths = @($pkg.Group | ForEach-Object { $_.FullName })

    foreach ($infPath in $infPaths) {
        $infName = Split-Path $infPath -Leaf
        Write-Host "    -> $infName" -ForegroundColor DarkGray -NoNewline

        try {
            $output = @(& "$env:SystemRoot\System32\pnputil.exe" /add-driver "$infPath" /subdirs /install 2>&1)
            $exitCode = $LASTEXITCODE

            if ($exitCode -in @(0, 3010)) {
                Write-Host "  [OK]" -ForegroundColor Green
                $installedCount++
            } else {
                Write-Host "  [FAIL: exit $exitCode]" -ForegroundColor Red
                $failedCount++
                $output | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkRed }
            }
        } catch {
            Write-Host "  [ERROR]" -ForegroundColor Red
            $failedCount++
            Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
        }
    }
    Write-Host ""
}

# ── Summary ─────────────────────────────────────────────────────────────
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  INSTALL COMPLETE                                            |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Packages processed : $totalPackages" -ForegroundColor White
Write-Host "  INFs installed     : $installedCount" -ForegroundColor Green
if ($failedCount -gt 0) {
    Write-Host "  INFs failed        : $failedCount" -ForegroundColor Red
} else {
    Write-Host "  INFs failed        : 0" -ForegroundColor Green
}
Write-Host ""

# ── Reboot check ────────────────────────────────────────────────────────
$needsReboot = $false
foreach ($inf in $infs) {
    try {
        $drvResult = & "$env:SystemRoot\System32\pnputil.exe" /enum-driver "$($inf.FullName)" 2>&1
        if ($drvResult -match 'Reboot required') { $needsReboot = $true; break }
    } catch {}
}

if ($needsReboot) {
    Write-Host "  [!] A reboot is recommended to complete driver installation." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  DriverDex Offline Bundle — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
Write-Host ""
'@

    Set-Content -Path $deployerCmd -Value $cmdContent -Encoding ASCII -Force
    Set-Content -Path $deployerPs1 -Value $ps1Content  -Encoding UTF8 -Force
    Write-OK "Generated Install-Offline.cmd and install_offline.ps1"

    # ── ZIP prompt ──────────────────────────────────────────────────────
    Write-Host ""
    $wantZip = Read-Input -Prompt 'Create a ZIP archive of the bundle? (y/n)' -Default 'n' `
        -Validator { param($v) $v -match '^[YyNn]$' } `
        -ErrMsg    'Enter y or n.'

    if ($wantZip -match '^[Yy]') {
        Write-Step "Creating ZIP archive..."
        $zipPath = Join-Path (Split-Path $outRoot -Parent) 'DriverDex-Offline-Bundle.zip'
        try {
            Compress-Archive -Path "$outRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
            Write-OK "ZIP created: $zipPath"
        } catch {
            Write-Err -What "Failed to create ZIP archive" `
                      -Reason $_.Exception.Message `
                      -Fix    "Check that the output folder is not read-only."
        }
    }

    # ── Final output ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  OFFLINE BUNDLE READY                                        |" -ForegroundColor Green
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Output folder: $outRoot" -ForegroundColor White
    Write-Host ""
    Write-Host "  To deploy on the target PC:" -ForegroundColor Cyan
    Write-Host "    1. Copy the entire output folder to the air-gapped machine" -ForegroundColor DarkGray
    Write-Host "    2. Double-click Install-Offline.cmd" -ForegroundColor DarkGray
    Write-Host "    3. All drivers will be installed automatically" -ForegroundColor DarkGray
    Write-Host ""

    Write-Log -Level INFO -Msg "Offline Packager complete: $(@($drivers).Count) drivers, output=$outRoot"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

function Main {
    Clear-Host
    Initialize-Tls
    Write-Header -Version $Script:VERSION

    Write-Log -Level INFO -Msg "DriverDex v$Script:VERSION session started."

    # ── Scratch directory ───────────────────────────────────────────────
    $Script:scratch = Join-Path $env:TEMP ("driverdex-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $Script:scratch | Out-Null

    Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
        Remove-Item $Script:scratch -Recurse -Force -ErrorAction SilentlyContinue
    } | Out-Null

    try {
        $mode = Show-MainMenu
        if ($mode -eq 'quit') {
            Write-Info "Exiting DriverDex. Goodbye."
            return
        }
        if ($mode -eq 'search') {
            Write-Host ""
            Invoke-SearchEngine -IsAdmin (Test-Administrator) -ScratchDir $Script:scratch
            Write-Host ""
            Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
            Write-Info "  Session log: $(Get-LogPath)"
            Write-Host ""
            Write-Log -Level INFO -Msg "Search Engine session complete."
            $hwidsForContrib = @()
            try { $hwidsForContrib = @(Get-AllHardwareIDs) } catch {}
            Invoke-ContributePrompt -HWIDs $hwidsForContrib -Reason 'partial' -UnmatchedLocalDrivers @()
            return
        }
        if ($mode -eq 'winupdate') {
            $isAdmin = Test-Administrator
            if (-not $isAdmin) { Request-Elevation }
            $isAdmin = Test-Administrator
            Invoke-ForceWindowsUpdate -IsAdmin $isAdmin
            Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
            Write-Info "  Session log: $(Get-LogPath)"
            Write-Host ""
            Write-Log -Level INFO -Msg "Force Windows Update session complete."
            $hwidsForContrib = @()
            try { $hwidsForContrib = @(Get-AllHardwareIDs) } catch {}
            Invoke-ContributePrompt -HWIDs $hwidsForContrib -Reason 'partial' -UnmatchedLocalDrivers @()
            return
        }
        if ($mode -eq 'packager') {
            Invoke-OfflinePackager
            Write-Host ""
            Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
            Write-Info "  Session log: $(Get-LogPath)"
            Write-Host ""
            Write-Log -Level INFO -Msg "Offline Packager session complete."
            return
        }

        # ── Auto-Detect mode ────────────────────────────────────────────
        $Script:ContribHWIDs         = @()
        $Script:ContribUnmatched     = @()
        $Script:ContribReason        = 'no_drivers'
        $Script:ContribShouldPrompt  = $true

        try {
        $os      = Get-OSInfo
        $isAdmin = Test-Administrator

        Write-Step "System information"
        Write-Info "OS      : $($os.Caption) (Build $($os.Build))"
        Write-Info "Arch    : $($os.Arch)"
        Write-Info "PS      : v$($os.PSVersion)"
        Write-Info "Admin   : $(if ($isAdmin) { 'Yes ✔' } else { 'No ✘ (elevation recommended)' })"
        Write-Info "Log     : $(Get-LogPath)"
        Write-Host ""
        Write-Log -Level INFO -Msg "OS=$($os.Caption) Build=$($os.Build) Arch=$($os.Arch) Admin=$isAdmin"

        # Step 1: Elevation
        if (-not $isAdmin) { Request-Elevation }
        $isAdmin = Test-Administrator

        # Step 2: Network
        Write-Divider
        if (-not (Test-NetworkConnectivity)) {
            $Script:ContribShouldPrompt = $false
            return
        }
        Write-Host ""

        # Step 3: Hardware scan
        Write-Divider
        $hwids        = Get-AllHardwareIDs
        $problemHWIDs = Get-ProblemDevices
        Write-OK "Found $(@($hwids).Count) hardware IDs · $(@($problemHWIDs).Count) problem device(s)"
        Write-Host ""

        $Script:ContribHWIDs = $hwids

        if (@($hwids).Count -eq 0) {
            Write-Err -What "No hardware IDs found." `
                      -Reason "CIM and WMI queries returned empty results." `
                      -Fix    "Ensure you have read access to WMI on this machine."
            $Script:ContribShouldPrompt = $false
            return
        }

        # Step 3b: Local driver inventory
        $installedSnapshot = Get-InstalledDriverSnapshot
        Write-Host ""

        # Step 4: API query
        Write-Divider
        $scanArch = ConvertTo-NormalizedArch -Value $os.Arch -Source 'Get-OSInfo'
        $drivers = Search-Drivers -HWIDs $hwids -SystemArch $scanArch -InstalledSnapshot $installedSnapshot
        Write-Host ""

        $unmatchedLocal = Get-UnmatchedLocalDrivers -AllHWIDs $hwids -MatchedDrivers @($drivers) -Snapshot $installedSnapshot
        $Script:ContribUnmatched = $unmatchedLocal

        if (@($drivers).Count -eq 0) {
            Write-Warn "No matching drivers found in the DriverDex database for your hardware. (Searched arch: $scanArch)"
            Write-Host ""
            $Script:ContribReason = 'no_drivers'
            return
        }

        $Script:ContribReason = 'partial'

        if (@($unmatchedLocal).Count -gt 0) {
            Write-Accent "  [$(@($unmatchedLocal).Count) locally installed driver(s) have no DriverDex entry yet — more on this at the end]"
            Write-Host ""
        }

        $byCat = $drivers | Group-Object Category
        $catSummary = ($byCat | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '  ·  '
        Write-OK "Found $(@($drivers).Count) matching driver(s)  [$catSummary]"
        Write-Host ""

        # Step 5: Driver selection
        $selected = Show-DriverMenu -Drivers @($drivers) -ProblemHWIDs $problemHWIDs

        if (-not $selected -or @($selected).Count -eq 0) {
            Write-Info "No drivers selected."
            return
        }
        Write-Host ""

        # Step 6: Output folder
        Write-Divider
        $outRoot = Get-OutputFolder
        Write-Host ""

        $estMB = @($selected).Count * 200
        Write-Info "Estimated download: ~${estMB} MB (rough estimate)"

        # Download extractor once
        Write-Divider
        Write-Step "Downloading DriverDex extractor..."
        $extractor = Join-Path $Script:scratch 'extractor.exe'
        try {
            Get-DriverFile -Url (Get-ExtractorUrl) -Dest $extractor -Label 'extractor.exe'
        } catch {
            Write-Err -What "Failed to download extractor." `
                      -Reason $_.Exception.Message `
                      -Fix    "Check your internet connection and re-run the script."
            return
        }
        Write-Host ""

        # Step 7: Per-driver processing
        $results = [System.Collections.Generic.List[object]]::new()
        $dIdx    = 0

        foreach ($drv in $selected) {
            $dIdx++
            Show-DriverPanel -Driver $drv -Idx $dIdx -Total @($selected).Count

            $res = Install-DriverPackage `
                        -Driver        $drv `
                        -OutputRoot    $outRoot `
                        -ScratchDir    $Script:scratch `
                        -ExtractorPath $extractor `
                        -IsAdmin       $isAdmin
            $results.Add($res)
            Write-Log -Level INFO -Msg "Driver '$($drv.DisplayName)': success=$($res.Success) partial=$($res.PartialFailure) ($($res.PackagesAdded)/$($res.PackagesTotal)) skipped=$($res.Skipped) reboot=$($res.RebootRequired)"
        }

        # Step 8: Summary
        Show-InstallSummary -Results @($results)

        # Step 10: Reboot prompt
        Invoke-RebootPrompt -Results @($results)

        Write-Host "  DriverDex — https://github.com/rhshourav/driverdex" -ForegroundColor DarkCyan
        Write-Info "  Session log: $(Get-LogPath)"
        Write-Host ""
        Write-Log -Level INFO -Msg "Session complete."

        } catch {
            Write-Err -What "Unexpected error during driver detection." `
                      -Reason $_.Exception.Message `
                      -Fix "Check the log for details, then re-run the script." `
                      -Err $_
        } finally {
            if ($Script:ContribShouldPrompt) {
                Invoke-ContributePrompt `
                    -HWIDs                $Script:ContribHWIDs `
                    -Reason               $Script:ContribReason `
                    -UnmatchedLocalDrivers $Script:ContribUnmatched
            }
        }

    } catch {
        Write-Err -What "DriverDex encountered an unexpected error and had to stop." `
                  -Reason $_.Exception.Message `
                  -Fix "Check the log for details, then re-run the script." `
                  -Err $_
    } finally {
        Remove-Item -Recurse -Force $Script:scratch -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
try {
    Main
} finally {
    # Restore the caller's original session settings — important when this
    # script is run via `irm <url> | iex`, since it then executes in the
    # caller's own scope and would otherwise leave their interactive shell
    # permanently in StrictMode/ErrorActionPreference='Stop'.
    $ErrorActionPreference = $Script:__DDxPriorEAP
    $ProgressPreference    = $Script:__DDxPriorProgress
    Set-StrictMode -Off
    Remove-Variable -Name __DDxPriorEAP, __DDxPriorProgress, __DDxBootstrapFailed, __DDxImportFailed, __DDxPSVer `
        -Scope Script -ErrorAction SilentlyContinue
}
# ═══════════════════════════════════════════════════════════════════════════════
# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUkQImQC+aJa5Lyl8yDTDO3Qlv
# HcqgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBT4UYaaNYxytD/eziNPmWT09U3WaTANBgkq
# hkiG9w0BAQEFAASCAQCv3Hu1Teb41QEGY+ujSMZp/YXO1P1wQAfXq6jusZkz6fc+
# 7iqoC/Q6QhbgCUbkutVCkxWZzYOM+xrCh9O8NL6cjfhk4UPoN8FN4UrCrxTgcQFV
# kwkUzL6Q0Hjy3bsAN/uqhrLvaPEqiFVUzuhanUiOEWkk6NeuSYjBALr4FMUdCPGd
# 2jViPWgbqX0TDFbvKcHGeg3s6O9W1u+f5TLgS+WeJ3+9PNolxRDUEPH+A2OA3Zkr
# THWhybax6sHFyVsiB64E5UNvu5YXdCQs8zInswL4nHSCdmjju/RcDage7BAm6A5v
# VywDqADKkBnkedpLLqI/52gsnqdmPMR4v23zJitFoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0MFowLwYJKoZIhvcNAQkEMSIEIC3pu+/5fdBUiGy3
# SHMp6IPrZkpy0YaX/jHFlAkpnzegMA0GCSqGSIb3DQEBAQUABIICAK/T9Ss7Xw9z
# ShahpBgaabxFl5gmPL6aclvwFJCBu2V1ZjMKLFZCujyQG8fWVhghnBuP8n2YEqFE
# zqLBQ2cngtU+6abpdHOrvKpSpjqylCDyWTrBP8vZmlG/7EqbGqdZQmzOwb3YWCMi
# F09DipIR64DevnX0/a7B/W5k6eT34zJ1f4UtqVSGjyy6YEPWMCDTZb55zmLgW1Hf
# 17LdnCNBgmaKDUgH4+QnoQuLPTmSxVqzA05MtwqsLy4IoU0I3q7mC08SZvZdEPWM
# ZMhf8El9IU24kj9pRykYg0WIoX8VAJfSZPWqJq4maJ35zq7558MSXXzAcOCh1Kne
# Hf5Ki9tyCBIdrsi/KLX1Lg/ItH/W8ccMcSetkuSL7UUcN1HorWdK0QMb4RYRQq76
# ZZmvysRAzJo9ffGzZPp3SphqE4EIfBnPOhWllbM7UIP3wAW5VYTkKQJj7K8Ox3nN
# pkfajfnRFLzpD0CWnJp7BDil2cqeied4osmCgIiYvSLFBRuyJHmGitJLuU1/rG3T
# y7WXy2BGlPnBYdaSPR+LOmNZfwAKEAOGE5lI95zK8JKjlUBVcZ93kZuX9a2A91On
# zpjWQQeuRZIeaKqa1BjPCyoliAHfw07XgLwGWulJKKctyW6aip4TVFjuP+EIdgQk
# 9hebF1Wra81v7Kk7yCTzXkbCqZXOXBsu
# SIG # End signature block
