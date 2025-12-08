# PowerShell & CMD Activation Script Collection  
*(Educational Study Repository)*

## ⚠️ Disclaimer

This repository is created **strictly for educational, research, and learning purposes**.

It demonstrates how PowerShell and CMD scripts:
- Perform environment validation
- Interact with Windows licensing components
- Query system activation status
- Automate troubleshooting tasks

❌ This project does **not** promote software piracy or license circumvention.  
❌ Running these scripts on production systems is discouraged.  
✅ Use only in **controlled test or lab environments**.

---
## To Test and Run use Those Commands:
- For Windows 8, 10, 11
```
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run | iex
```
or From Original Source:
```
irm https://get.activated.win | iex
```
If the above is blocked (by ISP/DNS), try this (needs updated Windows 10 or 11):
```
iex (curl.exe -s --doh-url https://1.1.1.1/dns-query https://get.activated.win | Out-String)
```
- For Windows 7
```
iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run'))
```
or From Original Source:
```
iex ((New-Object Net.WebClient).DownloadString('https://get.activated.win'))
```
## 📘 About This Repository

This repository contains a collection of **PowerShell and CMD scripts** designed to help learners understand:

- Windows & Office activation mechanisms
- Script-based automation workflows
- Real-world PowerShell bootstrapper behavior
- Common patterns analyzed by security professionals
- Defensive detection of activation-related scripts

---

## 📂 Project Structure & File Details

### 🔹 PowerShell Bootstrapper

| File | Purpose |
|----|----|
| `script.ps1` | Prepares the PowerShell environment, validates execution conditions (Full Language Mode, .NET availability), securely downloads required CMD scripts, verifies file integrity using SHA-256, executes them with administrative privileges, and cleans up temporary files afterward. |

---

### 🔹 Add_Active

| Item | Purpose |
|----|----|
| `Add_Active` | Contains helper logic and supporting components used by activation workflow scripts for demonstration and analysis purposes. |

---

### 🔹 All-In-One

| File / Folder | Purpose |
|----|----|
| `AllInOne` | Houses combined scripts that provide a single interface to demonstrate multiple activation and system configuration operations. |
| `AIO.cmd` | A menu-driven **All-In-One controller script** that allows users to navigate between activation checks, edition changes, and troubleshooting actions. |

---

### 🔹 Separate-Files

These scripts isolate individual tasks so learners can study them independently.

#### 🗂 Activat0s
| Item | Purpose |
|----|----|
| `Activat0s` | Groups activation-related scripts into a modular structure for focused analysis. |

#### 🧩 Individual CMD Scripts

| File | What It Does |
|----|----|
| `0hook-Activation-AI0.cmd` | Demonstrates hook-based activation techniques and how system hooks interact with licensing components. |
| `0nline-KM5-Activation.cmd` | Shows the workflow of online KMS-style activation logic, including client-server interaction simulation. |
| `HWID-Activati0n.cmd` | Demonstrates how hardware-based digital licenses (HWID) are tied to system identifiers. |
| `TSF0rge-Activation.cmd` | Explains token-based license handling and how forged tokens are analyzed in security research. |
| `Change-0ffice-Edition.cmd` | Automates switching Microsoft Office editions through licensing configuration commands. |
| `Change-Wind0ws-Edition.cmd` | Demonstrates Windows edition conversion logic using built-in system licensing APIs. |
| `Check-Activati0n-Status.cmd` | Queries and displays current Windows and Office activation status for diagnostic purposes. |
| `Extract-0EM-Folder.cmd` | Extracts and displays OEM licensing files and certificates for educational inspection. |
| `Troubleshoot.cmd` | Performs automated checks and repair steps for common activation-related problems. |

---

## 🧠 What You Can Learn From This Project

- PowerShell bootstrap and loader design
- CMD & PowerShell interoperability
- Activation status detection mechanisms
- Common scripting techniques flagged by antivirus engines
- Defensive analysis of activation scripts
- System troubleshooting automation

---

## 🛡️ Security & Ethics Note

- Some scripts mimic behavior used by **unauthorized activation tools**
- Such techniques are studied by security teams to understand **attack patterns**
- Ethical use and responsible learning are expected

---

## ✅ Recommended Learning Topics

- Windows Software Protection Platform (SPP)
- KMS vs HWID licensing models
- PowerShell execution policies & language modes
- AMSI & script block logging
- Malware loader behavioral patterns

---

## ✍️ Author

**rhshourav**  
Educational scripting & security research

---
This project is provided **as-is for educational analysis**.  
No warranty, no endorsement, no commercial use.
