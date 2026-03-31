# AutoDriverDeploy

**Author:** rhshourav
**Version:** 1.0.1

---

## Overview

AutoDriverDeploy is a hardened PowerShell deployment script designed to:

* Automatically detect and install missing drivers
* Install drivers from local repositories (`.inf`)
* Pull driver updates directly from Windows Update
* Support enterprise deployment scenarios (MDT / SCCM / standalone)
* Provide structured logging and exit codes for automation pipelines

---

## Features

* ✔ Local driver staging via `pnputil`
* ✔ Windows Update driver automation (COM API, no external modules)
* ✔ Self-elevating execution
* ✔ Robust logging (file + transcript separation)
* ✔ Reboot handling (3010 exit code support)
* ✔ Compatible with PowerShell 5.1 and PowerShell 7+

---

## Quick Run (One-Liner)

Run directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1 | iex
```

Run with parameters:

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1) -DriverSourcePath "D:\Drivers" -RebootIfRequired
```

---

## Usage

### Basic Execution

```powershell
.\AutoDriverDeploy.ps1
```

### With Local Driver Repository

```powershell
.\AutoDriverDeploy.ps1 -DriverSourcePath "D:\Drivers"
```

### Skip Windows Update

```powershell
.\AutoDriverDeploy.ps1 -SkipWindowsUpdate
```

### Silent Deployment with Reboot

```powershell
.\AutoDriverDeploy.ps1 -DriverSourcePath "\\server\drivers" -RebootIfRequired
```

---

## Parameters

| Parameter            | Description                    |
| -------------------- | ------------------------------ |
| `-DriverSourcePath`  | Path to folder or `.inf` files |
| `-SkipWindowsUpdate` | Disable online driver updates  |
| `-RebootIfRequired`  | Auto reboot if needed          |
| `-LogPath`           | Custom log file path           |
| `-NoTranscript`      | Disable transcript logging     |
| `-NoElevate`         | Disable auto elevation         |

---

## Exit Codes

| Code   | Meaning                  |
| ------ | ------------------------ |
| `0`    | Success                  |
| `3010` | Success, reboot required |
| `1`    | Error                    |

---

## Requirements

* Windows 10 / 11 / Server
* PowerShell 5.1 or newer
* Administrator privileges (auto-elevates)

---

## Notes

* Windows Update drivers may not always include latest OEM drivers (GPU/vendor-specific)
* For offline deployment, use `-DriverSourcePath`
* Script is safe for enterprise automation pipelines

---

## Security Notice

This script executes directly in memory using:

```powershell
irm ... | iex
```

Only run scripts from trusted sources.

---


## Contributing

Pull requests and improvements are welcome.

---
