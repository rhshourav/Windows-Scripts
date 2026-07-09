#Requires -Version 5.1
<#
.SYNOPSIS
    PyForge v1.0.2 - Universal Python to EXE Compiler
.DESCRIPTION
    Compiles any Python script into a standalone Windows EXE.
    Supports PyInstaller & Nuitka engines, icon branding,
    version-info embedding, and Authenticode code signing
    (self-signed or real PFX certificate).
.AUTHOR
    rhshourav
.NOTES
    Compatible with: iex (irm <url>)
    Requires:        Python 3.8+ on PATH
    Supports:        Windows 10+ (PowerShell 5.1 / PS7+)
    CHANGELOG (1.0.3):
      - Fixed: icon normalization silently dropped every requested .ico size
        larger than the source image (confirmed Pillow behaviour: "sizes
        bigger than the original ... will be ignored", no warning, no
        error). Any source under 256x256 -- the common case -- lost its
        largest frames with zero indication. The source is now padded to
        square and upscaled before saving, so all 16-256px sizes always
        land in the file, and the log now prints the sizes actually
        embedded.
      - Fixed: PyInstaller's own build output (including icon-related
        WARNING lines) was being discarded on a "successful" build because
        the failure check relied on $LASTEXITCODE, which Start-Job never
        actually propagates back to the calling session. Icon/warning/error
        lines from PyInstaller are now always shown.
      - Added: the exact normalized icon file used for the build is now
        copied next to the EXE (<name>_icon_debug.ico) so it can be
        inspected directly, since BUILD_TEMP is deleted before the user
        ever sees it.
    CHANGELOG (1.0.2):
      - Fixed: icon paths pasted with surrounding quotes (Explorer "Copy as
        path") were silently rejected. Paths are now sanitized on input.
      - Fixed: non-native icon files (e.g. a .png/.jpg renamed to .ico) built
        successfully but silently produced NO custom icon, because Pillow
        (required by PyInstaller to convert/normalize icons) was never
        installed. Pillow is now installed and every icon is normalized into
        a proper multi-resolution .ico before compiling, so both engines
        embed it reliably at every size Windows needs (16-256px).
      - Fixed: malformed/invalid .ico files are now detected up front via
        signature check, instead of failing silently mid-build.
      - Fixed: '--upx-dir=.' forced UPX lookup into the current directory
        only, contradicting the "ensure upx.exe is on PATH" message and
        silently disabling compression. Now honours PATH as documented.
      - Fixed: a failure while copying the finished EXE to the output folder
        was caught by the global cleanup trap, which deleted the temp build
        before the user ever saw the file. The EXE is now preserved and its
        location reported if the copy step fails.
      - Added: automatic, non-destructive Windows icon-cache refresh after
        an icon-branded build, since a stale Explorer icon cache is the most
        common reason a *correctly* embedded icon appears not to show.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
#  GLOBALS
# ─────────────────────────────────────────────────────────────
$PYFORGE_VERSION = '1.0.3'
$PYFORGE_AUTHOR  = 'rhshourav'
$BUILD_TEMP      = Join-Path $env:TEMP "PyForge_$(Get-Random)"
$ORIGINAL_DIR    = Get-Location

# ─────────────────────────────────────────────────────────────
#  COLOUR HELPERS
# ─────────────────────────────────────────────────────────────
function C {
    param([string]$Text, [string]$Color='White', [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Text -ForegroundColor $Color }
}
function Blank  { Write-Host '' }
function Ruler  ($char='─') { C ($char * 68) 'DarkGray' }
function OK     ($msg) { C "  ✔  $msg" 'Green' }
function WARN   ($msg) { C "  ⚠  $msg" 'Yellow' }
function ERR    ($msg) { C "  ✖  $msg" 'Red' }
function INFO   ($msg) { C "  ·  $msg" 'Cyan' }
function LABEL  ($msg) { C $msg 'DarkGray' }

# ─────────────────────────────────────────────────────────────
#  PROGRESS BAR
# ─────────────────────────────────────────────────────────────
function Show-Bar {
    param([int]$Pct, [string]$Label='')
    $width   = 40
    $filled  = [math]::Round($width * $Pct / 100)
    $empty   = $width - $filled
    $bar     = ('█' * $filled) + ('░' * $empty)
    $pctStr  = "$Pct%".PadLeft(4)
    Write-Host "`r  " -NoNewline
    Write-Host '[' -ForegroundColor DarkGray -NoNewline
    Write-Host $bar -ForegroundColor Green    -NoNewline
    Write-Host ']' -ForegroundColor DarkGray  -NoNewline
    Write-Host " $pctStr  " -ForegroundColor Yellow -NoNewline
    Write-Host $Label.PadRight(30) -ForegroundColor White -NoNewline
}
function Finish-Bar ($Label='Done') {
    Show-Bar 100 $Label
    Write-Host ''
}

# ─────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    $Host.UI.RawUI.WindowTitle = "PyForge v$PYFORGE_VERSION  |  $PYFORGE_AUTHOR"
    Blank
    C '  ██████╗ ██╗   ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗' 'Green'
    C '  ██╔══██╗╚██╗ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝' 'Green'
    C '  ██████╔╝ ╚████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗  ' 'Green'
    C '  ██╔═══╝   ╚██╔╝  ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝  ' 'DarkGreen'
    C '  ██║        ██║   ██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗' 'DarkGreen'
    C '  ╚═╝        ╚═╝   ╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝' 'DarkGray'
    Blank
    C "  Universal Python → EXE Compiler" 'White'
    C "  Author: $PYFORGE_AUTHOR   Version: $PYFORGE_VERSION" 'DarkGray'
    Ruler
    Blank
}

# ─────────────────────────────────────────────────────────────
#  CLEANUP TRAP
# ─────────────────────────────────────────────────────────────
function Invoke-Cleanup {
    Set-Location $ORIGINAL_DIR
    if (Test-Path $BUILD_TEMP) {
        Remove-Item $BUILD_TEMP -Recurse -Force -ErrorAction SilentlyContinue
    }
}
trap { Invoke-Cleanup; ERR "Fatal: $_"; exit 1 }

# ─────────────────────────────────────────────────────────────
#  PROMPT HELPERS  (minimal, styled)
# ─────────────────────────────────────────────────────────────
function Ask {
    param([string]$Question, [string]$Default='')
    $hint = if ($Default) { " [default: $Default]" } else { '' }
    C "  ┌ $Question$hint" 'Cyan'
    C '  └▶ ' 'DarkGray' -NoNewline
    $ans = Read-Host
    if ([string]::IsNullOrWhiteSpace($ans) -and $Default) { return $Default }
    return $ans.Trim()
}

function Choose {
    param([string]$Question, [string[]]$Options)
    C "  ┌ $Question" 'Cyan'
    for ($i=0; $i -lt $Options.Count; $i++) {
        C "  │  [$($i+1)] $($Options[$i])" 'White'
    }
    C '  └▶ ' 'DarkGray' -NoNewline
    do {
        $raw = Read-Host
        $idx = [int]$raw - 1
    } while ($idx -lt 0 -or $idx -ge $Options.Count)
    return $Options[$idx]
}

function YesNo {
    param([string]$Question, [string]$Default='Y')
    $hint = if ($Default -eq 'Y') { 'Y/n' } else { 'y/N' }
    C "  ┌ $Question [$hint]" 'Cyan'
    C '  └▶ ' 'DarkGray' -NoNewline
    $r = Read-Host
    if ([string]::IsNullOrWhiteSpace($r)) { $r = $Default }
    return $r -match '^[Yy]'
}

# Strip stray wrapping quotes/whitespace from pasted paths. Windows Explorer's
# "Copy as path" wraps the result in literal double quotes, which otherwise
# makes Test-Path fail silently and the icon/cert get dropped without a clear
# reason.
function Clean-PathInput {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return $Path.Trim().Trim('"').Trim("'").Trim()
}

# ─────────────────────────────────────────────────────────────
#  ICON HELPERS
# ─────────────────────────────────────────────────────────────
# A real Windows .ico file always starts with the 4-byte signature
# 00 00 01 00. Files from "png to ico" web converters, or a plain
# renamed .png/.jpg, usually fail this check — which is the single
# most common reason a supplied "icon" never shows up on the EXE.
function Test-IsRealIco {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 4) { return $false }
        return ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 1 -and $bytes[3] -eq 0)
    } catch {
        return $false
    }
}

