# DriverDex

**Automatic Hardware Driver Detector & Installer**
Scans your hardware, checks it against the DriverDex database, and only bothers you about what actually needs attention.

## Quick Start

```powershell
irm https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/DriverDex-Installer.ps1 | iex
```

Run that in PowerShell (Admin recommended — it'll offer to self-elevate if you don't). That's it.

> Adjust the path above if the script lives somewhere other than the repo root — e.g. `.../main/installer/DriverDex-Installer.ps1`.

**Already have the file locally?**

```powershell
powershell -ExecutionPolicy Bypass -File ".\DriverDex-Installer.ps1"
```

## What it does

1. Scans every PnP hardware device on your system
2. Queries the DriverDex API for matching drivers
3. Cross-checks what's *already* installed — by hardware ID, not just provider name
4. Shows you a table with each driver tagged `NEW`, `UPDATE`, `INSTALLED`, or `NEWER INSTALLED`
5. Pre-selects only what actually needs action (`SMART` mode) — you can still force `ALL`, `PROBLEMS`, or pick by number
6. Downloads (SHA-256 verified), extracts, and installs via `pnputil`
7. If your hardware isn't in the database yet, invites you to contribute it — anonymously, opt-in, no account needed

## Requirements

| | |
|---|---|
| OS | Windows 7 SP1, 8.1, 10, 11 (x86 & x64) |
| PowerShell | 5.1+ |
| Elevation | Recommended — required for actual driver install via `pnputil` |
| Network | Required (API + GitHub-hosted driver packages) |

## Selection modes

| Command | What it installs |
|---|---|
| `SMART` *(default)* | Only drivers that need action: new, update available, or on a problem device |
| `ALL` | Every matched driver, including ones already installed |
| `PROBLEMS` | Only drivers for devices currently erroring in Device Manager |
| `1,3,5` | Specific rows by number |
| `NONE` / `q` | Exit without installing anything |

## Privacy

Contribution is opt-in and anonymized — no account, no PII, no file/browsing data. Full policy: [PRIVACY.md](https://github.com/rhshourav/driverdex/blob/main/PRIVACY.md)

## Links

- Repo: https://github.com/rhshourav/driverdex
- Session logs: `%TEMP%\DriverDex-<date>.log`
