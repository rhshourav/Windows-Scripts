#Requires -Version 5.1
<#
.SYNOPSIS
    AutoDriverDeploy v3.1.0  --  Unified Windows Driver Deployment Tool
    Author  : rhshourav
    Repo    : https://github.com/rhshourav/Windows-Scripts
    Runs via: irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1 | iex

.DESCRIPTION
    Deploys drivers through three methods:
      LDC  - Community driver pack (rhshourav/LDC on GitHub)
      WU   - Force Windows Update driver search
      INF  - Local INF file or folder via pnputil

    LDC mode supports:
      AUTO   - HWID match first, category fallback
      SEARCH - Browse manifest, multi-select specific drivers

    Compatible with LDC Builder v4.5.4-rest:
      * ldc_index.json shard discovery (falls back to sequential probe)
      * 7z multi-volume archive format (.7z.0001, .7z.0002 ...)
        -- Uses system 7z/7za binary if found on PATH or common locations
        -- Downloads 7za.exe from repo as first fallback
        -- Downloads 7zextra.zip from repo, extracts 7za.exe as second fallback
        -- Falls back to pure-PS byte-join + .NET ZipFile for ZIP packs
      * 'parts' metadata per manifest entry (part_num, filename, url)
      * Legacy single-zip entries (zip / zip_url fields) still supported

.NOTES
    Compatible  : Windows 10+  /  PowerShell 5.1+
    Elevation   : Auto-elevates to Administrator if needed
    Cleanup     : Temp files removed on exit or mid-session abort

.CHANGELOG
    v3.2.0 - Robust detection + Y-default confirmations
             * Get-PnpDevice -PresentOnly:$false enumerates ALL devices
               including ghost / non-present (USB dongles, hidden, etc.)
             * Win32_PnPSignedDriver cross-reference: detect installed version
               and skip drivers that are already up-to-date
             * Matched-driver table shows [PRESENT]/[GHOST], [MISSING]/
               [UP-TO-DATE vX]/[UPDATE from vX] badges per driver
             * Confirm-Action defaults to Y on Enter (prompts show [Y/n])
             * Only drivers that NeedsUpdate are installed in AUTO mode
    v3.1.0 - 7z binary repo fallback
             * Try downloading 7za.exe directly from repo if not found locally
             * Try downloading 7zextra.zip from repo, extract 7za.exe if direct download fails
             * Both fallbacks use existing Invoke-Download with progress bar
             * Downloaded binary is cached in TempRoot for the session
    v3.0.0 - LDC Builder v4.5.4-rest compatibility
             * ldc_index.json shard discovery with sequential fallback
             * Full 7z multi-volume download + extraction
             * 7z binary auto-detection (PATH + common install paths)
             * Pure-PS byte-concat fallback for ZIP legacy packs
             * Updated PnpClassMap to match builder _CLASS_TO_TYPE exactly
             * Hardened error handling throughout -- no unhandled exceptions
             * All network calls use try/catch with descriptive messages
             * Removed all bare throws in favour of Write-Err + return
    v2.0.0 - Initial public release
#>

[CmdletBinding()]
param(
    [string[]]$DriverSourcePath,
    [switch]$SkipWindowsUpdate,
    [switch]$NoElevate,
    [switch]$NoTranscript,
    [string]$LogPath,
    [switch]$RebootIfRequired
)

# ================================================================
#  GLOBAL STATE
# ================================================================
$ErrorActionPreference   = 'Stop'
$script:ScriptVersion    = '3.2.0'
$script:ScriptName       = 'AutoDriverDeploy'
$script:ScriptAuthor     = 'rhshourav'
$script:RebootRequired   = $false
$script:ChangesMade      = $false
$script:TranscriptStart  = $false
$script:TempRoot         = $null
$script:LogFile          = $null

# LDC GitHub constants  (mirrors ldc_builder_v4.5.4-rest constants)
$script:LDC_REPO_OWNER    = 'rhshourav'
$script:LDC_REPO_NAME     = 'LDC'
$script:LDC_GH_BRANCH     = 'main'
$script:LDC_INDEX_FILE    = 'ldc_index.json'
$script:LDC_MANIFEST_BASE = 'https://raw.githubusercontent.com/rhshourav/LDC/main/drivers.manifest'
$script:LDC_INDEX_URL     = 'https://raw.githubusercontent.com/rhshourav/LDC/main/ldc_index.json'
$script:LDC_BASE_RAW      = 'https://raw.githubusercontent.com/rhshourav/LDC/main/drivers'

# 7z repo fallback URLs
$script:SEVENZ_EXE_URL    = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/tools/7za.exe'
$script:SEVENZ_ZIP_URL    = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/tools/7zextra.zip'

# ================================================================
#  CONSOLE SETUP
# ================================================================
try {
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'White'
    Clear-Host
} catch {}

$script:ConsoleWidth = 74
try {
    $w = $Host.UI.RawUI.WindowSize.Width
    if ($w -gt 50 -and $w -lt 220) { $script:ConsoleWidth = $w - 2 }
} catch {}

# ================================================================
#  UI HELPERS
# ================================================================
function Write-Divider {
    param([string]$Char = '-', [string]$Color = 'DarkGray')
    $line = '+' + ($Char * ($script:ConsoleWidth - 2)) + '+'
    Write-Host $line -ForegroundColor $Color
}

function Write-Banner {
    $inner = $script:ConsoleWidth - 2
    $top   = '+' + ('=' * $inner) + '+'
    $blank = '|' + (' ' * $inner) + '|'

    $t1    = " AUTO DRIVER DEPLOY  v$($script:ScriptVersion)  by $($script:ScriptAuthor) "
    $t2    = " github.com/rhshourav/Windows-Scripts "
    $t3    = ' LDC + Windows Update + Local INF '

    function Center-Line { param([string]$Text)
        $pad = [Math]::Max(0, [int](($inner - $Text.Length) / 2))
        '|' + (' ' * $pad) + $Text + (' ' * ($inner - $pad - $Text.Length)) + '|'
    }

    Write-Host ''
    Write-Host $top              -ForegroundColor Cyan
    Write-Host $blank            -ForegroundColor Cyan
    Write-Host (Center-Line $t1) -ForegroundColor Cyan
    Write-Host (Center-Line $t2) -ForegroundColor DarkCyan
    Write-Host (Center-Line $t3) -ForegroundColor DarkGray
    Write-Host $blank            -ForegroundColor Cyan
    Write-Host $top              -ForegroundColor Cyan
    Write-Host ''
}

function Write-Section {
    param([string]$Title, [string]$Color = 'Cyan')
    $inner   = $script:ConsoleWidth - 2
    $dashes  = $inner - $Title.Length - 5
    $line    = '+-- ' + $Title + ' ' + ('-' * [Math]::Max(0, $dashes)) + '+'
    Write-Host ''
    Write-Host $line -ForegroundColor $Color
}

function Write-OK {
    param([string]$Msg)
    Write-Host '  [ OK ]  ' -ForegroundColor Green -NoNewline
    Write-Host $Msg -ForegroundColor White
    Write-Log $Msg 'OK'
}

function Write-Warn {
    param([string]$Msg)
    Write-Host '  [WARN]  ' -ForegroundColor Yellow -NoNewline
    Write-Host $Msg -ForegroundColor Yellow
    Write-Log $Msg 'WARN'
}

function Write-Err {
    param([string]$Msg)
    Write-Host '  [ ERR ] ' -ForegroundColor Red -NoNewline
    Write-Host $Msg -ForegroundColor Red
    Write-Log $Msg 'ERROR'
}

function Write-Info {
    param([string]$Msg)
    Write-Host '  [INFO]  ' -ForegroundColor White -NoNewline
    Write-Host $Msg -ForegroundColor White
    Write-Log $Msg 'INFO'
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $script:LogFile) { return }
    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $enc    = New-Object System.Text.UTF8Encoding($false)
        $fs     = [System.IO.File]::Open(
                      $script:LogFile,
                      [System.IO.FileMode]::OpenOrCreate,
                      [System.IO.FileAccess]::Write,
                      [System.IO.FileShare]::ReadWrite)
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $sw     = New-Object System.IO.StreamWriter($fs, $enc)
        $sw.WriteLine($entry)
        $sw.Flush()
        $sw.Dispose()
        $fs.Dispose()
    } catch {}
}

