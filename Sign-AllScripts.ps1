#Requires -Version 3.0
<#
.SYNOPSIS
    Creates a self-signed code-signing certificate and signs all .ps1 scripts.
.DESCRIPTION
    Generates a free internal code-signing cert (valid 3 years), installs it
    into the local trust stores, exports the public key for distribution,
    and signs every .ps1 file in the repo.

    NOTE: .bat and .cmd files cannot be reliably code-signed on Windows.
    Consider converting critical batch scripts to PowerShell (.ps1) if
    code signing is required.
.NOTES
    Run as Administrator from the repo root.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Subject         = 'CN=RHSHOURAV-IT-Ops'
$RepoRoot        = $PSScriptRoot
$TimestampServer = 'http://timestamp.digicert.com'

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
# 3. Export public key for distribution
# ---------------------------------------------------------------------------
$exportDir  = Join-Path $RepoRoot 'certs'
if (-not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$cerPath = Join-Path $exportDir 'RHSHOURAV-IT-Ops.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Force
Write-Host "  [+] Public key exported: $cerPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Sign all .ps1 files
# ---------------------------------------------------------------------------
Write-Host "`n  [-] Scanning for .ps1 files..." -ForegroundColor Cyan

$scripts = Get-ChildItem -Path $RepoRoot -Filter '*.ps1' -Recurse -File |
           Where-Object { $_.FullName -notlike '*\certs\*' }

Write-Host "  [-] Found $($scripts.Count) script(s) to sign.`n" -ForegroundColor Cyan

$ok = 0; $fail = 0

foreach ($script in $scripts) {
    $relPath = $script.FullName.Substring($RepoRoot.Length + 1)
    try {
        $sig = Set-AuthenticodeSignature -FilePath $script.FullName `
                                         -Certificate $cert `
                                         -TimestampServer $TimestampServer `
                                         -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            Write-Host "  [+] $relPath" -ForegroundColor Green
            $ok++
        } else {
            Write-Host "  [!] $relPath  ->  $($sig.Status)" -ForegroundColor Yellow
            $fail++
        }
    } catch {
        Write-Host "  [X] $relPath  ->  $_" -ForegroundColor Red
        $fail++
    }
}

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
Write-Host "`n  ===========================================" -ForegroundColor Cyan
Write-Host "  Signed   : $ok" -ForegroundColor Green
if ($fail -gt 0) { Write-Host "  Failed   : $fail" -ForegroundColor Red }
Write-Host "  ===========================================`n" -ForegroundColor Cyan
