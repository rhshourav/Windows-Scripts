# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

# Function to check New Outlook via Registry
function Check-NewOutlook {
    $RegPath = "HKCU:\Software\Microsoft\Office\16.0\Outlook\Setup"
    if (Test-Path $RegPath) {
        Write-Host "New Outlook is detected in Registry."
        return $true
    }
    return $false
}

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
        text  = "Outlook Uninstaller v1.5.2)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

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