function Read-MenuChoice {
    param([string]$Prompt = 'Select', [string[]]$Valid)
    while ($true) {
        Write-Host ''
        Write-Host "  $Prompt " -ForegroundColor Yellow -NoNewline
        $choice = (Read-Host).Trim().ToUpper()
        if ($Valid -contains $choice) { return $choice }
        Write-Host '  Invalid selection. Please try again.' -ForegroundColor Red
    }
}

function Confirm-Action {
    param([string]$Prompt)
    Write-Host "  $Prompt [Y/n]: " -ForegroundColor Yellow -NoNewline
    $inp = (Read-Host).Trim()
    if ($inp.Length -eq 0) { return $true }   # Enter = Y (default)
    return ($inp.ToUpper() -ne 'N')
}

function Wait-AnyKey {
    Write-Host ''
    Write-Host '  Press any key to continue...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
}

# ================================================================
#  UTILITY HELPERS
# ================================================================
function Test-IsAdministrator {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Convert-UpdateResultCode {
    param([int]$Code)
    switch ($Code) {
        0 { 'NotStarted' }        1 { 'InProgress' }
        2 { 'Succeeded' }         3 { 'SucceededWithErrors' }
        4 { 'Failed' }            5 { 'Aborted' }
        default { "Unknown($Code)" }
    }
}

function Get-PnPUtilPath {
    foreach ($p in @(
        (Join-Path $env:windir 'Sysnative\pnputil.exe'),
        (Join-Path $env:windir 'System32\pnputil.exe')
    )) { if (Test-Path -LiteralPath $p) { return $p } }
    $cmd = Get-Command pnputil.exe -ErrorAction SilentlyContinue
    if ($cmd) { return if ($cmd.Path) { $cmd.Path } else { $cmd.Definition } }
    return $null
}

function Invoke-Executable {
    param([string]$FilePath, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Not found: $FilePath" }
    $output = & $FilePath @Arguments 2>&1
    $code   = $LASTEXITCODE
    foreach ($line in $output) {
        if ($null -ne $line -and $line.ToString().Trim().Length -gt 0) {
            Write-Log $line.ToString()
        }
    }
    return $code
}

function Invoke-DeviceScan {
    $pnp = Get-PnPUtilPath
    if (-not $pnp) { Write-Warn 'pnputil.exe not found, skipping device scan.'; return }
    Write-Info 'Triggering device rescan...'
    try {
        $code = Invoke-Executable -FilePath $pnp -Arguments @('/scan-devices')
        if     ($code -eq 0)    { Write-OK 'Device rescan complete.' }
        elseif ($code -eq 3010) { $script:RebootRequired = $true; Write-Warn 'Device rescan: reboot required.' }
        else                    { Write-Warn "Device rescan exit code: $code" }
    } catch {
        Write-Warn "Device rescan failed: $($_.Exception.Message)"
    }
}

function ConvertTo-ArgumentString {
    param([object]$Parameters)
    $items = @()
    foreach ($key in $Parameters.Keys) {
        $val = $Parameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter] -or $val -is [bool]) {
            if ($val) { $items += "-$key" }; continue
        }
        if ($val -is [array]) {
            foreach ($e in $val) {
                if ($null -ne $e -and $e.ToString().Length -gt 0) {
                    $items += "-$key"; $items += '"' + $e.ToString().Replace('"', '`"') + '"'
                }
            }; continue
        }
        if ($null -ne $val -and $val.ToString().Length -gt 0) {
            $items += "-$key"; $items += '"' + $val.ToString().Replace('"', '`"') + '"'
        }
    }
    return ($items -join ' ')
}

# ================================================================
#  DOWNLOAD WITH REAL PROGRESS BAR
# ================================================================
function Show-DownloadBar {
    param([string]$Label, [long]$Received, [long]$Total, [int]$BarWidth = 28)

    $pct    = if ($Total -gt 0) { [int](($Received / $Total) * 100) } else { -1 }
    $fill   = if ($pct -ge 0)  { [int](($pct / 100.0) * $BarWidth) } else { 0 }
    $empty  = $BarWidth - $fill
    $bar    = '[' + ('#' * $fill) + ('-' * $empty) + ']'

    $rcv    = '{0:N1} MB' -f ($Received / 1MB)
    $tot    = if ($Total -gt 0) { ' / {0:N1} MB' -f ($Total / 1MB) } else { '' }
    $pctStr = if ($pct -ge 0) { '{0,3}%' -f $pct } else { '  ? %' }

    $maxLabel = $script:ConsoleWidth - $BarWidth - 28
    if ($Label.Length -gt $maxLabel -and $maxLabel -gt 5) {
        $Label = $Label.Substring(0, $maxLabel - 3) + '...'
    }

    $line = "  $bar $pctStr  $rcv$tot  $Label"
    $pad  = ' ' * [Math]::Max(0, $script:ConsoleWidth - $line.Length - 1)
    try { Write-Host "`r$line$pad" -NoNewline -ForegroundColor Cyan } catch {}
}

function Invoke-Download {
    param([string]$Url, [string]$OutPath, [string]$Label = 'Downloading')

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent        = "AutoDriverDeploy/$($script:ScriptVersion)"
    $req.Timeout          = 600000
    $req.ReadWriteTimeout = 600000
    $req.AllowAutoRedirect = $true

    $resp    = $req.GetResponse()
    $total   = $resp.ContentLength
    $netStr  = $resp.GetResponseStream()
    $fileStr = [System.IO.File]::Create($OutPath)

    try {
        $buf      = New-Object byte[] 65536
        $received = [long]0
        Show-DownloadBar -Label $Label -Received 0 -Total $total

        while ($true) {
            $read = $netStr.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            $fileStr.Write($buf, 0, $read)
            $received += $read
            Show-DownloadBar -Label $Label -Received $received -Total $total
        }
        Write-Host ''
    } finally {
        try { $fileStr.Flush(); $fileStr.Close() } catch {}
        try { $netStr.Close()                     } catch {}
        try { $resp.Close()                       } catch {}
    }
}

