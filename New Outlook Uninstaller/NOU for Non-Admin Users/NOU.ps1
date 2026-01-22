# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

$Package = Get-AppxPackage | Where-Object { $_.Name -like "*OutlookForWindows*" }
$PackageFullName = $Package.PackageFullName
Write-Output $PackageFullName
remove-appxpackage $PackageFullName
