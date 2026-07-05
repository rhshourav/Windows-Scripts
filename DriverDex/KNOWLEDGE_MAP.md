# DriverDex — Knowledge Map for Next AI

## Project Overview

**DriverDex** is a PowerShell-based automatic hardware driver detector and installer for Windows. It scans PnP devices, queries a REST API for matching drivers, lets the user review/select packages, then downloads (with progress + SHA-256), extracts, and installs via pnputil.

- **Version:** 2.4.0
- **Compatibility:** Windows 7 SP1, 8.1, 10, 11 (x86 and x64)
- **Requires:** PowerShell 5.1+ (both Windows PowerShell and PowerShell Core)
- **Author:** https://github.com/rhshourav/driverdex

---

## File Structure

```
DriverDex/
├── DriverDex.ps1              (1,556 lines) — Main entry point, imports all modules
├── driverrun.ps1              (3,251 lines) — Original monolithic script, DO NOT MODIFY
├── Modules/
│   ├── Utils.psm1             (444 lines) — Core utilities, logging, safe property access
│   ├── Formatting.psm1        (582 lines) — Unicode box-drawing tables, CJK support
│   ├── UI.psm1                (457 lines) — Banners, menus, status messages, error display
│   ├── Drivers.psm1           (433 lines) — Hardware enumeration, API integration
│   ├── Download.psm1          (199 lines) — Multi-part downloads, Git LFS, SHA-256
│   ├── Install.psm1           (401 lines) — Archive extraction, pnputil install, rollback
│   ├── Cache.psm1             (300 lines) — Runspace pool cache, O(1) search indexes
│   └── Search.psm1            (558 lines) — Weighted search engine, fuzzy matching
├── offline-packager/
│   ├── scan.cmd               (10 lines) — USB launcher for air-gapped PCs, auto-elevates
│   └── scan.ps1               (108 lines) — Hardware scanner, exports inventory.json
├── README.md
├── KNOWLEDGE_MAP.md
└── KNOWLEDGE_GRAPH.md
```

**Total:** ~6,000+ lines across 12 files.

---

## Module Dependency Graph

```
DriverDex.ps1 (orchestrator)
  ├── Utils.psm1        (no dependencies)
  ├── Formatting.psm1   (depends on: Utils)
  ├── UI.psm1           (depends on: Utils, Formatting)
  ├── Drivers.psm1      (depends on: Utils)
  ├── Download.psm1     (depends on: Utils)
  ├── Install.psm1      (depends on: Utils, Download, UI)
  ├── Cache.psm1        (depends on: Utils, Drivers)
  └── Search.psm1       (depends on: Utils, Cache)
```

**Import order matters.** Modules must be imported in dependency order:
```
Utils → Formatting → UI → Drivers → Download → Install → Cache → Search
```

---

## Exported Functions by Module

### Utils.psm1 (16 functions)
| Function | Purpose |
|---|---|
| `Get-Prop` | Safe property access for PSCustomObject + Newtonsoft JObject (PS 5.1) |
| `ConvertTo-CleanFieldString` | Array dedup + join (fixes `[string]` cast duplication bug) |
| `Join-Unique` | Joins unique values from array |
| `Write-Log` | Writes to daily rotating log at `%TEMP%\DriverDex-YYYYMMDD.log` |
| `Get-LogPath` | Returns current log path |
| `Get-AnsiSupported` | Detects ANSI escape sequence support |
| `Get-ConsoleWidth` | Returns console width (default 120) |
| `Initialize-Tls` | Sets TLS protocol versions |
| `Compare-DriverVersion` | Compares version strings (returns -1/0/1) |
| `Show-Spinner` / `Clear-SpinnerLine` | Animated Braille spinner |
| `Read-Input` | Reads user input with prompt, default, validation |
| `Test-Administrator` | Checks admin rights |
| `Get-OSInfo` / `Request-Elevation` | OS info / UAC elevation |
| `Test-NetworkConnectivity` | Network test |

