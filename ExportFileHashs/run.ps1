<#
===============================================================================
Script Name : File Hash Exporter
Author      : rhshourav
Project     : Windows Script 
Description : Calculates file hashes and saves results as:
              filename HASH
===============================================================================
#>

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