# Normalizes whatever image the user provided into a proper multi-resolution
# .ico (16/24/32/48/64/128/256 px) using Pillow, so the icon looks crisp in
# the taskbar, Explorer list view, and desktop shortcuts alike. Returns the
# path to the normalized icon, or the original path if normalization fails
# (build continues with whatever PyInstaller/Nuitka can make of the source).
function New-NormalizedIcon {
    param([string]$SourcePath, [string]$WorkDir)

    $destIco = Join-Path $WorkDir 'app_icon.ico'
    $pyScript = @'
import sys
from PIL import Image

src, dest = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
img = Image.open(src).convert("RGBA")

# Pillow's ICO writer silently DROPS any requested size that is bigger than
# the source image: "Any sizes bigger than the original size ... will be
# ignored" (Pillow docs). A source under 256x256 -- extremely common for a
# logo, screenshot, or favicon -- therefore loses its largest frames with
# NO warning and NO error. That's a fully "successful" build that just
# never got a usable icon resource, which looks identical to this bug
# report. Force the source up to the largest requested size first so every
# requested size is guaranteed to actually land in the file.
max_size = max(sizes)
if img.width != img.height:
    # Pad to square on a transparent canvas first so upscaling doesn't
    # stretch/distort non-square artwork.
    side = max(img.width, img.height)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    img = canvas
if img.width < max_size:
    img = img.resize((max_size, max_size), Image.LANCZOS)

img.save(dest, format="ICO", sizes=[(s, s) for s in sizes])

# Read the file back and report exactly which sizes made it in, so a
# truncated icon is visible in the build log instead of failing silently.
check = Image.open(dest)
print(f"OK sizes={check.info.get('sizes')}")
'@
    $pyScriptPath = Join-Path $WorkDir 'normalize_icon.py'
    $pyScript | Out-File -FilePath $pyScriptPath -Encoding utf8

    try {
        $result = & python $pyScriptPath $SourcePath $destIco 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $destIco)) {
            OK "Icon normalized to multi-resolution .ico: $destIco"
            $sizesLine = $result | Where-Object { $_ -match '^OK sizes=' } | Select-Object -Last 1
            if ($sizesLine) { INFO "  Embedded $sizesLine" }
            return $destIco
        } else {
            WARN "Icon normalization failed — using original file as-is."
            WARN ($result -join ' ')
            return $SourcePath
        }
    } catch {
        WARN "Icon normalization failed — using original file as-is: $_"
        return $SourcePath
    }
}