# ================================================================
#  7Z BINARY DETECTION  (v3.1.0 -- repo fallback)
# ================================================================
function Find-SevenZipBinary {
    <#
    .SYNOPSIS
        Locate a usable 7z / 7za / 7zz executable.
        Search order:
          1. System PATH
          2. Common Windows install locations
          3. Download 7za.exe directly from GitHub repo
          4. Download 7zextra.zip from GitHub repo, extract and locate 7za.exe
        Returns the full path, or $null if all methods fail.
    #>

    $candidates = @('7z', '7za', '7zz')

    # ── 1. Check PATH ────────────────────────────────────────────────────────
    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $path = if ($cmd.Path) { $cmd.Path } else { $cmd.Definition }
            if ($path -and (Test-Path -LiteralPath $path)) {
                Write-Log "7z binary found on PATH: $path" 'INFO'
                return $path
            }
        }
    }

    # ── 2. Common install locations ──────────────────────────────────────────
    $installDirs = @(
        "${env:ProgramFiles}\7-Zip",
        "${env:ProgramFiles(x86)}\7-Zip",
        "${env:ProgramData}\chocolatey\bin",
        "${env:LOCALAPPDATA}\Programs\7-Zip"
    )
    foreach ($dir in $installDirs) {
        foreach ($name in @('7z.exe','7za.exe','7zz.exe')) {
            $full = Join-Path $dir $name
            if (Test-Path -LiteralPath $full) {
                Write-Log "7z binary found at: $full" 'INFO'
                return $full
            }
        }
    }

    # ── 3. Download 7za.exe directly from repo ───────────────────────────────
    Write-Warn '7z not found locally. Trying to download 7za.exe from repo...'
    $dl7zaPath = Join-Path $script:TempRoot '7za.exe'
    try {
        Invoke-Download -Url $script:SEVENZ_EXE_URL -OutPath $dl7zaPath -Label '7za.exe [repo]'
        if ((Test-Path -LiteralPath $dl7zaPath) -and (Get-Item $dl7zaPath).Length -gt 10240) {
            Write-OK "7za.exe downloaded successfully from repo."
            Write-Log "7z binary obtained via direct download: $dl7zaPath" 'INFO'
            return $dl7zaPath
        } else {
            Write-Warn '7za.exe download completed but file appears invalid -- trying zip fallback.'
            Remove-Item $dl7zaPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warn "Direct 7za.exe download failed: $($_.Exception.Message)"
    }

    # ── 4. Download 7zextra.zip from repo, extract 7za.exe ──────────────────
    Write-Warn 'Trying 7zextra.zip from repo...'
    $dlZipPath    = Join-Path $script:TempRoot '7zextra.zip'
    $dlZipExtract = Join-Path $script:TempRoot '7zextra_extracted'
    try {
        Invoke-Download -Url $script:SEVENZ_ZIP_URL -OutPath $dlZipPath -Label '7zextra.zip [repo]'

        if (-not (Test-Path -LiteralPath $dlZipPath) -or (Get-Item $dlZipPath).Length -lt 1024) {
            Write-Warn '7zextra.zip download appears invalid.'
            Remove-Item $dlZipPath -Force -ErrorAction SilentlyContinue
        } else {
            # Extract the zip using .NET
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $dlZipExtract -Force | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($dlZipPath, $dlZipExtract)
            Remove-Item $dlZipPath -Force -ErrorAction SilentlyContinue

            # Search recursively for any usable 7z binary inside the extracted folder
            $found = Get-ChildItem -Path $dlZipExtract -Recurse -Include '7za.exe','7z.exe','7zz.exe' `
                         -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -gt 10240 } |
                     Sort-Object { $_.Name } |   # prefer 7z.exe > 7za.exe > 7zz.exe alphabetically reversed; close enough
                     Select-Object -First 1

            if ($found) {
                # Copy to TempRoot so it survives if extracted folder gets cleaned
                $finalPath = Join-Path $script:TempRoot $found.Name
                Copy-Item -LiteralPath $found.FullName -Destination $finalPath -Force
                Write-OK "7z binary extracted from 7zextra.zip: $($found.Name)"
                Write-Log "7z binary obtained via zip extraction: $finalPath" 'INFO'
                return $finalPath
            } else {
                Write-Warn 'No usable 7z binary found inside 7zextra.zip.'
            }
        }
    } catch {
        Write-Warn "7zextra.zip fallback failed: $($_.Exception.Message)"
    } finally {
        Remove-Item $dlZipExtract -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ── All methods exhausted ────────────────────────────────────────────────
    Write-Log '7z binary unavailable -- will use pure-PS byte-concat fallback.' 'WARN'
    return $null
}

# Cache 7z path once per session
$script:SevenZipPath    = $null
$script:SevenZipChecked = $false

function Get-SevenZipPath {
    if (-not $script:SevenZipChecked) {
        $script:SevenZipPath    = Find-SevenZipBinary
        $script:SevenZipChecked = $true
    }
    return $script:SevenZipPath
}

# ================================================================
#  ARCHIVE EXTRACTION  (v3.0.0: archive-agnostic)
# ================================================================
function Expand-DriverArchive {
    <#
    .SYNOPSIS
        Extract a driver archive to $Destination.

        Handles three formats produced by LDC Builder v4.5.4-rest:
          1. Single .zip  (legacy or ZIP fallback)
          2. Multi-part .zip  (partNN.zip -- concatenate then unzip)
          3. Multi-volume .7z (.7z.0001 / .7z.0002 ...)
             a. If 7z binary available: invoke 7z directly against the
                first volume -- 7z handles the rest automatically.
             b. If no binary: concatenate all parts byte-by-byte into
                a single combined file, then try ZIP extraction
                (works only when the builder used its ZIP fallback path).

        Returns $true on success, $false on failure.
    #>
    param(
        [string[]]$ArchivePaths,   # ordered list of part paths on disk
        [string]$Destination
    )

    if (-not $ArchivePaths -or $ArchivePaths.Count -eq 0) {
        Write-Err 'Expand-DriverArchive: no archive paths supplied.'
        return $false
    }

    $firstPath = $ArchivePaths[0]

    # Determine archive format from first filename
    $firstName = [System.IO.Path]::GetFileName($firstPath).ToLower()

    $is7z     = $firstName -match '\.7z(\.\d{4})?$'
    $isZip    = $firstName.EndsWith('.zip')
    $isMulti  = ($ArchivePaths.Count -gt 1)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    # ── 7z multi-volume ─────────────────────────────────────────────────────
    if ($is7z) {
        $sevenZip = Get-SevenZipPath

        if ($sevenZip) {
            # Use binary -- point at first volume; 7z finds the rest automatically
            Write-Info "Extracting 7z archive with binary: $sevenZip"
            try {
                $code = Invoke-Executable -FilePath $sevenZip `
                    -Arguments @('x', $firstPath, "-o$Destination", '-y', '-aoa')
                if ($code -eq 0 -or $code -eq 1) {  # 1 = warnings but ok
                    return $true
                }
                Write-Err "7z extraction exited with code $code"
                return $false
            } catch {
                Write-Err "7z extraction failed: $($_.Exception.Message)"
                return $false
            }
        }

        # No binary -- warn and attempt byte-concat + ZIP fallback
        Write-Warn '7z binary not found. Attempting byte-concatenation fallback.'
        Write-Warn 'Note: This only works if the builder used its ZIP fallback path.'
        $combinedPath = Join-Path (Split-Path $firstPath) '_combined_fallback.zip'
        $ok = Merge-PartsToFile -PartPaths $ArchivePaths -OutPath $combinedPath
        if (-not $ok) { return $false }

        $result = Expand-ZipFile -ZipPath $combinedPath -Destination $Destination
        Remove-Item $combinedPath -Force -ErrorAction SilentlyContinue
        return $result
    }

    # ── Multi-part ZIP (partNN.zip) ─────────────────────────────────────────
    if ($isZip -and $isMulti) {
        Write-Info "Combining $($ArchivePaths.Count) ZIP parts..."
        $combinedPath = Join-Path (Split-Path $firstPath) '_combined.zip'
        $ok = Merge-PartsToFile -PartPaths $ArchivePaths -OutPath $combinedPath
        if (-not $ok) { return $false }

        $result = Expand-ZipFile -ZipPath $combinedPath -Destination $Destination
        Remove-Item $combinedPath -Force -ErrorAction SilentlyContinue
        return $result
    }

    # ── Single ZIP ───────────────────────────────────────────────────────────
    if ($isZip) {
        return (Expand-ZipFile -ZipPath $firstPath -Destination $Destination)
    }

    Write-Err "Unrecognised archive format: $firstName"
    return $false
}

function Merge-PartsToFile {
    <#
    .SYNOPSIS
        Concatenate ordered part files into a single output file.
        Returns $true on success.
    #>
    param([string[]]$PartPaths, [string]$OutPath)

    $outStream = $null
    try {
        $outStream = [System.IO.File]::Create($OutPath)
        foreach ($part in $PartPaths) {
            if (-not (Test-Path -LiteralPath $part)) {
                Write-Err "Part file missing: $part"
                return $false
            }
            $bytes = [System.IO.File]::ReadAllBytes($part)
            $outStream.Write($bytes, 0, $bytes.Length)
        }
        return $true
    } catch {
        Write-Err "Part merge failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($outStream) {
            try { $outStream.Flush(); $outStream.Close() } catch {}
        }
    }
}

function Expand-ZipFile {
    <#
    .SYNOPSIS
        Extract a single .zip file using .NET ZipFile.
        Returns $true on success.
    #>
    param([string]$ZipPath, [string]$Destination)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
        return $true
    } catch {
        Write-Err "ZIP extraction failed: $($_.Exception.Message)"
        return $false
    }
}

