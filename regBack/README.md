# WARDEN: Windows Advanced Registry Defense, Export & Restoration Nexus

**WARDEN** is a high-performance PowerShell utility designed to safeguard the Windows Registry through advanced extraction techniques, integrity verification, and fail-safe restoration points. It serves as a comprehensive "defense engine" for system administrators and power users who need more than just a basic `.reg` export.

---

### 🚀 Quick Start (One-Line Command)
To launch WARDEN immediately with administrative privileges, run the following in an **Elevated PowerShell** prompt:

```powershell
iex (irm 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1')
```
*(Note: Ensure your execution policy allows scripts or use `-ExecutionPolicy Bypass` if running the local file).*

---

### ✨ Key Features
* **Full Spectrum Backups**: Captures `HKLM`, `HKCU`, `HKU`, and `HKCR`, including system-critical hives like `SAM`, `SECURITY`, and `SYSTEM`.
* **VSS Integration**: Utilizes Volume Shadow Copy (VSS) to extract registry hives that are normally locked by the operating system.
* **Integrity Assurance**: Generates a **SHA-256 hash manifest** for every backup file to ensure no tampering or corruption has occurred prior to restoration.
* **Automated Elevation**: Includes built-in UAC self-elevation and utilizes SYSTEM-privilege task scheduling to access the most restricted areas of the registry.
* **Safety-First Restoration**: Automatically creates a "Pre-Restore Safety Snapshot" before applying changes, allowing for full rollback if things go sideways.
* **Metadata Rich**: Backups are archived in ZIP format containing embedded **JSON metadata** (OS version, session ID, timestamps, and user data).
* **Selective Targeting**: Allows for custom keyword searches to backup specific application keys or service definitions instead of the entire hive.

---

### 🛠️ Technical Specifications
| Requirement | Detail |
| :--- | :--- |
| **OS Compatibility** | Windows 10 & Windows 11 |
| **Shell Version** | PowerShell 5.0 or higher |
| **Privileges** | Administrator (Mandatory) |
| **Dependencies** | None (Uses native Windows binaries like `reg.exe` and `vssadmin`) |
| **Output** | ZIP Archives with SHA-256 Verification |

---

### 📂 Default Storage
By default, WARDEN organizes all exports into:
`C:\WARDEN_Backups\`

Inside this directory, you will find session-specific folders containing:
* **registry_export/**: Individual `.reg` files.
* **hive_files/**: Raw binary hives (SAM, SYSTEM, etc.).
* **WARDEN_metadata.json**: Detailed session and system info.
* **WARDEN_SHA256_XXXX.sha256**: The integrity manifest.

---

### ⚠️ Disclaimer
> **WARDEN** handles system-critical components. While it includes robust safety snapshots and rollback features, modifying the Windows Registry always carries inherent risks. Always verify your backups before proceeding with a full system restoration.

**Author:** rhshourav
**Repository:** [WindowsScripts](https://github.com/rhshourav/WindowsScripts)
