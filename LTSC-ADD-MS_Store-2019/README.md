
# LTSC Add Microsoft Store Installer

**Author:** rhshourav  
**GitHub:** [https://github.com/rhshourav](https://github.com/rhshourav)  
**Supporting Repo:** [https://github.com/lixuy/LTSC-Add-MicrosoftStore](https://github.com/lixuy/LTSC-Add-MicrosoftStore)

---

## Description

This script automates the installation of Microsoft Store and related apps on Windows LTSC / LTSB editions.  

It downloads all required `.Appx` and `.AppxBundle` files into a temporary folder, runs the installation script (`Add-Store.cmd`) with administrator privileges, and automatically deletes the temporary files after installation.

The script also displays author and repository information at the start of execution.

---

## Features

- Downloads all required Microsoft Store files from GitHub.
- Runs `Add-Store.cmd` as Administrator.
- Installs Microsoft Store, Desktop App Installer, VCLibs, Xbox Identity Provider, and Store Purchase App.
- Automatically deletes temporary installation files after completion.
- Displays author and repo information in CMD/PowerShell.

---

## Requirements

- Windows 10 / 11 LTSC or LTSB edition.
- Administrator privileges.
- Internet connection for downloading files.

---

## Usage
### Try
```
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1 | iex
```
### OR
1. Download `Install-Store.ps1`.
2. Right-click the script → **Run with PowerShell (as Administrator)**.
3. The script will:
   - Display author and repo information.
   - Download all required files to a temporary folder.
   - Run `Add-Store.cmd` with elevated privileges.
   - Delete temporary files after installation.

---

## Notes

- Must run as **Administrator** or installation will fail.
- Internet connection is required.
- Designed for **LTSC / LTSB editions** where Microsoft Store is missing.

---

## License

This project is for **educational purposes**. You may use and modify it for personal or learning purposes. Redistribution without proper credit is discouraged.

---

**Author:** rhshourav  
**GitHub:** [https://github.com/rhshourav](https://github.com/rhshourav)  
**Supporting Repo:** [https://github.com/lixuy/LTSC-Add-MicrosoftStore](https://github.com/lixuy/LTSC-Add-MicrosoftStore)