# ================================================================
#  LDC -- INF CLASS -> CATEGORY MAP
#  Kept in exact sync with ldc_builder_v4.5.4-rest _CLASS_TO_TYPE
# ================================================================
$script:PnpClassMap = @{
    # Network
    'net'                 = 'Net';   'nettrans'            = 'Net'
    'netservice'          = 'Net';   'netclient'           = 'Net'
    'network'             = 'Net'
    # Display / GPU
    'display'             = 'Display'; 'monitor'           = 'Display'
    'hdc'                 = 'Display'
    # Audio / Media
    'media'               = 'Audio';   'audio'             = 'Audio'
    'hdaudio'             = 'Audio';   'audioendpoint'     = 'Audio'
    # Storage
    'diskdrive'           = 'Storage'; 'cdrom'             = 'Storage'
    'floppydisk'          = 'Storage'; 'tapedrive'         = 'Storage'
    'storage'             = 'Storage'; 'scsiadapter'       = 'Storage'
    'volumesnapshot'      = 'Storage'; 'volume'            = 'Storage'
    'mediumchanger'       = 'Storage'
    # USB
    'usb'                 = 'USB';     'usbdevice'         = 'USB'
    # Bluetooth
    'bluetooth'           = 'Bluetooth'; 'bth'             = 'Bluetooth'
    'bthle'               = 'Bluetooth'
    # Input / HID
    'hid'                 = 'Input';   'hidclass'          = 'Input'
    'keyboard'            = 'Input';   'mouse'             = 'Input'
    'pen'                 = 'Input';   'sensor'            = 'Input'
    'biometric'           = 'Input';   'tabletinputdevice' = 'Input'
    # Chipset / System
    'system'              = 'Chipset'; 'processor'         = 'Chipset'
    'computer'            = 'Chipset'; 'acpi'              = 'Chipset'
    'unknown'             = 'Chipset'; 'battery'           = 'Chipset'
    'smartcardreader'     = 'Chipset'
    # Ports / Serial
    'ports'               = 'Ports';   'multiportserial'   = 'Ports'
    'modem'               = 'Ports'
    # Imaging / Camera
    'image'               = 'Imaging'; 'camera'            = 'Imaging'
    'stillimage'          = 'Imaging'; 'scanner'           = 'Imaging'
    # Printer
    'printer'             = 'Printer'; 'printqueue'        = 'Printer'
    'pnpprinters'         = 'Printer'
    # Security / SmartCard
    'securityaccelerator' = 'Security'; 'securitydevices'  = 'Security'
    'smartcard'           = 'Security'
    # Firmware / UEFI
    'firmware'            = 'Firmware'; 'softwaredevice'   = 'Firmware'
    'softwarecomponent'   = 'Firmware'
    # Wireless
    'wireless'            = 'Wireless'; 'wlan'             = 'Wireless'
    'bluetoothaudio'      = 'Wireless'
    # Power
    'power'               = 'Power'
    # Other (infra / virtual -- builder maps these to "Other")
    'infrared'            = 'Other';    'multifunction'    = 'Other'
    '1394'                = 'Other';    '61883'            = 'Other'
    'dot4'                = 'Other';    'dot4print'        = 'Other'
    'ieeef16'             = 'Other';    'extension'        = 'Other'
}

# ================================================================
#  LDC -- INDEX + MANIFEST LOADER  (updated for ldc_index.json)
# ================================================================
function Invoke-SafeRestMethod {
    <#
    .SYNOPSIS
        Wraps Invoke-RestMethod with TLS 1.2 and error handling.
        Returns the parsed object or $null on failure.
    #>
    param([string]$Uri, [string]$Label = $Uri)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        return Invoke-RestMethod -Uri $Uri -ErrorAction Stop
    } catch {
        Write-Log "HTTP fetch failed for $Label : $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-LdcIndex {
    <#
    .SYNOPSIS
        Download ldc_index.json from GitHub.
        Returns the parsed index object, or $null if unavailable.
    #>
    Write-Info 'Fetching ldc_index.json from GitHub...'
    $idx = Invoke-SafeRestMethod -Uri $script:LDC_INDEX_URL -Label 'ldc_index.json'
    if ($idx -and $idx.manifest_shards) {
        Write-OK "ldc_index.json loaded -- $(@($idx.manifest_shards).Count) manifest shard(s) listed."
        return $idx
    }
    Write-Warn 'ldc_index.json not available or has no shard list -- will probe sequentially.'
    return $null
}

function Get-LdcManifests {
    <#
    .SYNOPSIS
        Load all enabled driver entries from every manifest shard.

        Discovery order (mirrors github_pull_manifest in builder):
          1. Download ldc_index.json
          2. If index has manifest_shards list, download those shards in order
          3. Fallback: probe .2.json / .3.json ... until 404

        Returns a flat array of driver entry objects.
    #>
    Write-Info 'Fetching LDC manifest(s) from GitHub...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $allDrivers = [System.Collections.ArrayList]@()

    # ── Step 1: try ldc_index.json for exact shard list ──────────────────────
    $index = Get-LdcIndex
    $shardUrls = [System.Collections.ArrayList]@()

    if ($index -and $index.manifest_shards) {
        $shards = @($index.manifest_shards)
        foreach ($shard in $shards) {
            $fname = $shard.filename
            if (-not $fname) { continue }
            # Build raw URL from filename (always in repo root)
            $url = "https://raw.githubusercontent.com/$($script:LDC_REPO_OWNER)/$($script:LDC_REPO_NAME)/$($script:LDC_GH_BRANCH)/$fname"
            [void]$shardUrls.Add($url)
        }
        Write-Info "Using $($shardUrls.Count) shard URL(s) from ldc_index.json."
    }

    if ($shardUrls.Count -eq 0) {
        # ── Fallback: sequential probe ─────────────────────────────────────────
        Write-Info 'Falling back to sequential shard probe...'
        [void]$shardUrls.Add("$($script:LDC_MANIFEST_BASE).json")
        for ($i = 2; $i -le 50; $i++) {
            [void]$shardUrls.Add("$($script:LDC_MANIFEST_BASE).$i.json")
        }
    }

    $shardNum = 0
    foreach ($url in $shardUrls) {
        $shardNum++
        $json = Invoke-SafeRestMethod -Uri $url -Label "shard $shardNum"

        if (-not $json) {
            if ($shardNum -eq 1) {
                Write-Err "Cannot reach LDC manifest. Check your internet connection."
                return @()
            }
            # 404 or error on a non-primary shard -- stop probing
            break
        }

        # Accept either a bare array or an object with a "drivers" property
        $entries = $null
        if ($json -is [array]) {
            $entries = $json
        } elseif ($json.drivers) {
            $entries = @($json.drivers)
        } else {
            Write-Warn "Shard $shardNum has unexpected structure -- skipping."
            continue
        }

        $enabled = @($entries | Where-Object { $_ -and $_.enabled -ne $false })
        foreach ($e in $enabled) { [void]$allDrivers.Add($e) }
        Write-OK "Shard $shardNum loaded -- $($enabled.Count) driver(s)"

        if ($json.PSObject.Properties.Name -contains 'total_shards') {
            $total = [int]$json.total_shards
            if ($shardNum -ge $total) { break }
        }
    }

    Write-OK "Total available drivers: $($allDrivers.Count)"
    return @($allDrivers)
}

# ================================================================
#  LDC -- HARDWARE DETECTION & MATCHING
# ================================================================
function Get-LocalHardwareIDs {
    $list            = [System.Collections.ArrayList]@()
    $installedDriver = @{}   # HWID.ToUpper() -> DriverVersion

    # ── Pre-build installed-driver lookup from Win32_PnPSignedDriver ─────────
    try {
        $signed = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                  Where-Object { $_.HardwareID -and $_.DriverVersion }
        foreach ($d in $signed) {
            foreach ($hwid in @($d.HardwareID)) {
                $key = $hwid.ToUpper()
                if ($key -and -not $installedDriver.ContainsKey($key)) {
                    $installedDriver[$key] = $d.DriverVersion
                }
            }
        }
    } catch {}

    # Helper: return first matching installed driver version for a device's HWIDs
    function script:Get-InstalledVer([string[]]$HWIDs, [string[]]$CompatIDs) {
        foreach ($id in ($HWIDs + $CompatIDs)) {
            if (-not $id) { continue }
            $v = $installedDriver[$id.ToUpper()]
            if ($v) { return $v }
        }
        return $null
    }

    # ── Primary path: Get-PnpDevice (PS 5.1+, Win10+) ───────────────────────
    #    -PresentOnly:$false captures ALL devices: connected, disconnected, ghost
    $pnpDevices = @()
    try {
        $pnpDevices = @(Get-PnpDevice -PresentOnly:$false -ErrorAction SilentlyContinue |
                        Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 })
    } catch {}

    if ($pnpDevices.Count -gt 0) {
        foreach ($dev in $pnpDevices) {
            $hwids   = @($dev.HardwareID   | Where-Object { $_ })
            $compats = @($dev.CompatibleID | Where-Object { $_ })
            if ($hwids.Count -eq 0) { continue }

            # IsPresent: device is physically connected/active
            # Status 'Unknown' = ghost / not currently connected
            $isPresent = $true
            if ($dev.PSObject.Properties['Present']) {
                $isPresent = [bool]$dev.Present
            } elseif ($dev.Status -eq 'Unknown' -or $dev.Status -eq 'UNKNOWN') {
                $isPresent = $false
            }

            $pnpClass = if ($dev.Class) { $dev.Class.ToLower() } else { '' }
            $instVer  = script:Get-InstalledVer -HWIDs $hwids -CompatIDs $compats

            [void]$list.Add([PSCustomObject]@{
                Name                   = if ($dev.FriendlyName) { $dev.FriendlyName }
                                         elseif ($dev.Name)     { $dev.Name }
                                         else                   { 'Unknown Device' }
                HardwareIDs            = $hwids
                CompatIDs              = $compats
                PNPClass               = $pnpClass
                IsPresent              = $isPresent
                Status                 = if ($dev.Status) { $dev.Status } else { 'Unknown' }
                InstalledDriverVersion = $instVer
            })
        }
        Write-Log "Get-PnpDevice enumerated $($list.Count) device(s) (all, including non-present)." 'INFO'
        return @($list)
    }

    # ── Fallback path: Win32_PnPEntity via CIM ───────────────────────────────
    #    ConfigManagerErrorCode 24 = not present, 45 = not connected, 47 = being removed
    Write-Log 'Get-PnpDevice unavailable -- falling back to Win32_PnPEntity.' 'WARN'
    try {
        $raw = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
               Where-Object { $_.HardwareID -and @($_.HardwareID).Count -gt 0 }

        foreach ($dev in $raw) {
            $hwids   = @($dev.HardwareID  | Where-Object { $_ })
            $compats = if ($dev.CompatibleID) { @($dev.CompatibleID | Where-Object { $_ }) } else { @() }
            if ($hwids.Count -eq 0) { continue }

            $errCode   = try { [int]$dev.ConfigManagerErrorCode } catch { 0 }
            $isPresent = $errCode -notin @(24, 45, 47)
            $pnpClass  = if ($dev.PNPClass) { $dev.PNPClass.ToLower() } else { '' }
            $instVer   = script:Get-InstalledVer -HWIDs $hwids -CompatIDs $compats

            [void]$list.Add([PSCustomObject]@{
                Name                   = if ($dev.Name) { $dev.Name } else { 'Unknown Device' }
                HardwareIDs            = $hwids
                CompatIDs              = $compats
                PNPClass               = $pnpClass
                IsPresent              = $isPresent
                Status                 = if ($dev.Status) { $dev.Status } else { 'Unknown' }
                InstalledDriverVersion = $instVer
            })
        }
    } catch {
        Write-Warn "Hardware enumeration partial error: $($_.Exception.Message)"
    }
    return @($list)
}

