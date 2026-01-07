# Windows Optimizer

A **production‑grade Windows 10/11 optimization framework** designed for performance, gaming latency reduction, and hardware‑aware tuning. The project is modular, reversible, and transparent by design.

This repository is intended for power users, administrators, and engineers who want **deterministic performance improvements** without breaking Windows updateability or core system stability.

---

## Core Principles

* Explicit execution (no background or hidden behavior)
* Snapshot before modification
* Reversible changes
* Profile‑based optimization
* Transparent, documented telemetry

---

## Optimization Profiles

| Profile               | Purpose                                                     |
| --------------------- | ----------------------------------------------------------- |
| Level 1 – Balanced    | Safe performance improvements with minimal risk             |
| Level 2 – Performance | Aggressive background reduction while maintaining stability |
| Level 3 – Aggressive  | Maximum performance; reduced services and features          |
| Gaming                | Latency‑focused tuning for gaming workloads                 |
| Hardware‑Aware        | Dynamic tuning based on CPU, RAM, disk, and platform        |

---

## Telemetry (Enabled by Default)

### Why telemetry exists

Telemetry is used **only** to understand how the optimizer is used and to improve stability across different hardware configurations. It is **not required** for the tool to function.

### Telemetry status

* **Enabled by default**
* **User is explicitly informed at runtime**
* **Can be declined or disabled permanently**

The user is shown a clear notice before any data is transmitted.

---

## Data Collected

Only the following **non‑sensitive metadata** is collected:

* Username
* Computer name
* Domain or workgroup name
* Local IPv4 address(es)
* Selected optimization profile
* Timestamp

### Data NOT collected

* Files or file contents
* Installed applications
* Running processes
* Browsing or usage history
* MAC addresses
* External IP address
* Hardware serial numbers
* Credentials or secrets

All telemetry payloads are human‑readable and visible in the source code.

---

## Telemetry Control

At first execution, the user is informed that telemetry is enabled and given the option to:

* Continue with telemetry enabled
* Disable telemetry permanently

Disabling telemetry does **not** affect optimization functionality.

Telemetry preference is stored locally per user.

---

## Reversibility

Before any optimization profile is applied:

* A system snapshot is taken
* Service states, power plan, and key settings are recorded

Users can restore a previous snapshot at any time using the selector menu.

---

## Repository Structure

```
Windows-Optimizer/
│
├── core/
│   ├── Logger.ps1
│   ├── Snapshot.ps1
│   ├── Restore.ps1
│   ├── HardwareDetect.ps1
│   └── Telemetry.ps1
│
├── profiles/
│   ├── Level1-Balanced.ps1
│   ├── Level2-Performance.ps1
│   ├── Level3-Aggressive.ps1
│   ├── Gaming.ps1
│   └── Hardware-Aware.ps1
│
├── Select-Optimization.ps1
├── README.md
└── LICENSE
```

---

## Disclaimer

This project makes system‑level changes. While care is taken to preserve stability and reversibility, **use at your own risk**. Review scripts before execution.

---

