#Requires -Version 5.1
<#
.SYNOPSIS
    PyForge v1.0.0 - Universal Python to EXE Compiler
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
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
#  GLOBALS
# ─────────────────────────────────────────────────────────────
$PYFORGE_VERSION = '1.0.0'
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
    $script:CFG_SCRIPT = Ask 'Python script path (.py)'
    while (-not (Test-Path $script:CFG_SCRIPT -PathType Leaf)) {
        ERR "File not found: $($script:CFG_SCRIPT)"
        $script:CFG_SCRIPT = Ask 'Python script path (.py)'
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
    $script:CFG_ICON = Ask 'Icon path (.ico)  [leave blank to skip]' ''
    if ($script:CFG_ICON -and -not (Test-Path $script:CFG_ICON)) {
        WARN "Icon not found — will compile without icon"
        $script:CFG_ICON = ''
    } elseif ($script:CFG_ICON) {
        $script:CFG_ICON = Resolve-Path $script:CFG_ICON | Select-Object -ExpandProperty Path
        OK "Icon: $($script:CFG_ICON)"
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
        $script:CFG_PFX_PATH = Ask 'Path to your .pfx certificate file'
        while (-not (Test-Path $script:CFG_PFX_PATH)) {
            ERR "PFX not found: $($script:CFG_PFX_PATH)"
            $script:CFG_PFX_PATH = Ask 'Path to your .pfx certificate file'
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
         StringStruct(u'OriginalFilename', u'$($script:CFG_NAME).exe'),
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
        "--name=$($script:CFG_NAME)",
        "--version-file=$versionFile",
        "--target-arch=$pyArch",
        "--distpath=$(Join-Path $BUILD_TEMP 'dist_pyinstaller')",
        "--workpath=$(Join-Path $BUILD_TEMP 'work_pyinstaller')",
        "--specpath=$BUILD_TEMP"
    )

    if ($script:CFG_NOCONSOLE) { $args += '--noconsole' }
    if ($script:CFG_ICON)      { $args += "--icon=$($script:CFG_ICON)" }
    if ($script:CFG_UPX)       { $args += '--upx-dir=.' } else { $args += '--noupx' }

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

    if ($LASTEXITCODE -ne 0 -and ($output -join '') -match 'Error|error') {
        Write-Host ''
        ERR "PyInstaller failed. Output:"
        $output | ForEach-Object { C "    $_" 'DarkGray' }
        exit 1
    }

    Finish-Bar 'Compilation complete'
    $exePath = Join-Path $BUILD_TEMP "dist_pyinstaller\$($script:CFG_NAME).exe"
    if (-not (Test-Path $exePath)) {
        ERR "Output EXE not found at: $exePath"
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
        "--output-filename=$($script:CFG_NAME).exe",
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

    $exePath = Join-Path $nuitkaOut "$($script:CFG_NAME).exe"
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

    $outDir = Join-Path $ORIGINAL_DIR 'PyForge_Output'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    C '  COPYING OUTPUT' 'Yellow'
    Ruler

    $i = 0
    foreach ($exe in $ExePaths) {
        $i++
        $dest = Join-Path $outDir (Split-Path $exe -Leaf)
        Copy-Item -Path $exe -Destination $dest -Force
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

    # Cleanup build artefacts
    Show-Bar 95 'Cleaning up...'
    Invoke-Cleanup
    Finish-Bar 'Cleaned'

    Show-Summary -ExePaths ($builtExes | ForEach-Object {
        Join-Path $outDir (Split-Path $_ -Leaf)
    }) -OutDir $outDir
}

Main

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUBLzsPVBDtYhq42bgo8xPeqnu
# bCCgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRlE3zY03pz3whPtzondCoMpmK2KjANBgkq
# hkiG9w0BAQEFAASCAQCUIoFBy58SMs934wFa7U5mI44nlYmc4osJbUajSQJP+TB8
# N5jM1ZWn6+JIvLhd2eeGbyFGDxiCTnVAlVX1Na1PUtQjmkuB5fAyMRNw7PVaccPS
# PWGn76brQa+QUzIa/Yt/BIY+3J+xaVfops6t3Fprg0Sgls1b0MkNFtjY5jLYZEjO
# z6GHqefUlmsBkcSPbEm1UhLvBsl8U/63/PL6h6z6eHeaAM5RB7+/rW+L5i4TvHhJ
# WN/4t0asrgKXjBCjvaS7gIFjmivDsPCd/qylm5KWQwXd1QgcZSybHYW6rXiJ3qUG
# rM421j2+ww5ZLqpORYDg0yvtSuiU0NTYeCOmE3gEoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ1MFowLwYJKoZIhvcNAQkEMSIEILPofV6LE44OfNTk
# cKkO9N7KMuNitJh1iTIWuz9yAnNDMA0GCSqGSIb3DQEBAQUABIICAE42cvqVqgnW
# oWnSJXVpZDZgLTL7P8WDvXxaiU3VY5axqB6w08EM3Wnegw6CXu4LhAjPcKDgi3sl
# o3SaSsUfPnHWTHS7aw1zfui3V28DrQIZ4Mi7EwprFecpewwFFsIKfOlSCUCp1hGF
# 5JNhbrnc30XEiDsAqXesmGlxmvFGIaZXSu2TELSPRtvSW501ma/1j+hLZZqIILJx
# 6NabxcHb/cPKiKaBy0CyQPnlvBWJb54lh2X6poLEEL94nS50fo13LAJvhOCC4y7J
# eOUssTyhoWIpzT9xnlxH5Ia3JBB2gS5+xQCAy3k7kvbVBagV32mm8fGfjxMq1K1j
# HvuLgwQmIO9mYEIXSC5RewmyII+nwziVtEN9wvJENmy1Wpv0jaWmgBtngEyUeT3D
# L8DA34qFpYXagsPM9Pp9Ep0svt4KVAaPDARTRcf6oBg6res+h9vaGfZWwMO3+F28
# FtmVLdAlJ9UHvoxE8MIJIgfLiSvf0JFRW9/vstDi3Scl6q0kbGl7pb1neOP0cSbZ
# Lk2U1CDUvBr3U5yZR399uvAn5HxEZ1mXHWuz2FYJv2+tAjJdMSODuYhyJLYzabi2
# AFFBMMEoJtskRzUVQACoSEYIe99zbAFLVsfJxFpfPYvNofC4m/QtRVszhLd7xitt
# I3Zvj4PH/w0t6n/w+kttYYBzpdEgG/ya
# SIG # End signature block
