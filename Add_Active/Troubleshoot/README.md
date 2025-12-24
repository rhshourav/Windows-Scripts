# Troubleshooting Guide – Windows Activation & System Repair

This directory contains **step-by-step troubleshooting guides** related to Windows activation, system instability, and PowerShell execution issues.  
Each document focuses on a **specific failure scenario** and provides recovery-oriented solutions.

These guides are intended for **educational, recovery, and diagnostic purposes**.

---

## 📁 Available Troubleshooting Documents

### 1️⃣ [PowerShell Issues](./Powershell_issue.md)
**File:** `Powershell_issue.md`

Use this guide if:
- PowerShell scripts fail to run
- Errors show `ConstrainedLanguage`
- .NET commands fail inside PowerShell
- Scripts exit immediately or behave unexpectedly

This document focuses on fixing **PowerShell execution environment issues** that can prevent scripts from running properly.

---

### 2️⃣ [Fix WPA Registry](./Fix%20WPA%20Registry.md)
**File:** `Fix WPA Registry.md`

Use this guide if:
- Windows activation fails repeatedly
- `sppsvc` service is broken or consumes high CPU
- Activation-related services do not start
- WPA registry corruption is suspected

This guide explains how to **safely clear kernel-protected WPA registry keys** using Windows Recovery Environment.

---

### 3️⃣ [In-Place Repair Upgrade](./In-Place%20Repair%20Upgrade.md)
**File:** `In-Place Repair Upgrade.md`

Use this guide if:
- System files are corrupted
- Activation and PowerShell issues persist
- Windows services fail even after registry fixes
- You want to repair Windows **without losing files or apps**

This method performs a **full Windows repair** while preserving user data and installed applications.

---

## 🔄 Recommended Troubleshooting Order

For best results, follow this sequence:

1. **[PowerShell Issues](./Powershell_issue.md)**  
   → Fix script execution and environment problems

2. **[Fix WPA Registry](./Fix%20WPA%20Registry.md)**  
   → Resolve activation and `sppsvc`-related failures

3. **[In-Place Repair Upgrade](./In-Place%20Repair%20Upgrade.md)**  
   → Perform a full system repair if issues persist

---

## ⚠️ Important Notes

- Some steps require **Administrator privileges**
- Recovery operations may reboot the system
- Do not interrupt repair processes once started
- Always read the full guide before executing commands

---

## 📌 Summary

This folder serves as a **central troubleshooting hub** for resolving:
- Windows activation problems
- PowerShell execution failures
- Registry corruption
- System-level Windows issues

Each document is independent but can be used together for **progressive troubleshooting**.

---

**Author:** rhshourav  
**Repository:** Windows-Scripts  
**Purpose:** Educational & system recovery documentation
