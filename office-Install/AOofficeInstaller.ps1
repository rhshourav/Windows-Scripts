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
#   Version : 3.1.0  |  Windows 10 / 11  |  x64
#
#   USAGE (run as Administrator):
#     iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-Office.ps1")
#
# ============================================================

# SilentlyContinue: we catch our own errors; never let PS silently kill the script
$ErrorActionPreference = "SilentlyContinue"
Set-StrictMode -Off

# ================================================================
#  CONSTANTS
# ================================================================
$SCRIPT_VER  = "3.1.0"
$SCRIPT_AUTH = "rhshourav"
$SCRIPT_REPO = "https://github.com/rhshourav/Windows-Scripts"

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
        $w = $h.WindowSize
        if ($w.Width -lt 80) { $w.Width = 80; $h.WindowSize = $w }
    } catch {}
    Clear-Host
}

function Write-C {
    param([string]$msg, [string]$col = 'White', [switch]$NoNewLine)
    if ($NoNewLine) { Write-Host $msg -ForegroundColor $col -NoNewline }
    else            { Write-Host $msg -ForegroundColor $col }
}

function Write-Div {
    param([string]$c = '-', [string]$col = 'DarkGray')
    Write-C ($c * 72) $col
}

function Write-Step { param([string]$m); Write-C "  [>>] $m" 'Yellow' }
function Write-OK   { param([string]$m); Write-C "  [OK] $m" 'Green'  }
function Write-Warn { param([string]$m); Write-C "  [!!] $m" 'Yellow' }
function Write-Fail { param([string]$m); Write-C "  [XX] $m" 'Red'    }
function Write-Info { param([string]$m); Write-C "       $m" 'DarkGray' }

# ================================================================
#  PROGRESS BAR
#  $Pct 0-100 = filled bar   |   $Pct -1 = bouncing indeterminate
#  Single function, no overloads, no closure issues
# ================================================================
$script:BounceTick = 0

function Show-Bar {
    param([string]$Label, [int]$Pct, [string]$Info = "")

    $W = 44   # inner bar character width

    if ($Pct -lt 0) {
        # indeterminate bounce
        $script:BounceTick++
        $pos   = $script:BounceTick % ($W - 3)
        $pad1  = ' ' * $pos
        $pad2  = ' ' * ([Math]::Max(0, $W - 3 - $pos))
        $inner = $pad1 + '<=>' + $pad2
        $bar   = '[' + $inner + ']'
        $line  = "  {0,-20} {1}  {2}" -f $Label, $bar, $Info
    } else {
        # determinate
        $filled = [int][Math]::Round($Pct / 100 * $W)
        $empty  = $W - $filled
        $block  = [string][char]9608   # █
        $shade  = [string][char]9617   # ░
        $bar    = '[' + ($block * $filled) + ($shade * $empty) + ']'
        $line   = "  {0,-20} {1} {2,3}%  {3}" -f $Label, $bar, $Pct, $Info
    }

    Write-Host ("`r" + $line + '    ') -NoNewline -ForegroundColor Cyan
}

function Clear-Bar {
    Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline
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
    Write-C ("  Office Suite Universal Installer  |  v{0}  |  {1}" -f $SCRIPT_VER, $SCRIPT_AUTH) 'DarkCyan'
    Write-Div '=' 'DarkCyan'
    Write-C ""
}

# ================================================================
#  ADMIN CHECK
# ================================================================
function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Fail "This script must be run as Administrator."
        Write-Info "Right-click PowerShell -> 'Run as administrator', then try again."
        Write-C ""
        Read-Host "  Press ENTER to exit"
        exit 1
    }
}

