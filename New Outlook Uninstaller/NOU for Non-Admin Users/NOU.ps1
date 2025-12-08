$Package = Get-AppxPackage | Where-Object { $_.Name -like "*OutlookForWindows*" }
$PackageFullName = $Package.PackageFullName
Write-Output $PackageFullName
remove-appxpackage $PackageFullName