### Formatting.psm1 (12 functions)
| Function | Purpose |
|---|---|
| `Get-SafeString` | Converts any value to display string (handles arrays via `Sort-Object -Unique`) |
| `Get-DisplayWidth` | Display width accounting for CJK wide characters |
| `Truncate-Text` | Truncates with `...` suffix (ASCII, not Unicode ellipsis) |
| `Get-ColumnWidths` | Computes optimal column widths with proportional compression |
| `Draw-Table` | Unicode box-drawing table renderer |
| `Draw-BorderedBox` | Bordered content box |
| `Get-PaginationBar` | Pagination indicator: `« ‹ 1 2 [3] 4 5 … › »` |
| `Show-SearchTable` / `Show-DriverDetail` / `Show-InstallSummary` | Formatted display functions |
| `Show-ProgressBar` / `Clear-ProgressLine` | Inline progress bar |

### UI.psm1 (16 functions)
| Function | Purpose |
|---|---|
| `Write-Step/OK/Warn/Info/Sub/Accent/Divider/Err` | Status message functions |
| `Write-Header` / `Write-SearchBanner` | Branded headers |
| `Show-MainMenu` | 5-mode menu: Auto, Search, WinUpdate, Offline Packager, Quit |
| `Show-DriverTable` / `Show-DriverMenu` / `Show-DriverPanel` | Interactive menus |
| `Show-SearchHelp` | Help text |
| `Get-OutputFolder` | Gets/creates download output folder |

### Drivers.psm1 (16 functions)
| Function | Purpose |
|---|---|
| `Get-AllHardwareIDs` | Scans PnP devices, returns deduplicated uppercased HWIDs |
| `Get-ProblemDevices` | Devices with missing/malfunctioning drivers |
| `Get-InstalledDriverSnapshot` | Snapshots installed drivers |
| `Get-UnmatchedLocalDrivers` | Local drivers without API matches |
| `Get-DriverClassification` | Classifies driver types/status |
| `ConvertTo-NormalizedDriverRecord` | Normalizes API responses |
| `Invoke-ApiWithRetry` / `Invoke-ApiFast` | API call with retry |
| `Search-Drivers` | Searches drivers via API |
| `Test-DriverInstalled` | Checks if driver is installed |
| `Get-ApiBase/Get-LfsBatchUrl/Get-ExtractorUrl/Get-SearchApi/Get-GithubHost/Get-ApiHost` | API endpoint getters |

### Download.psm1 (3 functions)
| Function | Purpose |
|---|---|
| `Get-PartUrls` | Builds multi-part archive URL list (`.0001`, `.0002`, ...) |
| `Resolve-LFSPointer` | Resolves Git LFS pointer to real download URL |
| `Get-DriverFile` | Downloads with progress, retry, LFS, SHA-256 |

### Install.psm1 (4 functions)
| Function | Purpose |
|---|---|
| `Invoke-Extractor` | Runs extractor.exe, retries on corrupted binary |
| `Install-DriverPackage` | pnputil install with vendor fallback + rollback |
| `Invoke-SearchDownload` | Download workflow from search results |
| `Invoke-RebootPrompt` | Post-install reboot prompt |

### Cache.psm1 (9 functions)
| Function | Purpose |
|---|---|
| `Build-HwidCache` | Builds HWID cache using runspace pools (parallel) |
| `Build-SearchIndex` | Builds O(1) lookup dictionaries |
| `Get-HwidCache` / `Get-HwidCacheBuilt` / `Get-IndexBuilt` | Cache state accessors |
| `Get-CacheByProvider/Category/Arch/DriverId` | Filtered cache lookups |

### Search.psm1 (7 functions)
| Function | Purpose |
|---|---|
| `Get-RelevanceScore` | Weighted scoring: Exact=100, StartsWith=70, WholeWord=50, Contains=30, HWID=25, Provider=15, Category=10, Version=5 |
| `Get-FuzzyScore` | Sliding-window Levenshtein fuzzy matching |
| `Get-LevenshteinDistance` | Edit distance calculation |
| `Parse-SearchQuery` | Parses `query provider:intel arch:x64 sort:name` |
| `Test-RecordFilter` | Tests record against structured filters |
| `Sort-SearchResults` | Sorts by relevance/name/version |
| `Invoke-WeightedSearch` | Main search entry point (API → cache → fuzzy fallback) |

