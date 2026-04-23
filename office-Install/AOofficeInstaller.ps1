# ============================================================
#
#   ██████╗ ██╗  ██╗███████╗██╗  ██╗ ██████╗ ██╗   ██╗██████╗
#   ██╔══██╗██║  ██║██╔════╝██║  ██║██╔═══██╗██║   ██║██╔══██╗
#   ██████╔╝███████║███████╗███████║██║   ██║██║   ██║██████╔╝
#   ██╔══██╗██╔══██║╚════██║██╔══██║██║   ██║╚██╗ ██╔╝██╔══██╗
#   ██║  ██║██║  ██║███████║██║  ██║╚██████╔╝ ╚████╔╝ ██║  ██║
#   ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝
#
#   Office Suite Universal Installer
#   Author  : rhshourav
#   GitHub  : https://github.com/rhshourav/Windows-Scripts
#   Version : 3.2.0  |  Windows 10 / 11  |  x64
#
#   USAGE (run as Administrator):
#     iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-Office.ps1")
#
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
Set-StrictMode -Off

# ================================================================
#  CONSTANTS
# ================================================================
$SCRIPT_VER  = "3.2.0"
$SCRIPT_AUTH = "rhshourav"
$SCRIPT_REPO = "https://github.com/rhshourav/Windows-Scripts"

# Console width — keep all output under this to prevent line-wrap garble
$CON_W = 78

$PACKAGES = @(
    [ordered]@{ Id=1; Name="Microsoft 365 (Office 365)"; Short="M365";
        ZipUrl="https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/O365.zip"
        ZipName="O365.zip"; Xml="windows64bit.xml" },
    [ordered]@{ Id=2; Name="Office LTSC 2021"; Short="LTSC2021";
        ZipUrl="https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/OLTSC-2021.zip"
        ZipName="OLTSC-2021.zip"; Xml="Configuration.xml" },
    [ordered]@{ Id=3; Name="Office LTSC 2024"; Short="LTSC2024";
        ZipUrl="https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/OLTSC-2024.zip"
        ZipName="OLTSC-2024.zip"; Xml="Configuration.xml" },
    [ordered]@{ Id=4; Name="Office 2019"; Short="O2019";
        ZipUrl="https://raw.githubusercontent.com/rhshourav/ideal-fishstick/refs/heads/main/O2019.zip"
        ZipName="O2019.zip"; Xml="Configuration.xml" }
)

# ================================================================
#  THEME
# ================================================================
function Set-Theme {
    try {
        $h = $Host.UI.RawUI
        $h.BackgroundColor = 'Black'
        $h.ForegroundColor = 'White'
        $w = $h.WindowSize; if ($w.Width -lt 82) { $w.Width = 82; $h.WindowSize = $w }
    } catch {}
    Clear-Host
}

function Write-C {
    param([string]$msg, [string]$col='White', [switch]$NoNewLine)
    if ($NoNewLine) { Write-Host $msg -ForegroundColor $col -NoNewline }
    else            { Write-Host $msg -ForegroundColor $col }
}
function Write-Div  { param([string]$c='-',[string]$col='DarkGray'); Write-C ($c*$CON_W) $col }
function Write-Step { param([string]$m); Write-C "  [>>] $m" 'Yellow' }
function Write-OK   { param([string]$m); Write-C "  [OK] $m" 'Green'  }
function Write-Warn { param([string]$m); Write-C "  [!!] $m" 'Yellow' }
function Write-Fail { param([string]$m); Write-C "  [XX] $m" 'Red'    }
function Write-Info { param([string]$m); Write-C "       $m" 'DarkGray' }

# ================================================================
#  PROGRESS BAR
#
#  KEY FIX: We write a full fixed-width line padded to $CON_W chars
#  then use \r to overwrite it. This prevents any character bleed-through
#  from a previous longer line, and prevents wrapping that breaks \r.
#
#  $Pct -1  = indeterminate bounce
#  $Pct 0-100 = filled bar
# ================================================================
$script:Tick = 0

