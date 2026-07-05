# Version control comment for git tracking

This file represents the refactored PowerShell menu system (v27.5.0) that converts the flat 26-item menu into a hierarchical structure while preserving all functionality.

## Refactoring Summary
- **Before**: 26 flat items in single menu level
- **After**: 9 main items + 3 submenu shortcuts (applications, system, hardware)
- **Preserved**: All execution logic, elevation, system status, security features
- **New**: Hierarchical navigation, breadcrumbs, back button support

## Usage
This script is meant to be run from the main menu or via direct URL to individual tools.
Run with: `powershell -NoProfile -ExecutionPolicy Bypass -File windowsScripts-Refactored.ps1`

## Notes
- Auto-elevates to administrator when needed
- Retrieves LAN IPs for Local Intranet trust zone in child windows
- Displays real-time system status on every menu draw
- Compatible with iex/irm invocation patterns
- Consists of 515 lines (slightly longer due to additional navigation features)