### DriverDex.ps1 (6 functions + Main)
| Function | Purpose |
|---|---|
| `Set-BlackBackground` | Force black terminal background |
| `Invoke-SearchEngine` | Interactive search REPL |
| `Invoke-ContributePrompt` | Contribution pitch + privacy info |
| `Invoke-ForceWindowsUpdate` | Install pending Windows updates |
| `Invoke-OfflinePackager` | Offline Packager: USB prep, inventory import, installer generation |
| `Main` | Top-level orchestrator |

---

## Offline Packager

### Purpose
For PCs without internet access. Two-step workflow:
1. Prepare USB with scanner files
2. Run scan on air-gapped PC, bring inventory back
3. Generate driver installation package on online PC

### Files
| File | Lines | Purpose |
|---|---|---|
| `offline-packager/scan.cmd` | 10 | USB launcher with auto-elevation, calls scan.ps1 |
| `offline-packager/scan.ps1` | 108 | Standalone hardware scanner, exports inventory.json |

### Menu Entry
- **[P] Offline Packager** in `Show-MainMenu` (UI.psm1)
- **`Invoke-OfflinePackager`** function in DriverDex.ps1

### Workflow Options
| Option | Description |
|---|---|
| 1 - I have inventory.json | User provides path to existing inventory file |
| 2 - Prepare USB for air-gapped PC | Copies scanner files, shows instructions, waits for return |

### USB Detection Features
- 25-second countdown with live USB scanning
- Any key press skips countdown immediately
- Auto-skip if USB detected before countdown ends
- Multiple USB drive selection
- Fallback options if no USB: retry, save to any folder, or go back

### Inventory Path
- Default: `Documents\inventory.json` (via `[Environment]::GetFolderPath('MyDocuments')`)
- Accepts file path or folder path (auto-resolves `folder\inventory.json`)

### Generated Output
| File | Purpose |
|---|---|
| `Install-Offline.cmd` | Double-click batch: auto-elevates + sets execution policy |
| `install_offline.ps1` | Recursive `pnputil /add-driver /subdirs /install` for all `.inf` files |
| `inventory.json` | Original scan data (copied from input) |

### inventory.json Schema
```json
{
    "computer_name": "WORKSTATION-01",
    "timestamp": "2026-07-04T12:00:00.000Z",
    "hardwareids": ["PCI\\VEN_8086&DEV_1502", "USB\\VID_046D&PID_C52B"],
    "device_info": [
        {
            "ClassGuid": "{4d36e972...}",
            "VendorID": "8086",
            "DeviceID": "1502",
            "Name": "Intel(R) Ethernet Connection",
            "InstanceId": "PCI\\VEN_8086&DEV_1502&..."
        }
    ],
    "windows_version": "Microsoft Windows 11 Pro",
    "architecture": "AMD64"
}
```

---

## API Endpoints

| Endpoint | URL | Purpose |
|---|---|---|
| HWID Lookup | `https://driverdex-check.driverdex.workers.dev/api/hwid` | GET, queries by hardware IDs |
| Text Search | `https://driverdex-check.driverdex.workers.dev/api/search` | GET, queries by search term |
| LFS Batch | `https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch` | Git LFS pointer resolution |
| Extractor | `https://raw.githubusercontent.com/rhshourav/DriverDex/refs/heads/main/extractor/extractor.exe` | Downloaded on first run |

---

## Known Bugs & Fixes Applied

### 1. Get-PartUrls returns 'h' instead of full URL
- **File:** `Download.psm1:22`
- **Cause:** `return @($PrimaryUrl)` gets unwrapped to a string by PowerShell
- **Fix:** `return ,@($PrimaryUrl)` — comma operator forces array

### 2. Truncate-Text Unicode ellipsis display issues
- **File:** `Formatting.psm1:77-78`
- **Cause:** Unicode ellipsis `…` (U+2026) caused width calculation issues
- **Fix:** Changed to ASCII `...` with `$target = $MaxWidth - 3`

