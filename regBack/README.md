# 🧰 Windows Scripts – Registry Backup & Restore

**Author:** rhshourav
**Project:** Windows Scripts
**Module:** Registry Migration Tool

---

## 📌 Overview

This script provides a **safe, interactive way** to:

* 🔹 Backup selected registry keys
* 🔹 Restore registry keys on another PC
* 🔹 Copy application folders
* 🔹 Generate logs + manifest for auditing

Designed for **real-world migration scenarios** (like moving INA software, drivers, or legacy apps).

---

## ⚡ Quick Run (One-Line Install)

Run directly from GitHub:

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/regbackRe.ps1")
```

---

## 🔐 Security Notice (IMPORTANT)

Before running any remote script:

* Always review the script source:
  👉 https://github.com/rhshourav/Windows-Scripts

* PowerShell remote execution is powerful but risky

* Only run scripts you trust

💡 Hosting scripts on GitHub and executing via PowerShell is a common automation method in system administration ([github-wiki-see.page][1])

---

## 🚀 Features

* ✅ Interactive mode (no parameters needed)
* ✅ Auto admin elevation
* ✅ Black terminal theme
* ✅ Registry validation (skips invalid keys)
* ✅ Safe file copy using `robocopy`
* ✅ Logging + manifest system
* ✅ Production hardened (error handling + strict mode)

---

## 🧭 How It Works

### 1️⃣ Run the script

```powershell
.\regbackRe.ps1
```

### 2️⃣ Choose mode

```
1) Backup
2) Restore
```

---

## 💾 Backup Mode

You will be prompted to:

* Select source folder
* Select backup location
* Choose registry keys

### Output structure:

```
WindowsScriptsBackup/
 ├── Files/
 ├── Registry/
 ├── Meta/
 │    ├── manifest.json
 │    ├── hashes.txt
 └── migration.log
```

---

## 🔄 Restore Mode

You will be prompted to:

* Select backup folder
* Select destination folder

### Automatically:

* Restores files
* Imports `.reg` files
* Loads manifest

---

## 🧠 Default Registry Paths

```text
HKLM\SOFTWARE\INA
HKCU\SOFTWARE\INA
```

You can override with custom paths.

---

## ⚠️ Important Notes

* Do NOT restore full registry blindly
* Best used for:

  * Custom apps (like INA systems)
  * Legacy software migration
* Drivers must still be reinstalled manually

---

## 🧪 Example Use Case

* Old PC → Backup INA system
* New PC → Restore registry + files
* Reinstall dependencies
* System works without full reinstall

---

## 🛠 Requirements

* Windows 10 / 11
* PowerShell 5.1+
* Administrator privileges

---

## 📂 Project Structure

```
Windows-Scripts/
 └── regBack/
     └── regbackRe.ps1
```

---

## 🧾 License

MIT (or your preferred license)

---

## ⭐ Support

If this helped you:

* Star the repo ⭐
* Share with others
* Improve and contribute

---

[1]: https://github-wiki-see.page/m/limehawk/rmm-scripts/wiki/Scripts?utm_source=chatgpt.com "Scripts - limehawk/rmm-scripts GitHub Wiki"
