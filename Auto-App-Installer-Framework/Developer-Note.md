# Developer-Note.md — Custom Arguments (Rules System)

This project supports an **installer rules system** to make deployments repeatable without manually selecting apps or typing vendor-specific silent switches.

Rules let you:

* **Preselect** installers automatically (based on filename matching)
* **Override/define arguments** per installer (EXE/MSI)
* Keep a safe default behavior when no rule exists

---

## 1) Where to configure rules

Rules are defined in the **Rule Configuration** section:

```powershell
$global:InstallerRules = @(
  [pscustomobject]@{
    Name      = 'Green apps: all users'
    AppliesTo = 'Exe'
    MatchType = 'Contains'
    Match     = 'green'
    Args      = '/ALLUSER'
    Preselect = $true
  }
)
```

This is intentionally simple so you can expand it over time.

---

## 2) Rule fields (meaning)

Each rule is a `pscustomobject` with these fields:

| Field       | Required | Values                      | Purpose                                    |
| ----------- | -------- | --------------------------- | ------------------------------------------ |
| `Name`      | Yes      | Any string                  | Label used for logging and troubleshooting |
| `AppliesTo` | Yes      | `Exe`, `Msi`, `Any`         | Limits rule to EXE/MSI or both             |
| `MatchType` | Yes      | `Contains`, `Like`, `Regex` | Matching strategy against the filename     |
| `Match`     | Yes      | Text/pattern                | Pattern value for match                    |
| `Args`      | No       | String or string array      | Arguments to use instead of defaults       |
| `Preselect` | No       | `$true/$false`              | If true, app is auto-selected in CLI       |

---

## 3) Matching behavior

Rules match against the **installer filename** (`$App.Name`) — not the full path.

Matching is evaluated as:

* `Contains`: case-insensitive substring match
* `Like`: PowerShell wildcard match (e.g. `*chrome*`)
* `Regex`: regular expression match

### First-match wins

Rules are evaluated in order. The **first matching rule** is used.

That means: put more specific rules **above** more general rules.

Example:

```powershell
$global:InstallerRules = @(
  # Specific first
  [pscustomobject]@{ Name='Green MSI special'; AppliesTo='Msi'; MatchType='Regex'; Match='^GreenApp.*\.msi$'; Args='/i "X" /qn'; Preselect=$true },
  # General later
  [pscustomobject]@{ Name='Any green'; AppliesTo='Any'; MatchType='Contains'; Match='green'; Args='/ALLUSER'; Preselect=$true }
)
```

---

## 4) Default behavior when no rule exists

If no rule matches:

### MSI (default)

```text
msiexec.exe /i "<msiPath>" /qn /norestart
```

### EXE (default)

```text
/S
```

**Important:** Many EXE installers do not support `/S`. You should add rules for your known packages to avoid hangs or interactive prompts.

---

## 5) Custom arguments: string vs array

### A) String args (simplest)

Use a single string when arguments are straightforward:

```powershell
Args = '/ALLUSER /S /norestart'
```

If an argument includes spaces, quote it:

```powershell
Args = '/S /D="C:\Program Files\Green App"'
```

### B) Array args (recommended for reliability)

Use an array to avoid quoting issues and to represent “multiple arguments” explicitly:

```powershell
Args = @('/ALLUSER', '/S', '/norestart')
```

If your script’s launch logic supports arrays, `Start-Process -ArgumentList` will pass them cleanly.

---

## 6) MSI rules: how to do it correctly

MSI installs always run through `msiexec.exe`. If you provide a rule for MSI args, you must provide **the full msiexec argument string**, because the script will not “merge” defaults unless you implement that logic.

Example: setting MSI properties:

```powershell
[pscustomobject]@{
  Name      = 'Green MSI all users'
  AppliesTo = 'Msi'
  MatchType = 'Contains'
  Match     = 'green'
  Args      = '/i "C:\Path\GreenApp.msi" /qn ALLUSERS=1 /norestart'
  Preselect = $true
}
```

### Practical recommendation

Do **not** hardcode full MSI paths in rules unless the MSI path is stable. Prefer letting the script build the MSI path, and only override **properties/switches** if you later implement `AppendArgs` logic.

---

## 7) Recommended rule patterns (examples)

### Example 1: EXE “all users” switch by name

```powershell
[pscustomobject]@{
  Name      = 'Green apps: all users'
  AppliesTo = 'Exe'
  MatchType = 'Contains'
  Match     = 'green'
  Args      = @('/ALLUSER')
  Preselect = $true
}
```

### Example 2: Chrome enterprise installer flags

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

### Example 3: VLC (common silent switch)

```powershell
[pscustomobject]@{
  Name      = 'VLC silent'
  AppliesTo = 'Exe'
  MatchType = 'Like'
  Match     = '*vlc*'
  Args      = @('/S')
  Preselect = $false
}
```

---

## 8) Operational pitfalls (read this before blaming the script)

1. **Silent switches are vendor-specific**

   * `/S`, `/silent`, `/qn`, `/verysilent`, etc. are not universal across EXE installers.
   * If you don’t add a rule, the default `/S` may do nothing.

2. **Quoting matters**

   * Paths with spaces must be quoted.
   * Prefer args arrays when possible.

3. **Exit codes are not standardized**

   * `0` usually means success, but some vendors use non-zero “success with reboot required” codes.
   * Treat exit codes in context (and document your known ones).

4. **First-match rule order**

   * If your “general” rule is above your “specific” rule, the specific one will never trigger.

---

## 9) Suggested extension (if you want “defaults + extras”)

If you want “use default args but append extra switches,” add an optional `AppendArgs` field:

```powershell
AppendArgs = @('/ALLUSER')
```

Then implement:

* build default spec first
* append rule `AppendArgs`

This avoids writing full MSI command strings just to add properties.

---

## 10) Developer checklist

Before adding a rule:

* Confirm the installer’s silent switch works manually
* Decide whether it should be `Preselect=$true`
* Prefer `Like` or `Regex` if filenames are inconsistent
* Put specific rules above general ones
* Keep one canonical ruleset per environment (IT shares differ)

