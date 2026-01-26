# Developer-Note.md — Rules (Custom Arguments) + Post-Install Hooks

This installer supports two extensibility layers:

1. **Rules** (filename-based matching)

   * Preselect installers automatically
   * Override EXE/MSI arguments (string or array)
   * Optionally bind a remote post-install script URL per installer

2. **Post-install hooks**

   * **Local** post scripts shipped alongside installers
   * **Remote** post scripts fetched from GitHub raw (optional; OFF by default)

This note documents how to add, test, and maintain them safely.

---

## 1) Rules System Overview

Rules are defined in one place:

```powershell
$global:InstallerRules = @( ... )
```

Rules are evaluated against **installer filename** (`$App.Name`), not full path.

### Rule fields

| Field       | Required | Values                      | Notes                                                |
| ----------- | -------- | --------------------------- | ---------------------------------------------------- |
| `Name`      | Yes      | string                      | Used in logs; keep unique and descriptive            |
| `AppliesTo` | Yes      | `Exe`, `Msi`, `Any`         | Limit rule scope                                     |
| `MatchType` | Yes      | `Contains`, `Like`, `Regex` | Choose the simplest that works                       |
| `Match`     | Yes      | string/pattern              | Pattern value                                        |
| `Args`      | No       | string or string[]          | Overrides default args                               |
| `Preselect` | No       | bool                        | Auto-select matching installers                      |
| `PostUrl`   | No       | string                      | Remote post script URL (used only if remote enabled) |

### Precedence: first-match wins

Rules are evaluated **top to bottom**. The first match is applied.

This is the number-one maintenance hazard. Keep **specific rules above general rules**.

---

## 2) Default Execution Behavior (No Rule)

If an installer does not match any rule:

### MSI default

```text
msiexec.exe /i "<msi>" /qn /norestart
```

### EXE default

```text
/S
```

**Reality check:** `/S` is not universal. If you expect automation to be reliable, you must add rules for common EXE vendors.

---

## 3) Adding Custom Arguments (Args)

### Recommended format: args as arrays

Use arrays to avoid quoting problems and make multi-argument switches explicit:

```powershell
Args = @('/ALLUSER','/S','/norestart')
```

### Simple format: args as strings

Use strings only for simple cases:

```powershell
Args = '/ALLUSER /S'
```

If you must use paths with spaces, you must quote inside the string:

```powershell
Args = '/S /D="C:\Program Files\Example App"'
```

### MSI args rules (important)

If you set `Args` for an MSI rule, you are overriding the default MSI handling. In the current implementation:

* MSI with rule args runs: `msiexec.exe <Args>`

So you should provide **complete msiexec arguments**, e.g.:

```powershell
[pscustomobject]@{
  Name      = 'Example MSI with properties'
  AppliesTo = 'Msi'
  MatchType = 'Like'
  Match     = '*example*.msi'
  Args      = @('/i', $App.FullName, '/qn', 'ALLUSERS=1', '/norestart')
  Preselect = $true
}
```

If you do not want to manage MSI full args, do not override MSI args; rely on default and introduce `AppendArgs` only if/when you add that feature.

---

## 4) Rule Design Guidelines (Avoid “rule drift”)

### Prefer stable matching

* Use `Like` for vendor patterns: `*chrome*`, `*vlc*`
* Use `Regex` only when needed (it’s easy to overshoot)
* Avoid `Contains` for very short tokens (e.g., `pro`, `setup`) because it will produce false positives

### Normalize naming in your installer repository

Rules become brittle if filenames vary per version. Best practice is to adopt consistent naming:

* `Chrome_x64_Enterprise.exe`
* `VLC_3.0.20_x64.exe`
* `GreenApp_1.2.3.msi`

If you don’t control naming, your rule maintenance cost will stay high.

### Rule order policy

Keep a dedicated layout:

1. **Company-critical** rules (most specific)
2. Core baseline apps (Chrome, 7-Zip, VLC)
3. Department-specific apps
4. Catch-all / general rules (least specific)

---

