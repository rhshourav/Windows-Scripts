# Auto App Installer (CLI-only) — by rhshourav

A hardened, **CLI-only** PowerShell auto-installer for Windows 10/11.

## Key Features

* **Auto-elevates to Administrator** (PowerShell 5.1-safe, relaunches itself using `-EncodedCommand`)
* “GUI-style” CLI UX: headers, colors, progress bars
* Works with **UNC/network shares** and local fallback directory
* **Select installation source** (Staff/Production shares), then performs **recursive scan**
* Detects and lists **`.exe` and `.msi`**
* CLI selection with numbers/ranges and helper commands (`all/none/filter/show/back/done`)
* Requires **explicit user confirmation** before installing
* Optional `-ConfirmEach` to confirm before every installer
* Sequential installs (`Start-Process -Wait`) with **exit code capture**
* Robust logs:

  * Transcript log
  * Meta log (structured INFO/WARN/ERROR/OK lines)
* If no network shares are reachable:

  * 30s graceful fallback countdown (progress bar)
  * Uses local fallback directory if present
  * Optionally downloads a framework script to TEMP **for manual review** (not executed automatically)

---

## Requirements

* Windows **10 or 11**
* PowerShell **5.1+**
* Must be run elevated (script will auto-elevate)

---

## Quick Run (IEX + IRM)

> **Security warning:** `iex (irm ...)` executes remote code directly in memory. This is convenient but not a safe default for production environments. Prefer “Safer Run” below.

Run in PowerShell:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1")
```

### With parameters

If your script is a standalone `.ps1` with parameters, **IEX is not the right tool** for reliable parameter passing. Use “Safer Run” to pass parameters normally.

---

## Safer Run (Recommended)

Download to disk, review, optionally verify integrity, then execute:

```powershell
$u   = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1"
$dst = "$env:TEMP\auto_app_installer.ps1"

irm $u -OutFile $dst

# Optional integrity check
Get-FileHash $dst -Algorithm SHA256

# Run (elevated)
powershell -NoProfile -ExecutionPolicy Bypass -File $dst
```

### Best practice: pin to a commit SHA

Do **not** run mutable branch URLs (like `main`) in production automation. Pin to a commit so the code cannot change unexpectedly.

Example format:

```powershell
$u = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/<COMMIT_SHA>/Auto-App-Installer-Framework/autoInstallFromLocal.ps1"
```

---

## What It Does (High-Level Flow)

1. **Self-check**

   * Verifies Windows 10/11
   * Verifies PowerShell version
2. **Elevates to Admin** if required

   * Relaunches itself with the same working directory and forwarded parameters
3. **Selects an installation source**

   * Shows reachable sources and lets you choose
4. **Enumerates installers (recursive)**

   * Finds `*.exe` and `*.msi` under the selected path
5. **CLI selection**

   * Supports: `all`, `none`, `1,3,5`, `1-4,8`, `filter <text>`, `show`, `back`, `done`
6. **Explicit permission gate**

   * Prompts once before starting installation
   * Optional: `-ConfirmEach` prompts per installer
7. **Installs sequentially**

   * Waits each installer
   * Captures exit codes
8. **Writes logs**

   * Transcript + meta log under `%TEMP%`

---

## Installation Sources (UNC Shares)

The script checks these locations and lists whichever are reachable:

* `\\192.168.18.201\it\Antivirus\Sentinel`
* `\\192.168.18.201\it\PC Setup\Staff pc`
* `\\192.168.18.201\it\PC Setup\Production pc`
* `\\192.168.19.44\it\PC Setup\Production pc`
* `\\192.168.19.44\it\PC Setup\Staff pc`

If none are reachable:

* Displays a **30-second** fallback countdown (progress bar)
* Falls back to: `.\Installers` (by default) or your custom `-LocalFallbackDir`
* If local fallback is also missing, optionally downloads the framework script to TEMP for manual review

---

## Installer Execution Logic

### MSI

Runs via:

```text
msiexec.exe /i "<path>.msi" /qn /norestart
```

### EXE

Default best-effort silent switch:

```text
/S
```

> EXE silent switches are not universal. If you want reliable automation, maintain a per-installer argument mapping/ruleset based on your actual packages.

---

## CLI Commands

Inside the selection prompt:

* `all` — select all installers
* `none` — clear selection
* `1,3,5` — select specific numbers
* `1-4,8,10-12` — select ranges
* `filter <text>` — show matching entries (does not auto-select)
* `show` — print full list again
* `back` — return to source selection
* `done` — finalize selection

---

## Parameters

### `-ConfirmEach`

Ask for confirmation before each selected installer:

```powershell
.\autoInstallFromLocal.ps1 -ConfirmEach
```

### `-LocalFallbackDir`

Override the fallback folder used when network shares are unavailable:

```powershell
.\autoInstallFromLocal.ps1 -LocalFallbackDir "C:\Installers"
```

### `-FrameworkUrl`

URL used only when no network share and no local fallback are available (download is optional and not auto-executed):

```powershell
.\autoInstallFromLocal.ps1 -FrameworkUrl "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/auto.ps1"
```

---

## Logs

Logs are written to:

* Transcript log:

  * `%TEMP%\rhshourav\WindowsScripts\AutoAppInstaller\AppInstall_YYYYMMDD_HHMMSS.log`
* Meta log:

  * `%TEMP%\rhshourav\WindowsScripts\AutoAppInstaller\AppInstall_YYYYMMDD_HHMMSS.meta.log`

The meta log includes structured entries like:

* Host/User/PSVersion
* Selected source path
* Install command lines
* Exit codes and failures

---

## Troubleshooting

* **No installers found**

  * Verify the selected share path contains `.exe` or `.msi` files
  * Confirm permissions to the UNC path
* **Installer prompts or hangs**

  * The EXE likely does not support `/S`
  * Add correct silent switches for that installer (rules/mapping)
* **Elevation relaunch issues**

  * Confirm your endpoint allows `Start-Process -Verb RunAs`
  * Ensure the script is being run from a file path (not pasted into console)

---

## Security Notes

* Avoid running mutable remote code with `iex (irm ...)` outside of testing.
* Pin to a commit SHA and/or verify hashes when distributing internally.
* Treat installer shares as sensitive: access control and integrity matter as much as the script.

---

## Ownership

Author: **rhshourav**
Intended use: internal Windows 10/11 endpoint automation.
