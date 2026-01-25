# Windows Photos “Invalid Value for Registry” Fix (Auto Default Apps)

**Part of:** Windows-Scripts  
**Author:** rhshourav  
**Repo:** rhshourav/Windows-Scripts   

This PowerShell script fixes the common Windows Photos error **“Invalid Value for Registry”** and (optionally) re-applies **default app file associations** using a curated XML from this repository. It is designed to run cleanly in automation and supports **auto-elevation**, including when executed via `iex (irm ...)`. 

---

## What it does

### 1) Default app associations (optional)
- Auto-detects OS profile (Windows 10 / Windows 11 / Server variants) and installed apps.
- Downloads the best-matching **Default App Associations XML** from the repo.
- Copies it to `C:\ProgramData\DefaultAppAssociations.xml`.
- Sets policy: `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\DefaultAssociationsConfiguration`.
- Runs `DISM /Online /Import-DefaultAppAssociations` to import the baseline associations.  

### 2) Clears broken per-user associations
- Removes `UserChoice`, `OpenWithList`, and `OpenWithProgids` under:
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts`
- Targets common image extensions like: `.jpg .jpeg .png .bmp .gif .tif .tiff .webp .heic .jfif`.  

### 3) Repairs Microsoft Photos (optional)
- Terminates Photos processes.
- Clears Photos per-user data folders (`LocalState`, `TempState`, `Settings`).
- Re-registers the Photos Appx package for all users (where available).
- Optionally runs `wsreset.exe`.
- Launches Photos once for re-initialization.  

### 4) Auto-elevation
- If not running as admin, it relaunches itself elevated.
- Works both when running from a `.ps1` file and when executed “in-memory” via `iex (irm ...)` (it writes a temporary `.ps1` to `%TEMP%` to elevate safely).  

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Administrator privileges (script will auto-elevate)
- Internet access to download the XML (and optional `.reg`) from the repository  

---

## Quick start

### Run via IEX (recommended for your automation style)

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Photo-Invalid-Reg-Value/winPhotoInvalidRegFix.ps1")
````

### Run locally

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\winPhotoInvalidRegFix.ps1
```

---

## Parameters

| Parameter           |   Type | Default | Description                                                                   |
| ------------------- | -----: | ------: | ----------------------------------------------------------------------------- |
| `-ForceConfig`      | string |    `""` | Force a specific XML filename (must exist in repo folder).                    |
| `-SkipPhotosRepair` | switch |     off | Skips Microsoft Photos repair steps.                                          |
| `-SkipDefaultApps`  | switch |     off | Skips XML/policy/DISM association steps (no default-association enforcement). |
| `-SkipWsReset`      | switch |     off | Skips `wsreset.exe` during Photos repair.                                     |
| `-DeepRepair`       | switch |     off | Runs DISM RestoreHealth + SFC (`/scannow`).                                   |

### Examples

Force a specific association XML:

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Photo-Invalid-Reg-Value/winPhotoInvalidRegFix.ps1") `
  -ForceConfig "Win11_ImageGlass+VLC+NanaZip+Acrobat.xml"
```

Only repair Photos (do not touch default apps policy / associations):

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Photo-Invalid-Reg-Value/winPhotoInvalidRegFix.ps1") `
  -SkipDefaultApps
```

Only apply default app associations (do not repair Photos):

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Photo-Invalid-Reg-Value/winPhotoInvalidRegFix.ps1") `
  -SkipPhotosRepair
```

---

## How config selection works (XML auto-pick)

The script:

1. Detects OS profile: `Win10`, `Win11`, `Win2019`, `Win2022`, `WinServer`  
2. Detects installed apps via paths/uninstall registry checks:

   * ImageGlass, VLC, NanaZip/7-Zip, Adobe Acrobat, Foxit  
3. Builds a preferred XML name:

   * Example: `Win11_ImageGlass+VLC+NanaZip+Acrobat.xml`  
4. Falls back to OS default:

   * Example: `Win11_Multi_Default.xml`  
5. If still not found, uses a “best score” fuzzy match (OS prefix + most tags).  

### Available association files

The **File Associations** folder contains `PhotoViewer.reg` plus multiple OS/app-tag XML variants, including (examples):

* `Win11_ImageGlass+VLC+7zip+Acrobat.xml`
* `Win11_ImageGlass+VLC+NanaZip+Acrobat.xml`
* `Win11_Multi_Default.xml`
* `Win10_PhotoViewer+Foxit.xml`
* `WinServer_PhotoViewer+AdobeAcrobat.xml`

If `PhotoViewer.reg` exists, the script downloads and imports it before applying the XML (useful when XML expects Photo Viewer ProgIDs).  

---

## What changes on the system

### Files

* `C:\ProgramData\DefaultAppAssociations.xml` (copied from downloaded XML)  
* A temp working folder under `%TEMP%` (downloads and staging)  

### Registry

* Sets `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\DefaultAssociationsConfiguration` to the XML path  
* Removes per-user `FileExts` association subkeys for the targeted image extensions  

---

## Notes and expected behavior

* For the **current user**, default apps may not appear “fixed” instantly. The script itself recommends **sign out / sign in** if needed.  
* In shared environments (AVD/FSLogix), enforce the XML via policy and apply at logon (the script prints this guidance).  
* This approach does **not** attempt to forge Windows “UserChoice hash” values. It removes broken user choices and applies an admin baseline via policy/DISM.  

---

## Troubleshooting

* **Script can’t find a suitable XML**

  * Add a fallback like `Win11_Multi_Default.xml` (or the matching OS prefix) to the repo’s File Associations folder.  
  * Or run with `-ForceConfig "<exact filename>.xml"`.

* **Photos is missing on Server / debloated images**

  * The script will skip re-register if the package isn’t present.  

* **Corporate policy overrides**

  * If your domain/MDM enforces Default Apps, it may overwrite or block changes after reboot/logon.

---

## Source

* Script: `Windows-Photo-Invalid-Reg-Value/winPhotoInvalidRegFix.ps1`  
* Association assets: `Windows-Photo-Invalid-Reg-Value/File Associations/*` 