# ─────────────────────────────────────────────────────────────
#  PREFLIGHT CHECKS
# ─────────────────────────────────────────────────────────────
function Test-Requirements {
    C '  PRE-FLIGHT CHECKS' 'Yellow'
    Ruler

    # Python
    Show-Bar 10 'Checking Python...'
    try {
        $pyVer = & python --version 2>&1
        Finish-Bar 'Python found'
        OK "Python: $pyVer"
    } catch {
        Write-Host ''
        ERR 'Python not found on PATH. Install Python 3.8+ and retry.'
        exit 1
    }

    # pip
    Show-Bar 20 'Checking pip...'
    try {
        $null = & python -m pip --version 2>&1
        Finish-Bar 'pip found'
        OK 'pip: available'
    } catch {
        Write-Host ''
        ERR 'pip not available. Run: python -m ensurepip --upgrade'
        exit 1
    }

    # OS check  (PS 5.1 safe — $IsWindows does not exist in WinPS)
    Show-Bar 30 'Checking OS...'
    Finish-Bar 'OS verified'
    $osIsWindows = ($env:OS -eq 'Windows_NT') -or
                   ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                       [System.Runtime.InteropServices.OSPlatform]::Windows) 2>$null) -or
                   ($PSVersionTable.PSEdition -ne 'Core' -and $PSVersionTable.Platform -eq $null)
    if ($osIsWindows) {
        OK "OS: Windows (compilation + signing available)"
        $script:IS_WINDOWS = $true
    } else {
        WARN "OS: Non-Windows. EXE cross-compilation via Wine is unsupported."
        WARN "Output EXE will be built via PyInstaller wine mode or Nuitka cross."
        $script:IS_WINDOWS = $false
    }

    Blank
}

