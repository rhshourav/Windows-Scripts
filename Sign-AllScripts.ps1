#Requires -Version 3.0
<#
.SYNOPSIS
    Creates a self-signed code-signing certificate and signs all scripts.
.DESCRIPTION
    Generates a free internal code-signing cert (valid 3 years), installs it
    into the local trust stores, exports the public key for distribution,
    and signs every .ps1, .bat, and .cmd file in the repo.
    .ps1 files are signed with PowerShell's Set-AuthenticodeSignature.
    .bat/.cmd files are signed with osslsigncode (installed via winget).
.NOTES
    Run as Administrator from the repo root.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Subject         = 'CN=RHSHOURAV-IT-Ops'
$RepoRoot        = $PSScriptRoot
$TimestampServer = 'http://timestamp.digicert.com'
$PfxPassword     = 'TempPfx123!'

# ---------------------------------------------------------------------------
# 1. Get or create the code-signing certificate
# ---------------------------------------------------------------------------
Write-Host "`n  [-] Checking for code-signing certificate..." -ForegroundColor Cyan

$cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object { $_.Subject -eq $Subject } |
        Select-Object -First 1

if (-not $cert) {
    Write-Host "  [-] Certificate not found. Creating new one (valid 3 years)..." -ForegroundColor Yellow
    $expiry = (Get-Date).AddYears(3)
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
                                      -Subject $Subject `
                                      -NotAfter $expiry `
                                      -CertStoreLocation Cert:\CurrentUser\My
    Write-Host "  [+] Created: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "  [+] Found existing certificate: $($cert.Thumbprint)" -ForegroundColor Green
    if ($cert.NotAfter -lt (Get-Date)) {
        Write-Host "  [!] Certificate expired! Removing and creating a new one..." -ForegroundColor Red
        Remove-Item -LiteralPath $cert.PSPath -Force
        $expiry = (Get-Date).AddYears(3)
        $cert = New-SelfSignedCertificate -Type CodeSigningCert `
                                          -Subject $Subject `
                                          -NotAfter $expiry `
                                          -CertStoreLocation Cert:\CurrentUser\My
        Write-Host "  [+] Created new: $($cert.Thumbprint)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 2. Install into local trust stores
# ---------------------------------------------------------------------------
Write-Host "`n  [-] Installing certificate into trust stores..." -ForegroundColor Cyan

$rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
$rootStore.Open('ReadWrite')
$rootStore.Add($cert)
$rootStore.Close()
Write-Host "  [+] Trusted Root Certification Authorities" -ForegroundColor Green

$pubStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'CurrentUser')
$pubStore.Open('ReadWrite')
$pubStore.Add($cert)
$pubStore.Close()
Write-Host "  [+] Trusted Publishers" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Export public key (.cer) and PFX for osslsigncode
# ---------------------------------------------------------------------------
$exportDir  = Join-Path $RepoRoot 'certs'
if (-not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$cerPath = Join-Path $exportDir 'RHSHOURAV-IT-Ops.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Force
Write-Host "  [+] Public key exported: $cerPath" -ForegroundColor Green

$pfxPath     = Join-Path $exportDir 'RHSHOURAV-IT-Ops.pfx'
$pfxPassword = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPassword -Force
Write-Host "  [+] PFX exported: $pfxPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Find osslsigncode (for .bat/.cmd signing)
# ---------------------------------------------------------------------------
$osslsigncode = Get-ChildItem 'C:\Users\*\AppData\Local\Microsoft\WinGet\Packages\*\bin\osslsigncode.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName

if (-not $osslsigncode) {
    $osslsigncode = (Get-Command osslsigncode -ErrorAction SilentlyContinue).Source
}

if ($osslsigncode) {
    Write-Host "  [+] osslsigncode found: $osslsigncode" -ForegroundColor Green
} else {
    Write-Host "  [!] osslsigncode not found. .bat/.cmd files will be skipped." -ForegroundColor Yellow
    Write-Host "      Install with: winget install osslsigncode" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. Sign all .ps1 files
# ---------------------------------------------------------------------------
Write-Host "`n  [-] Scanning for .ps1 files..." -ForegroundColor Cyan

$ps1Scripts = Get-ChildItem -Path $RepoRoot -Filter '*.ps1' -Recurse -File |
              Where-Object { $_.FullName -notlike '*\certs\*' }

Write-Host "  [-] Found $($ps1Scripts.Count) .ps1 file(s) to sign.`n" -ForegroundColor Cyan

$ps1Ok = 0; $ps1Fail = 0

foreach ($script in $ps1Scripts) {
    $relPath = $script.FullName.Substring($RepoRoot.Length + 1)
    try {
        $sig = Set-AuthenticodeSignature -FilePath $script.FullName `
                                         -Certificate $cert `
                                         -TimestampServer $TimestampServer `
                                         -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            Write-Host "  [+] $relPath" -ForegroundColor Green
            $ps1Ok++
        } else {
            Write-Host "  [!] $relPath  ->  $($sig.Status)" -ForegroundColor Yellow
            $ps1Fail++
        }
    } catch {
        Write-Host "  [X] $relPath  ->  $_" -ForegroundColor Red
        $ps1Fail++
    }
}

# ---------------------------------------------------------------------------
# 6. Sign all .bat and .cmd files (via osslsigncode)
# ---------------------------------------------------------------------------
$batCmdOk = 0; $batCmdFail = 0

if ($osslsigncode) {
    Write-Host "`n  [-] Scanning for .bat and .cmd files..." -ForegroundColor Cyan

    $batCmdFiles = Get-ChildItem -Path $RepoRoot -Include '*.bat','*.cmd' -Recurse -File |
                   Where-Object { $_.FullName -notlike '*\certs\*' }

    Write-Host "  [-] Found $($batCmdFiles.Count) .bat/.cmd file(s) to sign.`n" -ForegroundColor Cyan

    foreach ($file in $batCmdFiles) {
        $relPath = $file.FullName.Substring($RepoRoot.Length + 1)
        $outFile = "$($file.FullName).signed"
        try {
            & $osslsigncode sign -pkcs12 $pfxPath -pass $PfxPassword `
                           -h sha256 -ts $TimestampServer `
                           -in $file.FullName -out $outFile 2>&1 | Out-Null

            if (Test-Path $outFile) {
                Remove-Item $file.FullName -Force
                Rename-Item $outFile $file.FullName
                Write-Host "  [+] $relPath" -ForegroundColor Green
                $batCmdOk++
            } else {
                Write-Host "  [X] $relPath" -ForegroundColor Red
                $batCmdFail++
            }
        } catch {
            Write-Host "  [X] $relPath  ->  $_" -ForegroundColor Red
            $batCmdFail++
            if (Test-Path $outFile) { Remove-Item $outFile -Force }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
Write-Host "`n  ===========================================" -ForegroundColor Cyan
Write-Host "  .ps1      : $ps1Ok signed" -ForegroundColor Green
Write-Host "  .bat/.cmd : $batCmdOk signed" -ForegroundColor Green
if ($ps1Fail -gt 0 -or $batCmdFail -gt 0) {
    Write-Host "  Failed    : $($ps1Fail + $batCmdFail)" -ForegroundColor Red
}
Write-Host "  ===========================================`n" -ForegroundColor Cyan
