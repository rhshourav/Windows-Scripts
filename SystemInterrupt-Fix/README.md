# Intel System Interrupt Fix Toolkit

This repository contains **two PowerShell utilities** designed specifically to **reduce high “System Interrupts” CPU usage** on Intel-based Windows systems.

These scripts target **real, known causes** of interrupt storms such as:
- Power management misconfiguration
- CPU idle state issues
- MSI / interrupt handling problems
- DPC latency spikes

No placebo tweaks. No unsafe hacks.

---

## ⚠️ IMPORTANT DISCLAIMER

These scripts:
- Require **Administrator privileges**
- Modify **power, registry, and CPU behavior**
- Are intended for **advanced users**

Always test on non-critical systems first.

---

## 📦 Included Scripts

### ✅ Intel-SystemInterrupt-Fix.ps1
**Status:** ✔ Stable / Recommended  
**Purpose:** Fix common Intel System Interrupt CPU spikes

#### What it does
- Switches to **Ultimate Performance** power plan
- Disables deep CPU idle states that cause interrupt storms
- Applies Intel-safe power & scheduling optimizations
- Targets laptops and desktops with Intel CPUs

#### When to use
- High CPU usage from **“System Interrupts”**
- Audio crackling
- Mouse / keyboard stutter
- Random micro-freezes
- DPC latency warnings

#### Usage
```powershell
.\Intel-SystemInterrupt-Fix.ps1
````

The script auto-elevates using standard UAC if not already running as Administrator.

---

### ⚠️ wpt_interrupt_fix_plus.ps1

**Status:** 🧪 Advanced / Aggressive
**Purpose:** Extended interrupt & latency mitigation

This is a **stronger version** intended for troubleshooting difficult cases.

#### Additional actions

* Forces interrupt-related CPU behavior
* Applies deeper registry-based scheduling changes
* Reduces interrupt coalescing where possible
* Prioritizes real-time responsiveness over power saving

#### Recommended for

* Persistent System Interrupts after basic fixes
* Real-time workloads (audio, low-latency input, VMs)
* Testing and diagnostics

⚠️ Not recommended for battery-focused laptops.

#### Usage

```powershell
.\wpt_interrupt_fix_plus.ps1
```

---

## 🔒 Elevation & Security

Both scripts:

* Automatically request **Administrator privileges**
* Use **standard Windows UAC**
* Do **not** bypass Windows security
* Are compatible with **PowerShell 5.1+**

---

## 🧪 Compatibility

* Intel CPUs only
* Windows 10 (1909+)
* Windows 11
* Works on:

  * Desktops
  * Laptops
  * Virtual machines (Intel host)

Not intended for AMD systems.

---

## 📉 What This Does NOT Do

* ❌ No fake FPS boosts
* ❌ No service deletion
* ❌ No driver tampering
* ❌ No unsafe kernel hacks
* ❌ No permanent changes without reboot

All changes are **reversible** via reboot or power plan reset.

---

## 🧠 Technical Background

High “System Interrupts” CPU usage is commonly caused by:

* C-state transition latency
* Poor interrupt routing
* Power management conflicts
* Misbehaving drivers amplified by CPU power states

These scripts address those root causes directly.

---

## 👤 Author

**rhshourav**
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)

---

## 📌 Recommendation

If you are unsure:

➡ Start with **Intel-SystemInterrupt-Fix.ps1**
Only use **wpt_interrupt_fix_plus.ps1** if the problem persists
