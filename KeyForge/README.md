# KeyForge

*Forge. Manage. Eliminate.*

A single-file PowerShell console for inspecting Windows keyboard layouts, language packs, input methods, and regional/locale settings.

**This build: `v1.0.0` — Core Foundation + UI Shell (Phase 1+2 of 4).** Everything in it is read-only. Installing, removing, or repairing anything is intentionally out of scope here — see [Roadmap](#roadmap).

## What's in this build

- **Live dashboard** — Windows version/build/edition, architecture, admin status, current language/keyboard/region/locale/timezone, at-a-glance counts.
- **Full terminal UI engine** — rounded box drawing, colored tables, tree view, spinners, progress bars, confirmation/info/choice dialogs, all with automatic ASCII fallback for hosts without Unicode support.
- **9 working, read-only screens**: Installed Languages, Installed Keyboard Layouts, Region Settings, Locale Settings, Time & Region, Language Features, Diagnostics (lite), Export Configuration (JSON snapshot), Live Monitoring (lite), plus Settings and About.
- **The other 11 menu items** (install/remove language, remove/set keyboard, set display language, cleanup, advanced removal, backup, restore, repair, import configuration) appear in the menu as clearly labeled placeholders naming the phase they ship in — the menu structure matches the full 22-item spec so nothing has to be renumbered later.
- **Foundation layer**: structured logging (`%LOCALAPPDATA%\KeyForge\Logs`), custom exception types, a `never-crash` error envelope around every operation, a TTL cache for expensive queries, and validation/format/conversion utilities ready for the write-capable modules to build on.

## Usage

```powershell
# From a saved file
.\KeyForge.ps1

# Directly from GitHub, no local file
irm https://raw.githubusercontent.com/rhshourav/windows-scripts/main/KeyForge/keyforge.ps1 | iex

# With options
powershell -ExecutionPolicy Bypass -File .\KeyForge.ps1 -NoColor -VerboseLog
```

| Flag | Effect |
|---|---|
| `-Help` | Print usage and exit |
| `-Version` | Print version and exit |
| `-NoColor` | Disable colored output |
| `-VerboseLog` | Write verbose entries to the session log |
| `-DebugLog` | Write debug entries (implies `-VerboseLog`) |

Requires Windows PowerShell 5.1+ or PowerShell 7+, on Windows 10 1909+ or Windows 11. No modules, no installer, no external dependencies.

## Design notes worth knowing

- **No forced black background.** The palette uses foreground colors only, so it doesn't override whatever theme your terminal already has.
- **Auto-refresh never eats your keystrokes.** The dashboard refreshes on an idle timer, but any keypress resets the countdown so a partially-typed menu selection is never wiped out mid-type.
- **DISM calls are opt-in, not automatic.** The dashboard never touches DISM (it can take seconds); the full language/feature inventory only runs when you open those screens, with a spinner while it works.
- **All data goes in `%LOCALAPPDATA%\KeyForge\`** (`Logs`, `Backups`, `Exports`, `Temp`) — never next to the script, since there often isn't one on disk when launched via `irm | iex`.

## Roadmap

| Phase | Scope |
|---|---|
| **1 + 2 (this build)** | Core foundation, full UI shell, read-only screens |
| **3** | Registry handler, install/remove language & keyboard, backup/restore, region/locale writes |
| **4** | Cleanup, advanced/nuclear removal (scoped to supported DISM/capability APIs — see note below), repair, full live monitoring |

> **Note on destructive operations:** the original spec called for direct WinSxS component manipulation for "Nuclear Removal." That's intentionally *not* how Phase 4 will work — Microsoft doesn't support manual WinSxS surgery outside DISM's own reference-counted servicing logic, and doing it anyway risks an unbootable system for no real benefit. Phase 4's deepest removal tier will use the supported surface (`Remove-Language`, `Uninstall-WindowsCapability`, `DISM /Remove-Package`) plus aggressive registry/cache cleanup instead, which achieves the same practical outcome without that risk.

## Project structure

```
rhshourav/windows-scripts/
└── KeyForge.ps1     ← this file (single-file, no dependencies)
```

`README.md`, `CHANGELOG.md`, `LICENSE`, and the `docs/`/`examples/`/`screenshots/` folders from the full repo layout aren't included in this pass — happy to generate those next if useful.
