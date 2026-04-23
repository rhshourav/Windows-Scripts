# ============================================================
#
#  ########  ##     ##  ######  ##     ##  #######  ##     ##
#  ##     ## ##     ## ##    ## ##     ## ##     ## ##     ##
#  ##     ## ##     ## ##       ##     ## ##     ## ##     ##
#  ########  ######### ######   ######### ##     ## ##     ##
#  ##   ##   ##     ## ##       ##     ## ##     ## ##     ##
#  ##    ##  ##     ## ##    ## ##     ## ##     ## ##     ##
#  ##     ## ##     ##  ######  ##     ##  #######   #######
#
#  ============================================================
#  Office Suite Universal Installer
#  Author  : rhshourav
#  GitHub  : https://github.com/rhshourav/Windows-Scripts
#  Version : 4.0.0  |  Windows 10 / 11  |  x64
#  ============================================================
#
#  USAGE (run as Administrator):
#    iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-Office.ps1")
#
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
Set-StrictMode -Off

# ================================================================
#  CONSTANTS
# ================================================================
$SCRIPT_VER  = "4.0.0"
$SCRIPT_AUTH = "rhshourav"
$SCRIPT_REPO = "https://github.com/rhshourav/Windows-Scripts"
$CON_W       = 80

$PACKAGES = @(
    [ordered]@{
        Id      = 1
        Name    = "Microsoft 365 (Office 365)"
        Short   = "M365"
        ZipUrl  = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/O365.zip"
        ZipName = "O365.zip"
        Xml     = "windows64bit.xml"
    },
    [ordered]@{
        Id      = 2
        Name    = "Office LTSC 2021"
        Short   = "LTSC2021"
        ZipUrl  = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/OLTSC-2021.zip"
        ZipName = "OLTSC-2021.zip"
        Xml     = "Configuration.xml"
    },
    [ordered]@{
        Id      = 3
        Name    = "Office LTSC 2024"
        Short   = "LTSC2024"
        ZipUrl  = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/OLTSC-2024.zip"
        ZipName = "OLTSC-2024.zip"
        Xml     = "Configuration.xml"
    },
    [ordered]@{
        Id      = 4
        Name    = "Office 2019"
        Short   = "O2019"
        ZipUrl  = "https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/O2019.zip"
        ZipName = "O2019.zip"
        Xml     = "Configuration.xml"
    }
)

# ================================================================
#  CONSOLE THEME
# ================================================================
function Set-Theme {
    try {
        $h = $Host.UI.RawUI
        $h.BackgroundColor = 'Black'
        $h.ForegroundColor = 'White'
        try {
            $ws = $h.WindowSize
            if ($ws.Width -lt ($CON_W + 2)) {
                $ws.Width  = $CON_W + 2
                $h.WindowSize = $ws
            }
        } catch {}
    } catch {}
    Clear-Host
}

# ================================================================
#  UI HELPERS
# ================================================================
function Write-C {
    param([string]$msg, [string]$col = 'White', [switch]$NoNewLine)
    if ($NoNewLine) { Write-Host $msg -ForegroundColor $col -NoNewline }
    else            { Write-Host $msg -ForegroundColor $col }
}

function Write-Div {
    param([string]$char = '-', [string]$col = 'DarkGray')
    Write-C ($char * $CON_W) $col
}

function Write-Step { param([string]$m); Write-C "  [>>] $m" 'Yellow'   }
function Write-OK   { param([string]$m); Write-C "  [OK] $m" 'Green'    }
function Write-Warn { param([string]$m); Write-C "  [!!] $m" 'Yellow'   }
function Write-Fail { param([string]$m); Write-C "  [XX] $m" 'Red'      }
function Write-Info { param([string]$m); Write-C "       $m" 'DarkGray' }

# ================================================================
#  PROGRESS BAR
#
#  Format:
#   Label (14 chars) [bar (32 chars)] PCT%  Info
#
#  Uses \r to overwrite on the same line. Line is always padded
#  to exactly $CON_W-1 chars to prevent bleed-through and wrap.
#
#  $Pct = -1  => bouncing indeterminate block
#  $Pct = 0-100 => filled deterministic bar
# ================================================================
$script:BarTick = 0

