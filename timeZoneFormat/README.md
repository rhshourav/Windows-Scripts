<h1 align="center">Dhaka Time Zone + Time Sync + Date/Time Format (All Users)</h1>

<p align="center">
  Force Windows time zone to Dhaka, force time synchronization, validate Dhaka time drift, and set date/time formats for all users.
</p>

---

## What this script does

**Time zone (system-wide)**
- Forces Windows time zone to **Dhaka** (`Bangladesh Standard Time`)

**Time sync (system-wide)**
- Ensures **Windows Time (w32time)** service is enabled and running
- Configures NTP peers (best-effort)
- Forces a resync (with safety controls so the script continues even if resync is slow/blocked)

**Date/Time display format (all users)**
- Prompts once for **Short Date** and **Time** formats
- Applies those formats to:
  - All **currently loaded** user profiles (HKEY_USERS\<SID>)
  - All **offline** user profiles by loading their `NTUSER.DAT`
  - The **Default** profile (future users)
  - `HKEY_USERS\.DEFAULT` (system/logon context)
- Refreshes the **current session** so changes appear immediately (best-effort)

> Note: For other users who are already logged in, some applications may require sign-out/sign-in to fully reflect changes. The script writes the correct values for them in one run.

---

## One-line execution (Run as Administrator)

Open **PowerShell as Administrator**, then run:

```powershell
iex (irm "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1")
````

---

## Requirements

* Windows 10 / Windows 11
* Administrator privileges (the script will attempt to auto-elevate if started non-admin)
* Network access for NTP sync (in domain environments, time sync may be controlled by policy)

---

## What you’ll see

* Current time zone and whether it was changed
* w32time service status and forced resync output
* Local time vs computed Dhaka time drift
* A prompt to choose date and time formats (unless you run in a non-interactive mode)

---

## Troubleshooting

### Resync hangs or fails

This is typically environmental:

* Domain time hierarchy overrides manual NTP peers
* NTP blocked (UDP/123), firewall rules, proxy policy, or restricted services

The script still sets time zone + formats, and continues even if resync fails.

### Format doesn’t change immediately for another user

* The script *applies* formats for all users, but already-running apps can cache locale settings.
* Users may need to sign out/in to see the change everywhere.

---

## Security note

This script modifies:

* System time zone settings
* Windows Time service configuration (best-effort)
* Per-user registry values under `Control Panel\International`

Review the script before deploying in managed environments.

---

## Author

**Shourav (rhshourav)**
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)
