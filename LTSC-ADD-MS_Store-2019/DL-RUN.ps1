# =========================================================
# Script to download LTSC Add Microsoft Store files and run CMD as Admin
# =========================================================

# Folder to save files
$DownloadFolder = "$env:USERPROFILE\Downloads\LTSC-Add-MicrosoftStore"
if (-Not (Test-Path $DownloadFolder)) {
    New-Item -ItemType Directory -Path $DownloadFolder | Out-Null
}

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
    $destination = Join-Path $DownloadFolder $fileName
    Write-Host "Downloading $fileName..."
    Invoke-WebRequest -Uri $url -OutFile $destination
}

# Run the CMD file as Administrator
$cmdPath = Join-Path $DownloadFolder "Add-Store.cmd"
if (Test-Path $cmdPath) {
    Write-Host "Running Add-Store.cmd as Administrator..."
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$cmdPath`"" -Verb RunAs
} else {
    Write-Host "Add-Store.cmd not found!"
}
