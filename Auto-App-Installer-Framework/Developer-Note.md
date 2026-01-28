# Developer Note — Auto App Installer (CLI-only) Framework
**Project:** Windows-Scripts / Auto App Installer  
**Script:** Auto App Installer – CLI Only (v2.2.0+)  
**Author:** rhshourav

This note documents the **rule system**, **custom arguments**, and the **pre/post install hook mechanism** (local + optional remote). It is written for maintainers who will extend or troubleshoot the installer framework.

---

## 1) Core Behavior Summary

### Installer discovery
- Scans the selected source folder for **`.exe` and `.msi`**.
- Uses **recursive scan** (subfolders included) for all sources.
- Sorts by filename for display and planning.

### Installation execution
- Executes **sequentially** (wait for each installer to finish).
- Captures exit codes.
- Logs everything into:
  - Transcript log
  - Meta log (structured markers for troubleshooting)

### Hooks (pre/post)
Each installer can have:
- **Pre-install hook** (runs before installer)
- **Post-install hook** (runs after installer)

Hooks can be:
- **Local**: auto-discovered next to the installer
- **Remote**: rule-based URL (OFF by default)

---

## 2) Rule System (First-Match Wins)

Rules control:
- **Which installers are preselected**
- **Which arguments are used for EXE/MSI**
- **Optional remote hook URLs** (pre/post)

### Rule fields
| Field | Required | Values | Purpose |
|---|---:|---|---|
| `Name` | Yes | string | Label for display/logging |
| `AppliesTo` | Yes | `Exe` / `Msi` / `Any` | Restricts rule to installer type |
| `MatchType` | Yes | `Contains` / `Like` / `Regex` | How filename match is evaluated |
| `Match` | Yes | string | Pattern/keyword/regex |
| `Args` | No | string or string[] | Overrides default install args |
| `Preselect` | No | bool | If true, auto-preselect in CLI |
| `PreUrl` | No | https URL | Remote **pre-install** hook (requires remote enabled) |
| `PostUrl` | No | https URL | Remote **post-install** hook (requires remote enabled) |

### Matching rules
- Matching is done against **`$App.Name`** (filename with extension).
- Rules are evaluated **top-to-bottom**.
- **First match wins** — put specific rules above broad ones.

---

## 3A) Custom Arguments (EXE/MSI)

### Defaults (when no rule overrides)
- **EXE default args:** `@('/S')`
- **MSI default command:** `msiexec.exe` with args `@('/i', <msi>, '/qn', '/norestart')`

### When `Args` is present in a rule
- **EXE:** `Args` becomes the installer `ArgumentList`.
- **MSI:** `Args` is treated as **full** `msiexec.exe` argument list.
  - Example: `@('/i', $App.FullName, '/qn', 'REBOOT=ReallySuppress')`

### Recommended formatting
Use tokenized arrays (string[]) whenever possible:
- Good: `Args = @('/silent','/install')`
- Avoid: `Args = '/silent /install'`  
  (String args can work, but arrays avoid quoting and spacing issues.)
Copy/paste the following into your **Developer Note / README**.

---


## 3B) EXE Watchdog (Anti-“Installer Waits for App to Exit”)

Some EXE installers **spawn the application at the end** (e.g., `Greenshot.exe`) and then **wait for that spawned process to exit** before the installer itself terminates. Because this framework installs sequentially and waits on processes, the main script appears “stuck” until the launched app is closed.

To handle this, the framework supports an **EXE watchdog**: after the installer starts, it can **close/kill specific processes** if they appear, allowing the installer to exit and the framework to continue.

### Watchdog rule fields (EXE only)

Add these optional fields to a matching EXE rule:

| Field                       | Required | Type       | Purpose |
| --------------------------- | -------: | ---------- | ------- |
| `WatchCloseProcesses`       |       No | `string[]` | Process names to close/kill (e.g., `@('Greenshot')`). `.exe` suffix is optional. |
| `WatchCloseAfterSeconds`    |       No | `int`      | Delay (seconds) after installer start before watchdog triggers (e.g., `8`). |
| `WatchCloseIncludeExisting` |       No | `bool`     | If `true`, closes even pre-existing processes with that name (prevents deadlocks). If `false`, only targets processes that were not running before install started. |

### How it behaves

- The installer is started normally (no detaching).
- The framework waits in small intervals.
- After `WatchCloseAfterSeconds`, the framework:
  1. attempts a graceful close (`CloseMainWindow()`)
  2. then force-kills (`Stop-Process -Force`) if still running
- Once the installer exits, the framework proceeds to the next item.

