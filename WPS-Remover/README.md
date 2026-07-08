# WPS Office Enterprise Removal Utility

A single-file, zero-dependency PowerShell 5.1 script that completely and safely removes every
version of WPS Office (Kingsoft Office) from Windows 10 / Windows 11 — designed to run directly
from the web with no local file needed.

**Author:** rhshourav
**Repository:** https://github.com/rhshourav/Windows-Scripts/

---

## Quick start

```powershell
# Interactive (asks for confirmation, shows console UI)
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/WPS-Remover/remove-wps.ps1)

# Preview only — makes no changes
& { iex (irm https://.../remove-wps.ps1) } -DryRun -Verbose

# Fully unattended (RMM / SCCM / Intune)
& { iex (irm https://.../remove-wps.ps1) } -Silent -Force -JsonLog -NoRestart
```

> Must be run from an **elevated (Administrator)** PowerShell session. The script checks this
> itself and stops with clear instructions if it isn't.

If you saved the file locally instead:

```powershell
.\remove-wps.ps1 -DryRun -Verbose
```

## What it does

In order, it: detects every WPS Office / Kingsoft installation (registry, MSI, portable) →
terminates running processes → runs the real vendor/MSI uninstaller → removes services,
scheduled tasks, and startup entries → cleans registry remnants (including COM/shell-extension
registrations and every user's hive, even profiles that aren't logged on) → removes shortcuts,
leftover files/folders, and (optionally) file associations and firewall rules → re-validates the
system is clean → writes a report.

Every deletion is gated behind positive identification as WPS Office/Kingsoft, checked against a
protective blacklist (Microsoft Office, LibreOffice, OpenOffice, Adobe, user documents, fonts,
etc.) that is never touched — see **Safety design** below.

## Parameters

| Parameter | Effect |
|---|---|
| `-Silent` | Quiet mode: suppresses non-essential console output. Implies `-Force`. |
| `-DryRun` | Detect and report only — no changes are made. Safe to run anytime. |
| `-Force` | Skip the interactive confirmation prompt. Required for unattended runs. |
| `-NoRestart` | Never auto-restart; locked files are scheduled for deletion on next boot instead. |
| `-LogPath <dir>` | Where logs/reports are written. Default: `%ProgramData%\WpsRemovalUtility\Logs`. |
| `-JsonLog` | Also write a structured JSON Lines log and a JSON summary report. |
| `-CleanupTemp` | Also scan `%TEMP%`, Windows Temp, and the Windows Installer cache. |
| `-CleanupFirewall` | Also remove Windows Firewall rules created by WPS Office. |
| `-CleanupFileAssociations` | Also remove WPS file-type associations (ProgIDs). |

Standard `-Verbose` / `-Debug` switches (built into every PowerShell script via `[CmdletBinding()]`)
control log detail; `-Debug` surfaces internal DEBUG-level trace messages.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success — system confirmed clean by the Validation Engine (or nothing was found). |
| 1 | Completed with one or more errors logged. |
| 2 | Cancelled by the user at the confirmation prompt. |
| 3 | Completed, but residual items remain (see the report) — often just pending-reboot items. |
| 5 | Not running elevated. |
| 99 | Unhandled/unexpected error. |

**Note on exit codes and `iex`:** when the script is run via `iex (irm ...)` there is no
backing `.ps1` file, so calling `exit` would close the user's *entire* interactive PowerShell
session — the script detects this and only calls `exit <code>` when it's actually running as a
saved file; otherwise it sets `$LASTEXITCODE` instead. Run it as a saved file (as SCCM/Intune/RMM
tooling normally does) if your deployment pipeline needs a real process exit code.

## Safety design

- **Whitelist + blacklist, both sides checked.** Nothing is touched unless it positively matches
  a WPS/Kingsoft identity pattern *and* does not match the protective blacklist (Microsoft Office,
  LibreOffice, OpenOffice, Adobe, user Documents, fonts, Wi-Fi Protected Setup, etc.). The
  blacklist wins on conflict.
- **Ambiguous binaries are corroborated.** Generic names WPS also happens to use (`wps.exe`,
  `et.exe`, `wpp.exe`) are only acted on after confirming file metadata or install path.
- **User documents are never touched**, including anything under a profile's `Documents` folder —
  even a WPS-created backup folder there is left alone, since it may contain real user files.
- **Run keys are edited value-by-value**, never key-by-key — every other autorun entry is left
  exactly as it was.
- **File-type associations are cleared, not reassigned** — an extension WPS owned is left with no
  default handler (normal post-uninstall state) instead of being force-pointed at another app.
- **DryRun mode** previews the entire run with zero changes.

## Known limitations (by design)

- **No PowerShell classes.** Re-running this script in the same console (which is exactly what
  happens with `iex`) would throw "type already exists" if classes were used, so the whole tool
  is built from plain functions + shared script-scoped state instead — this is what makes it safe
  to run over and over.
- **No file quarantine/undo.** Deleted files are gone; there's no recycle-bin-style rollback.
  Registry deletions are logged in full (component + old value context) so state can be manually
  reconstructed if ever needed, and `-DryRun` lets you audit everything first.
- **MRU/RecentDocs binary lists aren't edited.** These structures live inside Explorer's own
  binary blobs; editing them risks corruption for very little benefit and is skipped deliberately.
- Requires the `ScheduledTasks` and `NetSecurity` PowerShell modules, which ship inbox with
  Windows 10/11 — no `Install-Module` is ever performed.

## Logs & reports

Written to `-LogPath` (default `%ProgramData%\WpsRemovalUtility\Logs`):

- `WpsRemoval_<timestamp>.log` — plain-text log, always written.
- `WpsRemoval_<timestamp>.json` — JSON Lines log (only with `-JsonLog`).
- `WpsRemoval_Report_<timestamp>.txt` / `.json` — final summary report, always written.
