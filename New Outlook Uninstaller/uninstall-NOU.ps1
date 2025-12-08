# Function to check New Outlook via Registry
function Check-NewOutlook {
    $RegPath = "HKCU:\Software\Microsoft\Office\16.0\Outlook\Setup"
    if (Test-Path $RegPath) {
        Write-Host "New Outlook is detected in Registry."
        return $true
    }
    return $false
}

# Function to uninstall New Outlook via Winget
function Uninstall-WithWinget {
    Write-Host "Trying to uninstall New Outlook using Winget..."
    try {
        winget uninstall --id "Microsoft.OutlookForWindows" --silent --accept-source-agreements
        Write-Host "New Outlook uninstalled successfully via Winget."
        return $true
    }
    catch {
        Write-Host "Winget failed. Trying alternative methods..."
        return $false
    }
}

# Function to uninstall New Outlook via Appx Package
function Uninstall-WithAppx {
    Write-Host "Checking for Appx version of New Outlook..."
    $NewOutlookApp = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*OutlookForWindows*" }
    
    if ($NewOutlookApp) {
        try {
            Write-Host "Uninstalling New Outlook via Appx..."
            Remove-AppxPackage -Package $NewOutlookApp.PackageFullName -AllUsers -ErrorAction Stop
            Write-Host "New Outlook uninstalled successfully via Appx."
            return $true
        }
        catch {
            Write-Host "Failed to remove New Outlook via Appx."
            return $false
        }
    }
    return $false
}

# Function to uninstall New Outlook via MSI (if applicable)
function Uninstall-WithMSI {
    Write-Host "Checking for MSI version of New Outlook..."
    $NewOutlookProduct = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE '%Outlook%'" 
    
    if ($NewOutlookProduct) {
        try {
            Write-Host "Uninstalling New Outlook via MSI..."
            $NewOutlookProduct.Uninstall()
            Write-Host "New Outlook uninstalled successfully via MSI."
            return $true
        }
        catch {
            Write-Host "Failed to remove New Outlook via MSI."
            return $false
        }
    }
    return $false
}

# Function to remove residual files
function Remove-ResidualFiles {
    Write-Host "Removing leftover New Outlook files..."
    Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Outlook" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:APPDATA\Microsoft\Outlook" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Residual files removed successfully."
}

# Main Execution Flow
if (Check-NewOutlook) {
    $wingetSuccess = Uninstall-WithWinget
    $appxSuccess = Uninstall-WithAppx
    $msiSuccess = Uninstall-WithMSI

    if (-not $wingetSuccess -and -not $appxSuccess -and -not $msiSuccess) {
        Write-Host "All uninstallation methods failed. Please remove manually."
    }
    else {
        Remove-ResidualFiles
        Write-Host "✅ New Outlook fully uninstalled."
    }
}
else {
    Write-Host "New Outlook is NOT installed."
}