# ─────────────────────────────────────────────────────────────
#  COLLECT USER INPUT
# ─────────────────────────────────────────────────────────────
function Get-BuildConfig {
    C '  BUILD CONFIGURATION' 'Yellow'
    Ruler
    Blank

    # Script path
    $script:CFG_SCRIPT = Clean-PathInput (Ask 'Python script path (.py)')
    while (-not (Test-Path $script:CFG_SCRIPT -PathType Leaf)) {
        ERR "File not found: $($script:CFG_SCRIPT)"
        $script:CFG_SCRIPT = Clean-PathInput (Ask 'Python script path (.py)')
    }
    $script:CFG_SCRIPT = Resolve-Path $script:CFG_SCRIPT | Select-Object -ExpandProperty Path
    OK "Script: $($script:CFG_SCRIPT)"
    Blank

    # App name
    $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($script:CFG_SCRIPT)
    $script:CFG_NAME = Ask 'Application name' $defaultName
    OK "Name: $($script:CFG_NAME)"
    Blank

    # Version
    $script:CFG_VERSION = Ask 'Version string' '1.0.0'
    OK "Version: $($script:CFG_VERSION)"
    Blank

    # Description
    $script:CFG_DESC = Ask 'Short description' "$($script:CFG_NAME) Application"
    OK "Description: $($script:CFG_DESC)"
    Blank

    # Icon (optional)
    $script:CFG_ICON = Clean-PathInput (Ask 'Icon path (.ico, .png, .jpg or .bmp)  [leave blank to skip]' '')
    if ($script:CFG_ICON -and -not (Test-Path $script:CFG_ICON -PathType Leaf)) {
        WARN "Icon not found — will compile without icon"
        WARN "(Tip: if you pasted this via 'Copy as path', check for a typo — quotes are handled automatically now.)"
        $script:CFG_ICON = ''
    } elseif ($script:CFG_ICON) {
        $script:CFG_ICON = Resolve-Path $script:CFG_ICON | Select-Object -ExpandProperty Path
        if (Test-IsRealIco $script:CFG_ICON) {
            OK "Icon: $($script:CFG_ICON)"
        } else {
            WARN "File is not a native Windows .ico (likely a renamed image, e.g. from a web converter)."
            WARN "PyForge will auto-convert it into a proper multi-resolution .ico before compiling."
            OK  "Icon (will be converted): $($script:CFG_ICON)"
        }
    } else {
        INFO "No icon specified — using default"
    }
    Blank

    # Console mode
    $consoleChoice = Choose 'Window mode' @('Console (shows terminal window)', 'Windowed (no terminal window / GUI app)')
    $script:CFG_NOCONSOLE = $consoleChoice -match 'Windowed'
    OK "Mode: $consoleChoice"
    Blank

    # Compiler
    $script:CFG_COMPILER = Choose 'Compiler engine' @('PyInstaller (faster build, widely supported)', 'Nuitka (smaller/faster EXE, C-compiled)', 'Let me choose at runtime (build both)')
    OK "Compiler: $($script:CFG_COMPILER)"
    Blank

    # UPX compression
    $script:CFG_UPX = YesNo 'Compress EXE with UPX? (reduces size ~50%, needs UPX on PATH)' 'N'
    Blank

    # Signing
    $script:CFG_SIGN = Choose 'Code signing (Authenticode)' @(
        'Self-signed certificate (free, install & trust locally)',
        'Real PFX certificate (.pfx file you provide)',
        'Skip signing'
    )
    OK "Signing: $($script:CFG_SIGN)"

    if ($script:CFG_SIGN -match 'Real PFX') {
        Blank
        $script:CFG_PFX_PATH = Clean-PathInput (Ask 'Path to your .pfx certificate file')
        while (-not (Test-Path $script:CFG_PFX_PATH)) {
            ERR "PFX not found: $($script:CFG_PFX_PATH)"
            $script:CFG_PFX_PATH = Clean-PathInput (Ask 'Path to your .pfx certificate file')
        }
        $script:CFG_PFX_PATH = Resolve-Path $script:CFG_PFX_PATH | Select-Object -ExpandProperty Path
        $script:CFG_PFX_PASS = Read-Host '  └▶ PFX password (hidden)' -AsSecureString
        OK "PFX: $($script:CFG_PFX_PATH)"
    }

    Blank
    Ruler
    C '  CONFIGURATION SUMMARY' 'Yellow'
    Ruler
    INFO "Script   : $($script:CFG_SCRIPT)"
    INFO "App Name : $($script:CFG_NAME)"
    INFO "Version  : $($script:CFG_VERSION)"
    INFO "Compiler : $($script:CFG_COMPILER)"
    INFO "Signing  : $($script:CFG_SIGN)"
    INFO "UPX      : $(if ($script:CFG_UPX) {'Yes'} else {'No'})"
    Ruler
    Blank

    if (-not (YesNo 'Proceed with build?')) {
        WARN 'Build cancelled by user.'
        exit 0
    }
    Blank
}

# ─────────────────────────────────────────────────────────────
#  INSTALL DEPENDENCIES
# ─────────────────────────────────────────────────────────────
function Install-Deps {
    C '  INSTALLING DEPENDENCIES' 'Yellow'
    Ruler

    # ── Ensure Python Scripts dir is on PATH (Store / user installs often miss this) ──
    Show-Bar 5 'Checking Python Scripts PATH...'
    $pythonScripts = & python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
    if ($pythonScripts -and (Test-Path $pythonScripts)) {
        if ($env:PATH -notlike "*$pythonScripts*") {
            $env:PATH = "$pythonScripts;$env:PATH"
            Finish-Bar 'Scripts dir added to PATH'
            OK "Added to PATH: $pythonScripts"
        } else {
            Finish-Bar 'Scripts PATH OK'
        }
    } else {
        Finish-Bar 'Scripts PATH check done'
    }
    Blank

    function pip-install ($pkg, [int]$pct, [string]$label) {
        Show-Bar $pct $label
        $result = & python -m pip install $pkg --upgrade --quiet 2>&1
        # Non-zero exit OR output contains "error" (case-insensitive), but ignore PATH warnings
        $hasError = ($LASTEXITCODE -ne 0) -and (($result -join '') -match '(?i)error')
        if ($hasError) {
            Write-Host ''
            ERR "pip install $pkg failed:"
            $result | ForEach-Object { C "    $_" 'DarkGray' }
            exit 1
        }
        # Re-check PATH after install in case Scripts dir appeared
        $newScripts = & python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
        if ($newScripts -and (Test-Path $newScripts) -and ($env:PATH -notlike "*$newScripts*")) {
            $env:PATH = "$newScripts;$env:PATH"
        }
        Finish-Bar "$pkg ready"
    }

    $needsPyInstaller = $script:CFG_COMPILER -match 'PyInstaller|runtime'
    $needsNuitka      = $script:CFG_COMPILER -match 'Nuitka|runtime'

    if ($needsPyInstaller) { pip-install 'pyinstaller'    20 'PyInstaller...' }
    if ($needsNuitka)      { pip-install 'nuitka ordered-set zstandard' 60 'Nuitka...' }
    if ($script:CFG_ICON)  { pip-install 'pillow' 75 'Pillow (icon support)...' }
    if ($script:CFG_UPX)  { INFO 'UPX: ensure upx.exe is on PATH (download from upx.github.io)' }
    Finish-Bar 'All deps ready'
    Blank
}

