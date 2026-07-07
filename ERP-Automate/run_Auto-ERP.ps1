# ============================================================
# Oracle Instant Client Installer
# With Fallback Source Locations
# COM Auto-Detection, Progress Bars, Colorful Output
# Optional Font Installation
# Auto-Elevates to Administrator
# ============================================================
# Script Info
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

$ScriptName = "ERP Setup"
$Author     = "rhshourav"
$GitHub     = "https://github.com/rhshourav/Windows-Scripts"
$Version    = "v1.0.9t"

Write-Host ""
Write-Host ""
Write-Host (" Script   : " + $ScriptName) -ForegroundColor White
Write-Host (" Author   : " + $Author)     -ForegroundColor White
Write-Host (" GitHub   : " + $GitHub)     -ForegroundColor Cyan
Write-Host (" Version  : " + $Version)    -ForegroundColor Yellow

$ErrorActionPreference = "Stop"
# ================================================================
#  TELEMETRY
# ================================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "ERP Setup  v$($Version)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
# -----------------------------
# Auto-Elevate to Admin
# -----------------------------
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Warning "Script is not running as administrator. Restarting as admin..."
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process $pwsh "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# -----------------------------
# COM Detection - global
# -----------------------------
if (-not ("NativeMethods" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr LoadLibrary(string lpFileName);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    [DllImport("kernel32.dll")]
    public static extern bool FreeLibrary(IntPtr hModule);
}
"@
}

# -----------------------------
# Decode Base64 Path
# -----------------------------
function Decode-Base64Path {
    param([string]$Encoded)
    $bytes = [Convert]::FromBase64String($Encoded)
    [Text.Encoding]::UTF8.GetString($bytes)
}

