# 🟢 ✅ BACKUP REGISTRY (Old PC)

Run **Command Prompt / PowerShell as Administrator**

### 🔹 Backup main registry hives:

```bat
reg export HKLM\SOFTWARE D:\Migration\HKLM_SOFTWARE.reg /y
reg export HKCU\SOFTWARE D:\Migration\HKCU_SOFTWARE.reg /y
```
or
```
New-Item -ItemType Directory -Path D:\Migration -Force reg export HKLM\SOFTWARE D:\Migration\HKLM_SOFTWARE.reg /y
```

---

### 🔹 (Optional but recommended) backup more:

```bat
reg export HKLM\SYSTEM D:\Migration\HKLM_SYSTEM.reg /y
reg export HKLM\SECURITY D:\Migration\HKLM_SECURITY.reg /y
reg export HKLM\SAM D:\Migration\HKLM_SAM.reg /y
```

⚠️ Note:

* SYSTEM/SECURITY/SAM may require **SYSTEM privileges**
* Not always needed unless doing deep migration

---

### 📁 Final backup folder example:

```
D:\Migration\
 ├── HKLM_SOFTWARE.reg
 ├── HKCU_SOFTWARE.reg
 ├── HKLM_SYSTEM.reg
```

---

# 🔵 ✅ RESTORE REGISTRY (New PC)

Run **as Administrator**

### 🔹 Restore:

```bat
reg import D:\Migration\HKLM_SOFTWARE.reg
reg import D:\Migration\HKCU_SOFTWARE.reg
```

---

# ⚠️ VERY IMPORTANT WARNINGS

## ❌ Do NOT blindly restore everything

Registry contains:

* hardware-specific configs
* drivers
* user SID references

👉 Restoring full registry can:

* break Windows
* cause boot issues
* crash apps

---

# 🟡 🔥 SAFE STRATEGY (Recommended for you)

Since you use **INA industrial software**, do this instead:

### ✅ Step 1: Install apps normally

### ✅ Step 2: Restore ONLY needed keys

Example:

```bat
reg export HKLM\SOFTWARE\INA D:\Migration\INA.reg /y
reg export HKCU\SOFTWARE\INA D:\Migration\INA_USER.reg /y
```

Then restore:

```bat
reg import D:\Migration\INA.reg
reg import D:\Migration\INA_USER.reg
```

👉 Much safer and cleaner

---

# 🧠 Pro Tip (BEST METHOD)

Before exporting, find exact keys:

```bat
reg query HKLM\SOFTWARE /s | findstr /i "INA"
```

This helps isolate only relevant entries.

---

# 🧯 Emergency Recovery Tip

Before restoring on new PC:

```bat
reg export HKLM\SOFTWARE backup_before_restore.reg /y
```

👉 So you can roll back if something breaks


