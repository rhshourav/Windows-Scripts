# In-Place Repair Upgrade (Keep Files & Apps)

An **in-place repair upgrade** is a safe and effective way to fix Windows system issues without deleting personal files or installed applications.  
This process reinstalls core Windows components and can resolve system corruption, update failures, and stability issues.

---

## What This Does

- Repairs corrupted Windows system files
- Fixes update and upgrade-related errors
- Keeps personal files and installed programs
- Refreshes Windows system components

---

## Requirements

- A Windows ISO that matches:
  - Installed Windows edition
  - System architecture
  - System language
- Administrator access

---

## Step 1: Check System Architecture

Open **PowerShell as Administrator** and run:

```powershell
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment").PROCESSOR_ARCHITECTURE
````

**Results:**

* `AMD64` / `x64` → 64-bit
* `x86` → 32-bit

Use an ISO that matches this result.

---

## Step 2: Check System Language

Run:

```cmd
dism /english /online /get-intl | find /i "Default system UI language"
```

**Alternative command:**

```powershell
[Globalization.CultureInfo]::GetCultureInfo(
  [Convert]::ToInt32(
    (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language").InstallLanguage, 16
  )
).Name
```

The ISO language must match the installed Windows language.

---

## Step 3: Edition Notes (LTSC)

* If you are running **Enterprise LTSC**, use the **same LTSC ISO**
* Do **not** use Evaluation editions (cannot be activated)

---

## Step 4: Mount the ISO

* Right-click the ISO file
* Select **Open with → Windows Explorer**
* A new DVD drive will appear once mounted

---

## Step 5: Unsupported Hardware (Windows 11 Only)

On some systems, Windows 11 setup may fail due to unsupported hardware.
In such cases, switching the edition temporarily allows setup to continue.

### Windows 11 24H2 or newer:

```cmd
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID /d IoTEnterprise /f
```

### Windows 11 LTSC 2024:

```cmd
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID /d IoTEnterpriseS /f
```

⚠️ After applying the command, **run `setup.exe` immediately** from the mounted ISO.

---

## Step 6: Run the Repair Upgrade

* Open the mounted DVD drive
* Run **setup.exe**
* Continue through the setup process
* On the final confirmation screen, ensure it shows:

> **Keep personal files and apps**

* Proceed and wait for completion

---

## Important Notes

* If Windows 11 LTSC 2024 is already fully updated, a repair upgrade requires a **recently updated ISO**
* Microsoft does not regularly release updated LTSC ISO files
* Manual ISO updating may be required

---

## Summary

An in-place repair upgrade reinstalls Windows while preserving user data and applications.
It is one of the most effective methods to fix persistent system issues without performing a clean installation.