# ================================================================
#  TLS
# ================================================================
function Enable-Tls {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# ================================================================
#  TELEMETRY  (best-effort, never blocks execution)
# ================================================================
function Send-Telemetry {
    param($pkg)
    try {
        $ips = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -EA SilentlyContinue |
                ForEach-Object { $_.IPAddress } |
                Where-Object   { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                Select-Object -Unique) -join ', '

        $body = ([ordered]@{
            token = 'shourav'
            text  = "Office Installer v$SCRIPT_VER | Pkg: $($pkg.Short)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $ips"
        } | ConvertTo-Json)

        Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' `
                          -Method Post -ContentType 'application/json' `
                          -Body $body -TimeoutSec 5 -EA SilentlyContinue | Out-Null
    } catch {}
}

# ================================================================
#  DOWNLOAD FILE
#  Strategy: BITS first (gives real progress), then IWR fallback.
#  No WebClient async — avoids closure scope bug completely.
# ================================================================
function Get-FileProgress {
    param([string]$Url, [string]$Dest, [string]$Label)

    # Try BITS (Background Intelligent Transfer Service)
    $usedBits = $false
    try {
        Import-Module BitsTransfer -EA Stop

        $job = Start-BitsTransfer -Source $Url -Destination $Dest -Asynchronous -EA Stop
        $usedBits = $true

        while ($job.JobState -notin @('Transferred','Error','TransientError')) {
            $total = $job.BytesTotal
            $recv  = $job.BytesTransferred
            if ($total -gt 0) {
                $pct  = [int]($recv / $total * 100)
                $info = "{0:N1} / {1:N1} MB" -f ($recv / 1MB), ($total / 1MB)
                Show-Bar $Label $pct $info
            } else {
                Show-Bar $Label -1 "connecting..."
            }
            Start-Sleep -Milliseconds 400
        }

        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job -EA SilentlyContinue
            Clear-Bar
            return   # success
        }

        # BITS transfer errored — clean up and fall through
        Remove-BitsTransfer -BitsJob $job -EA SilentlyContinue
        $usedBits = $false

    } catch {
        $usedBits = $false
    }

    # Fallback: Invoke-WebRequest (synchronous, no live % but always works)
    Show-Bar $Label -1 "downloading..."
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    } catch {
        $ErrorActionPreference = $prevPref
        Clear-Bar
        throw "Download failed: $_"
    }
    $ErrorActionPreference = $prevPref
    Clear-Bar
}

# ================================================================
#  PATCH XML — inject silent display config if missing
# ================================================================
function Set-SilentXml {
    param([string]$Path)
    try {
        $txt = Get-Content -LiteralPath $Path -Raw
        if ($txt -notmatch '<Display\b') {
            $inject = "  <Display Level=`"None`" AcceptEULA=`"TRUE`" />`r`n"
            $txt    = $txt -replace '</Configuration>', ($inject + '</Configuration>')
            Set-Content -LiteralPath $Path -Value $txt -Encoding UTF8
        }
    } catch {
        Write-Warn "XML patch skipped (non-fatal): $_"
    }
}

# ================================================================
#  WAIT FOR PROCESS with indeterminate progress bar
# ================================================================
function Wait-ProcessBar {
    param([System.Diagnostics.Process]$Proc, [string]$Label)
    while (-not $Proc.HasExited) {
        Show-Bar $Label -1 "please wait..."
        Start-Sleep -Milliseconds 500
    }
    Clear-Bar
}

# ================================================================
#  WATCH ODT DOWNLOAD PHASE — file-count growth as proxy for progress
# ================================================================
function Watch-OdtDownload {
    param([System.Diagnostics.Process]$Proc, [string]$OfficeDir, [string]$Label)

    $lastCount = 0
    $stuckSecs = 0

    while (-not $Proc.HasExited) {
        $count = 0
        if (Test-Path $OfficeDir) {
            $count = @(Get-ChildItem $OfficeDir -Recurse -File -EA SilentlyContinue).Count
        }

        if ($count -ne $lastCount) { $stuckSecs = 0 } else { $stuckSecs += 5 }
        $lastCount = $count

        $info = "files cached: $count"
        if ($stuckSecs -ge 300) { $info += "  (active — Microsoft CDN can pause)" }

        # File count tops out around 100-200 — use as rough proxy, cap at 95
        $pct = [Math]::Min(95, $count)
        Show-Bar $Label $pct $info

        Start-Sleep -Seconds 5
    }
    Clear-Bar
}