# ─────────────────────────────────────────────────────────────
#  CREATE VERSION INFO FILE  (PyInstaller)
# ─────────────────────────────────────────────────────────────
function New-VersionFile {
    param([string]$OutPath)

    $parts = $script:CFG_VERSION -split '\.'
    while ($parts.Count -lt 4) { $parts += '0' }
    $v = $parts | ForEach-Object { [int]$_ }

    $vFile = @"
VSVersionInfo(
  ffi=FixedFileInfo(
    filevers=($($v[0]), $($v[1]), $($v[2]), $($v[3])),
    prodvers=($($v[0]), $($v[1]), $($v[2]), $($v[3])),
    mask=0x3f,
    flags=0x0,
    OS=0x40004,
    fileType=0x1,
    subtype=0x0,
    date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        u'040904B0',
        [StringStruct(u'CompanyName',      u'$PYFORGE_AUTHOR'),
         StringStruct(u'FileDescription',  u'$($script:CFG_DESC)'),
         StringStruct(u'FileVersion',      u'$($script:CFG_VERSION)'),
         StringStruct(u'InternalName',     u'$($script:CFG_NAME)'),
         StringStruct(u'OriginalFilename', u'$([System.IO.Path]::GetFileNameWithoutExtension($script:CFG_SCRIPT)).exe'),
         StringStruct(u'ProductName',      u'$($script:CFG_NAME)'),
         StringStruct(u'ProductVersion',   u'$($script:CFG_VERSION)')])
    ]),
    VarFileInfo([VarStruct(u'Translation', [1033, 1200])])
  ]
)
"@
    $vFile | Out-File -FilePath $OutPath -Encoding utf8
}

# ─────────────────────────────────────────────────────────────
#  PYINSTALLER BUILD
# ─────────────────────────────────────────────────────────────
function Invoke-PyInstaller {
    C '  BUILDING WITH PYINSTALLER' 'Yellow'
    Ruler

    $versionFile = Join-Path $BUILD_TEMP 'version_info.txt'
    New-VersionFile $versionFile

    # Detect Python bitness to match target arch
    $pyArch = & python -c "import struct; print('x86_64' if struct.calcsize('P')*8==64 else 'x86')" 2>&1
    if ($pyArch -notmatch 'x86') { $pyArch = 'x86_64' }

    $args = @(
        '--onefile',
        '--clean',
        "--name=$([System.IO.Path]::GetFileNameWithoutExtension($script:CFG_SCRIPT))",
        "--version-file=$versionFile",
        "--target-arch=$pyArch",
        "--distpath=$(Join-Path $BUILD_TEMP 'dist_pyinstaller')",
        "--workpath=$(Join-Path $BUILD_TEMP 'work_pyinstaller')",
        "--specpath=$BUILD_TEMP"
    )

    if ($script:CFG_NOCONSOLE) { $args += '--noconsole' }
    if ($script:CFG_ICON)      { $args += "--icon=$($script:CFG_ICON)" }
    # PyInstaller already searches $env:PATH for upx.exe by default — passing
    # --upx-dir=. previously overrode that and restricted the search to the
    # current directory only, so UPX was silently never found. Omit the flag
    # entirely and let PyInstaller use its documented PATH-based lookup.
    if (-not $script:CFG_UPX)  { $args += '--noupx' }

    # Manifest for UAC + Windows 10 compat
    $manifest = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="$($script:CFG_VERSION).0" name="$($script:CFG_NAME)" type="win32"/>
  <description>$($script:CFG_DESC)</description>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges>
      <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
    </requestedPrivileges></security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
    </application>
  </compatibility>
</assembly>
"@
    $manifestPath = Join-Path $BUILD_TEMP 'app.manifest'
    $manifest | Out-File -FilePath $manifestPath -Encoding utf8
    $args += "--manifest=$manifestPath"

    Show-Bar 10 'Preparing...'
    Start-Sleep -Milliseconds 300

    # Run PyInstaller with live progress simulation
    $job = Start-Job -ScriptBlock {
        param($a, $s)
        & python -m PyInstaller @a $s 2>&1
    } -ArgumentList $args, $script:CFG_SCRIPT

    $pct = 10
    while ($job.State -eq 'Running') {
        $pct = [math]::Min($pct + 2, 90)
        Show-Bar $pct 'Compiling...'
        Start-Sleep -Milliseconds 400
    }

    $output = Receive-Job $job -Wait
    Remove-Job $job

    # NOTE: $LASTEXITCODE here reflects the calling session's last *direct*
    # native call -- Start-Job/Receive-Job never bridges the background
    # process's exit code back to it. The old check below (`$LASTEXITCODE
    # -ne 0 -and ...`) was effectively dead: it almost never fired, which
    # meant PyInstaller's own icon-related WARNINGs (e.g. an icon it
    # couldn't parse, or fell back on) were silently discarded even on a
    # "successful" build. Surface them unconditionally instead.
    if ($script:CFG_ICON) {
        $iconLines = $output | Where-Object { $_ -match 'icon' }
        if ($iconLines) {
            INFO 'PyInstaller icon-related log lines:'
            $iconLines | ForEach-Object { C "    $_" 'DarkGray' }
        }
    }
    $warnErrLines = $output | Where-Object { $_ -match '^\s*(WARNING|ERROR):' }
    if ($warnErrLines) {
        WARN 'PyInstaller warnings/errors:'
        $warnErrLines | ForEach-Object { C "    $_" 'DarkGray' }
    }

    Finish-Bar 'Compilation complete'
    $scriptExeName = [System.IO.Path]::GetFileNameWithoutExtension($script:CFG_SCRIPT)
    $exePath = Join-Path $BUILD_TEMP "dist_pyinstaller\$scriptExeName.exe"
    if (-not (Test-Path $exePath)) {
        ERR "PyInstaller did not produce an EXE. Full output:"
        $output | ForEach-Object { C "    $_" 'DarkGray' }
        exit 1
    }
    OK "PyInstaller EXE: $exePath"
    Blank
    return $exePath
}

