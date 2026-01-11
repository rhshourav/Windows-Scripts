# 🚀 Windows 10 → Windows 11 Forced Upgrade Automation

**Fully automated, data-safe, hardware-bypass Windows 11 upgrade script**
Compatible with **Windows PowerShell 5.1** and runnable via:

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1)
```

---

## 📌 Overview

This script performs an **in-place upgrade** from **Windows 10 to Windows 11** while:

* ✅ Keeping **all files, apps, and user accounts**
* ✅ Bypassing **TPM, CPU, Secure Boot, and RAM requirements**
* ✅ Supporting **single PC or multiple remote PCs**
* ✅ Auto-downloading the Windows 11 ISO (with fallback)
* ✅ Auto-detecting Windows edition (Home / Pro)
* ✅ Showing live progress & upgrade phases
* ✅ Allowing **user-controlled reboot**
* ✅ Cleaning up automatically after execution

This is the **same upgrade method used by Windows Update**, but fully automated and controllable.

---

## ⚠️ Important Safety Notes (READ)

✔ **NO data loss**
✔ **NO clean install**
✔ **NO formatting**
✔ **NO user deletion**

❌ Data loss occurs **ONLY** if you boot from the ISO or choose “Custom Install”
❌ This script does **NOT** do that

A **10-day rollback** to Windows 10 remains available after upgrade.

---

## 🧠 Features

### ✔ Hardware Requirement Bypass

* TPM
* Secure Boot
* Unsupported CPU
* Insufficient RAM

Implemented via **Microsoft-recognized registry flags**:

* `LabConfig`
* `MoSetup`

---

### ✔ Automatic ISO Download (With Fallback)

* Primary Microsoft CDN
* Secondary fallback mirror
* Uses **BITS** for reliability
* Auto-cleanup after use

---

### ✔ Edition Auto-Detection

* Detects installed Windows edition
* Uses correct Windows 11 upgrade path
* No user input required

---

### ✔ Progress Polling

* Detects setup phases
* Shows real-time status
* Displays exit codes for diagnostics

---

### ✔ Remote Fan-Out (Multiple PCs)

* Uses **PowerShell Remoting (WinRM)**
* Supports:

  * `-Computers` parameter
  * `computers.txt` file (one host per line)
* Fully unattended per remote machine

---

## 📂 File Structure

```
UpgradeToWin11.ps1
README.md
computers.txt   (optional)
```

---

## ▶️ Usage

### 🔹 Local Machine Upgrade

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1)
```

---

### 🔹 Multiple Remote Machines

Create `computers.txt`:

```
PC01
PC02
192.168.1.50
```

Run:

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1) -ComputersFile C:\path\computers.txt
```

---

### 🔹 Inline Remote List

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1) -Computers PC01,PC02
```

---

## 🔄 Reboot Behavior

* ❌ **No forced reboot**
* ✅ User is prompted at the end
* ✅ Remote machines log completion and wait for admin-initiated reboot

---

## 🧪 Compatibility

| Component      | Supported             |
| -------------- | --------------------- |
| Windows 10     | ✅ Yes                 |
| Windows 11     | ❌ Not needed          |
| PowerShell 5.1 | ✅ Yes                 |
| PowerShell 7   | ⚠️ Untested           |
| WinRM          | ✅ Required for remote |
| Admin Rights   | ✅ Required            |

---

## 🔐 Security Notes

* Script must run **as Administrator**
* Uses **official Windows setup engine**
* No telemetry modification outside setup flags
* No third-party tools required

---

## 🛠 Troubleshooting

### ISO Download Fails

* Script auto-tries fallback
* Ensure:

  * Internet access
  * TLS 1.2 enabled
  * No proxy blocking Microsoft CDN

### Remote PC Not Responding

* Ensure WinRM enabled:

  ```powershell
  Enable-PSRemoting -Force
  ```
* Firewall allows WinRM

### Setup Appears Stuck

* This is normal during:

  * “Copying files”
  * “Installing features”
* Progress polling will continue to update

---

## 🔙 Rollback (If Needed)

Within **10 days** of upgrade:

```
Settings → System → Recovery → Go back
```

---

## 📜 Disclaimer

This script uses **documented Microsoft mechanisms**, but **bypassing hardware checks is not officially supported** by Microsoft.

Use at your own risk — **recommended to test on non-production machines first**.