# ================================================================
#  VERIFY OFFICE ON DISK
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

    $uid     = ([Guid]::NewGuid().ToString('N')).Substring(0,6)
    $workDir = Join-Path $env:TEMP "OfficeInstall_$($pkg.Short)_$uid"
    $zipPath = Join-Path $workDir $pkg.ZipName

    Write-C ""
    Write-Div '-' 'DarkCyan'
    Write-C "  Package  : $($pkg.Name)" 'Cyan'
    Write-C "  Work dir : $workDir" 'DarkGray'
    Write-Div '-' 'DarkCyan'
    Write-C ""

    Send-Telemetry $pkg

    $installOk = $false

    try {

        # 1. Create working directory
        New-Item -ItemType Directory -Path $workDir -Force -EA Stop | Out-Null
        Write-Step "Working directory ready."

        # 2. Download package ZIP
        Write-Step "Downloading installer package..."
        Enable-Tls
        Get-FileProgress -Url $pkg.ZipUrl -Dest $zipPath -Label "Downloading ZIP"

        if (-not (Test-Path $zipPath)) { throw "ZIP file not found after download. URL may be wrong: $($pkg.ZipUrl)" }
        $sizeMB = "{0:N1} MB" -f ((Get-Item $zipPath).Length / 1MB)
        Write-OK "Downloaded. ($sizeMB)"

        # 3. Extract ZIP
        Write-Step "Extracting..."
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        try {
            Expand-Archive -Path $zipPath -DestinationPath $workDir -Force
        } catch {
            $ErrorActionPreference = $prevPref
            throw "Extraction failed: $_"
        }
        $ErrorActionPreference = $prevPref
        Write-OK "Extracted."

        # 4. Locate files
        $setupExe = Get-ChildItem $workDir -Recurse -Filter 'setup.exe' -File -EA SilentlyContinue |
                    Select-Object -First 1
        $cfgXml   = Get-ChildItem $workDir -Recurse -Filter $pkg.Xml   -File -EA SilentlyContinue |
                    Select-Object -First 1

        if (-not $setupExe) { throw "setup.exe not found inside the ZIP archive." }
        if (-not $cfgXml)   { throw "$($pkg.Xml) not found inside the ZIP archive." }

        Write-Info "Setup  : $($setupExe.FullName)"
        Write-Info "Config : $($cfgXml.FullName)"

        # 5. Patch XML
        Set-SilentXml $cfgXml.FullName
        Write-OK "Configuration ready (silent mode)."

        # 6. ODT /download — fetch Office binaries from Microsoft CDN
        Write-C ""
        Write-Step "Fetching Office binaries (1-3 GB from Microsoft CDN)..."
        Write-Info "Network traffic is normal. Do NOT close this window."
        Write-C ""

        $officeDir = Join-Path $workDir "Office"

        $dlProc = Start-Process `
            -FilePath         $setupExe.FullName `
            -ArgumentList     "/download `"$($cfgXml.FullName)`"" `
            -WorkingDirectory $workDir `
            -PassThru

        if ($null -eq $dlProc) { throw "Could not launch ODT download process." }

        Watch-OdtDownload -Proc $dlProc -OfficeDir $officeDir -Label "Office Binaries"

        if ($dlProc.ExitCode -ne 0) {
            throw "ODT /download failed. Exit code: $($dlProc.ExitCode).`n  Check: $env:TEMP\USL-*.log"
        }
        Write-OK "Binaries cached locally."

        # 7. ODT /configure — run installer
        Write-C ""
        Write-Step "Running Office installer (several minutes)..."
        Write-C ""

        $instProc = Start-Process `
            -FilePath         $setupExe.FullName `
            -ArgumentList     "/configure `"$($cfgXml.FullName)`"" `
            -WorkingDirectory $workDir `
            -PassThru

        if ($null -eq $instProc) { throw "Could not launch ODT configure process." }

        Wait-ProcessBar -Proc $instProc -Label "Installing Office"

        if ($instProc.ExitCode -ne 0) {
            throw "ODT /configure failed. Exit code: $($instProc.ExitCode).`n  Check: $env:TEMP\USL-*.log"
        }
        Write-OK "Installer finished (exit 0)."

        # 8. Verify
        if (Test-OfficePresent) {
            Write-OK "WINWORD.EXE detected. Install confirmed."
        } else {
            Write-Warn "WINWORD.EXE not in default path — launch Word to verify."
        }

        $installOk = $true

    } catch {
        Write-C ""
        Write-Fail "Failed : $($pkg.Name)"
        Write-Fail "Reason : $_"
        Write-Warn "Skipping to next package."

    } finally {
        # Always remove temp files regardless of outcome
        try {
            if (Test-Path $workDir) {
                Write-C ""
                Write-Step "Removing temp files..."
                Remove-Item -LiteralPath $workDir -Recurse -Force -EA SilentlyContinue
                Write-OK "Temp files removed."
            }
        } catch {}
    }

    return $installOk
}