function Show-Bar {
    param(
        [string]$Label,
        [int]   $Pct,
        [string]$Info = ''
    )

    $script:BarTick++
    $BAR_W = 32   # inner fill width

    # ---- build the fill / bounce section ----
    if ($Pct -lt 0) {
        # Bounce: a 4-char wide block oscillates across the bar
        $range = $BAR_W - 4
        $pos   = $script:BarTick % ($range * 2)
        if ($pos -gt $range) { $pos = ($range * 2) - $pos }
        $inner = (' ' * $pos) + '<=>' + (' ' * ($range - $pos + 1))
        $bar   = "[${inner}]"
        $pStr  = '  ...'
    } else {
        $filled = [Math]::Max(0, [Math]::Min($BAR_W, [int][Math]::Round($Pct / 100.0 * $BAR_W)))
        $empty  = $BAR_W - $filled
        $inner  = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * $empty)
        $bar    = "[${inner}]"
        $pStr   = (" {0,3}%" -f $Pct)
    }

    # ---- assemble line ----
    $lbl     = ("  {0}" -f $Label.PadRight(14).Substring(0, 14))
    $right   = "${pStr}  ${Info}"
    $content = "${lbl} ${bar}${right}"

    # Pad / truncate to exactly CON_W-1 so it never wraps
    $max = $CON_W - 1
    if ($content.Length -gt $max) { $content = $content.Substring(0, $max) }
    $content = $content.PadRight($max)

    Write-Host "`r${content}" -NoNewline -ForegroundColor Cyan
}

function Clear-Bar {
    Write-Host ("`r" + (' ' * ($CON_W - 1)) + "`r") -NoNewline
}

# ================================================================
#  BANNER
# ================================================================
function Write-Banner {
    Clear-Host
    Write-C ""
    Write-C "  ########  ##     ##  ######  ##     ##  #######  ##     ## " 'Cyan'
    Write-C "  ##     ## ##     ## ##    ## ##     ## ##     ## ##     ## " 'Cyan'
    Write-C "  ##     ## ##     ## ##       ##     ## ##     ## ##     ## " 'Cyan'
    Write-C "  ########  ######### ######   ######### ##     ## ##     ## " 'Cyan'
    Write-C "  ##   ##   ##     ## ##       ##     ## ##     ## ##     ## " 'Cyan'
    Write-C "  ##    ##  ##     ## ##    ## ##     ## ##     ## ##     ## " 'Cyan'
    Write-C "  ##     ## ##     ##  ######  ##     ##  #######   ####### " 'Cyan'
    Write-C ""
    Write-Div '=' 'DarkCyan'
    Write-C ("  Office Suite Universal Installer  v{0}  |  {1}" -f $SCRIPT_VER, $SCRIPT_AUTH) 'White'
    Write-C ("  {0}" -f $SCRIPT_REPO) 'DarkGray'
    Write-Div '=' 'DarkCyan'
    Write-C ""
}

# ================================================================
#  ADMIN CHECK
# ================================================================
function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal]
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Fail "Administrator privileges required."
        Write-Info "Right-click PowerShell and select 'Run as administrator'."
        Write-C ""
        Read-Host "  Press ENTER to exit"
        exit 1
    }

    Write-OK "Running as Administrator."
}

# ================================================================
#  TLS
# ================================================================
function Enable-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12
    } catch {}
}

# ================================================================
#  TELEMETRY  (non-blocking, swallowed)
# ================================================================
function Send-Telemetry {
    param($pkg)
    try {
        $ips = (Get-CimInstance Win32_NetworkAdapterConfiguration `
                    -Filter 'IPEnabled=True' -EA SilentlyContinue |
                ForEach-Object { $_.IPAddress } |
                Where-Object   { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                Select-Object  -Unique) -join ', '

        $body = ([ordered]@{
            token = 'shourav'
            text  = ("Office Installer v{0} | {1}`nUser:{2}  PC:{3}  IP:{4}" -f
                     $SCRIPT_VER, $pkg.Short,
                     $env:USERNAME, $env:COMPUTERNAME, $ips)
        } | ConvertTo-Json)

        Invoke-RestMethod `
            -Uri         'https://cryocore.rhshourav02.workers.dev/message' `
            -Method      Post `
            -ContentType 'application/json' `
            -Body        $body `
            -TimeoutSec  5 `
            -EA          SilentlyContinue | Out-Null
    } catch {}
}