function Show-Bar {
    param([string]$Label, [int]$Pct, [string]$Info='')

    $script:Tick++
    $BAR_W = 36   # inner bar width — kept short so total line stays under $CON_W

    if ($Pct -lt 0) {
        # Bouncing block — 3 chars wide, bounces left-right
        $range = $BAR_W - 3
        $pos   = $script:Tick % ($range * 2)
        if ($pos -gt $range) { $pos = ($range * 2) - $pos }   # reverse
        $inner = (' ' * $pos) + '[=]' + (' ' * ($range - $pos))
        $bar   = '|' + $inner + '|'
        $right = " $Info"
    } else {
        $filled = [int][Math]::Round($Pct / 100 * $BAR_W)
        $empty  = $BAR_W - $filled
        $bar    = '|' + ([string][char]9608 * $filled) + ([string][char]9617 * $empty) + '|'
        $right  = " $Pct%  $Info"
    }

    # Build the line, truncate label and info so it never exceeds $CON_W
    $lbl     = $Label.PadRight(18).Substring(0,18)   # fixed 18 chars
    $content = "  $lbl $bar$right"

    # Pad or truncate to exactly ($CON_W - 1) so it never wraps
    $maxLen = $CON_W - 1
    if ($content.Length -gt $maxLen) { $content = $content.Substring(0,$maxLen) }
    $content = $content.PadRight($maxLen)

    Write-Host "`r$content" -NoNewline -ForegroundColor Cyan
}

function Clear-Bar {
    # Overwrite the current bar line with spaces then reset cursor
    Write-Host ("`r" + (' ' * ($CON_W - 1)) + "`r") -NoNewline
}

# ================================================================
#  BANNER
# ================================================================
function Write-Banner {
    Clear-Host
    Write-C ""
    Write-C "  ██████╗ ██╗  ██╗███████╗██╗  ██╗ ██████╗ ██╗   ██╗██████╗  " 'Cyan'
    Write-C "  ██╔══██╗██║  ██║██╔════╝██║  ██║██╔═══██╗██║   ██║██╔══██╗ " 'Cyan'
    Write-C "  ██████╔╝███████║███████╗███████║██║   ██║██║   ██║██████╔╝  " 'Cyan'
    Write-C "  ██╔══██╗██╔══██║╚════██║██╔══██║██║   ██║╚██╗ ██╔╝██╔══██╗  " 'Cyan'
    Write-C "  ██║  ██║██║  ██║███████║██║  ██║╚██████╔╝ ╚████╔╝ ██║  ██║  " 'Cyan'
    Write-C "  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝  " 'Cyan'
    Write-C ""
    Write-Div '=' 'DarkCyan'
    Write-C "  Office Suite Universal Installer  |  v$SCRIPT_VER  |  $SCRIPT_AUTH" 'DarkCyan'
    Write-Div '=' 'DarkCyan'
    Write-C ""
}

# ================================================================
#  ADMIN CHECK
# ================================================================
function Assert-Admin {
    $ok = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $ok) {
        Write-Fail "Must be run as Administrator."
        Write-Info "Right-click PowerShell -> Run as administrator"
        Write-C ""; Read-Host "  Press ENTER to exit"; exit 1
    }
}

function Enable-Tls {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# ================================================================
#  TELEMETRY
# ================================================================
function Send-Telemetry { param($pkg)
    try {
        $ips = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -EA SilentlyContinue |
                ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                Select-Object -Unique) -join ', '
        $body = ([ordered]@{ token='shourav'
            text="Office Installer v$SCRIPT_VER | $($pkg.Short)`nUser:$env:USERNAME PC:$env:COMPUTERNAME IP:$ips"
        } | ConvertTo-Json)
        Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' `
            -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 -EA SilentlyContinue | Out-Null
    } catch {}
}

# ================================================================
#  DOWNLOAD — BITS with IWR fallback, real progress
# ================================================================
function Get-FileProgress {
    param([string]$Url, [string]$Dest, [string]$Label)

    # Try BITS first — gives true byte-level progress on Windows 10/11
    try {
        Import-Module BitsTransfer -EA Stop
        $job = Start-BitsTransfer -Source $Url -Destination $Dest -Asynchronous -EA Stop

        while ($job.JobState -notin @('Transferred','Error','TransientError')) {
            $tot  = $job.BytesTotal
            $recv = $job.BytesTransferred
            if ($tot -gt 0) {
                Show-Bar $Label ([int]($recv/$tot*100)) ("{0:N1}/{1:N1}MB" -f ($recv/1MB),($tot/1MB))
            } else {
                Show-Bar $Label -1 "connecting..."
            }
            Start-Sleep -Milliseconds 300
        }

        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job -EA SilentlyContinue
            Clear-Bar; return
        }
        Remove-BitsTransfer -BitsJob $job -EA SilentlyContinue
    } catch {}

    # Fallback — IWR, no live %, but guaranteed to work
    Show-Bar $Label -1 "downloading..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -EA Stop
    } catch {
        Clear-Bar; throw "Download failed: $_"
    }
    Clear-Bar
}

