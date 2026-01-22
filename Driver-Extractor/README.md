<h1 align="center">Driver Extractor + Driver Installer (Windows Scripts)</h1>

<p align="center">
  Two hardened PowerShell scripts for driver workflow:
  <b>Extract</b> driver packages from selected system drives into a centralized repository, then <b>Install</b> drivers from extracted INF files using <code>pnputil</code>.
</p>

---

## Overview

This repository contains two CLI-first PowerShell scripts:

1) **Driver Extractor (`dExtractor.ps1`)**  
   Scans one or more local drives (Fixed/Removable) for driver packages and extracts them into a structured output repository.

2) **Driver Installer (`dInstaller.ps1`)**  
   Recursively scans extracted folders for `.inf` files and installs drivers via `pnputil`.

Both scripts are **Administrator-only** and **auto-elevate** when run non-admin.

---

## What’s included

### 1) Driver Extractor (`dExtractor.ps1`)

Scans selected local drives and extracts driver packages into a centralized output folder.

**Key capabilities**
- Detects **local drives** automatically (**Fixed + Removable**).
- **Drive selection (multi-select)**:
  - Choose drives by **number or letter**, e.g. `1,3` or `C,D` or `1,D`
  - Press **Enter** to select **ALL**.
  - Type `Q` to cancel.
- Searches for common driver package formats:
  - `.zip`, `.cab`, `.msi`, `.exe`
  - plus additional archive formats when **7-Zip** is present (e.g., `.7z`, `.rar`, `.tar`, `.gz`, `.iso`, `.wim`, `.esd`, etc.)
- Extracts to default output:
  - `C:\Extracted-DRivers`
- Optional custom output folder prompt.
- Themed ASCII UI + progress indicators.
- Best-effort support for vendor `.exe` packages:
  - 7-Zip extraction first, then common silent extraction switches.
- Reports **INF counts** per extracted package (sanity check that it contains actual driver content).
- Writes a scan manifest + summary logs.

**Output structure**
- Root output:  
  `C:\Extracted-DRivers`
- Extracted packages:  
  `C:\Extracted-DRivers\Extracted\<DriveLetter>\PackageName_yyyyMMdd-HHmmss\`
- Optional source copy inside each package folder:  
  `...\_source\original_package.ext`
- Logs:  
  `C:\Extracted-DRivers\Logs\yyyyMMdd-HHmmss\`

**Notes / exclusions**
The extractor uses directory exclusions to avoid noise and protected trees (e.g., `\Windows\`, `\Program Files\`, `\ProgramData\`, etc.).  
By default, it **does not scan `\Users\`** because it is usually large and low-signal. If you need user downloads/desktops, toggle `$IncludeUsersTree = $true` in the script.

---

### 2) Driver Installer (`dInstaller.ps1`)

Installs drivers from extracted `.inf` files using `pnputil`.

**Key capabilities**
- Default repository root:
  - `C:\Extracted-DRivers\Extracted`
- Recursively finds `.inf` files.
- Installs with:
  - `pnputil /add-driver "<inf>" /install`
- Themed ASCII UI + progress indicators.
- Logs success/failure to a timestamped folder.
- Supports **Dry Run** mode to preview actions without changes.

**Important reality checks**
Driver installs can fail for normal reasons, including:
- signature enforcement / unsigned drivers
- device/hardware mismatch
- vendor drivers that require full installers/services (not pure INF)
- Windows blocks for older/incompatible packages

Failures are logged with details. This is expected behavior on mixed driver sets.

---

## One-line execution (Run as Administrator)

PowerShell will download and execute remote code. Only do this if you trust the source and understand the risk.

### Driver Extractor
```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1")
````

### Driver Installer

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1")
```

---

## Recommended workflow

1. **Extract first**

* Run `dExtractor.ps1`
* Select the drive(s) you want scanned
* Confirm extraction after scan results

2. **Install next**

* Run `dInstaller.ps1`
* (Optional) Dry Run first
* Then install drivers from `.inf` files

---

## Requirements

* Windows 10 / Windows 11
* PowerShell 5.1+ (Windows PowerShell)
* Administrator privileges (auto-elevate)
* `pnputil` (built-in on Windows)
* Optional but recommended: **7-Zip**

  * Improves extraction success for vendor packages and non-zip archives
  * Extractor can optionally attempt installation via `winget` if available

---

## Safety notes

* Driver installation changes system state. Use on controlled systems. Consider a restore point / backup strategy.
* Scanning full drives can be time-consuming depending on storage size and number of files.
* Remote execution (`iex (irm ...)`) is inherently risky. For safer usage:

  * download the scripts, review them, then run locally.

---

## Author

**Shourav (rhshourav)**
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)