# ─────────────────────────────────────────────────────────────
#  NUITKA BUILD
# ─────────────────────────────────────────────────────────────
function Invoke-Nuitka {
    C '  BUILDING WITH NUITKA' 'Yellow'
    Ruler

    $nuitkaOut = Join-Path $BUILD_TEMP 'dist_nuitka'
    New-Item -ItemType Directory -Path $nuitkaOut -Force | Out-Null

    $args = @(
        '-m', 'nuitka',
        '--onefile',
        "--output-dir=$nuitkaOut",
        "--output-filename=$([System.IO.Path]::GetFileNameWithoutExtension($script:CFG_SCRIPT)).exe",
        '--assume-yes-for-downloads',
        '--windows-product-name=' + $script:CFG_NAME,
        '--windows-product-version=' + $script:CFG_VERSION,
        '--windows-file-description=' + $script:CFG_DESC,
        '--windows-company-name=' + $PYFORGE_AUTHOR
    )

    if ($script:CFG_NOCONSOLE) { $args += '--windows-disable-console' }
    if ($script:CFG_ICON)      { $args += "--windows-icon-from-ico=$($script:CFG_ICON)" }

    Show-Bar 5 'Starting Nuitka (C compilation — takes time)...'

    $job = Start-Job -ScriptBlock {
        param($a, $s)
        & python @a $s 2>&1
    } -ArgumentList $args, $script:CFG_SCRIPT

    $pct = 5
    while ($job.State -eq 'Running') {
        $pct = [math]::Min($pct + 1, 90)
        Show-Bar $pct 'C-compiling (Nuitka)...'
        Start-Sleep -Milliseconds 800
    }

    $output = Receive-Job $job -Wait
    Remove-Job $job

    Finish-Bar 'Nuitka build complete'

    $scriptExeName = [System.IO.Path]::GetFileNameWithoutExtension($script:CFG_SCRIPT)
    $exePath = Join-Path $nuitkaOut "$scriptExeName.exe"
    if (-not (Test-Path $exePath)) {
        ERR "Nuitka EXE not found. Output:"
        $output | Select-Object -Last 20 | ForEach-Object { C "    $_" 'DarkGray' }
        exit 1
    }
    OK "Nuitka EXE: $exePath"
    Blank
    return $exePath
}