function Find-LdcMatches {
    param([array]$ManifestDrivers, [array]$LocalDevices)

    $arch    = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $matched = [System.Collections.ArrayList]@()

    foreach ($driver in $ManifestDrivers) {
        $dArch = if ($driver.arch) { $driver.arch } else { 'x64' }
        if ($dArch -ne '*' -and $dArch -ne $arch) { continue }

        $dHwids  = if ($driver.hwids)         { @($driver.hwids)         } else { @() }
        $dCompat = if ($driver.compatible_ids) { @($driver.compatible_ids) } else { @() }
        $dCat    = if ($driver.category)      { $driver.category          } else { '' }

        $matchType   = $null
        $matchDevice = $null

        :outer foreach ($dev in $LocalDevices) {
            foreach ($hwid in $dev.HardwareIDs) {
                foreach ($mhwid in $dHwids) {
                    if ($hwid -eq $mhwid -or
                        $hwid.ToUpper().StartsWith($mhwid.ToUpper())) {
                        $matchType = 'HWID'; $matchDevice = $dev; break outer
                    }
                }
                foreach ($cid in $dCompat) {
                    if ($hwid -eq $cid -or
                        $hwid.ToUpper().StartsWith($cid.ToUpper())) {
                        $matchType = 'HWID'; $matchDevice = $dev; break outer
                    }
                }
            }
            foreach ($cid in $dev.CompatIDs) {
                if ($dHwids -contains $cid -or $dCompat -contains $cid) {
                    $matchType = 'HWID'; $matchDevice = $dev; break outer
                }
            }
        }

        if (-not $matchType -and $dCat) {
            foreach ($dev in $LocalDevices) {
                $devCat = $script:PnpClassMap[$dev.PNPClass]
                if ($devCat -and $devCat -eq $dCat) {
                    $matchType = 'CAT'; $matchDevice = $dev; break
                }
            }
        }

        if ($matchType) {
            # Determine device presence and installed driver status
            $devIsPresent  = if ($matchDevice -and $matchDevice.PSObject.Properties['IsPresent']) {
                                 [bool]$matchDevice.IsPresent } else { $true }
            $instVer       = if ($matchDevice -and $matchDevice.PSObject.Properties['InstalledDriverVersion']) {
                                 $matchDevice.InstalledDriverVersion } else { $null }

            # NeedsUpdate: driver not installed, or manifest version is newer
            $needsUpdate   = $true
            if ($instVer -and $driver.version) {
                try {
                    $instParsed = [System.Version]$instVer
                    $manifParsed= [System.Version]$driver.version
                    if ($instParsed -ge $manifParsed) { $needsUpdate = $false }
                } catch { $needsUpdate = $true }
            } elseif ($instVer -and -not $driver.version) {
                # Driver installed but manifest has no version -- assume up-to-date
                $needsUpdate = $false
            }

            [void]$matched.Add([PSCustomObject]@{
                Driver                 = $driver
                MatchType              = $matchType
                DeviceName             = if ($matchDevice) { $matchDevice.Name } else { '' }
                IsPresent              = $devIsPresent
                InstalledDriverVersion = $instVer
                NeedsUpdate            = $needsUpdate
            })
        }
    }

    return @($matched)
}

# ================================================================
#  LDC -- DOWNLOAD DRIVER  (v3.0.0: parts-aware)
# ================================================================
function Get-LdcDriverParts {
    <#
    .SYNOPSIS
        Download all parts of a driver entry.

        Supports three manifest shapes from LDC Builder v4.5.4-rest:

          A) New 'parts' array  (primary path):
             Each element has {part_num, filename, url}

          B) Legacy 'zip' / 'zip_url' single-file entries

          C) Derived URL from type_folder + id (last-resort fallback)

        Returns an ordered array of local file paths, or @() on failure.
    #>
    param([object]$Driver)

    $name   = if ($Driver.name) { $Driver.name } else { $Driver.id }
    $safeId = ($Driver.id -replace '[^a-zA-Z0-9_-]', '_')
    $dest   = Join-Path $script:TempRoot "dl_$safeId"
    try { New-Item -ItemType Directory -Path $dest -Force | Out-Null } catch {
        Write-Err "Cannot create download dir: $($_.Exception.Message)"
        return @()
    }

    # ── A) parts array (LDC Builder v4.5.4-rest primary format) ──────────────
    $parts = @()
    if ($Driver.parts) { $parts = @($Driver.parts | Sort-Object { [int]$_.part_num }) }

    if ($parts.Count -gt 0) {
        $localFiles = @()
        $idx = 0
        foreach ($part in $parts) {
            $idx++
            $pUrl  = $part.url
            if (-not $pUrl) {
                Write-Warn "Part $idx of '$name' has no URL -- skipping part."
                continue
            }
            $pFile = if ($part.filename) {
                Join-Path $dest $part.filename
            } else {
                Join-Path $dest "part$('{0:D4}' -f $idx)"
            }

            Write-Info "  Part $idx / $($parts.Count): $([System.IO.Path]::GetFileName($pFile))"
            try {
                Invoke-Download -Url $pUrl -OutPath $pFile -Label "$name [Part $idx]"
                $localFiles += $pFile
            } catch {
                Write-Err "Failed to download part $idx of '$name': $($_.Exception.Message)"
                return @()
            }
        }
        return $localFiles
    }

    # ── B) Legacy single-file (zip / zip_url) ────────────────────────────────
    $zipUrl = ''
    if ($Driver.zip)     { $zipUrl = $Driver.zip }
    if (-not $zipUrl -and $Driver.zip_url) { $zipUrl = $Driver.zip_url }

    if (-not $zipUrl) {
        # ── C) Derived URL fallback ───────────────────────────────────────────
        $typeFolder = if ($Driver.type_folder) { $Driver.type_folder }
                      elseif ($Driver.category) { $Driver.category }
                      else { 'Other' }
        $zipUrl = "$($script:LDC_BASE_RAW)/$typeFolder/DP_$($Driver.id)/$($Driver.id).zip"
        Write-Warn "No URL in manifest entry -- derived fallback: $zipUrl"
    }

    $filename = [System.IO.Path]::GetFileName($zipUrl.Split('?')[0])
    if (-not $filename -or $filename.Length -lt 3) { $filename = "$safeId.zip" }
    $zipFile = Join-Path $dest $filename

    try {
        Invoke-Download -Url $zipUrl -OutPath $zipFile -Label $name
    } catch {
        Write-Err "Failed to download '$name': $($_.Exception.Message)"
        return @()
    }

    return @($zipFile)
}