## 5) Post-Install Hooks Overview

Post-install hooks run **after** an installer finishes. They are meant for:

* Configuration steps (registry tweaks, file copy, policy import)
* Cleanup (remove desktop icons, remove temp files)
* Validation (check service exists, check version installed)

### Execution criteria

By default, post scripts run only when the installer exit code is `0`.

You can change this behavior with:

* `-RunPostOnFail` (run post scripts even on failure)
* `-SkipPostInstall` (disable all post scripts)

---

## 6) Local Post-Install Scripts

### Naming convention

For installer:

* `GreenAppSetup.exe`

Place post script in the **same folder**:

* `GreenAppSetup.post.ps1` or
* `GreenAppSetup.post.cmd` or
* `GreenAppSetup.post.bat`

### Enable/disable

Local post scripts are controlled by:

* `-EnableLocalPostInstall` (default: enabled in the latest code)
* `-SkipPostInstall` (disables everything)

### When to use local

Use local post scripts when the post-step must travel with the installer content on the share (offline installs, consistent packaging).

---

## 7) Remote Post-Install Scripts (GitHub raw)

Remote post scripts are optional because they materially increase security risk.

### How it works

* You add `PostUrl` to a rule:

  ```powershell
  PostUrl = 'https://raw.githubusercontent.com/.../something.post.ps1'
  ```
* The installer downloads that script to:

  * `%TEMP%\rhshourav\WindowsScripts\PostInstall\...`
* Then executes it

### Remote is OFF by default

To use remote post scripts, the operator must explicitly enable it:

```powershell
.\autoInstallFromLocal.ps1 -EnableRemotePostInstall
```

### Domain allowlist

The script blocks remote URLs not in `TrustedPostDomains` (default contains `raw.githubusercontent.com`).

### Non-negotiable maintenance rule: pin to commit SHA

Do not reference mutable branches like `main` for `PostUrl`.

Correct format:

```powershell
PostUrl = "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/<COMMIT_SHA>/PostInstall/green.post.ps1"
```

If you do not pin, you are accepting supply-chain risk.

---

## 8) Maintenance Workflow (Recommended)

### Step 1 — Add/update installer package

* Place installer in correct share folder
* Ensure filename is stable enough to match

### Step 2 — Validate silent flags manually

Run once on a test VM:

* Verify the installer is truly silent
* Confirm exit code behavior

### Step 3 — Add/update a rule

* Prefer `MatchType='Like'`
* Use `Args` as array
* Decide if `Preselect` should be `$true` (only for baseline apps)

### Step 4 — Add post-install script if needed

Choose one:

* Local: create `InstallerBaseName.post.ps1`
* Remote: commit `PostInstall/*.ps1` and pin `PostUrl` to commit SHA

### Step 5 — Test end-to-end

* Test with network share available
* Test with network share unavailable (local fallback)
* Confirm summary shows correct args and post results
* Review meta logs for correctness

### Step 6 — Promote

* Only after repeatable success in test
* Keep a changelog entry for new rules/post scripts

---

## 9) Operational Guardrails (What to enforce internally)

If you run this in an enterprise setting:

1. **Restrict write access** to installer shares

   * If any user can drop an EXE + `.post.ps1` into the share, you’ve created an easy lateral movement path.

2. Keep remote post disabled for normal operators

   * Only enable it in controlled use cases.

3. Pin to commit SHA for all remote scripts

   * No exceptions.

4. Keep rules small and explicit

   * Your goal is predictable deployment, not clever automation.

---

## 10) Troubleshooting

* Post script not running:

  * Confirm `-SkipPostInstall` is not set
  * Confirm post script name matches `<BaseName>.post.ps1`
  * Confirm `-EnableLocalPostInstall` or `-EnableRemotePostInstall` as applicable

* Remote post blocked:

  * URL host not in `TrustedPostDomains`
  * URL not https
  * Rule has no `PostUrl`

* Wrong rule applies:

  * Rule order issue (first-match wins)
  * Use more specific `Like/Regex`
  * Move the specific rule above the general rule