# ─────────────────────────────────────────────────────────────
#  CODE SIGNING
# ─────────────────────────────────────────────────────────────
function Invoke-Sign {
    param([string[]]$ExePaths)

    if (-not $script:IS_WINDOWS) {
        WARN 'Signing skipped (non-Windows OS)'
        return
    }

    C '  CODE SIGNING' 'Yellow'
    Ruler

    if ($script:CFG_SIGN -match 'Self-signed') {

        Show-Bar 20 'Generating self-signed certificate...'
        $certParams = @{
            Subject           = "CN=$($script:CFG_NAME), O=$PYFORGE_AUTHOR"
            Type              = 'CodeSigningCert'
            CertStoreLocation = 'Cert:\CurrentUser\My'
            HashAlgorithm     = 'SHA256'
            NotAfter          = (Get-Date).AddYears(5)
            KeyUsage          = 'DigitalSignature'
        }
        $cert = New-SelfSignedCertificate @certParams
        Finish-Bar 'Certificate created'

        # Trust it locally (requires admin for LocalMachine store, fall back to CurrentUser)
        Show-Bar 50 'Installing certificate into Trusted Publishers...'
        try {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
                'TrustedPublisher', 'LocalMachine')
            $store.Open('ReadWrite')
            $store.Add($cert)
            $store.Close()
            OK 'Added to LocalMachine\TrustedPublisher (requires admin)'
        } catch {
            WARN 'Could not add to LocalMachine (no admin). Adding to CurrentUser instead.'
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
                'TrustedPublisher', 'CurrentUser')
            $store.Open('ReadWrite')
            $store.Add($cert)
            $store.Close()
        }
        Finish-Bar 'Certificate trusted'

        Show-Bar 70 'Signing EXE(s)...'
        foreach ($exe in $ExePaths) {
            $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert `
                       -TimestampServer 'http://timestamp.digicert.com' `
                       -HashAlgorithm SHA256 -ErrorAction SilentlyContinue
            if ($sig.Status -eq 'Valid') {
                Finish-Bar "Signed: $(Split-Path $exe -Leaf)"
                OK "Signed: $exe"
            } else {
                WARN "Signing status: $($sig.Status) — $exe"
                WARN "Note: Self-signed EXEs show SmartScreen warning on other machines."
                WARN "For full trust, use a real EV code-signing certificate."
            }
        }

    } elseif ($script:CFG_SIGN -match 'Real PFX') {

        Show-Bar 30 'Loading PFX certificate...'
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                $script:CFG_PFX_PATH,
                [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:CFG_PFX_PASS)
                )
            )
        } catch {
            Write-Host ''
            ERR "Failed to load PFX: $_"
            exit 1
        }
        Finish-Bar 'Certificate loaded'
        OK "Subject: $($cert.Subject)"
        OK "Expires: $($cert.NotAfter)"

        Show-Bar 60 'Signing EXE(s)...'
        foreach ($exe in $ExePaths) {
            $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert `
                       -TimestampServer 'http://timestamp.digicert.com' `
                       -HashAlgorithm SHA256
            if ($sig.Status -eq 'Valid') {
                Finish-Bar "Signed: $(Split-Path $exe -Leaf)"
                OK "Signed: $exe"
            } else {
                WARN "Signing issue: $($sig.Status) for $exe"
            }
        }

    } else {
        WARN 'Signing skipped by user request.'
    }

    Blank
}

# ─────────────────────────────────────────────────────────────
#  COPY TO OUTPUT
# ─────────────────────────────────────────────────────────────
function Copy-Output {
    param([string[]]$ExePaths)

    # Always the folder the original .py script lives in — not %TEMP%,
    # not the current working directory the script happened to be launched
    # from.
    $outDir = Split-Path $script:CFG_SCRIPT -Parent

    C '  COPYING OUTPUT' 'Yellow'
    Ruler
    INFO "Destination (folder of the source .py): $outDir"

    try {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    } catch {
        ERR "Could not create/access output folder: $outDir"
        ERR "$_"
        WARN "Your built EXE(s) are safe here (not deleted): $BUILD_TEMP"
        foreach ($exe in $ExePaths) { WARN "  $exe" }
        exit 1
    }

    $i = 0
    foreach ($exe in $ExePaths) {
        $i++
        $dest = Join-Path $outDir (Split-Path $exe -Leaf)
        try {
            Copy-Item -Path $exe -Destination $dest -Force -ErrorAction Stop
        } catch {
            Write-Host ''
            ERR "Failed to copy $(Split-Path $exe -Leaf) to $outDir"
            ERR "$_"
            WARN "(Often the destination file is locked because a previous build is still running.)"
            WARN "Your build was NOT lost — it's still here: $exe"
            exit 1
        }
        $pct = [math]::Round($i / $ExePaths.Count * 100)
        Show-Bar $pct "Copying $(Split-Path $exe -Leaf)..."
        Start-Sleep -Milliseconds 200
    }
    Finish-Bar 'Output ready'
    Blank
    OK "Output folder: $outDir"
    return $outDir
}

