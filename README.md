<div align="center">

<img src="assets/Windows-Scripts-Logo.png" alt="Windows Scripts Logo" width="280" />

### **Ultimate Windows IT Automation (PowerShell)** *Effortless deployment, optimization, and system fixes.*

Author: **rhshourav** | GitHub: [rhshourav/Windows-Scripts](https://github.com/rhshourav/Windows-Scripts)

</div>

---

## 📖 Overview

`windowsScripts.ps1` is a centralized **Admin-elevated menu** designed for IT professionals and power users. It simplifies complex tasks into single-key commands.

* **Compatibility:** Windows 10 (all builds) & Windows 11.
* **Smart Elevation:** Requests UAC once and handles the rest.
* **Multi-Tasking:** Launches tools in new windows so the main menu stays open.
* **Zero Install:** Run everything directly from the cloud or via a local tiny launcher.

---

## ⚡ Quick Start

### The All-in-One Menu (Recommended)

Run the latest interactive menu directly from GitHub:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1')"

```

---

## 🛠️ Direct Tool Modules (One-Liners)

Use these commands to run a specific tool immediately without opening the main menu.

### 📦 Application & Office Setup

| Tool | PowerShell Command |
| --- | --- |
| **App Framework** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1')` |
| **Office 365** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/office-Install/install-o365.ps1')` |
| **Office LTSC 2021** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/office-Install/install-ltsc2021.ps1')` |
| **Microsoft Store** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1')` |
| **Edge Installer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1')` |

### 🧹 Uninstaller Tools

| Tool | PowerShell Command |
| --- | --- |
| **New Outlook** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1')` |
| **Microsoft Edge** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1')` |

### ⚙️ System Optimization & Updates

| Tool | PowerShell Command |
| --- | --- |
| **Windows Tuner** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1')` |
| **Win Optimizer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1')` |
| **Disable Updates** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1')` |
| **Win 10 to 11** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1')` |

### 🔧 Hardware, Printers & Fixes

| Tool | PowerShell Command |
| --- | --- |
| **MediCat USB** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/Run-MediCat.ps1')` |
| **Auto Driver Installer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1')` |
| **Extract Drivers** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1')` |
| **WARDEN[Registry Nexus]** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1')` |
| **IP Config** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1')` |
| **Richo B&W** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1')` |
| **Interrupt Fix** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1')` |

---

## 🛡️ Security & Best Practices

1. **UAC Elevation:** These scripts require Administrative privileges to modify system settings, registry keys, and install software.
2. **Execution Policy:** Using `-ExecutionPolicy Bypass` only affects the current session and does not lower your system's global security posture.
3. **Review Code:** It is always recommended to review the raw code on GitHub before running any script that interacts with system binaries.

## 📄 License

This project is licensed under the **MIT License**. Feel free to fork, modify, and distribute.
