#Requires -Version 5.1
<#
.SYNOPSIS
    PyForge v2.0.0 - Universal Python to EXE Compiler
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
$PYFORGE_VERSION = '2.0.0'
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
    $script:CFG_VERSION = Ask 'Version string' '2.0.0'
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

    if ($needsPyInstaller) { pip-install 'pyinstaller'    10 'PyInstaller...' }
    if ($needsNuitka)      { pip-install 'nuitka ordered-set zstandard' 30 'Nuitka...' }
    if ($script:CFG_UPX)  { INFO 'UPX: ensure upx.exe is on PATH (download from upx.github.io)' }

    pip-install 'pywin32' 50 'pywin32 (version info)...'
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

    $args = @(
        '--onefile',
        '--clean',
        "--name=$($script:CFG_NAME)",
        "--version-file=$versionFile",
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
