# Auto App Installer (CLI-only) — by rhshourav

A hardened, **CLI-only** PowerShell auto-installer for Windows 10/11 that:
- Auto-elevates to Admin
- Uses a “GUI-style” CLI UX (colors, headers, progress bars)
- Resolves **Staff / Production** network share locations
- Enumerates and installs **.exe** and **.msi**
- Runs installers **sequentially** (waits for each to exit)
- Requires **explicit user permission** before installing
- Creates robust logs (Transcript + meta log)
- Provides a **30s graceful fallback** with progress bar
- Designed to be expandable and self-checking

---

## Quick Run (IEX + IRM)

> **Warning:** `iex (irm ...)` executes remote code directly in memory. This is convenient but **not a secure default**. Use the “Safer Run” method below for production where integrity matters.

Run in an **elevated PowerShell** (Run as Administrator):


```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1")
````

### With parameters (example)

If your hosted script supports parameters, pass them after the expression is loaded:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
$script = irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/auto.ps1"
iex $script
# Then run the entry script/function if your framework defines one, or re-run with parameters if implemented as a script.
```

> If your raw script is a standalone `.ps1` that accepts parameters, prefer the “Safer Run” approach which supports normal parameter passing reliably.

---

## Safer Run (Recommended)

Download to disk, review, optionally verify hash/signature, then execute:

```powershell
$u = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Auto-App-Installer-Framework/auto.ps1"
$dst = "$env:TEMP\auto_app_installer.ps1"

irm $u -OutFile $dst

# Optional: verify integrity (recommended)
Get-FileHash $dst -Algorithm SHA256

# Run (elevated)
powershell -NoProfile -ExecutionPolicy Bypass -File $dst
```

### Best practice: Pin to a commit (strongly recommended)

Avoid “moving target” URLs by pinning to a specific commit hash:

```powershell
$u = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/<COMMIT_SHA>/Auto-App-Installer-Framework/auto.ps1"
```

---

## What it does (high-level flow)

1. **Elevates to Admin** if required (relaunches self with `runas`)
2. Locates the first reachable network share from:

   * `\\192.168.18.201\it\PC Setup\Staff pc`
   * `\\192.168.18.201\it\PC Setup\Production pc`
   * `\\192.168.19.44\it\PC Setup\Production pc`
   * `\\192.168.19.44\it\PC Setup\Staff pc`
3. Enumerates installers:

   * `*.msi` (runs via `msiexec /i ... /qn /norestart`)
   * `*.exe` (default silent `/S` unless overridden by mapping)
4. CLI selection (no GUI):

   * supports `all`, `none`, `1,3,5`, `1-4,8`, `filter <text>`, `show`, `done`
5. Requests explicit **permission to proceed**
6. Installs sequentially, captures **exit codes**, logs results
7. Writes logs to:

   * Transcript log: `%TEMP%\rhshourav\WindowsScripts\AutoAppInstaller\*.log`
   * Meta log: `%TEMP%\rhshourav\WindowsScripts\AutoAppInstaller\*.meta.log`

---

## CLI Usage Notes

### Confirm each installer (optional)

If enabled, you will be asked before *each* selected installer:

```powershell
.\auto.ps1 -ConfirmEach
```

### Local fallback installers folder (optional)

If network shares are unavailable, the script can fall back to a local folder (default: `.\Installers` relative to script):

```powershell
.\auto.ps1 -LocalFallbackDir "C:\Installers"
```

---

## Important Operational Notes

### EXE silent switches are not universal

The default `"/S"` will not work for every vendor. For reliable automation, maintain a filename-to-arguments map in the script (e.g. `knownExeArgs`) with **validated** silent switches per installer.

### Avoid executing mutable “main” branch URLs in production

If you use `iex (irm ...)`, at minimum pin to a commit SHA and/or verify hashes out-of-band. Otherwise you are trusting that the remote content will never change and cannot be tampered with.

---

## Troubleshooting

* **“String is missing the terminator”**: your editor likely injected smart quotes. Use PowerShell ISE or VS Code and ensure plain ASCII quotes.
* **No installers found**: verify the share path is reachable and contains `.exe` or `.msi`.
* **Installer hangs**: the EXE likely needs different silent flags. Add it to the per-installer mapping.

---

## License / Ownership

Author: **rhshourav**
Intended use: internal IT automation for Windows 10/11 endpoints.

If you want this README to match your exact repo structure, replace the raw URL(s) above with your actual script path(s) in GitHub.

