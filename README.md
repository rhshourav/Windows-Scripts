<div align="center">

<img src="assets/Windows-Scripts-Logo.png" alt="Windows Scripts Logo" width="280" />

### **Ultimate Windows IT Automation (PowerShell)** *Effortless deployment, optimization, and system fixes.*

Author: **rhshourav** | GitHub: [rhshourav/Windows-Scripts](https://github.com/rhshourav/Windows-Scripts)

</div>

---

## 📖 Overview

`windowsScripts.ps1` is a centralized **Admin-elevated menu** designed for IT professionals and power users. It simplifies complex tasks into single-key commands.[web:10]

* **Compatibility:** Windows 10 (all builds) & Windows 11.[web:10]
* **Smart Elevation:** Requests UAC once and handles the rest.
* **Multi-Tasking:** Launches tools in new windows so the main menu stays open.
* **Zero Install:** Run everything directly from the cloud or via a local tiny launcher.

---

## ⚡ Quick Start

### The All-in-One Menu (Recommended)

Run the latest interactive menu directly from GitHub:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://tinyurl.com/Win-Scripts')"
```

or:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1')"
```

---

## 🛠️ Direct Tool Modules (One-Liners)

Use these commands to run a specific tool immediately without opening the main menu.[web:10]

### 📦 Application & Office Setup

| Tool | PowerShell Command |
| --- | --- |
| **App Framework** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1')` |
| **Office 365** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1')` |
| **Office LTSC 2021** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1')` |
| **Microsoft Store (LTSC)** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1')` |
| **Edge Installer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1')` |
| **RICHO Printer Setup** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/aoRICHO.ps1')` |

### 🧹 Uninstaller Tools

| Tool | PowerShell Command |
| --- | --- |
| **New Outlook** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1')` |
| **Microsoft Edge** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1')` |

### ⚙️ System Optimization, Maintenance & Updates

| Tool | PowerShell Command |
| --- | --- |
| **Windows Tuner** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1')` |
| **Windows Optimizer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1')` |
| **Disable Updates** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1')` |
| **Enable Updates** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1')` |
| **Win 10 to 11 Upgrade** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1')` |
| **Remove Duplicate Files (DupReaper)** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1')` |
| **Time / Zone Formatter** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1')` |
| **IP Config Tool** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1')` |

### 🔧 Hardware, Drivers, ERP & Fixes

| Tool | PowerShell Command |
| --- | --- |
| **MediCat USB Installer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/installMUSVB.ps1')` |
| **Disk Manager** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1')` |
| **Extract Drivers** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1')` |
| **Install Extracted Drivers** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1')` |
| **Auto Driver Deploy** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1')` |
| **ERP Font Install** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1')` |
| **ERP Automate Setup** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1')` |
| **WARDEN [Registry Nexus]** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1')` |
| **Intel Interrupt Fix** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1')` |
| **WPT Interrupt Fix** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1')` |

---

## 🛡️ Security & Best Practices

1. **UAC Elevation:** These scripts require Administrative privileges to modify system settings, registry keys, and install software.[web:24]
2. **Execution Policy:** Using `-ExecutionPolicy Bypass` only affects the current session and does not permanently weaken your system’s policy.[web:24]
3. **Review Code:** Always review the raw code on GitHub before running any script that interacts with system binaries or configuration.[web:13]

## 📄 License

This project is licensed under the **MIT License**. Feel free to fork, modify, and distribute.[web:10]