# ─────────────────────────────────────────────────────────────
#  FINAL SUMMARY
# ─────────────────────────────────────────────────────────────
function Show-Summary {
    param([string[]]$ExePaths, [string]$OutDir)

    Blank
    Ruler
    C '  BUILD COMPLETE' 'Green'
    Ruler
    Blank
    C "  ┌─ App      : $($script:CFG_NAME) v$($script:CFG_VERSION)" 'White'
    C "  ├─ Signed   : $($script:CFG_SIGN)" 'White'
    C "  ├─ Compiler : $($script:CFG_COMPILER)" 'White'
    C "  └─ Output   : $OutDir" 'Green'
    Blank
    foreach ($exe in $ExePaths) {
        $size = [math]::Round((Get-Item $exe).Length / 1MB, 2)
        OK "  $(Split-Path $exe -Leaf)  ($size MB)"
    }
    Blank
    WARN 'NOTES:'
    if ($script:CFG_SIGN -match 'Self-signed') {
        WARN '  Self-signed EXE is trusted only on machines where cert was installed.'
        WARN '  Windows SmartScreen may still warn on other PCs.'
        WARN '  For full trust + no warnings: use a real EV code-signing cert.'
    }
    if ($script:CFG_COMPILER -match 'PyInstaller') {
        INFO '  PyInstaller EXE extracts to %TEMP% on first run (normal behaviour).'
    }
    if ($script:CFG_ICON) {
        WARN '  Icon still looks wrong/default? The icon in the file is almost'
        WARN '  always correct even when Explorer shows the old one — that''s a'
        WARN '  stale icon cache. Try: right-click the EXE > Properties (confirms'
        WARN '  the real icon), or reboot / run "ie4uinit.exe -show" again.'
        WARN '  Renaming the EXE once also forces Explorer to redraw it.'
    }
    Blank
    Ruler
    C "  PyForge v$PYFORGE_VERSION  ·  $PYFORGE_AUTHOR" 'DarkGray'
    Blank
}

# ─────────────────────────────────────────────────────────────
#  RUNTIME COMPILER CHOICE  (when user selected "Let me choose")
# ─────────────────────────────────────────────────────────────
function Get-RuntimeChoice {
    Blank
    return Choose 'Which compiler do you want to use now?' @(
        'PyInstaller',
        'Nuitka',
        'Build both (compare outputs)'
    )
}

# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────
function Main {
    Show-Banner
    Test-Requirements
    Get-BuildConfig
    Install-Deps

    New-Item -ItemType Directory -Path $BUILD_TEMP -Force | Out-Null

    if ($script:CFG_ICON) {
        C '  PREPARING ICON' 'Yellow'
        Ruler
        $script:CFG_ICON = New-NormalizedIcon -SourcePath $script:CFG_ICON -WorkDir $BUILD_TEMP
        Blank
    }

    $builtExes = @()

    $effectiveCompiler = $script:CFG_COMPILER
    if ($effectiveCompiler -match 'runtime') {
        $effectiveCompiler = Get-RuntimeChoice
    }

    if ($effectiveCompiler -match 'PyInstaller|both') {
        $exe = Invoke-PyInstaller
        $builtExes += $exe
    }

    if ($effectiveCompiler -match 'Nuitka|both') {
        $exe = Invoke-Nuitka
        $builtExes += $exe
    }

    if ($builtExes.Count -eq 0) {
        ERR 'No EXE was produced. Check errors above.'
        exit 1
    }

    Invoke-Sign -ExePaths $builtExes

    $outDir = Copy-Output -ExePaths $builtExes

    if ($script:CFG_ICON -and (Test-Path $script:CFG_ICON)) {
        # The normalized icon only ever existed inside BUILD_TEMP, which
        # Invoke-Cleanup deletes a few lines below -- so today there is no
        # way to inspect the exact file that was actually embedded. Copy it
        # next to the EXE so it can be double-clicked / Properties-checked
        # directly, independent of anything PyInstaller or Explorer did.
        $iconDebugPath = Join-Path $outDir "$($script:CFG_NAME)_icon_debug.ico"
        try {
            Copy-Item -Path $script:CFG_ICON -Destination $iconDebugPath -Force
            INFO "Saved the exact icon file used for this build: $iconDebugPath"
            INFO "  Check its Properties/thumbnail first -- if IT looks wrong, the"
            INFO "  problem is upstream of PyInstaller (source image or normalization)."
        } catch {
            INFO "Could not save a debug copy of the icon (non-fatal): $_"
        }
    }

    if ($script:CFG_ICON -and $script:IS_WINDOWS) {
        # The EXE's icon resource can be 100% correct while Windows Explorer
        # still shows a stale cached icon (especially when re-using the same
        # filename across builds). This is a harmless, reversible refresh —
        # it does not touch or restart Explorer.
        try {
            & ie4uinit.exe -show 2>&1 | Out-Null
            OK 'Windows icon cache refreshed (ie4uinit.exe -show).'
        } catch {
            INFO 'Could not auto-refresh the icon cache; see NOTES below if the icon looks wrong.'
        }
    }

    # Cleanup build artefacts
    Show-Bar 95 'Cleaning up...'
    Invoke-Cleanup
    Finish-Bar 'Cleaned'

    Show-Summary -ExePaths ($builtExes | ForEach-Object {
        Join-Path $outDir (Split-Path $_ -Leaf)
    }) -OutDir $outDir
}

Main
