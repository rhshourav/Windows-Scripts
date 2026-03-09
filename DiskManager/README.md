# Windows-Scripts – Disk Manager

![Banner](https://via.placeholder.com/800x100.png?text=Windows+Scripts+-+Disk+Manager)

**Author:** rhshourav
**Version:** 2.0.0
**Log Directory:** `Documents\rhshourav\windowsScripts\logs`

---

## Overview

**Windows-Scripts Disk Manager** is an advanced, interactive PowerShell-based toolkit for managing disks and partitions on Windows 10/11 systems. It combines a terminal UI, ASCII visualization, SMART monitoring, secure erase, and remote management features — all in a single script that can be executed via `Invoke-RestMethod`.

Designed for system administrators and power users, it provides a **Linux-style `lsblk` view**, partition visualizer, disk performance benchmarking, and much more.

---

## Features

* **Interactive Terminal UI** with arrow-key navigation (ncurses-style menu)
* **Disk Topology View (`lsblk` style)**
* **ASCII Partition Visualizer**
* **Total System Storage & RAM Information**
* **Live Partition Resize Monitoring**
* **Disk Benchmarking (Write Speed Test)**
* **SMART Health Monitoring**
* **BitLocker Lock / Unlock**
* **Drive Hiding via Registry**
* **Drive Letter Management**
* **NVMe / USB / RAID Disk Detection**
* **Secure Erase for HDD/SSD (via DiskPart)**
* **Remote Disk Management via WinRM**
* **Auto-update from GitHub**
* **Logging**: All operations saved under `Documents\rhshourav\windowsScripts\logs/diskmgr.log`

---

## Installation

1. Clone or download the repository:

```powershell
git clone https://github.com/rhshourav/Windows-Scripts.git
```

2. Navigate to the folder:

```powershell
cd Windows-Scripts
```

3. Run the Disk Manager via PowerShell:

```powershell
# Execute directly from GitHub (safe)
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1 | iex
```

> **Note:** Run PowerShell as Administrator for full disk management privileges.

---

## Usage

1. **Launch the script** – the banner and system info will display.
2. **Navigate the menu** using **Up/Down arrow keys**.
3. **Press Enter** to select a tool or feature.
4. Features like **Secure Erase** or **BitLocker Unlock** will require confirmation.
5. **Logs** are automatically saved after every operation.

---

## Examples

**Disk Topology (lsblk-style)**

```
Disk2 (ADATA LEGEND 710) [NVMe]
  |- Partition 1  FAT32 0.2 GB
  |- Partition 3  C NTFS 237.5 GB
Disk0 (ST1000DM003) [SATA]
  |- Partition 1  D exFAT 931.5 GB
```

**ASCII Partition Map**

```
Disk2:
[P1] ███ 0.2 GB
[P3] █████████████████ 237.5 GB
```

**Disk Benchmark**

```
Write Speed: 150 MB/s
```

**SMART Health**

```
InstanceName           PredictFailure
NVMe0\_PHYSICALDRIVE0   False
```

---

## Logging

All operations are logged automatically in:

```
C:\Users\<USERNAME>\Documents\rhshourav\windowsScripts\logs\diskmgr.log
```

Logs include timestamps and action details, e.g.:

```
2026-03-09 07:15:32 | Secure erase disk 1
2026-03-09 07:16:10 | Resized drive C to 237.5 GB
```

---

## Safety & Failsafes

* **System Disk Protection**: prevents accidental formatting or erasing of system drive.
* **Confirmation prompts** for destructive actions (e.g., Secure Erase, Format, BitLocker).
* **Error handling** for uninitialized disks or removable media.

---

## Requirements

* Windows 10 or 11
* PowerShell 5.1 or higher
* Administrative privileges for full disk operations

Optional:

* WinRM enabled for remote disk management
* UTF-8 console encoding for proper ASCII visualization

---

## Contributing

1. Fork the repository.
2. Create a branch (`feature/your-feature`).
3. Commit your changes.
4. Open a pull request.

**Note:** Please test scripts in a safe environment before modifying disks.
