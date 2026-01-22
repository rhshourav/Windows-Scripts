<h1 align="center">Driver Extractor + Driver Installer (Windows Scripts)</h1>

<p align="center">
  Two hardened PowerShell scripts for driver workflow:
  <b>Extract</b> driver packages from system drives into a centralized repository, then <b>Install</b> drivers from extracted INF files using <code>pnputil</code>.
</p>

---

## What’s included

### 1) Driver Extractor (`dExtractor.ps1`)
Scans system-wide local drives and extracts driver packages into a single output folder.

**Key capabilities**
- Scans **local drives** automatically (Fixed + Removable)
- Finds common driver package formats:
  - `.zip`, `.cab`, `.msi`, `.exe`
  - plus archive formats if 7-Zip is available (e.g., `.7z`, `.rar`, `.tar`, `.gz`, `.iso`, etc.)
- Extracts to default output:
  - `C:\Extracted-DRivers`
- Supports optional custom output folder
- Uses a themed ASCII UI + progress bar
- Best-effort support for vendor EXE packages (7-Zip first, then common switches)
- Reports INF counts found per extracted package (useful to verify real driver content)

**Output structure (typical)**
- `C:\Extracted-DRivers\Extracted\<DriveLetter>\...`  
  (Each package gets its own timestamped folder; source package can be copied into `_source`.)

---

### 2) Driver Installer (`dInstaller.ps1`)
Installs drivers from extracted `.inf` files using `pnputil`.

**Key capabilities**
- Default driver repository root:
  - `C:\Extracted-DRivers\Extracted`
- Scans recursively for `.inf`
- Installs using:
  - `pnputil /add-driver "<inf>" /install`
- Themed ASCII UI + progress bar
- Logs success/failure to a timestamped folder
- Supports **Dry Run** mode to preview without changes

**Important reality checks**
- Some drivers will fail due to:
  - unsigned driver policy / signature enforcement
  - incompatible hardware
  - vendor installers requiring full setup apps/services
- This is normal. The script logs the failures with details.

---

## One-line execution (Run as Administrator)

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

* Run the extractor to centralize all driver packages and unpack them into the repository.

2. **Install next**

* Run the installer to add/install drivers from extracted INF files.

---

## Requirements

* Windows 10 / Windows 11
* PowerShell 5.1+ (default Windows PowerShell)
* Administrator privileges (both scripts auto-elevate)
* Optional but recommended: **7-Zip**

  * Improves extraction success for many vendor packages and archive formats
  * Extractor can optionally attempt installation via `winget` if available

---

## Safety notes

* Driver installation changes system state. Use on controlled systems and ideally create a restore point / backup strategy.
* Scanning entire drives can be time-consuming; the extractor uses exclusions to avoid obvious system noise, but it can still take time depending on storage size.

---

## Author

**Shourav (rhshourav)**
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)