# ================================================================
#  MENU
# ================================================================
function Show-Menu {
    Write-C "  Available Packages" 'White'
    Write-C ""
    foreach ($p in $PACKAGES) {
        Write-C ("  [{0}]  {1}" -f $p.Id, $p.Name) 'Yellow'
    }
    Write-C ""
    Write-C "  [A]  Install ALL packages" 'Green'
    Write-C "  [Q]  Quit" 'Red'
    Write-C ""
    Write-Div '-' 'DarkGray'
    Write-C ""
    Write-C "  Separate multiple choices with commas  (e.g.  1,2  or  A)" 'DarkGray'
    Write-C ""
    Write-C "  > " 'Cyan' -NoNewLine
}

function Resolve-Selection {
    param([string]$raw)

    $raw = $raw.Trim()
    if ($raw -match '^[Qq]$') { return 'QUIT' }
    if ($raw -match '^[Aa]$') { return $PACKAGES }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($tok in ($raw -split ',')) {
        $tok = $tok.Trim()
        $id  = 0
        if ([int]::TryParse($tok, [ref]$id)) {
            $match = $PACKAGES | Where-Object { $_.Id -eq $id }
            if ($match) { $selected.Add($match) }
            else        { Write-Warn "Unknown option '$tok' — ignored." }
        }
    }
    return $selected
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
Write-C ""
Write-Div '=' 'DarkCyan'
Write-C ""

Show-Menu
$raw = Read-Host

$selection = Resolve-Selection $raw

if ($selection -eq 'QUIT') {
    Write-C ""
    Write-C "  Aborted. No changes made." 'Yellow'
    Write-C ""
    exit 0
}

$queue = @($selection)

if ($queue.Count -eq 0) {
    Write-C ""
    Write-Warn "No valid selection. Exiting."
    Write-C ""
    exit 0
}

Write-C ""
Write-Div '-' 'DarkCyan'
Write-C "  Queued for installation:" 'White'
Write-C ""
foreach ($p in $queue) { Write-C "    +  $($p.Name)" 'Cyan' }
Write-C ""
Write-C "  Proceed? [Y/N] > " 'White' -NoNewLine
$confirm = (Read-Host).Trim()

if ($confirm -notmatch '^[Yy]$') {
    Write-C ""
    Write-C "  Cancelled. No changes made." 'Yellow'
    Write-C ""
    exit 0
}

# Run each install
$results = [ordered]@{}
foreach ($pkg in $queue) {
    $ok = Install-Package $pkg
    $results[$pkg.Name] = $ok
}

# Final summary
Write-C ""
Write-Div '=' 'DarkCyan'
Write-C "  SUMMARY" 'White'
Write-C ""
foreach ($name in $results.Keys) {
    if ($results[$name]) {
        Write-C "  [OK]  $name" 'Green'
    } else {
        Write-C "  [XX]  $name  -- see errors above" 'Red'
    }
}
Write-C ""
Write-C "  ODT logs : $env:TEMP\USL-*.log" 'DarkGray'
Write-C "  Next     : Launch Word or Excel to verify and activate." 'DarkGray'
Write-Div '=' 'DarkCyan'
Write-C ""