# -----------------------------
# Color Helpers
# -----------------------------
function Write-Header ($Text)  { Write-Host ""; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Step   ($Text)  { Write-Host "[*] $Text" -ForegroundColor White }
function Write-Success($Text)  { Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Warn   ($Text)  { Write-Host "[!] $Text" -ForegroundColor Yellow }
function Write-Verify ($Text)  { Write-Host "[VERIFIED] $Text" -ForegroundColor DarkGreen }

# -----------------------------
# Configuration
# -----------------------------

$InstantClientDir = "instantclient_10_2"
$OracleDir        = "C:\Program Files\$InstantClientDir"
$DestDll          = "C:\Windows\XceedZip.dll"

# Base64-obfuscated source locations (priority order)
$EncodedShares = @(
    "XFwxOTIuMTY4LjE2LjI1MVxlcnA=",   # Primary
    "XFwxOTIuMTY4LjE2LjI1MVxjYW0tZXJw", # Secondary
    "XFwxOTIuMTY4LjE3LjE0MlxtbGJkX2VycA=="        # Tertiary
)

# -----------------------------
# Source Selection with Fallback
# -----------------------------
function Get-AvailableSource {
    param(
        [string[]]$EncodedPaths,
        [string]$RequiredFolder
    )

    foreach ($encoded in $EncodedPaths) {
        try {
            $decoded = Decode-Base64Path $encoded
            Write-Step "Testing source: $decoded"

            if (-not (Test-Path $decoded)) {
                Write-Warn "Source not reachable"
                continue
            }

            $oraclePath = Join-Path $decoded $RequiredFolder
            $dllPath    = Join-Path $decoded "XceedZip.dll"

            if (-not (Test-Path $oraclePath)) {
                Write-Warn "Missing Oracle client folder"
                continue
            }

            if (-not (Test-Path $dllPath)) {
                Write-Warn "Missing XceedZip.dll"
                continue
            }

            Write-Success "Using source: $decoded"
            return $decoded
        }
        catch {
            Write-Warn "Error testing source: $_"
        }
    }

    throw "No valid source locations available."
}

# -----------------------------
# PATH Handling
# -----------------------------
function Add-ToSystemPath {
    param([string]$Entry)
    $entry = $Entry.TrimEnd('\')
    $path  = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = $path.Split(";") | ForEach-Object { $_.TrimEnd('\') }

    if ($parts -notcontains $entry) {
        [Environment]::SetEnvironmentVariable(
            "Path",
            ($path.TrimEnd(";") + ";" + $entry),
            "Machine"
        )
        Write-Step "Added '$entry' to system PATH"
    }
    else {
        Write-Step "'$entry' already exists in system PATH"
    }
}

# -----------------------------
# Validation
# -----------------------------
function Verify-SystemVariable {
    param([string]$Name, [string]$Expected)

    $actual = [Environment]::GetEnvironmentVariable($Name, "Machine")
    if (-not $actual) {
        throw "System variable '$Name' missing."
    }

    if ($actual.TrimEnd('\') -ne $Expected.TrimEnd('\')) {
        throw "System variable '$Name' mismatch."
    }

    Write-Verify "$Name = $actual"
}

function Verify-SystemPath {
    param([string]$ExpectedEntry)

    $expected = $ExpectedEntry.TrimEnd('\')
    $path = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = $path.Split(";") | ForEach-Object { $_.TrimEnd('\') }

    if (($parts | Where-Object { $_ -eq $expected }).Count -ne 1) {
        throw "PATH validation failed for '$expected'"
    }

    Write-Verify "PATH contains '$expected' exactly once"
}

# -----------------------------
# COM Detection
# -----------------------------
function Test-ComDll {
    param([string]$DllPath)

    if (-not (Test-Path $DllPath)) { return $false }

    $h = [NativeMethods]::LoadLibrary($DllPath)
    if ($h -eq [IntPtr]::Zero) { return $false }

    $p = [NativeMethods]::GetProcAddress($h, "DllRegisterServer")
    [NativeMethods]::FreeLibrary($h)

    return ($p -ne [IntPtr]::Zero)
}

# -----------------------------
# Start
# -----------------------------
Write-Header "Oracle Instant Client Installer"

$SourceShare = Get-AvailableSource `
    -EncodedPaths $EncodedShares `
    -RequiredFolder $InstantClientDir

$SourceOracle = Join-Path $SourceShare $InstantClientDir
$SourceDll    = Join-Path $SourceShare "XceedZip.dll"

# -----------------------------
# Copy Oracle Instant Client
# -----------------------------
if (Test-Path $OracleDir) {
    Write-Warn "Existing Oracle client found. Removing..."
    Remove-Item $OracleDir -Recurse -Force
}

Write-Step "Copying Oracle Instant Client..."
robocopy $SourceOracle $OracleDir /E /R:3 /W:5 /ETA
if ($LASTEXITCODE -ge 8) {
    throw "Oracle client copy failed (Robocopy exit code $LASTEXITCODE)"
}
Write-Success "Oracle Instant Client copied"

# -----------------------------
# Copy DLL
# -----------------------------
Write-Step "Copying XceedZip.dll..."
Copy-Item $SourceDll $DestDll -Force
Write-Success "XceedZip.dll copied"

# -----------------------------
# COM Registration
# -----------------------------
if (Test-ComDll $DestDll) {
    Write-Step "Registering XceedZip.dll..."
    & "$env:windir\System32\regsvr32.exe" /s "$DestDll"
    Write-Success "XceedZip.dll registered"
}
else {
    Write-Warn "XceedZip.dll is not COM-capable. Skipping registration."
}

# -----------------------------
# Environment Variables
# -----------------------------
Write-Step "Configuring environment variables..."
# Oracle variables
[Environment]::SetEnvironmentVariable("ORACLE_HOME", $OracleDir, "Machine")
[Environment]::SetEnvironmentVariable("TNS_ADMIN",  $OracleDir, "Machine")
Add-ToSystemPath $OracleDir

# -----------------------------
# Verification
# -----------------------------
Write-Header "Validating System Configuration"
Verify-SystemVariable "ORACLE_HOME" $OracleDir
Verify-SystemVariable "TNS_ADMIN"  $OracleDir
Verify-SystemPath $OracleDir


# -----------------------------
# Font Installation (Optional)
# -----------------------------
$installFonts = Read-Host "Do you want to install ERP fonts? (Y/N)"
if ($installFonts.Trim().ToUpper() -eq "Y") {
    try {
        Write-Step "Installing fonts..."
        $fontScript = "$env:TEMP\font_install.ps1"
        Invoke-WebRequest `
            -Uri "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/ERP-Automate/font_install.ps1" `
            -OutFile $fontScript
        . $fontScript
        Write-Success "Fonts installed"
    }
    catch {
        Write-Warn "Font installation failed: $_"
    }
}

# -----------------------------
# Done
# -----------------------------
Write-Host ""
Write-Success "Installation completed successfully."
Write-Warn "Log off or restart required for PATH changes to apply."

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUxFQfO8eB9PRiavHnPzIs7nQ7
# JyKgghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBSv8pXnoQxpKpowMrAgk4WzJeTQ0TANBgkq
# hkiG9w0BAQEFAASCAQAeL6f1u2Lx7XePlsYcijT/HqFFCV0eR6+myZdPe09lvQI9
# c7AomxtNfXeOQavPm7lL6/LeZiwlETqn79OttmzIofPgNkPqIJYNEf9ogQEiW24T
# 8oPNWoqnFwBuK0fxJWfBoqQrQ7a0uZFLUPncjV7WKvA8l61av+xnH09NGkWtxobs
# gDSPTPLixfT2Id5iIR9LPudJ7JG/EkMlaD3wnGuNfcD2o0JddYhnGw6SY0SdWaqZ
# RzDRvl3eonWJqMXCDAEjOKW+QlD+hBzRdCRRCnPJXD5MP7eQCutJmE3bihDvniDJ
# 7v+517wNiSY/Zg5EL0qKtnAsiWmShPv5ITprOc8IoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQ0NFowLwYJKoZIhvcNAQkEMSIEIER64Ea372mEuZkB
# 3R1f5lwcFjZFhekzXwWnUlqU55qyMA0GCSqGSIb3DQEBAQUABIICALh1C1EdckWb
# dH1fa9Ec85+8M9a2hii5Oi6L91y849oZtkUdxsgPLQtMJP9T1LuR+f7crRGTHxfD
# qaTgoZQ4+Sq6a34XcPfTHkpVr/iIaNfjHoeBLgwVhGxjxQHhIvSfjWGCZJxSV1+Q
# tai2KhatFCcjiP7zp/NtWMPGzsYhuv9HHCUhY6/JWRKhqIQb7USZs2BoL/rVtlQl
# 5r+67C//yGBnaa3hTSn8bxCBqiRD5EM0z1QlAOnUoCANDxPjfQKNC1bc5sEPR4VI
# GNBlKM50jrf/TFtFRPtmwQSowURG/kU+k5izFHyShecAYY1HhwWRSkr5WZgoR4Jj
# 0Vta4LB249nEX/3LxVOf/SLtlVxq1fuwgqFnCGSH/hyJE8kNjlD5qKYQSihX3j9D
# 20FmMVGAUzFGVvuYXBgyWcviyIqSnHMPQR4ft9L0Wkh+zM0x0OcxsnzSC2aDXizS
# 2ZSrDijSdmZG8S73XJsIGDBRNYEFdL4r3KfA2un5Zm9elO5flroaB672xyP465R4
# NtMyA3CA/cXyfpqT7iMjIGzk4/ENJiRnjY6wJhXjeZ8bPHdcFKL7PBLeZYi+VyT5
# 6rlEoq5uxWu9iRZLlaZgve1Jzuu6TCrOgl+9lu4LNv89SEbgomh36uv694Hix32f
# dFUIyZMePSL4WBcZyjCmya1NnEk4a8Hq
# SIG # End signature block
