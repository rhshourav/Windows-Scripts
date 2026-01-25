# MicroSoft-Edge (Windows-Scripts)

**Author:** Shourav  
**GitHub:** rhshourav/Windows-Scripts  
**Module:** `MicroSoft-Edge`  
**Purpose:** Non-interactive Microsoft Edge **install** and **uninstall** scripts for Windows 10 (19H1/1903) through Windows 11.

---

## What’s Included

### 1) Edge Uninstall (best-effort)
- Tries to remove Microsoft Edge using supported uninstall paths.
- May disable Edge update components depending on script options/menu.
- **Reality check:** On some Windows builds, Edge can be **retained/restored** by servicing/updates.

Script:
- `edge-Uninstall.ps1`  
  `https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1`

### 2) Edge Install (silent, no GUI)
- Downloads Microsoft Edge (Enterprise MSI) and installs silently (`msiexec /qn`).
- Shows a progress bar (download + install).
- **WebView2 is not targeted** unless your script explicitly adds it.

Script:
- `installEdge.ps1`  
  `https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1`

---

## Requirements

- Windows 10 **1903 (19H1)** or later, including Windows 11
- PowerShell **5.1+**
- Admin rights (scripts should self-elevate, but UAC must be allowed)
- Internet access to GitHub raw and Microsoft download endpoints

---

## Quick Run (IRM | IEX)

### Install Edge (silent)
Run in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1' | iex"
````

### Uninstall Edge (best-effort)

Run in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1' | iex"
```

---

## Recommended: Inspect Before Execute (Safer)

If you’re going to use `irm | iex`, you should at least inspect the script first:

### View in console

```powershell
irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1'
```

### Save locally then run

```powershell
$u='https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1'
$fp="$env:TEMP\installEdge.ps1"
irm $u -OutFile $fp
powershell -NoProfile -ExecutionPolicy Bypass -File $fp
```

---

## Notes / Known Behavior

* **Edge may come back** after Windows Feature Updates or servicing on some systems.
* If the endpoint is managed (GPO/Intune/MDM), policy can block removal or force reinstall.
* If downloads fail, verify:

  * TLS 1.2 availability (older environments)
  * proxy inspection/SSL interception rules
  * outbound access to GitHub raw and Microsoft download hosts

---

## Disclaimer

These scripts modify browser components and may affect enterprise baselines. Use in controlled environments, test on a pilot group first, and keep a rollback plan.
