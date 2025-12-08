# 🚀 New Outlook Uninstaller (NOU)

## 📝 Overview
This script automatically detects and **uninstalls New Outlook** on system startup. If "New Outlook" is installed, it will be removed **silently** without user intervention.

## ⚙️ How It Works
1. The script **checks** if New Outlook is installed via Registry, Appx, or MSI.
2. If found, it **uninstalls** it using **Winget, Appx, and MSI methods**.
3. It also **removes residual files** to prevent reinstallation.
4. It runs **automatically on startup** via Task Scheduler or the Startup folder.

---

## 🔧 Installation & Setup

## ⚙️ Installation:
- Onlne One Liner.
```
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1 | iex
```
- Offline.
✅ **Step 1: Download the Script**
Save the following **PowerShell script** as `uninstall_nou.ps1`.

```powershell
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
```

---

## 🖥️ **Step 2: Set Up the Script to Run on Startup**

### 📌 **Method 1: Task Scheduler (Recommended)**
1. Press **`Win + R`**, type `taskschd.msc`, and hit **Enter**.
2. Click **Create Task** on the right panel.
3. Under **General**, name it **"Remove New Outlook"**.
4. Check **"Run with highest privileges"**.
5. Go to **Triggers > New > At Startup**.
6. Go to **Actions > New > Start a Program**.
   - **Program/Script**: `powershell.exe`
   - **Arguments**:
     ```sh
     -ExecutionPolicy Bypass -File "C:\Path\To\uninstall_nou.ps1"
     ```
7. Click **OK**, then restart your PC to test.

### 📌 **Method 2: Add to Startup Folder (Alternative)**
1. Press **Win + R**, type:
   ```sh
   shell:startup
   ```
   and hit **Enter**.
2. Copy and paste `uninstall_nou.ps1` into this folder.
3. Restart your PC to check if the script runs automatically.

---

## ⚠️ Notes
- **Requires Winget** for automatic uninstallation.
- If Winget is unavailable, the script will attempt a **PowerShell-based removal**.
- Run PowerShell as **Administrator** if needed.
- Update the script if Microsoft changes New Outlook’s package name.

---

## 🤝 Contribute
Want to improve this script? Feel free to submit a **pull request** or suggest changes!

---

## 📜 License
This project is licensed under the **MIT License**.