### When to use

Use watchdog only for installers that:
- Launch the main app after install **and**
- Block the installer process from exiting until the app is closed.

### Example: Greenshot

```powershell
[pscustomobject]@{
  Name      = 'Greenshot - silent + watchdog'
  AppliesTo = 'Exe'
  MatchType = 'Contains'
  Match     = 'Greenshot'
  Args      = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/ALLUSERS')

  WatchCloseProcesses       = @('Greenshot')
  WatchCloseAfterSeconds    = 8
  WatchCloseIncludeExisting = $true
}
````

### Notes / cautions

* **Be specific** with matching (`Match='Greenshot'`) so watchdog doesn’t close unrelated apps.
* `WatchCloseIncludeExisting=$true` is the “no surprises” option for stubborn installers, but it will also close a user’s already-running instance.
* If you need to preserve user sessions, set `WatchCloseIncludeExisting=$false` so only newly-started processes are targeted.

````

---

## Update Section 2 “Rule Fields” table (append these rows)

Add these rows to your existing rule fields table:

```md
| `WatchCloseProcesses`       |       No | string[] | EXE watchdog: process names to close/kill if installer blocks |
| `WatchCloseAfterSeconds`    |       No | int      | EXE watchdog: seconds before close/kill triggers              |
| `WatchCloseIncludeExisting` |       No | bool     | EXE watchdog: if true, may close pre-existing processes       |
````

---

## Update Section 7 “Troubleshooting” (add this subsection)

```md
### Problem: installer “hangs” until an app is manually closed

**Symptom:**
- Installer finishes UI/steps, but framework shows “still installing” until you close a launched app.

**Cause:**
- Installer launched the app and is waiting for it to exit.

**Fix:**
1. Add a **specific rule** for the installer (e.g., `Match='Greenshot'`).
2. Set watchdog fields:
   - `WatchCloseProcesses=@('Greenshot')`
   - `WatchCloseAfterSeconds=8`
   - `WatchCloseIncludeExisting=$true` (or `$false` if you want to avoid closing a user’s existing instance)

**Verification:**
- In “Planned Installation” output, you should see:
  - `WatchClose: Greenshot` (or equivalent)
- Meta log should include watchdog markers if you log them (optional enhancement).
```

---

## 4) Local Hook Scripts (Pre/Post)

### Naming convention (strict)
Hooks are discovered by exact filename match based on the installer **BaseName**.

If installer is:
- `AdobeIllustrator2024.exe`  
Then hooks must be:
- `AdobeIllustrator2024.pre.ps1` / `.pre.cmd` / `.pre.bat`
- `AdobeIllustrator2024.post.ps1` / `.post.cmd` / `.post.bat`

**Important:**  
If your hook is called `illustrator.post.cmd` but installer BaseName is `AdobeIllustrator2024`, the hook will **not** run.

### Supported hook types
- PowerShell: `.ps1` (executed via `powershell.exe -ExecutionPolicy Bypass -File`)
- Batch/CMD: `.cmd` / `.bat` (executed via `cmd.exe /c`)

### Pre-install fail behavior
- Default behavior is **safer**:
  - If a pre-hook runs and fails (non-success exit code), the installer is **skipped**
  - Override with `-ContinueOnPreFail`

### Post-install eligibility
- Post hooks run after install success by default.
- “Success” is controlled by `PostSuccessExitCodes` (default: `0,3010,1641`)
  - Many enterprise installers return **3010** (reboot required) but installation succeeded.

---

## 5) Remote Hook Scripts (Pre/Post) — Optional, OFF by Default

Remote hooks are **disabled** unless explicitly enabled:
- `-EnableRemotePreInstall`
- `-EnableRemotePostInstall`

### Trust model
Remote URLs must satisfy:
- HTTPS only
- Domain allow-list via `TrustedHookDomains` (default: `raw.githubusercontent.com`)

If URL domain is not trusted:
- Remote hook is **blocked**
- A warning is displayed
- Meta log records `RemoteBlocked`

### Strong recommendation: pin to commit SHA
If you use GitHub raw URLs, do not use `main` branch for hooks. Pin to a commit SHA:

Bad (mutable):
- `https://raw.githubusercontent.com/<user>/<repo>/main/Hooks/app.post.ps1`

Good (immutable):
- `https://raw.githubusercontent.com/<user>/<repo>/<COMMIT_SHA>/Hooks/app.post.ps1`

This prevents silent drift and supply-chain surprises.

---

## 6) “Planned Installation” Output

