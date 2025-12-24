# Fix PowerShell ConstrainedLanguage Issue

## Troubleshooting Steps

If a PowerShell script fails and shows **ConstrainedLanguage** or indicates that PowerShell is not running in **Full Language Mode**, follow the steps below.

### Step 1: Open Command Prompt as Administrator
- Press **Start**
- Search for **Command Prompt**
- Right-click → **Run as administrator**

### Step 2: Remove the PowerShell Lockdown Policy
Run the following command:

```cmd
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v "__PSLockdownPolicy" /f
````

### Step 3: Restart PowerShell

* Close all open PowerShell windows
* Open a new PowerShell session
* Retry running the script

### Step 4: Verify Language Mode (Optional)

To confirm PowerShell is running in Full Language Mode:

```powershell
$ExecutionContext.SessionState.LanguageMode
```

Expected output:

```
FullLanguage
```

---

## Summary

This issue occurs when PowerShell is restricted to **ConstrainedLanguage mode**, which blocks advanced scripting features.
Removing the `__PSLockdownPolicy` registry value allows PowerShell to return to **Full Language Mode**, enabling scripts to run normally.

Use this fix only on systems you manage or for troubleshooting in controlled environments.