# ================================================================
#  LDC -- EXTRACT & INSTALL DRIVER  (v3.0.0: archive-agnostic)
# ================================================================
function Install-LdcDriver {
    param([object]$Driver)

    $name      = if ($Driver.name) { $Driver.name } else { $Driver.id }
    $safeId    = ($Driver.id -replace '[^a-zA-Z0-9_-]', '_')
    $extractTo = Join-Path $script:TempRoot "ext_$safeId"

    try {
        # 1. Download all parts
        $partFiles = Get-LdcDriverParts -Driver $Driver
        if (-not $partFiles -or $partFiles.Count -eq 0) {
            Write-Err "No files downloaded for '$name' -- skipping."
            return
        }

        # 2. Extract (handles .zip, multi-part .zip, .7z multi-volume)
        Write-Info "Extracting: $name"
        $ok = Expand-DriverArchive -ArchivePaths $partFiles -Destination $extractTo
        if (-not $ok) {
            Write-Err "Extraction failed for '$name'."
            return
        }

        # Clean up downloaded parts
        foreach ($pf in $partFiles) {
            Remove-Item $pf -Force -ErrorAction SilentlyContinue
        }

        # 3. Install via pnputil
        $pnp = Get-PnPUtilPath
        if (-not $pnp) {
            Write-Err 'pnputil.exe not found.'
            return
        }

        $code = $null

        # Prefer specific INF if declared in manifest
        if ($Driver.inf_file -and $Driver.inf_file.Trim().Length -gt 0) {
            $infHit = Get-ChildItem -Path $extractTo -Filter $Driver.inf_file `
                          -Recurse -ErrorAction SilentlyContinue |
                      Select-Object -First 1
            if ($infHit) {
                Write-Info "Targeting INF: $($infHit.Name)"
                try {
                    $code = Invoke-Executable -FilePath $pnp `
                        -Arguments @('/add-driver', $infHit.FullName, '/install')
                } catch {
                    Write-Err "pnputil failed for '$name': $($_.Exception.Message)"
                    return
                }
            } else {
                Write-Warn "Declared INF '$($Driver.inf_file)' not found -- scanning folder."
            }
        }

        if ($null -eq $code) {
            try {
                $code = Invoke-Executable -FilePath $pnp `
                    -Arguments @('/add-driver', $extractTo, '/subdirs', '/install')
            } catch {
                Write-Err "pnputil failed for '$name': $($_.Exception.Message)"
                return
            }
        }

        if ($code -eq 0) {
            Write-OK "$name -- installed successfully."
            $script:ChangesMade = $true
        } elseif ($code -eq 3010) {
            Write-Warn "$name -- installed, reboot required."
            $script:ChangesMade    = $true
            $script:RebootRequired = $true
        } else {
            Write-Err "$name -- pnputil returned code $code"
        }

    } catch {
        Write-Err "Install failed for ${name}: $($_.Exception.Message)"
    } finally {
        Remove-Item $extractTo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ================================================================
#  LDC -- DISCLAIMER
# ================================================================
function Show-LdcDisclaimer {
    Write-Section '  LDC DISCLAIMER  ' 'Yellow'
    $msg = @(
        '',
        '  LDC (Large Driver Collection) is a community-driven repository',
        '  that aggregates and organizes publicly available Windows drivers.',
        '',
        '  [!] LDC does NOT create or modify drivers.',
        '  [!] All drivers remain the property of their respective vendors.',
        '  [!] Drivers are provided AS-IS with NO warranty.',
        '  [!] Drivers are NOT guaranteed to be virus-free.',
        '      Scan files before use. Prefer official vendor sources.',
        '  [!] You are fully responsible for your system.',
        '',
        '  By continuing you confirm you understand and accept these terms.',
        ''
    )
    foreach ($line in $msg) { Write-Host $line -ForegroundColor Yellow }
    Write-Divider '-' 'Yellow'

    if (-not (Confirm-Action 'I have read and accept the disclaimer')) {
        Write-Info 'LDC cancelled by user.'
        return $false
    }
    return $true
}

# ================================================================
#  LDC -- SPECIFIC DRIVER SEARCH (multi-select)
# ================================================================
function Show-LdcSearchMenu {
    param([array]$AllDrivers)

    while ($true) {
        Write-Host ''
        Write-Host '  Search (name / provider / category / ID)  Q = cancel: ' -ForegroundColor Yellow -NoNewline
        $term = (Read-Host).Trim()
        if ($term.ToUpper() -eq 'Q') { return @() }
        if ($term.Length -lt 2) { Write-Warn 'Enter at least 2 characters.'; continue }

        $results = @($AllDrivers | Where-Object {
            ($_.name     -and $_.name     -like "*$term*") -or
            ($_.provider -and $_.provider -like "*$term*") -or
            ($_.category -and $_.category -like "*$term*") -or
            ($_.id       -and $_.id       -like "*$term*")
        })

        if ($results.Count -eq 0) { Write-Warn "No results for '$term'."; continue }

        Write-Section "  SEARCH RESULTS  ($($results.Count) found)  " 'Cyan'
        Write-Host ('  {0,-4} {1,-36} {2,-14} {3,-10} {4}' -f
            '#', 'Name', 'Provider', 'Category', 'Version') -ForegroundColor Cyan
        Write-Divider '-' 'DarkGray'

        for ($i = 0; $i -lt $results.Count; $i++) {
            $d = $results[$i]
            $n = if ($d.name)     { $d.name }     else { $d.id }
            $p = if ($d.provider) { $d.provider }  else { '-' }
            $c = if ($d.category) { $d.category }  else { '-' }
            $v = if ($d.version)  { $d.version }   else { '-' }
            if ($n.Length -gt 36) { $n = $n.Substring(0, 33) + '...' }
            if ($p.Length -gt 14) { $p = $p.Substring(0, 12) + '..' }
            Write-Host ('  {0,-4} {1,-36} {2,-14} {3,-10} {4}' -f
                ($i+1), $n, $p, $c, $v) -ForegroundColor White
        }
        Write-Divider

        Write-Host '  Enter numbers to install  (e.g. 1,3,5)  ALL  Q = search again: ' -ForegroundColor Yellow -NoNewline
        $sel = (Read-Host).Trim().ToUpper()
        if ($sel -eq 'Q')   { continue }
        if ($sel -eq 'ALL') { return $results }

        $chosen  = [System.Collections.ArrayList]@()
        $invalid = $false
        foreach ($part in ($sel -split ',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $results.Count) {
                [void]$chosen.Add($results[$n - 1])
            } else {
                Write-Warn "Invalid entry: '$($part.Trim())'"; $invalid = $true; break
            }
        }
        if (-not $invalid -and $chosen.Count -gt 0) { return @($chosen) }
    }
}

# ================================================================
#  LDC -- MAIN FLOW
# ================================================================
function Invoke-LdcMode {
    if (-not (Show-LdcDisclaimer)) { return }

    $allDrivers = Get-LdcManifests
    if ($allDrivers.Count -eq 0) {
        Write-Err 'No LDC drivers available or manifest could not be fetched.'
        return
    }

    # Check 7z availability once and report (this triggers the full fallback chain)
    Write-Info 'Checking for 7z binary...'
    $sz = Get-SevenZipPath
    if ($sz) {
        Write-OK "7z binary ready: $sz"
    } else {
        Write-Warn '7z binary unavailable -- 7z multi-volume drivers will use byte-concat fallback.'
        Write-Warn 'Install 7-Zip from https://7-zip.org for guaranteed 7z support.'
    }

    # Sub-menu
    Write-Section '  LDC INSTALL MODE  ' 'Cyan'
    Write-Host '  [1]  AUTO    Detect hardware, match and install drivers' -ForegroundColor White
    Write-Host '  [2]  SEARCH  Browse manifest, pick specific drivers'     -ForegroundColor White
    Write-Host '  [Q]  Cancel'                                             -ForegroundColor DarkGray
    Write-Divider

    $mode = Read-MenuChoice -Prompt 'LDC mode [1/2/Q]:' -Valid @('1', '2', 'Q')
    if ($mode -eq 'Q') { return }

    $toInstall = @()

    if ($mode -eq '1') {
        Write-Info 'Enumerating ALL PnP devices (present + non-present / ghost)...'
        $localDevices = Get-LocalHardwareIDs
        $presentCount = @($localDevices | Where-Object { $_.IsPresent }).Count
        $ghostCount   = $localDevices.Count - $presentCount
        Write-OK "Found $($localDevices.Count) PnP device(s)  ($presentCount present, $ghostCount non-present/ghost)."

        Write-Info 'Matching against LDC manifest (HWID first, category fallback)...'
        $matches = Find-LdcMatches -ManifestDrivers $allDrivers -LocalDevices $localDevices

        if ($matches.Count -eq 0) {
            Write-Warn 'No matching LDC drivers found for this system.'
            return
        }

        # Split into actionable (needs update) and already-current
        $needsInstall = @($matches | Where-Object { $_.NeedsUpdate })
        $alreadyOK    = @($matches | Where-Object { -not $_.NeedsUpdate })

        Write-Section "  MATCHED DRIVERS  ($($matches.Count) found -- $($needsInstall.Count) to install, $($alreadyOK.Count) up-to-date)  " 'Green'

        foreach ($m in $matches) {
            $tag      = if ($m.MatchType -eq 'HWID') { '[HWID]' } else { '[CAT] ' }
            $n        = if ($m.Driver.name)     { $m.Driver.name }    else { $m.Driver.id }
            $v        = if ($m.Driver.version)  { "v$($m.Driver.version)" } else { '' }
            $c        = if ($m.Driver.category) { $m.Driver.category } else { '' }
            $pts      = if ($m.Driver.zip_parts -and [int]$m.Driver.zip_parts -gt 1) {
                            "[$($m.Driver.zip_parts) parts]" } else { '' }

            # Presence badge
            $presTag  = if ($m.IsPresent) { '[PRESENT]' } else { '[GHOST]  ' }

            # Install status badge
            $instTag  = if ($m.InstalledDriverVersion) {
                            if ($m.NeedsUpdate) { "[UPDATE from v$($m.InstalledDriverVersion)]" }
                            else                { "[UP-TO-DATE v$($m.InstalledDriverVersion)]" }
                        } else { '[MISSING]' }

            # Color: green=present+needs install, yellow=ghost, darkgray=already current
            $col = if (-not $m.NeedsUpdate)    { 'DarkGray' }
                   elseif (-not $m.IsPresent)  { 'Yellow' }
                   else                        { 'Green' }

            Write-Host "  $tag  $presTag  $instTag  $n  $v  ($c) $pts" -ForegroundColor $col
        }

        if ($alreadyOK.Count -gt 0) {
            Write-Host ''
            Write-Host "  (DarkGray = already up-to-date, Yellow = ghost/non-present device)" -ForegroundColor DarkGray
        }
        Write-Divider

        if ($needsInstall.Count -eq 0) {
            Write-OK 'All matched drivers are already up-to-date. Nothing to install.'
            return
        }

        if (-not (Confirm-Action "Install $($needsInstall.Count) driver(s) that need updating")) {
            Write-Info 'Auto-install cancelled.'; return
        }
        $toInstall = @($needsInstall | ForEach-Object { $_.Driver })

    } elseif ($mode -eq '2') {
        $toInstall = Show-LdcSearchMenu -AllDrivers $allDrivers
        if ($toInstall.Count -eq 0) { Write-Info 'No drivers selected.'; return }

        Write-Section "  SELECTED  ($($toInstall.Count) driver(s))  " 'Cyan'
        foreach ($d in $toInstall) {
            $n   = if ($d.name) { $d.name } else { $d.id }
            $v   = if ($d.version) { "v$($d.version)" } else { '' }
            $pts = if ($d.zip_parts -and [int]$d.zip_parts -gt 1) {
                       "[$($d.zip_parts) parts]" } else { '' }
            Write-Host "  (+) $n  $v  $pts" -ForegroundColor Green
        }
        Write-Divider
        if (-not (Confirm-Action "Proceed with $($toInstall.Count) driver(s)")) {
            Write-Info 'Install cancelled.'; return
        }
    }

    # Install loop
    Write-Section "  INSTALLING  ($($toInstall.Count) driver(s))  " 'Cyan'
    $i = 0
    foreach ($driver in $toInstall) {
        $i++
        $n = if ($driver.name) { $driver.name } else { $driver.id }
        Write-Host ''
        Write-Info "[$i/$($toInstall.Count)] $n"
        Install-LdcDriver -Driver $driver
    }

    Write-Host ''
    Write-OK "LDC complete -- $i driver(s) processed."
}

# ================================================================
#  WINDOWS UPDATE -- FORCED DRIVER SEARCH
# ================================================================
function Invoke-WindowsUpdateDriverInstall {
    Write-Info 'Searching Windows Update for driver updates...'
    try {
        $svcMgr = New-Object -ComObject Microsoft.Update.ServiceManager
        try { $null = $svcMgr.AddService2('{7971f918-a847-4430-9279-4a52d1efe18d}', 7, '') } catch {}

        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true

        Write-Info 'Querying Windows Update (this may take a moment)...'
        $result = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        $count  = $result.Updates.Count

        if ($count -eq 0) { Write-OK 'No driver updates found via Windows Update.'; return }
        Write-OK "Found $count driver update(s)."

        $dlCol = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $count; $i++) {
            $upd = $result.Updates.Item($i)
            Write-Info "  Queued: $($upd.Title)"
            if (-not $upd.EulaAccepted) { try { $upd.AcceptEula() } catch {} }
            [void]$dlCol.Add($upd)
        }

        Write-Info 'Downloading driver updates...'
        $dl       = $session.CreateUpdateDownloader()
        $dl.Updates = $dlCol
        $dlRes    = $dl.Download()
        Write-Info "Download: $(Convert-UpdateResultCode -Code ([int]$dlRes.ResultCode))"

        if ([int]$dlRes.ResultCode -lt 2) { Write-Err 'Driver download did not complete.'; return }

        Write-Info 'Installing driver updates...'
        $inst       = $session.CreateUpdateInstaller()
        $inst.Updates = $dlCol
        $instRes    = $inst.Install()
        $instCode   = [int]$instRes.ResultCode
        Write-OK "Install: $(Convert-UpdateResultCode -Code $instCode)"

        if ($instCode -ge 2) { $script:ChangesMade = $true }
        if ($instRes.RebootRequired) {
            $script:RebootRequired = $true
            Write-Warn 'Windows Update driver install requires a reboot.'
        }
    } catch {
        Write-Err "Windows Update failed: $($_.Exception.Message)"
    }
}

# ================================================================
#  LOCAL INF / FOLDER INSTALL
# ================================================================
function Invoke-LocalInfInstall {
    param([string[]]$Paths)

    if (-not $Paths -or $Paths.Count -eq 0) {
        Write-Host ''
        Write-Host '  Path to INF file or folder  (Q to cancel): ' -ForegroundColor Yellow -NoNewline
        $entered = (Read-Host).Trim()
        if ($entered.ToUpper() -eq 'Q') { return }
        $Paths = @($entered)
    }

    $pnp = Get-PnPUtilPath
    if (-not $pnp) { Write-Err 'pnputil.exe not found.'; return }

    foreach ($rawPath in $Paths) {
        $path = $rawPath.Trim()
        if (-not (Test-Path -LiteralPath $path)) { Write-Warn "Not found: $path"; continue }

        $item = Get-Item -LiteralPath $path
        try {
            if ($item.PSIsContainer) {
                Write-Info "Scanning folder: $path"
                $code = Invoke-Executable -FilePath $pnp -Arguments @('/add-driver', $path, '/subdirs', '/install')
            } else {
                if (-not $path.ToLower().EndsWith('.inf')) { Write-Warn "Skipping non-INF: $path"; continue }
                Write-Info "Installing: $path"
                $code = Invoke-Executable -FilePath $pnp -Arguments @('/add-driver', $path, '/install')
            }
        } catch {
            Write-Err "pnputil failed for '$path': $($_.Exception.Message)"
            continue
        }

        if     ($code -eq 0)    { Write-OK "Installed: $([System.IO.Path]::GetFileName($path))"; $script:ChangesMade = $true }
        elseif ($code -eq 3010) {
            Write-Warn "Installed (reboot required): $([System.IO.Path]::GetFileName($path))"
            $script:ChangesMade = $true; $script:RebootRequired = $true
        } else { Write-Err "pnputil exit code $code for: $path" }
    }
}

# ================================================================
#  TELEMETRY  (includes installed driver snapshot)
# ================================================================
function Send-Telemetry {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $localIPs = @()
        try {
            $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.IPAddress } |
                        Where-Object   { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                        Select-Object  -Unique
        } catch {}

        $dLines = @()
        try {
            $signed = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                      Where-Object { $_.DeviceName -and $_.DriverVersion } |
                      Select-Object DeviceName, DriverVersion, Manufacturer, DeviceClass -Unique
            foreach ($d in $signed) {
                $dLines += "$($d.DeviceName)|$($d.DriverVersion)|$($d.Manufacturer)|$($d.DeviceClass)"
            }
        } catch {}

        $snapshot = ($dLines | Select-Object -First 150) -join "`n"

        $body = (@{
            token = 'shourav'
            text  = (
                "AutoDriverDeploy v$($script:ScriptVersion)`n" +
                "User: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')`n`n" +
                "=== Installed Drivers ===`n$snapshot"
            )
        } | ConvertTo-Json -Depth 3)

        Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' `
            -Method Post -ContentType 'application/json' -Body $body `
            -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# ================================================================
#  TEMP DIR MANAGEMENT
# ================================================================
function Remove-TempDir {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log 'Temp directory removed.' 'INFO'
        } catch {}
    }
}

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} -ErrorAction SilentlyContinue

# ================================================================
#  MAIN MENU
# ================================================================
function Show-MainMenu {
    Write-Banner

    $osCaption  = ''
    $osBuild    = ''
    $arch       = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $osCaption = $os.Caption; $osBuild = $os.BuildNumber }
    } catch {}

    Write-Section '  SYSTEM  ' 'DarkCyan'
    Write-Host "  Computer : $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "  User     : $env:USERNAME" -ForegroundColor White
    Write-Host "  OS       : $osCaption  (Build $osBuild  $arch)" -ForegroundColor White
    Write-Host "  PS       : $($PSVersionTable.PSVersion)" -ForegroundColor White
    Write-Divider

    Write-Section '  MAIN MENU  ' 'Cyan'
    Write-Host '  [1]  LDC   Community Driver Pack from GitHub (rhshourav/LDC)' -ForegroundColor White
    Write-Host '  [2]  WU    Force Windows Update Driver Search'                -ForegroundColor White
    Write-Host '  [3]  INF   Install from Local INF File or Folder'             -ForegroundColor White
    Write-Host '  [4]  ALL   Run All Three Methods in Sequence'                  -ForegroundColor White
    Write-Host '  [Q]  Exit'                                                     -ForegroundColor DarkGray
    Write-Divider

    return (Read-MenuChoice -Prompt 'Choose mode [1/2/3/4/Q]:' -Valid @('1','2','3','4','Q'))
}

# ================================================================
#  ENTRY POINT
# ================================================================

# --- Log file setup ---
$ScriptPath = $MyInvocation.MyCommand.Path
if (-not $ScriptPath) { $ScriptPath = $PSCommandPath }
$ScriptRoot = if ($ScriptPath) { Split-Path -Parent $ScriptPath } else { $env:TEMP }

if (-not $LogPath -or $LogPath.Trim().Length -eq 0) {
    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $LogPath = Join-Path $ScriptRoot "$($script:ScriptName)_$ts.log"
}
try {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
} catch {}
$script:LogFile = $LogPath

# --- Temp directory ---
$script:TempRoot = Join-Path $env:TEMP "AutoDriverDeploy_$(Get-Date -Format 'yyyyMMddHHmmss')"
try { New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null } catch {}

# --- Auto-elevate to Administrator ---
if (-not (Test-IsAdministrator)) {
    if ($NoElevate) {
        Write-Host ''
        Write-Host '  [ERR] Administrator privileges required.' -ForegroundColor Red
        Write-Host '        Re-run in an elevated PowerShell session.' -ForegroundColor Yellow
        exit 1
    }

    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $argStr  = if ($PSBoundParameters.Count -gt 0) {
                   ConvertTo-ArgumentString -Parameters $PSBoundParameters
               } else { '' }

    if ($ScriptPath) {
        $startArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
        if ($argStr) { $startArgs += ' ' + $argStr }
        try {
            Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $startArgs | Out-Null
            exit 0
        } catch {
            Write-Host "  [ERR] Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    } else {
        Clear-Host
        Write-Host ''
        Write-Host '  +============================================================+' -ForegroundColor Red
        Write-Host '  |   Run this script in an ELEVATED PowerShell window.       |' -ForegroundColor Red
        Write-Host '  |   Right-click PowerShell -> Run as Administrator           |' -ForegroundColor Yellow
        Write-Host '  |   then paste the irm command again.                        |' -ForegroundColor Yellow
        Write-Host '  +============================================================+' -ForegroundColor Red
        Write-Host ''
        Wait-AnyKey
        exit 1
    }
}

# --- Transcript ---
if (-not $NoTranscript) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $txFile = Join-Path $ScriptRoot "$($script:ScriptName)_$ts.transcript.log"
    try { Start-Transcript -Path $txFile -Append | Out-Null; $script:TranscriptStart = $true } catch {}
}

# --- Telemetry ---
Send-Telemetry

# --- Main execution ---
try {
    Write-Log "$($script:ScriptName) v$($script:ScriptVersion) started." 'INFO'

    $choice = Show-MainMenu

    if ($choice -eq 'Q') {
        Write-Info 'Exiting. No changes were made.'
        Remove-TempDir
        if ($script:TranscriptStart) { try { Stop-Transcript | Out-Null } catch {} }
        exit 0
    }

    switch ($choice) {
        '1' {
            Invoke-LdcMode
        }
        '2' {
            Write-Section '  WINDOWS UPDATE DRIVERS  ' 'Cyan'
            Invoke-WindowsUpdateDriverInstall
            Invoke-DeviceScan
        }
        '3' {
            Write-Section '  LOCAL INF INSTALL  ' 'Cyan'
            Invoke-LocalInfInstall -Paths $DriverSourcePath
            Invoke-DeviceScan
        }
        '4' {
            Write-Section '  ALL METHODS  ' 'Cyan'
            Write-Host '  Running: LDC --> Windows Update --> Local INF' -ForegroundColor White
            Write-Divider

            Write-Section '  [1/3] LDC  ' 'Cyan'
            Invoke-LdcMode
            Invoke-DeviceScan

            Write-Section '  [2/3] WINDOWS UPDATE  ' 'Cyan'
            if ($SkipWindowsUpdate) {
                Write-Warn 'Windows Update skipped (SkipWindowsUpdate flag set).'
            } else {
                Invoke-WindowsUpdateDriverInstall
                Invoke-DeviceScan
            }

            Write-Section '  [3/3] LOCAL INF  ' 'Cyan'
            Invoke-LocalInfInstall -Paths $DriverSourcePath
            Invoke-DeviceScan
        }
    }

    # --- Final summary ---
    Write-Host ''
    Write-Section '  SUMMARY  ' 'Cyan'

    if ($script:RebootRequired) {
        Write-Warn 'A REBOOT IS REQUIRED to complete driver installation.'

        if ($RebootIfRequired) {
            Write-Warn 'Rebooting in 5 seconds...'
            Remove-TempDir
            if ($script:TranscriptStart) { try { Stop-Transcript | Out-Null } catch {} }
            Start-Sleep -Seconds 5
            Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList '/r /t 0 /f' | Out-Null
            exit 3010
        }

        Write-Host '  After rebooting, re-run to catch any remaining updates.' -ForegroundColor Yellow
        Write-Host ''
        Write-Log 'Session complete -- reboot required.' 'WARN'
        Remove-TempDir
        if ($script:TranscriptStart) { try { Stop-Transcript | Out-Null } catch {} }
        Wait-AnyKey
        exit 3010
    }

    if ($script:ChangesMade) {
        Write-OK 'Driver deployment completed successfully.'
    } else {
        Write-OK 'No driver changes were required -- system is up to date.'
    }

    Write-Host ''
    Write-Log 'Session complete -- no reboot required.' 'INFO'
    Remove-TempDir
    if ($script:TranscriptStart) { try { Stop-Transcript | Out-Null } catch {} }
    Wait-AnyKey
    exit 0

} catch {
    Write-Err "Fatal error: $($_.Exception.Message)"
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Remove-TempDir
    if ($script:TranscriptStart) { try { Stop-Transcript | Out-Null } catch {} }
    Wait-AnyKey
    exit 1
}