### 3. Get-FuzzyScore can't handle typos
- **File:** `Search.psm1:109-187`
- **Cause:** Character-by-character matching fails on extra/missing characters
- **Fix:** Rewrote with sliding-window Levenshtein distance + word-based fallback

### 4. [System.Char] * [System.Double] crash
- **File:** `Formatting.psm1`, `UI.psm1`, `Search.psm1`
- **Cause:** `[Math]::Max()` returns `[double]` in PS 5.1; `[char]0x2500` is `[System.Char]`
- **PS 5.1 does NOT support `[char] * [int]` or `[char] * [double]`**
- **Fix:** Cast box chars to `[string][char]0x2500`; cast `[Math]` results to `[int]`

---

## Critical PowerShell 5.1 Gotchas

1. **`[char] * [int]` fails** — Always use `[string][char]0x...` or string literals `'─'`
2. **`[Math]::Max/Min/Ceiling` returns `[double]`** — Cast to `[int]` when used in string ops or array indexing
3. **`return @($x)` unwraps** — Use `,@($x)` to force array
4. **`ConvertFrom-Json` returns Newtonsoft JObject** — Use `Get-Prop` helper, not direct `.Property` access
5. **`Where-Object` may return single item** — Wrap in `@()` before checking `.Count`
6. **No `using namespace`** — Use full type names
7. **No class-based modules** — Use functions only

---

## Search Engine Architecture

```
User Input
  ↓
Parse-SearchQuery (extracts query + inline filters: provider: arch: sort:)
  ↓
Invoke-WeightedSearch
  ├── 1. API Search (text query) → ConvertTo-NormalizedDriverRecord
  ├── 2. API HWID (if query starts with \)
  ├── 3. Cache fallback (Build-SearchIndex → O(1) lookups)
  │     ├── Get-CacheByProvider
  │     ├── Get-CacheByCategory
  │     └── Get-CacheByArch
  ├── 4. Get-RelevanceScore (weighted: exact/starts/contains/word/HWID/provider/category/version)
  ├── 5. Get-FuzzyScore (Levenshtein sliding window, for near-misses)
  ├── 6. Test-RecordFilter (structured filters)
  └── 7. Sort-SearchResults (relevance/name/version)
```

---

## Cache Architecture

- `Build-HwidCache`: Uses runspace pool (max 16 concurrent) with 12-second budget ceiling
- `Build-SearchIndex`: Creates dictionaries for O(1) lookups by provider, category, arch, driverId
- Module-scope state: `$Script:HwidCache`, `$Script:HwidCacheBuilt`, `$Script:IndexBuilt`
- Separate dictionaries: `$Script:ByProvider`, `$Script:ByCategory`, `$Script:ByArch`, `$Script:ByDriverId`

---

## How to Run

```powershell
# Normal mode
powershell.exe -ExecutionPolicy Bypass -File "DriverDex.ps1"

# Admin mode (for full install support)
# Right-click PowerShell → Run as administrator, then:
Set-ExecutionPolicy Bypass -Scope Process
& "C:\Users\...\DriverDex.ps1"
```

---

## Testing Checklist

After any code change, verify:
1. `Import-Module` all 8 modules without errors
2. All exported functions are available via `Get-Command`
3. No `[System.Char] * [System.Int32/Double]` errors (check all `[Math]::` and `[char]` usage)
4. `Get-PartUrls` returns full URL array (not single char)
5. `Truncate-Text` uses ASCII `...` (not Unicode ellipsis)
6. `Get-FuzzyScore` handles typos (e.g., 'intell' vs 'Intel')
7. Search flow works: type query → results table → select → download → extract
8. Offline Packager: `[P]` menu option appears, workflows work, inventory.json parses correctly

---

## Future Improvements to Consider

- [ ] Add unit test framework (Pester)
- [ ] Add `--offline` mode for cached-only searches
- [ ] Add driver backup/restore functionality
- [ ] Add batch install from saved driver list
- [ ] Improve error messages for network failures
- [ ] Add proxy support
- [ ] Add `--json` output mode for scripting
- [ ] Add progress persistence for large inventory downloads