# ================================================================
#  DOWNLOAD  — BITS primary, IWR fallback, real-time progress
# ================================================================
function Get-FileProgress {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label
    )

    Enable-Tls

    # ---- BITS (true byte-level progress) ----
    $bitsOk = $false
    try {
        Import-Module BitsTransfer -EA Stop
        $job = Start-BitsTransfer -Source $Url -Destination $Dest -Asynchronous -EA Stop
        $bitsOk = $true

        while ($job.JobState -notin @('Transferred', 'Error', 'TransientError')) {
            $tot  = $job.BytesTotal
            $recv = $job.BytesTransferred
            if ($tot -gt 0) {
                $pct  = [int]($recv / $tot * 100)
                $info = "{0:N1}/{1:N1} MB" -f ($recv / 1MB), ($tot / 1MB)
                Show-Bar $Label $pct $info
            } else {
                Show-Bar $Label -1 "connecting..."
            }
            Start-Sleep -Milliseconds 400
        }

        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job -EA SilentlyContinue
            Clear-Bar
            return
        }

        # BITS failed — fall through to IWR
        Remove-BitsTransfer -BitsJob $job -EA SilentlyContinue
    } catch {
        $bitsOk = $false
    }

    # ---- IWR fallback ----
    Show-Bar $Label -1 "connecting..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -EA Stop
    } catch {
        Clear-Bar
        throw "Download failed: $_"
    }
    Clear-Bar
}

# ================================================================
#  XML PATCHER  — force fully silent, no EULA, no UI popup
#  Handles both missing and existing <Display> elements
# ================================================================
function Set-SilentXml {
    param([string]$Path)
    try {
        $txt = Get-Content -LiteralPath $Path -Raw

        if ($txt -match '<Display\b') {
            # Replace existing Display element entirely
            $txt = $txt -replace '<Display[^/]*/>', `
                '<Display Level="None" AcceptEULA="TRUE" />'
            $txt = $txt -replace '<Display[^>]*>.*?</Display>', `
                '<Display Level="None" AcceptEULA="TRUE" />'
        } else {
            # Inject before closing tag
            $inject = "  <Display Level=`"None`" AcceptEULA=`"TRUE`" />`r`n"
            $txt = $txt -replace '</Configuration>', "${inject}</Configuration>"
        }

        # Also ensure FORCEAPPSHUTDOWN so we don't stall on open apps
        if ($txt -notmatch 'FORCEAPPSHUTDOWN') {
            $inject2 = "  <Property Name=`"FORCEAPPSHUTDOWN`" Value=`"TRUE`" />`r`n"
            $txt = $txt -replace '</Configuration>', "${inject2}</Configuration>"
        }

        Set-Content -LiteralPath $Path -Value $txt -Encoding UTF8
    } catch {
        Write-Warn "XML patch skipped: $_"
    }
}

# ================================================================
#  CHILD PROCESS HELPER  — get direct children of a PID
# ================================================================
function Get-ChildPIDs {
    param([int]$ParentPID)
    try {
        return @(Get-CimInstance Win32_Process `
                    -Filter "ParentProcessId=$ParentPID" `
                    -EA SilentlyContinue |
                Select-Object -ExpandProperty ProcessId)
    } catch {
        return @()
    }
}

