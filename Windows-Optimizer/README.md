# 🚀 Windows Optimizer

A **single-file PowerShell Windows optimization utility** focused on **performance, transparency, reversibility, and user control**. This is **not** a shady debloater or placebo tweak pack. Every action is visible, logged, and (where possible) reversible.

---

## ⚠️ DISCLAIMER (READ CAREFULLY)

This tool **modifies Windows services, registry settings, power plans, and installed applications**.

* 🧠 Intended for **advanced users**
* 🛑 Not recommended for corporate or production machines without testing
* 🔍 Always review logs and snapshots
* ❗ You are fully responsible for the outcome

If you run scripts you don’t understand, **stop here**.

---

## ✨ FEATURES

### 🔐 Admin-Safe Execution

* Detects non-admin execution
* Clearly explains **why elevation is required**
* Relaunches cleanly (no crash, no instant close)

### 📜 Full Logging & Transparency

* Every action printed to screen
* Persistent log file stored locally
* Color-coded output for clarity
* No silent changes

### 💾 Automatic System Snapshot

* Captures key service states before changes
* Stored locally for rollback or manual restore

### ⚙️ Optimization Profiles

| Profile                  | Purpose                      | Risk   |
| ------------------------ | ---------------------------- | ------ |
| 🟢 Level 1 – Balanced    | Minor UI + telemetry tuning  | Low    |
| 🟡 Level 2 – Performance | Disables background services | Medium |
| 🔴 Level 3 – Aggressive  | Maximum service reduction    | High   |
| 🎮 Gaming                | High-performance power plan  | Medium |
| 🧠 Hardware-Aware        | CPU-aware power tuning       | Low    |

### 🧹 Optional Bloatware Removal

Safely removes **non-essential Microsoft apps only**:

* Xbox components
* News / Weather
* Feedback Hub
* Solitaire Collection

❌ **Never removed**:

* Microsoft Store
* Windows Update
* Windows Defender
* Core shell components

### 📡 Telemetry (Transparent & Disclosed)

Telemetry is **enabled by default** and clearly communicated to the user.

Collected data:

* 👤 Username
* 💻 Computer name
* ⚙️ Selected optimization profile

Purpose:

* 📊 Usage analytics
* 🛠 Script improvement

Telemetry failure **never breaks execution**.

---

## 🧩 REQUIREMENTS

* Windows 10 / 11
* PowerShell 5.1+
* Administrator privileges
* Internet access (only for telemetry and remote execution)

---

## ▶️ INSTALL / RUN

### ⚡ One-Line Execution (Recommended)

```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/Windows-Optimizer.ps1 | iex
```

### 📦 Manual Execution

1. Download `Windows-Optimizer.ps1`
2. Open PowerShell **as Administrator**
3. Run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
.\\Windows-Optimizer.ps1
```

---

## 📁 RUNTIME FILE STRUCTURE

Automatically created under `%TEMP%`:

```
WindowsOptimizer/
├── logs/
│   └── optimizer.log
├── snapshots/
│   └── snapshot-YYYYMMDD-HHMMSS.txt
```

---

## 🧾 LOGGING DETAILS

* 🖥 Console output is color-coded
* 🗂 Full persistent log stored locally
* ❌ Errors are non-fatal unless critical

Log levels:

* INFO
* ACTION
* WARN
* ERROR

---

## 🚫 WHAT THIS TOOL IS NOT

* ❌ A fake “FPS booster”
* ❌ A registry cleaner
* ❌ A miracle performance button
* ❌ Safe for beginners

Expect **measured, real improvements**, not magic.

---

## 🛣 ROADMAP

* 🔍 Dry-run / WhatIf mode
* 🧬 Windows build detection
* ♻️ Automated restore from snapshot
* 🏭 OEM bloatware detection
* 🤫 Silent / unattended mode

---

## 👤 AUTHOR

**Shourav**
Cyber Security Engineer
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)

---

## 🧨 FINAL WARNING

You are responsible for the system you run this on.

📖 Read the code.
🧠 Understand the changes.
📂 Check the logs.

If that mindset makes you uncomfortable — **do not use this tool**.
