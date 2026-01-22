# Windows Scripts

<div align="center">

<img src="assets/Windows-Scripts-Logo.png" alt="Windows Scripts Logo" width="280" />

**Windows automation (PowerShell)**  
Author: **rhshourav**  
GitHub: **https://github.com/rhshourav/Windows-Scripts**

</div>

---

## Overview

`windowsScripts.ps1` is an **admin-elevating PowerShell menu** that launches a set of common Windows IT automation tasks (apps, Office installs, ERP setup, printers, optimization, Windows Update control, and fixes).

Design goals:
- Works on **Windows 10 (older builds) through Windows 11**
- **Elevates once** at start (UAC prompt when needed)
- **Single-key menu** (press `1`, `2`, … `A`, `B`, etc. — no Enter)
- Each action runs in a **new elevated PowerShell window**
- Returns to the menu so you can run **multiple tasks** in one session

---

## Quick start

### Option 1 — One-line run (PowerShell)

Runs the latest menu directly from GitHub:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1')"
```

Notes:
- Expect a **UAC prompt** (this tool needs admin rights).
- `-ExecutionPolicy Bypass` applies only to this process run; it does not permanently change your policy.

### Option 2 — Download and run (recommended): `run.cmd`

1) Download **run.cmd**  
2) Right-click → **Run as administrator** (or double-click and accept UAC)  
3) The launcher downloads `windowsScripts.ps1` to `%TEMP%` and starts it.

---

## One-line commands (direct tools)

If you want to run a specific tool directly (without the menu), use the following **one-line** commands.

### App Setup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1')"
```

### Office

**Office 365 Install**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/office-Install/install-o365.ps1')"
```

**Office LTSC 2021 Install**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/office-Install/install-ltsc2021.ps1')"
```

**Microsoft Store for LTSC**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1')"
```

**New Outlook Uninstaller**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1')"
```

### ERP Auto Setup

**ERP Setup**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1')"
```

**ERP Font Setup**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1')"
```
### Time & IP Setup
**Dhaka Time Zone + Time Sync + Date/Time Format (All Users)**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1')"
```
**IP Config**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1')"
```
### Printer Setup

**RICHO B&W**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1')"
```

**RICHO Color**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addColorRICHO.ps1')"
```

###  Others
**Activation & Edition**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run.ps1')"
```

**Extract Drivers**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1')"
```

**Install Extracted Drivers**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1')"
```

### Windows Optimization

**Windows Tuner**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1')"
```

**Windows Optimizer**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1')"
```

### Windows Update

**Disable Windows Update**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1')"
```

**Enable Windows Update**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1')"
```

**Upgrade Windows 10 to 11**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1')"
```

### Windows System Interrupt Fix

**Intel System Interrupt Fix**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1')"
```

**WPT Interrupt Fix**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1')"
```

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1+ (built-in on Windows 10/11)
- Internet access to `raw.githubusercontent.com`
- Administrator rights (UAC prompt)

---

## Security notes (do not skip)

- Running remote scripts is a trust decision. Use only on machines you control or where you have explicit authorization.
- For production environments, pin to a **specific commit hash** instead of `main` to avoid unexpected upstream changes.
- Consider reviewing the script in a browser before executing in a high-control environment.

---

## License

This project is licensed under the **MIT License**. See [`LICENSE`](LICENSE).

