<div align="center">

<img src="assets/Windows-Scripts-Logo.png" alt="Windows Scripts Logo" width="280" />

# Windows Scripts
### Ultimate Windows IT Automation — PowerShell
*Effortless deployment, optimization, and system fixes.*

**Author:** [rhshourav](https://github.com/rhshourav) &nbsp;|&nbsp; **GitHub:** [rhshourav/Windows-Scripts](https://github.com/rhshourav/Windows-Scripts) &nbsp;|&nbsp; **Live:** [itrun.pages.dev](https://itrun.pages.dev)

</div>

---

## ⚡ Quick Start

### One-liner — Run from anywhere

```powershell
irm itrun.pages.dev | iex
```

> Runs the latest interactive menu directly. No install. No setup. Just paste and go.

### Alternative (GitHub Raw)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1')"
```

---

## 📖 Overview

`windowsScripts.ps1` is a centralized **Admin-elevated menu** built for IT professionals and power users. It collapses complex multi-step tasks into single-key commands.

- **Compatibility:** Windows 10 (all builds) & Windows 11
- **Smart Elevation:** Requests UAC once — handles the rest automatically
- **Multi-Tasking:** Launches each tool in its own window so the main menu stays open
- **Zero Install:** Run directly from the cloud via `wsrun.pages.dev` or GitHub Raw

---

## 🛠️ Direct Tool Modules

Run a specific tool immediately — no need to open the main menu.

### 📦 Application & Office Setup

| Tool | Command |
|---|---|
| **App Framework** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1')` |
| **Office 365** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1')` |
| **Office LTSC 2021** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1')` |
| **Microsoft Store (LTSC)** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1')` |
| **Edge Installer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1')` |
| **RICHO Printer Setup** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/aoRICHO.ps1')` |

### 🧹 Uninstaller Tools

| Tool | Command |
|---|---|
| **New Outlook** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1')` |
| **Microsoft Edge** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1')` |

### ⚙️ System Optimization, Maintenance & Updates

| Tool | Command |
|---|---|
| **Windows Tuner** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1')` |
| **Windows Optimizer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1')` |
| **Disable Updates** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1')` |
| **Enable Updates** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1')` |
| **Win 10 → 11 Upgrade** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1')` |
| **Remove Duplicate Files** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1')` |
| **Time / Zone Formatter** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1')` |
| **IP Config Tool** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1')` |

### 🔧 Hardware, Drivers, ERP & Fixes

| Tool | Command |
|---|---|
| **MediCat USB Installer** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/installMUSVB.ps1')` |
| **Disk Manager** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1')` |
| **Extract Drivers** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1')` |
| **Install Extracted Drivers** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1')` |
| **DriverDex (Auto Driver Install)** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex/DriverDex.ps1')` |
| **Auto Driver Deploy** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1')` |
| **ERP Font Install** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1')` |
| **ERP Automate Setup** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1')` |
| **WARDEN [Registry Nexus]** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1')` |
| **Intel Interrupt Fix** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1')` |
| **WPT Interrupt Fix** | `iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1')` |

---

## 🛡️ Security & Best Practices

1. **UAC Elevation** — Scripts require Administrator privileges to modify system settings, registry keys, and install software. Elevation is requested once and scoped to the session.
2. **Execution Policy** — `-ExecutionPolicy Bypass` only affects the current PowerShell session. Your system-wide policy is not changed.
3. **Review Before Running** — Always inspect the raw source on GitHub before executing any script that touches system binaries or configuration.

---

## 📄 License

Licensed under the **MIT License** — free to fork, modify, and distribute.
