# 🤖Oracle Instant Client Installer

A PowerShell script to install **Oracle Instant Client** with automatic COM detection, progress bars, environment variable setup, optional font installation, and admin elevation.  

---

## 💠Features

- **Automatic Administrator Elevation**: Script restarts with admin rights if needed.
- **Oracle Instant Client Installation**: Copies files from a network share to `C:\Program Files\`.
- **COM DLL Detection & Registration**: Detects if `XceedZip.dll` supports COM and registers it automatically.
- **Environment Variable Configuration**: Sets `TNS_ADMIN`, `ORACLE_HOME`, and updates system `PATH`.
- **Progress Indicators**: Shows detailed progress while copying files and DLLs.
- **Optional ERP Font Installation**: Prompts to download and install ERP fonts.
- **Validation & Verification**: Confirms environment variables and PATH entries are correctly configured.
- **Colorful Output**: Highlights steps, warnings, and successes in the console.

---

## 💠Requirements

- Windows OS
- PowerShell 5.1 or higher
- Network access to the Oracle Instant Client source share (e.g., `\\192.168.16.251\erp`)
- Administrator privileges (script auto-elevates if needed)

---

## 💠Usage
### One Line Code for ERP Setup
1. Run `Powershell` as an administrator
2. Run:
```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1 | iex
```
### One line Code for ERP Font Install
1. Run `Powershell` as an administrator
2. Run:
```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1 | iex
```
### One line Code Encode and Decode
1. Run:
```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/edCode.ps1 | iex
```
### Manual Install
1. Download or copy the script to a local folder.
2. Open PowerShell.
3. Run the script:

```powershell
.\OracleInstantClientInstaller.ps1
````

4. Follow prompts for optional font installation.

---

## ⚙️Configuration

The following variables can be adjusted at the top of the script:

```powershell
$EncodedShare = "XFwxOTIuMTY4LjE2LjI1MVxlcnA="    # Network share containing Oracle client
$InstantClientDir = "instantclient_10_2"      # Folder name of Oracle Instant Client
$OracleDir        = "C:\Program Files\$InstantClientDir"  # Installation target path
$SourceDll        = Join-Path $SourceShare "XceedZip.dll" # DLL to copy
$DestDll          = "C:\Windows\XceedZip.dll"             # Destination path for DLL
```

---

## 📝Notes

* **PATH Length Warning**: The script warns if the system PATH exceeds ~1800 characters.
* **Reboot/Logoff Required**: Environment variable changes may require a logoff or restart to take effect.
* **Font Installation**: Downloads and runs a separate script from GitHub.

---

## 🗒️Functions Overview

* `Add-ToSystemPath($Entry)`: Adds a folder to the system PATH.
* `Verify-SystemVariable($Name, $Expected)`: Validates system environment variables.
* `Verify-SystemPath($ExpectedEntry)`: Checks PATH for the required entry.
* `Test-ComDll($DllPath)`: Determines if a DLL supports COM registration.
* Color helpers: `Write-Header`, `Write-Step`, `Write-Success`, `Write-Warn`, `Write-Verify`.

---

## 🦖To-Do / Future Enhancements

* **Encrypt Source Paths**: Encode network share paths and sensitive file locations using **Base64** or another method to avoid exposing them in plain text.
* **Automatic Version Detection**: Detect the latest Oracle Instant Client version available on the share.
* **Error Logging**: Maintain a detailed log file for auditing and troubleshooting.
* **Silent Mode**: Allow the script to run fully unattended with preconfigured options.

---

## License

This script is provided as-is. Use at your own risk.

---

## 😎 Author

rhshourav
Educational scripting & security research