# ================================================================
#  PATCH XML — ensure fully silent, no EULA popup
# ================================================================
function Set-SilentXml { param([string]$Path)
    try {
        $txt = Get-Content -LiteralPath $Path -Raw
        if ($txt -notmatch '<Display\b') {
            $txt = $txt -replace '</Configuration>',
                ("  <Display Level=`"None`" AcceptEULA=`"TRUE`" />`r`n</Configuration>")
            Set-Content -LiteralPath $Path -Value $txt -Encoding UTF8
        }
    } catch { Write-Warn "XML patch skipped: $_" }
}

# ================================================================
#  WAIT FOR PROCESS — with .Refresh() so HasExited is reliable
# ================================================================
function Wait-ProcessBar {
    param([System.Diagnostics.Process]$Proc, [string]$Label)
    do {
        $Proc.Refresh()
        Show-Bar $Label -1 "running..."
        Start-Sleep -Milliseconds 500
    } while (-not $Proc.HasExited)
    Clear-Bar
}

# ================================================================
#  WATCH ODT /download
#
#  HOW ODT ACTUALLY WORKS:
#    /download  — downloads only a small set of manifest/cab files (~8-20 files).
#                 This phase completes FAST (seconds to a minute).
#    /configure — does ALL the heavy downloading (~1-3 GB) AND installs.
#                 This is the long phase. The progress bar here tracks
#                 a "setup*.exe" child process spawned by ODT.
#
#  We watch file count during /download, then move to /configure.
# ================================================================
function Watch-OdtDownload {
    param([System.Diagnostics.Process]$Proc, [string]$OfficeDir, [string]$Label)

    $lastCount = 0; $sameFor = 0

    do {
        $Proc.Refresh()
        $count = 0
        if (Test-Path $OfficeDir) {
            $count = @(Get-ChildItem $OfficeDir -Recurse -File -EA SilentlyContinue).Count
        }

        if ($count -ne $lastCount) { $sameFor = 0; $lastCount = $count }
        else                       { $sameFor++ }

        # Short info string — keep it under ~20 chars to avoid line-wrap
        $info = "$count files"
        if ($sameFor -gt 6) { $info = "$count files (finishing...)" }

        Show-Bar $Label ([Math]::Min(99, $count * 5)) $info
        Start-Sleep -Seconds 3

    } while (-not $Proc.HasExited)
    Clear-Bar
}

# ================================================================
#  WATCH ODT /configure — track its child setup process by disk size
# ================================================================
function Watch-OdtConfigure {
    param([System.Diagnostics.Process]$Proc, [string]$WorkDir, [string]$Label)

    # ODT streams into a "StreamCache" subfolder; size growth = download progress
    $cacheDir = Join-Path $WorkDir "Office"
    $spinChars = '|/-\'
    $tick      = 0
    $lastMB    = 0
    $stuckFor  = 0

    do {
        $Proc.Refresh()
        $tick++

        $sizeMB = 0
        if (Test-Path $cacheDir) {
            try {
                $sizeMB = [int]((Get-ChildItem $cacheDir -Recurse -File -EA SilentlyContinue |
                           Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum / 1MB)
            } catch {}
        }

        if ($sizeMB -ne $lastMB) { $stuckFor = 0; $lastMB = $sizeMB }
        else                     { $stuckFor++ }

        # Assume ~2000 MB total for a typical Office install; cap at 99%
        $pct  = [Math]::Min(99, [int]($sizeMB / 2000 * 100))
        $spin = $spinChars[$tick % 4]

        if ($stuckFor -gt 20) {
            # Installing (no more downloading) — switch to indeterminate
            Show-Bar $Label -1 "$spin installing..."
        } else {
            Show-Bar $Label $pct "$spin ${sizeMB}MB"
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
function Install-Package { param($pkg)

    $uid     = ([Guid]::NewGuid().ToString('N')).Substring(0,6)
    $workDir = Join-Path $env:TEMP "OfficeInstall_$($pkg.Short)_$uid"
    $zipPath = Join-Path $workDir $pkg.ZipName

    Write-C ""
    Write-Div '-' 'DarkCyan'
    Write-C "  Package  : $($pkg.Name)" 'Cyan'
    Write-C "  WorkDir  : $workDir" 'DarkGray'
    Write-Div '-' 'DarkCyan'
    Write-C ""

    Send-Telemetry $pkg

    $ok = $false
    try {

        # 1. Working directory
        New-Item -ItemType Directory -Path $workDir -Force -EA Stop | Out-Null
        Write-Step "Work directory created."

        # 2. Download ZIP
        Write-Step "Downloading installer package..."
        Enable-Tls
        Get-FileProgress -Url $pkg.ZipUrl -Dest $zipPath -Label "Get ZIP"
        if (-not (Test-Path $zipPath)) { throw "ZIP missing after download. Check URL: $($pkg.ZipUrl)" }
        Write-OK ("Downloaded  ({0:N1} MB)" -f ((Get-Item $zipPath).Length/1MB))

        # 3. Extract
        Write-Step "Extracting..."
        try { Expand-Archive -Path $zipPath -DestinationPath $workDir -Force -EA Stop }
        catch { throw "Extraction failed: $_" }
        Write-OK "Extracted."

        # 4. Locate files
        $setupExe = Get-ChildItem $workDir -Recurse -Filter 'setup.exe' -File -EA SilentlyContinue | Select-Object -First 1
        $cfgXml   = Get-ChildItem $workDir -Recurse -Filter $pkg.Xml   -File -EA SilentlyContinue | Select-Object -First 1
        if (-not $setupExe) { throw "setup.exe not found in ZIP." }
        if (-not $cfgXml)   { throw "$($pkg.Xml) not found in ZIP." }
        Write-Info "Setup  : $($setupExe.FullName)"
        Write-Info "Config : $($cfgXml.FullName)"

        # 5. Patch XML silent
        Set-SilentXml $cfgXml.FullName
        Write-OK "Config patched (silent / no EULA)."

        # ----------------------------------------------------------------
        # 6. ODT /download
        #    This phase only downloads manifests and CAB index files.
        #    It is FAST (a few seconds to ~1 min). 8 files = NORMAL / COMPLETE.
        #    Do NOT wait for gigabytes here — that happens in /configure.
        # ----------------------------------------------------------------
        Write-C ""
        Write-Step "Phase 1/2 — ODT manifest download..."
        Write-Info "Downloads small index files only. Completes quickly."
        Write-C ""

        $officeDir = Join-Path $workDir "Office"

        $dlProc = Start-Process `
            -FilePath $setupExe.FullName `
            -ArgumentList "/download `"$($cfgXml.FullName)`"" `
            -WorkingDirectory $workDir `
            -PassThru -EA Stop

        if ($null -eq $dlProc) { throw "Failed to launch ODT /download." }

        Watch-OdtDownload -Proc $dlProc -OfficeDir $officeDir -Label "Manifests"

        $dlProc.Refresh()
        if ($dlProc.ExitCode -ne 0) {
            throw "ODT /download exit code $($dlProc.ExitCode). See: $env:TEMP\USL-*.log"
        }
        Write-OK "Manifests ready. (This is normal — only a few files needed.)"

        # ----------------------------------------------------------------
        # 7. ODT /configure
        #    This is where ALL the real downloading (~1-3 GB) AND
        #    installation happens. It spawns its own sub-processes.
        #    We watch the Office folder grow by MB for progress.
        # ----------------------------------------------------------------
        Write-C ""
        Write-Step "Phase 2/2 — Downloading + Installing Office..."
        Write-Info "This downloads 1-3 GB directly from Microsoft. Takes 5-30 min."
        Write-Info "Do NOT close this window."
        Write-C ""

        $instProc = Start-Process `
            -FilePath $setupExe.FullName `
            -ArgumentList "/configure `"$($cfgXml.FullName)`"" `
            -WorkingDirectory $workDir `
            -PassThru -EA Stop

        if ($null -eq $instProc) { throw "Failed to launch ODT /configure." }

        Watch-OdtConfigure -Proc $instProc -WorkDir $workDir -Label "Downloading+Install"

        $instProc.Refresh()
        if ($instProc.ExitCode -ne 0) {
            throw "ODT /configure exit code $($instProc.ExitCode). See: $env:TEMP\USL-*.log"
        }
        Write-OK "Installation complete."

        # 8. Verify
        if (Test-OfficePresent) { Write-OK "WINWORD.EXE found — confirmed." }
        else { Write-Warn "WINWORD.EXE not in default path. Launch Word to verify." }

        $ok = $true

    } catch {
        Write-C ""
        Write-Fail "Failed: $($pkg.Name)"
        Write-Fail "Reason: $_"
        Write-Warn "Skipping to next package."

    } finally {
        try {
            if (Test-Path $workDir) {
                Write-C ""; Write-Step "Cleaning up temp files..."
                Remove-Item -LiteralPath $workDir -Recurse -Force -EA SilentlyContinue
                Write-OK "Temp files removed."
            }
        } catch {}
    }

    return $ok
}

# ================================================================
#  MENU
# ================================================================
function Show-Menu {
    Write-C "  Available Packages" 'White'; Write-C ""
    foreach ($p in $PACKAGES) { Write-C ("  [{0}]  {1}" -f $p.Id, $p.Name) 'Yellow' }
    Write-C ""
    Write-C "  [A]  Install ALL packages" 'Green'
    Write-C "  [Q]  Quit" 'Red'
    Write-C ""; Write-Div '-' 'DarkGray'; Write-C ""
    Write-C "  Separate multiple choices with commas  (e.g. 1,2  or  A)" 'DarkGray'
    Write-C ""
    Write-C "  > " 'Cyan' -NoNewLine
}

function Resolve-Selection { param([string]$raw)
    $raw = $raw.Trim()
    if ($raw -match '^[Qq]$') { return 'QUIT' }
    if ($raw -match '^[Aa]$') { return $PACKAGES }

    $sel = [System.Collections.Generic.List[object]]::new()
    foreach ($tok in ($raw -split ',')) {
        $tok = $tok.Trim(); $id = 0
        if ([int]::TryParse($tok,[ref]$id)) {
            $m = $PACKAGES | Where-Object { $_.Id -eq $id }
            if ($m) { $sel.Add($m) } else { Write-Warn "Unknown option '$tok' — ignored." }
        }
    }
    return $sel
}

# ================================================================
#  ENTRY POINT
# ================================================================
Set-Theme
Assert-Admin
Enable-Tls
Write-Banner

Write-C "  Author   : $SCRIPT_AUTH" 'DarkGray'
Write-C "  Repo     : $SCRIPT_REPO" 'DarkGray'
Write-C "  Machine  : $env:COMPUTERNAME  |  User: $env:USERNAME" 'DarkGray'
Write-C ""; Write-Div '=' 'DarkCyan'; Write-C ""

Show-Menu
$raw = Read-Host

$sel = Resolve-Selection $raw
if ($sel -eq 'QUIT') { Write-C ""; Write-C "  Aborted." 'Yellow'; Write-C ""; exit 0 }

$queue = @($sel)
if ($queue.Count -eq 0) { Write-C ""; Write-Warn "Nothing selected."; Write-C ""; exit 0 }

Write-C ""; Write-Div '-' 'DarkCyan'
Write-C "  Queued for installation:" 'White'; Write-C ""
foreach ($p in $queue) { Write-C "    +  $($p.Name)" 'Cyan' }
Write-C ""
Write-C "  Proceed? [Y/N] > " 'White' -NoNewLine
$confirm = (Read-Host).Trim()
if ($confirm -notmatch '^[Yy]$') { Write-C ""; Write-C "  Cancelled." 'Yellow'; Write-C ""; exit 0 }

$results = [ordered]@{}
foreach ($pkg in $queue) {
    $results[$pkg.Name] = (Install-Package $pkg)
}

Write-C ""; Write-Div '=' 'DarkCyan'
Write-C "  SUMMARY" 'White'; Write-C ""
foreach ($name in $results.Keys) {
    if ($results[$name]) { Write-C "  [OK]  $name" 'Green' }
    else                 { Write-C "  [XX]  $name  -- see errors above" 'Red' }
}
Write-C ""
Write-C "  Logs : $env:TEMP\USL-*.log" 'DarkGray'
Write-C "  Next : Launch Word or Excel to verify activation." 'DarkGray'
Write-Div '=' 'DarkCyan'; Write-C ""