The framework prints:
- Installer execution command
- Planned **Pre** and **Post** hooks per installer:
  - Local path if found
  - Remote URL if enabled and trusted
  - “(none)” or “(disabled)” or “BLOCKED (untrusted)”

This is the fastest way to verify hook naming and rule correctness before running.

---

## 7) Common Troubleshooting

### Problem: local post hook did not run
Most common causes:
1) **Name mismatch**: hook file name does not match installer BaseName
2) **Exit code gating**: install returned 3010/1641 and success list didn’t include it
3) Hooks disabled: `-SkipPostInstall` or `-EnableLocalPostInstall:$false`

### How to verify installer BaseName
Run in the installer folder:
```powershell
Get-ChildItem -File | Where-Object Extension -in '.exe','.msi' | Select-Object Name, BaseName
````

### How to confirm hooks were considered

Search meta log:

```powershell
Select-String -Path $env:TEMP\rhshourav\WindowsScripts\AutoAppInstaller\*.meta.log -Pattern 'PreInstall|PostInstall|NoLocalPreFound|NoLocalPostFound|RemoteBlocked'
```

---

## 8) Recommended Repo Layout

Example structure:

```
\\server\it\PC Setup\Auto\Staff pc\
  Adobe\
    AdobeIllustrator2024.exe
    AdobeIllustrator2024.pre.cmd
    AdobeIllustrator2024.post.cmd
  Browsers\
    ChromeSetup.exe
    ChromeSetup.pre.ps1
    ChromeSetup.post.ps1
  Utilities\
    7zip.msi
```

---

## 9) Rule Examples

### Example 1: Preselect + EXE args override

```powershell
[pscustomobject]@{
  Name      = 'Chrome silent'
  AppliesTo = 'Exe'
  MatchType = 'Like'
  Match     = '*chrome*'
  Args      = @('/silent','/install')
  Preselect = $true
}
```

### Example 2: MSI args override

```powershell
[pscustomobject]@{
  Name      = '7-Zip MSI quiet'
  AppliesTo = 'Msi'
  MatchType = 'Like'
  Match     = '*7zip*'
  Args      = @('/i', 'C:\Path\7zip.msi', '/qn', '/norestart')
  Preselect = $true
}
```

### Example 3: Remote hooks (only if explicitly enabled)

```powershell
[pscustomobject]@{
  Name      = 'Illustrator with remote hooks'
  AppliesTo = 'Exe'
  MatchType = 'Contains'
  Match     = 'illustrator'
  PreUrl    = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/<COMMIT_SHA>/Hooks/illustrator.pre.ps1'
  PostUrl   = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/<COMMIT_SHA>/Hooks/illustrator.post.ps1'
}
```

---

## 10) Maintenance Rules (Do This, Not That)

### Do

* Keep rules **minimal and specific**
* Use `string[]` for args
* Pin remote hooks to commit SHAs
* Keep hook scripts idempotent (safe to re-run)
* Write breadcrumbs in hooks when debugging, e.g.:

  * `%TEMP%\app.pre.ran.log`
  * `%TEMP%\app.post.ran.log`

### Don’t

* Don’t enable remote hooks by default
* Don’t use branch-based raw URLs for remote hooks
* Don’t assume success is only exit code 0 (3010/1641 exist)

---

## 11) Hook Exit Codes

### Pre-install success

Controlled by:

* `PreSuccessExitCodes` (default: `0`)

If pre hook returns code not in the list:

* Installer is skipped unless `-ContinueOnPreFail`

### Post-install eligibility

Controlled by:

* `PostSuccessExitCodes` (default: `0,3010,1641`)
* Plus `-RunPostOnFail` to force post even if install failed.

---

## 12) Quick Reference (Parameters)

### Pre-install controls

* `-SkipPreInstall`
* `-EnableLocalPreInstall:$true/$false`
* `-EnableRemotePreInstall` (default OFF)
* `-ContinueOnPreFail` (default OFF)
* `-PreSuccessExitCodes @(0)`

### Post-install controls

* `-SkipPostInstall`
* `-EnableLocalPostInstall:$true/$false`
* `-EnableRemotePostInstall` (default OFF)
* `-RunPostOnFail`
* `-PostSuccessExitCodes @(0,3010,1641)`

### Trust controls

* `-TrustedHookDomains @('raw.githubusercontent.com')`

---

## 13) Versioning Guidance

When you change behavior that affects execution flow:

* Bump patch/minor version
* Add a short changelog note near the top of the script header
* Update this Developer Note if:

  * Rule schema changes
  * Hook naming changes
  * Trust model changes
  * Default exit code logic changes

