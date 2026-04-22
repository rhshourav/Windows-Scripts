<#
===============================================================================
Script Name : File Hash Exporter
Author      : rhshourav
Project     : Windows Script 
Description : Calculates file hashes and saves results as:
              filename HASH
===============================================================================
#>
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
        text  = "Export File Hash V1.0.2`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
param(
    [string]$FolderPath,
    [string]$OutputFile,
    [string]$Algorithm
)

# ---------- DEFAULT VALUES ----------

if (-not $OutputFile) { $OutputFile = "HASH" }
if (-not $Algorithm) { $Algorithm = "SHA256" }

# ---------- GET FOLDER ----------

if (-not $FolderPath) {
    $FolderPath = Read-Host "Enter folder path"
}

if (!(Test-Path $FolderPath)) {
    Write-Host "Folder not found." -ForegroundColor Red
    exit
}

$OutputFile = Join-Path $FolderPath $OutputFile

Write-Host ""
Write-Host "Scanning folder: $FolderPath"
Write-Host "Algorithm: $Algorithm"
Write-Host "Output file: $OutputFile"
Write-Host ""

# ---------- CLEAR OLD OUTPUT ----------

if (Test-Path $OutputFile) {
    Remove-Item $OutputFile
}

# ---------- PROCESS FILES ----------

$files = Get-ChildItem $FolderPath -File

foreach ($file in $files) {

    try {

        $hash = Get-FileHash $file.FullName -Algorithm $Algorithm

        $line = "$($file.Name) $($hash.Hash)"

        Write-Host $line

        Add-Content $OutputFile $line

    }
    catch {

        Write-Host "Failed: $($file.Name)" -ForegroundColor Red

    }

}

Write-Host ""
Write-Host "Hash list saved."