# ================================================================
#  WATCH ODT /download  — phase 1 (manifests / CAB index only)
#  This is fast — completes in seconds to ~1 minute.
# ================================================================
function Watch-OdtDownload {
    param(
        [System.Diagnostics.Process]$Proc,
        [string]$OfficeDir,
        [string]$Label
    )

    $lastCount = 0
    $sameFor   = 0
    $timeout   = 300   # 5 min hard cap for manifest phase

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    do {
        $Proc.Refresh()

        $count = 0
        if (Test-Path $OfficeDir) {
            $count = @(Get-ChildItem $OfficeDir -Recurse -File -EA SilentlyContinue).Count
        }

        if ($count -ne $lastCount) { $sameFor = 0; $lastCount = $count }
        else                       { $sameFor++ }

        $info = "$count files"
        if ($sameFor -gt 8)              { $info = "$count files (finishing...)" }
        if ($sw.Elapsed.TotalSeconds -gt $timeout) { break }   # safety bail

        $pct = [Math]::Min(99, $count * 8)
        Show-Bar $Label $pct $info
        Start-Sleep -Seconds 2

    } while (-not $Proc.HasExited)

    Clear-Bar
}

# ================================================================
#  WATCH ODT /configure  — phase 2 (download + install, 1-3 GB)
#
#  FIX: Multi-vector monitoring to avoid false "stuck" detection:
#    1. Disk MB growth of the Office cache folder
#    2. Active child process count under setup.exe
#    3. Fallback: spinning indeterminate if no disk growth but
#       child processes are still alive (install phase)
# ================================================================
function Watch-OdtConfigure {
    param(
        [System.Diagnostics.Process]$Proc,
        [string]$WorkDir,
        [string]$Label
    )

    $cacheDir  = Join-Path $WorkDir "Office"
    $spin      = @('|', '/', '-', '\')
    $tick      = 0
    $lastMB    = 0
    $stuckFor  = 0
    $STUCK_THR = 30    # ticks (~90s) before we treat as "install phase"
    $TOTAL_MB  = 2200  # assumed total download for percent estimation

    do {
        $Proc.Refresh()
        $tick++

        # -- disk size measurement --
        $sizeMB = 0
        if (Test-Path $cacheDir) {
            try {
                $sum = (Get-ChildItem $cacheDir -Recurse -File -EA SilentlyContinue |
                        Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
                if ($sum) { $sizeMB = [int]($sum / 1MB) }
            } catch {}
        }

        if ($sizeMB -gt $lastMB) { $stuckFor = 0; $lastMB = $sizeMB }
        else                     { $stuckFor++ }

        # -- child process check --
        $childPIDs = Get-ChildPIDs -ParentPID $Proc.Id
        $hasKids   = ($childPIDs.Count -gt 0)

        $s = $spin[$tick % 4]

        if ($stuckFor -gt $STUCK_THR) {
            # Disk not growing — likely in unpack/registry-write install phase
            if ($hasKids) {
                Show-Bar $Label -1 "$s installing...  ${sizeMB}MB cached"
            } else {
                Show-Bar $Label -1 "$s finalising..."
            }
        } else {
            $pct  = [Math]::Min(99, [int]($sizeMB / $TOTAL_MB * 100))
            $info = "$s ${sizeMB}MB / ~${TOTAL_MB}MB"
            Show-Bar $Label $pct $info
        }

        Start-Sleep -Seconds 3

    } while (-not $Proc.HasExited)

    Clear-Bar
}

# ================================================================
#  VERIFY
# ================================================================
function Test-OfficePresent {
    $paths = @(
        "$env:ProgramFiles\Microsoft Office\Office16\WINWORD.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\WINWORD.EXE"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    return $false
}

# ================================================================
#  INSTALL ONE PACKAGE
# ================================================================
function Install-Package {
    param($pkg)

    $uid     = ([Guid]::NewGuid().ToString('N')).Substring(0, 8)
    $workDir = Join-Path $env:TEMP ("OffInst_{0}_{1}" -f $pkg.Short, $uid)
    $zipPath = Join-Path $workDir $pkg.ZipName

    Write-C ""
    Write-Div '=' 'DarkCyan'
    Write-C ("  [ {0} ]" -f $pkg.Name) 'Cyan'
    Write-Div '-' 'DarkCyan'
    Write-C ""

    Send-Telemetry $pkg

    $success = $false
    try {

        # -- 1. Work dir --
        New-Item -ItemType Directory -Path $workDir -Force -EA Stop | Out-Null
        Write-Step "Work directory created."

        # -- 2. Download ZIP --
        Write-Step "Downloading installer package..."
        Enable-Tls
        Get-FileProgress -Url $pkg.ZipUrl -Dest $zipPath -Label "Download"

        if (-not (Test-Path $zipPath)) {
            throw "ZIP not found after download. Verify URL: $($pkg.ZipUrl)"
        }
        Write-OK ("Package received  ({0:N1} MB)" -f ((Get-Item $zipPath).Length / 1MB))

        # -- 3. Extract --
        Write-Step "Extracting archive..."
        try {
            Expand-Archive -Path $zipPath -DestinationPath $workDir -Force -EA Stop
        } catch {
            throw "Extraction failed: $_"
        }
        Write-OK "Extracted."

        # Remove ZIP immediately to free space
        Remove-Item -LiteralPath $zipPath -Force -EA SilentlyContinue

        # -- 4. Locate setup.exe + XML --
        $setupExe = Get-ChildItem $workDir -Recurse -Filter 'setup.exe' `
                        -File -EA SilentlyContinue | Select-Object -First 1
        $cfgXml   = Get-ChildItem $workDir -Recurse -Filter $pkg.Xml `
                        -File -EA SilentlyContinue | Select-Object -First 1

        if (-not $setupExe) { throw "setup.exe not found in extracted package." }
        if (-not $cfgXml)   { throw "$($pkg.Xml) not found in extracted package." }

        Write-Info "Exe    : $($setupExe.FullName)"
        Write-Info "Config : $($cfgXml.FullName)"

        # -- 5. Patch XML --
        Set-SilentXml $cfgXml.FullName
        Write-OK "Config patched: silent mode, no EULA, force app shutdown."

        # ----------------------------------------------------------------
        # -- 6. ODT /download  (manifests + CAB index — fast, small) --
        # ----------------------------------------------------------------
        Write-C ""
        Write-Div '-' 'DarkGray'
        Write-Step "Phase 1/2  --  Manifest download"
        Write-Info "Downloads a small set of index files. Completes in <1 min."
        Write-C ""

        $officeDir = Join-Path $workDir "Office"

        $dlProc = Start-Process `
            -FilePath       $setupExe.FullName `
            -ArgumentList   "/download `"$($cfgXml.FullName)`"" `
            -WorkingDirectory $workDir `
            -PassThru -EA Stop

        if ($null -eq $dlProc) { throw "Could not launch ODT /download." }

        Watch-OdtDownload -Proc $dlProc -OfficeDir $officeDir -Label "Manifests"

        $dlProc.Refresh()
        if ($dlProc.ExitCode -ne 0) {
            throw "ODT /download exit code $($dlProc.ExitCode).  Check: $env:TEMP\USL-*.log"
        }
        Write-OK "Manifests ready."

        # ----------------------------------------------------------------
        # -- 7. ODT /configure  (full download + install, 1-3 GB) --
        # ----------------------------------------------------------------
        Write-C ""
        Write-Div '-' 'DarkGray'
        Write-Step "Phase 2/2  --  Downloading + Installing"
        Write-Info "Streams ~1-3 GB direct from Microsoft CDN.  Time: 5-30 min."
        Write-Info "Do NOT close this window."
        Write-C ""

        $instProc = Start-Process `
            -FilePath       $setupExe.FullName `
            -ArgumentList   "/configure `"$($cfgXml.FullName)`"" `
            -WorkingDirectory $workDir `
            -PassThru -EA Stop

        if ($null -eq $instProc) { throw "Could not launch ODT /configure." }

        Watch-OdtConfigure -Proc $instProc -WorkDir $workDir -Label "DL+Install"

        $instProc.Refresh()
        if ($instProc.ExitCode -ne 0) {
            throw "ODT /configure exit code $($instProc.ExitCode).  Check: $env:TEMP\USL-*.log"
        }
        Write-OK "Installation command completed (exit 0)."

        # -- 8. Verify --
        Write-C ""
        if (Test-OfficePresent) {
            Write-OK "Verified: WINWORD.EXE present."
        } else {
            Write-Warn "WINWORD.EXE not in default path — launch Word to confirm."
        }

        $success = $true

    } catch {
        Write-C ""
        Write-Fail "Install failed: $($pkg.Name)"
        Write-Fail "Reason : $_"

    } finally {
        # Always clean up — no leftovers
        try {
            if (Test-Path $workDir) {
                Write-C ""
                Write-Step "Removing temp files..."
                Remove-Item -LiteralPath $workDir -Recurse -Force -EA SilentlyContinue
                Write-OK "Temp cleaned."
            }
        } catch {}
    }

    return $success
}

# ================================================================
#  MENU
# ================================================================
function Show-Menu {
    Write-C ""
    Write-Div '=' 'DarkCyan'
    Write-C "  Available packages" 'White'
    Write-Div '-' 'DarkGray'
    Write-C ""
    foreach ($p in $PACKAGES) {
        Write-C ("  [{0}]  {1}" -f $p.Id, $p.Name) 'Yellow'
    }
    Write-C ""
    Write-Div '-' 'DarkGray'
    Write-C "  [A]  Install ALL packages" 'Green'
    Write-C "  [Q]  Quit" 'Red'
    Write-C ""
    Write-Info "Separate multiple IDs with commas:  1  or  1,3  or  A"
    Write-C ""
    Write-C "  > " 'Cyan' -NoNewLine
}

function Resolve-Selection {
    param([string]$raw)
    $raw = $raw.Trim()

    if ($raw -match '^[Qq]$') { return 'QUIT' }
    if ($raw -match '^[Aa]$') { return $PACKAGES }

    $sel = [System.Collections.Generic.List[object]]::new()
    foreach ($tok in ($raw -split ',')) {
        $tok = $tok.Trim()
        $id  = 0
        if ([int]::TryParse($tok, [ref]$id)) {
            $match = $PACKAGES | Where-Object { $_.Id -eq $id }
            if ($match) { $sel.Add($match) }
            else        { Write-Warn "Unknown option '$tok' — ignored." }
        }
    }
    return $sel
}

# ================================================================
#  ENTRY POINT
# ================================================================

Set-Theme
Enable-Tls
Write-Banner
Assert-Admin

Write-C ""
Write-Info "Machine : $env:COMPUTERNAME"
Write-Info "User    : $env:USERNAME"
Write-Info "OS      : $([System.Environment]::OSVersion.VersionString)"
Write-C ""

Show-Menu
$raw = Read-Host

$sel = Resolve-Selection $raw

if ($sel -eq 'QUIT') {
    Write-C ""
    Write-C "  Aborted." 'Yellow'
    Write-C ""
    exit 0
}

$queue = @($sel)

if ($queue.Count -eq 0) {
    Write-C ""
    Write-Warn "Nothing selected. Exiting."
    Write-C ""
    exit 0
}

Write-C ""
Write-Div '-' 'DarkCyan'
Write-C "  Queued for installation:" 'White'
Write-C ""
foreach ($p in $queue) {
    Write-C ("    +  {0}" -f $p.Name) 'Cyan'
}
Write-C ""
Write-C "  Continue? [Y/N] > " 'White' -NoNewLine
$confirm = (Read-Host).Trim()
if ($confirm -notmatch '^[Yy]$') {
    Write-C ""
    Write-C "  Cancelled." 'Yellow'
    Write-C ""
    exit 0
}

# ---- Run installs ----
$results = [ordered]@{}
foreach ($pkg in $queue) {
    $results[$pkg.Name] = (Install-Package $pkg)
}

# ---- Summary ----
Write-C ""
Write-Div '=' 'DarkCyan'
Write-C "  SUMMARY" 'White'
Write-Div '-' 'DarkGray'
Write-C ""
foreach ($name in $results.Keys) {
    if ($results[$name]) {
        Write-C ("  [OK]  {0}" -f $name) 'Green'
    } else {
        Write-C ("  [XX]  {0}  -- see errors above" -f $name) 'Red'
    }
}
Write-C ""
Write-Info "Logs : $env:TEMP\USL-*.log"
Write-Info "Next : Launch Word or Excel to verify and activate."
Write-Div '=' 'DarkCyan'
Write-C ""
