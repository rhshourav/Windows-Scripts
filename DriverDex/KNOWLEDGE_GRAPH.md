# DriverDex - Knowledge Graph

> Auto-generated comprehensive reference. Covers every file, function, API, data flow, dependency, and integration point.

---

## 1. Architecture Overview

```
+=====================================================================+
|                        LAUNCHER LAYER                               |
|  unimasScript.ps1 (v27.5.0)    windowsScripts.ps1 (v27.4.0)       |
|                                                                     |
|  Menu L: DriverDex Auto       Menu O: DriverDex Auto               |
|  Menu M: DriverDex Manual     BG Startup: DriverDexBG.exe          |
|           |                            |                            |
|           v                            v                            |
|  Download to %TEMP%\DriverDex-{guid}.ps1                           |
|  Execute: powershell.exe -NoProfile -ExecutionPolicy Bypass -File  |
+=====================================================================+
                              |
                              v
+=====================================================================+
|                     DRIVERDEX ENTRY POINTS                          |
|                                                                     |
|  DriverDex.ps1 (v2.4.0)         driverrun.ps1 (v2.2.3)            |
|  MODULAR - 1,556 lines           MONOLITHIC - 3,251 lines          |
|  Imports 8 modules               Self-contained, no deps           |
|  Includes Offline Packager       DO NOT MODIFY                     |
|  Fallback: downloads from GitHub                                   |
+=====================================================================+
                              |
                              v
+=====================================================================+
|                    8 MODULES (Modules/)                             |
|                                                                     |
|  Utils.psm1 ------> Formatting.psm1 ------> UI.psm1               |
|       |                   |                     |                   |
|       v                   v                     v                   |
|  Drivers.psm1        Download.psm1         Install.psm1            |
|       |                   |                     |                   |
|       v                   v                     |                   |
|  Cache.psm1 <------- Search.psm1 <--------------+                  |
+=====================================================================+
                              |
                              v
+=====================================================================+
|                   OFFLINE PACKAGER                                  |
|                                                                     |
|  offline-packager/                                                  |
|    scan.cmd    - USB launcher with auto-elevation (10 lines)       |
|    scan.ps1    - Air-gapped hardware scanner (108 lines)           |
|                                                                     |
|  Invoke-OfflinePackager (in DriverDex.ps1)                        |
|    Workflow selection, USB detection, scanner file copy,           |
|    inventory.json import, dynamic installer generation             |
+=====================================================================+
                              |
                              v
+=====================================================================+
|                      EXTERNAL SERVICES                              |
|                                                                     |
|  DriverDex API (Cloudflare Workers)   GitHub (raw + LFS)           |
|  HWID Lookup: /api/hwid/{id}          Module downloads             |
|  Text Search: /api/search?q=...       Extractor binary             |
|                                     LFS pointer resolution         |
|                                     Contribute scripts             |
+=====================================================================+
```

---

## 2. File Inventory

| File | Lines | Purpose |
|---|---|---|
| DriverDex.ps1 | 1,556 | Modular entry point (v2.4.0), Search Engine REPL, Offline Packager, contribution prompt, Force Windows Update, Main orchestrator |
| driverrun.ps1 | 3,251 | Monolithic entry point (v2.2.3), all functions inline, irm/iex target, DO NOT MODIFY |
| Modules/Utils.psm1 | 444 | Safe property access, array dedup, logging, ANSI detection, TLS, version compare, spinner, elevation, network check |
| Modules/Formatting.psm1 | 582 | Unicode box-drawing tables, column sizing, CJK-aware truncation, pagination, search table, driver detail, progress bar |
| Modules/UI.psm1 | 457 | Semantic output (Write-Step/OK/Warn/Err), branded banners, main menu, driver table/menu/panel, search help, output folder, Offline Packager menu |
| Modules/Drivers.psm1 | 433 | PnP hardware enumeration, API endpoints, driver classification, record normalization, API calls with retry/fast, installed check |
| Modules/Download.psm1 | 199 | Multi-part URL builder, Git LFS pointer resolution, file download with progress/retry/SHA-256 |
| Modules/Install.psm1 | 401 | Extractor runner, driver package installer (pnputil + vendor fallback + rollback), search-mode download+install, reboot prompt |
| Modules/Cache.psm1 | 300 | HWID cache builder (runspace pool, 16 concurrent, 12s budget), O(1) search index (6 dictionaries) |
| Modules/Search.psm1 | 558 | Weighted scoring engine, Levenshtein fuzzy matching, query parser (filters/sort), filter/sort engine, main search function |
| offline-packager/scan.cmd | 10 | USB launcher for air-gapped PCs, auto-elevates, calls scan.ps1 |
| offline-packager/scan.ps1 | 108 | Standalone hardware scanner, exports inventory.json (HWIDs, vendor IDs, class GUIDs, names) |
| README.md | 58 | Quick start, feature overview, requirements |
| KNOWLEDGE_MAP.md | ~270 | Developer knowledge base (predecessor to this file) |
| KNOWLEDGE_GRAPH.md | this file | Comprehensive reference for all components |

---

## 3. Module Dependency Graph (Import Order)

```
Utils.psm1                 [FOUNDATION - no dependencies]
    |
    +---> Formatting.psm1   [depends on: Utils]
    |         |
    |         +---> UI.psm1 [depends on: Utils, Formatting]
    |
    +---> Drivers.psm1      [depends on: Utils]
    |         |
    |         +---> Cache.psm1 [depends on: Utils, Drivers]
    |
    +---> Download.psm1     [depends on: Utils]
    |         |
    |         +---> Install.psm1 [depends on: Utils, Download, UI]
    |
    +---> Search.psm1       [depends on: Utils, Cache]
```

**Import order (critical):**
```
Utils -> Formatting -> UI -> Drivers -> Download -> Install -> Cache -> Search
```

---

## 4. Every Function by Module

### Utils.psm1 (16 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Get-Prop | Obj, Name, Default | Safe property access for PSCustomObject (PS6+) and Newtonsoft JObject (PS5.1) |
| ConvertTo-CleanFieldString | Value, Separator, MaxItems | Split, dedup (case-insensitive), join API fields |
| Join-Unique | InputArray, Separator, Sort, MaxItems | Join unique values from array |
| Write-Log | Level, Msg, Err | Append timestamped line to daily log file |
| Get-LogPath | (none) | Return current log file path |
| Get-AnsiSupported | (none) | Detect ANSI/VT support, cache result |
| Get-ConsoleWidth | (none) | Return console buffer width (60-300, default 120) |
| Initialize-Tls | (none) | Set TLS 1.2 + 1.3 (fallback 1.2 for Win7) |
| Compare-DriverVersion | A, B | Numeric part-by-part version comparison, returns -1/0/1 |
| Show-Spinner | Label | Render one Braille spinner frame on current line |
| Clear-SpinnerLine | (none) | Erase spinner line with spaces |
| Read-Input | Prompt, Default, Validator, ErrMsg | Unified prompt with default, validation (3 attempts), fallback |
| Test-Administrator | (none) | Return true if current process is elevated |
| Get-OSInfo | (none) | Return PSObject: Caption, Build, Version, Arch, PSVersion |
| Request-Elevation | (none) | UAC elevation. If irm/iex, downloads script to temp and relaunches |
| Test-NetworkConnectivity | (none) | DNS-resolve github.com and driverdex-check.driverdex.workers.dev |

### Formatting.psm1 (12 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Get-SafeString | Value, Fallback | Convert any value to display string, handle nulls and arrays |
| Get-DisplayWidth | Text | Return display width accounting for CJK wide chars (2-column) |
| Truncate-Text | Text, MaxWidth | Truncate with ... suffix, CJK-aware |
| Get-ColumnWidths | Headers, Rows, MinWidths, MaxTotal | Compute optimal column widths with proportional compression |
| Draw-Table | Title, Headers, Rows, Colors, IndexColumn, MaxTotalWidth | Full Unicode box-drawing table with auto-sizing |
| Draw-BorderedBox | Lines, Width, Title, Color, Indent | Single/multi-line bordered content box |
| Get-PaginationBar | CurrentPage, TotalPages, WindowSize | Generate pagination indicator |
| Show-SearchTable | Results, Page, PageSize | Paginated search results table with navigation hints |
| Show-DriverDetail | Item | Bordered box showing all driver fields |
| Show-InstallSummary | Results | Bordered box with per-driver status icons and totals |
| Show-ProgressBar | Current, Total, Label, Width | Inline progress bar with percentage |
| Clear-ProgressLine | (none) | Erase progress bar line |

### UI.psm1 (16 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Write-Step | Msg | White arrow message |
| Write-OK | Msg | Green checkmark message |
| Write-Warn | Msg | Yellow warning + logs as WARN |
| Write-Info | Msg | Indented DarkGray message |
| Write-Sub | Msg | Cyan down-arrow message |
| Write-Accent | Msg | Magenta message |
| Write-Divider | (none) | 60-char horizontal line |
| Write-Err | What, Reason, Fix, Err | Structured error: description, reason, fix, log path |
| Write-Header | Version | 78-char branded header with ASCII art logo |
| Write-SearchBanner | (none) | Search Engine branded header |
| Show-MainMenu | (none) | 5-mode menu: Auto/Search/WinUpdate/OfflinePackager/Quit |
| Show-DriverTable | Drivers, ProblemHWIDs | Numbered driver table with install-status coloring |
| Show-DriverMenu | Drivers, ProblemHWIDs | Table + selection prompt (PROBLEMS/UPDATES/ALL/NONE/numbers) |
| Show-DriverPanel | Driver, Idx, Total | Bordered work panel before driver processing |
| Show-SearchHelp | (none) | Full search engine help text |
| Get-OutputFolder | (none) | Prompt for output directory with write test |

### Drivers.psm1 (16 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Get-AllHardwareIDs | (none) | Scan Win32_PnPEntity + pnputil, return uppercased deduped HWIDs |
| Get-ProblemDevices | (none) | HWIDs with ConfigManagerErrorCode > 0 |
| Get-InstalledDriverSnapshot | (none) | Index Win32_PnPSignedDriver by HWID |
| Get-UnmatchedLocalDrivers | AllHWIDs, MatchedDrivers, Snapshot | Find hardware with local drivers not in DriverDex DB |
| Get-DriverClassification | Driver, ProblemHWIDs | Label/color/recommended per driver row |
| ConvertTo-NormalizedDriverRecord | M, MatchedHWID, Score | Convert raw API match to canonical PascalCase PSCustomObject |
| Invoke-ApiWithRetry | HWID | HWID API with 3 retries, exponential backoff |
| Invoke-ApiFast | HWID, ApiBase | Single-shot API call, 8s timeout, no retries |
| Search-Drivers | HWIDs, SystemArch, InstalledSnapshot | Query API for every HWID, tag with InstallStatus |
| Test-DriverInstalled | Provider, Version | Check Win32_PnPSignedDriver for match |
| Get-ApiBase | (none) | Return API_BASE URL |
| Get-LfsBatchUrl | (none) | Return LFS_BATCH_URL |
| Get-ExtractorUrl | (none) | Return EXTRACTOR_URL |
| Get-SearchApi | (none) | Return SEARCH_API URL |
| Get-GithubHost | (none) | Return GITHUB_HOST |
| Get-ApiHost | (none) | Return API_HOST |

### Download.psm1 (3 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Get-PartUrls | PrimaryUrl, ZipParts | Build URL list for multi-part archives |
| Resolve-LFSPointer | PointerPath, LfsBatchUrl | Read Git LFS pointer, POST to batch endpoint, return download info |
| Get-DriverFile | Url, Dest, Label, ExpectedSha256, MaxRetries, LfsBatchUrl | Download with progress, retry, LFS resolution, SHA-256 verify |

### Install.psm1 (4 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Invoke-Extractor | ExtractorPath, ArchivePath, OutputDir | Run extractor.exe, detect corruption, re-download once, retry |
| Install-DriverPackage | Driver, OutputRoot, ScratchDir, ExtractorPath, IsAdmin | Full pipeline: download, extract, manifest, pnputil, vendor fallback |
| Invoke-SearchDownload | Item, OutRoot, ScratchDir, Extractor, IsAdmin, InstallMode | Search-mode download+optional-install |
| Invoke-RebootPrompt | Results | Prompt with 10-second countdown if reboot needed |

### Cache.psm1 (9 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Build-HwidCache | ApiBase, MaxConcurrency, PerCallTimeoutSec, TotalBudgetSec | Scan all HWIDs via runspace pool, 12s budget |
| Build-SearchIndex | Records | Create 6 O(1) lookup dictionaries |
| Get-HwidCache | (none) | Return HWID cache array |
| Get-HwidCacheBuilt | (none) | Return cache built flag |
| Get-IndexBuilt | (none) | Return index built flag |
| Get-CacheByProvider | Provider | O(1) lookup by provider |
| Get-CacheByCategory | Category | O(1) lookup by category |
| Get-CacheByArch | Arch | O(1) lookup by architecture |
| Get-CacheByDriverId | DriverId | O(1) lookup by driver ID |

### Search.psm1 (7 functions)

| Function | Parameters | Purpose |
|---|---|---|
| Get-RelevanceScore | Record, Query | Weighted scoring: Exact=100, StartsWith=70, WholeWord=50, Contains=30, HWID=25, Provider=15, Category=10, Version=5 |
| Get-FuzzyScore | Text, Query | Sliding-window Levenshtein distance (0.0-1.0), requires >= 50% similarity |
| Get-LevenshteinDistance | Source, Target | Two-row DP Levenshtein edit distance |
| Parse-SearchQuery | InputText | Extract sort:, provider:, arch:, category:, version:, hardwareid:, name: filters |
| Test-RecordFilter | Record, Filters | Test record against all structured filters |
| Sort-SearchResults | Results, SortBy, Descending | Sort by name/provider/version/date/score/arch/category |
| Invoke-WeightedSearch | Query, Arch, Category | Main search: parse -> API -> cache fallback -> score -> filter -> sort |

### DriverDex.ps1 (6 functions + Main)

| Function | Parameters | Purpose |
|---|---|---|
| Set-BlackBackground | Restore | Force black terminal background |
| Invoke-SearchEngine | IsAdmin, ScratchDir | Interactive search REPL |
| Invoke-ContributePrompt | HWIDs, Reason, UnmatchedLocalDrivers | Show contribution pitch + privacy info |
| Invoke-ForceWindowsUpdate | IsAdmin | Install pending Windows updates |
| Invoke-OfflinePackager | IsAdmin | Offline Packager: workflow selection, USB prep, inventory import, installer generation |
| Main | (none) | Top-level orchestrator |

### Offline Packager Files

| File | Lines | Purpose |
|---|---|---|
| offline-packager/scan.cmd | 10 | USB launcher with auto-elevation, calls scan.ps1 via PowerShell |
| offline-packager/scan.ps1 | 108 | Standalone hardware scanner for air-gapped PCs, exports inventory.json |

---

## 5. All API Endpoints and URLs

| Service | URL | Method | Purpose |
|---|---|---|---|
| HWID Lookup | https://driverdex-check.driverdex.workers.dev/api/hwid/{encoded_hwid} | GET | Query drivers by hardware ID |
| Text Search | https://driverdex-check.driverdex.workers.dev/api/search?q={query}&arch={arch}&category={cat} | GET | Query drivers by keyword |
| LFS Batch | https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch | POST | Resolve Git LFS pointers to real downloads |
| Extractor Binary | https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/extractor/extractor.exe | GET | Downloaded on first run (13MB) |
| Elevation Script | https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex/driverrun.ps1 | GET | Downloaded for UAC elevation relaunch |
| Contribute TUI | https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/run.ps1 | GET | Interactive contribution walkthrough |
| Contribute BG | https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/contribute/bg/run_bg.ps1 | GET | Silent background contribution |
| Module Downloads | https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex/Modules/{mod}.psm1 | GET | Downloaded when run via irm/iex |
| DriverDexBG EXE | https://github.com/rhshourav/driverdex/releases/latest/download/DriverDexBG.exe | GET | Background driver installer, launched by launchers |

### DNS Check Targets
- github.com
- driverdex-check.driverdex.workers.dev

---

## 6. Data Flow Diagrams

### 6A. Auto-Detect Flow (Main Path)

```
Main()
  |
  +-> Initialize-Tls()
  +-> Write-Header()                          [UI]
  +-> Show-MainMenu() -> returns 'auto'       [UI]
  +-> Request-Elevation() if not admin        [Utils]
  +-> Test-NetworkConnectivity()              [Utils]
  +-> Get-AllHardwareIDs()                    [Drivers]
  |     Win32_PnPEntity (CIM/WMI fallback)
  |     + pnputil /enum-devices
  |     -> string[] of uppercased HWIDs
  |
  +-> Get-ProblemDevices()                    [Drivers]
  |     -> HWIDs with ConfigManagerErrorCode > 0
  |
  +-> Get-InstalledDriverSnapshot()           [Drivers]
  |     -> hashtable: HWID -> {Provider,Version,DeviceName,DriverDate}
  |
  +-> Search-Drivers(, , )    [Drivers]
  |     For each HWID:
  |       Invoke-ApiWithRetry()               [Drivers]
  |         GET /api/hwid/{hwid}
  |     Cross-reference snapshot:
  |       Compare-DriverVersion()             [Utils]
  |       -> InstallStatus: NEW/UPDATE/CURRENT/NEWER
  |     -> [pscustomobject[]] with 15+ fields
  |
  +-> Get-UnmatchedLocalDrivers()             [Drivers]
  +-> Show-DriverMenu()                       [UI]
  |     Show-DriverTable() + selection
  |
  +-> Get-OutputFolder()                      [UI]
  +-> Get-DriverFile(extractor)               [Download]
  |
  +-> For each selected driver:
  |     Show-DriverPanel()                    [UI]
  |     Install-DriverPackage()               [Install]
  |       Get-PartUrls()                      [Download]
  |       Get-DriverFile() per part           [Download]
  |         LFS detection + Resolve-LFSPointer()
  |       Invoke-Extractor()                  [Install]
  |       Write manifest.json
  |       pnputil /add-driver /subdirs /install
  |       Test-DriverInstalled()              [Drivers]
  |
  +-> Show-InstallSummary()                   [Formatting]
  +-> Invoke-RebootPrompt()                   [Install]
  +-> Invoke-ContributePrompt()               [DriverDex.ps1]
```

### 6B. Search Engine Flow

```
Invoke-SearchEngine()
  |
  +-> Set-BlackBackground()
  +-> Write-SearchBanner()                    [UI]
  +-> Get-OutputFolder()                      [UI]
  +-> Get-DriverFile(extractor)               [Download]
  |
  +-- REPL Loop:
        Read input -> switch dispatch:
          |
          +-> "help" -> Show-SearchHelp()
          +-> "n/p/first/last/g<N>" -> pagination
          +-> "filter" -> set arch+category, re-search
          +-> "sort:<field>" -> Sort-SearchResults()
          +-> "det<N>" -> Show-DriverDetail()
          +-> "d<N>" -> Invoke-SearchDownload(download)
          +-> "i<N>" -> Invoke-SearchDownload(install)
          +-> "<number>" -> Show-DriverDetail + d/i/x
          +-> "s <query>" or default:
                |
                +-> Invoke-WeightedSearch()     [Search]
                      Parse-SearchQuery()
                      HWID detection (\ in query)
                        GET /api/hwid/{query}
                      Text search
                        GET /api/search?q={query}
                      Cache fallback:
                        Build-HwidCache()       [Cache]
                          Runspace pool, 16 concurrent
                        Build-SearchIndex()
                          6 O(1) dictionaries
                      Get-RelevanceScore() per record
                      Get-FuzzyScore() bonus (Levenshtein)
                      Test-RecordFilter() per record
                      Sort-SearchResults()
                |
                +-> Show-SearchTable()          [Formatting]
```

### 6C. Launcher Flow

```
User selects menu item (L/M/O)
  |
  +-> Start-RemoteScript(Url, Title)
        |
        +-> Create inner script (base64-encoded)
        |     TLS 1.2 setup
        |     Zone mapping for LAN IPs
        |     UI setup (black bg, white text)
        |     Download script to temp file:
        |        = %TEMP%\DriverDex-{guid}.ps1
        |       Net.WebClient.DownloadFile(Url, tmpScript)
        |     Execute: powershell.exe -NoProfile -ExecutionPolicy Bypass -File 
        |     Cleanup temp file
        |
        +-> Start-Process powershell.exe -EncodedCommand <base64>
```

### 6D. Offline Packager Flow

```
Invoke-OfflinePackager()
  |
  +-> Show workflow menu:
  |     [1] I already have inventory.json
  |     [2] Prepare USB for air-gapped PC
  |
  +-> If Option 2 (USB Prep):
  |     Show 25-second countdown (any key to skip)
  |     Live USB detection during countdown
  |     If USB detected early -> skip countdown
  |
  |     If no USB found:
  |       [1] Retry detection
  |       [2] Save scanner files to any folder
  |       [3] Go back, provide path manually
  |
  |     If USB found:
  |       Single USB -> auto-select
  |       Multiple USBs -> let user choose
  |
  |     Copy scan.cmd + scan.ps1 to USB/DriverDex-Scanner/
  |     Show 6-step instructions for air-gapped PC
  |     Wait for user to return with inventory.json
  |
  +-> Prompt for inventory.json path (default: Documents)
  |     Accepts file path or folder path
  |     Resolves folder -> looks for inventory.json inside
  |
  +-> Parse inventory.json
  |     Validate JSON structure
  |     Extract HWID list from inventory
  |
  +-> Build driver catalog
  |     Query API for each HWID
  |     Group by category + architecture
  |     Rank: problem > missing > outdated > current
  |
  +-> Show catalog summary table
  |
  +-> Get-OutputFolder()
  |
  +-> Download all drivers
  |     Show-ProgressBar() per driver
  |     Get-DriverFile() per part
  |
  +-> Generate output files:
  |     Install-Offline.cmd     - Double-click installer (elevation + policy)
  |     install_offline.ps1     - Recursive pnputil /add-driver /subdirs /install
  |     inventory.json          - Original scan data
  |
  +-> Show final summary
```

---

## 7. Configuration Constants

### DriverDex.ps1

| Variable | Value |
|---|---|
| VERSION | 2.4.0 |
| GITHUB_RAW | https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex |

### driverrun.ps1 / Drivers.psm1

| Variable | Value |
|---|---|
| VERSION | 2.2.3 |
| API_BASE | https://driverdex-check.driverdex.workers.dev/api/hwid |
| SEARCH_API | https://driverdex-check.driverdex.workers.dev/api/search |
| LFS_BATCH_URL | https://github.com/rhshourav/driverdex.git/info/lfs/objects/batch |
| EXTRACTOR_URL | https://raw.githubusercontent.com/rhshourav/driverdex/refs/heads/main/extractor/extractor.exe |
| API_HOST | driverdex-check.driverdex.workers.dev |
| GITHUB_HOST | github.com |

### Cache.psm1

| Variable | Default | Purpose |
|---|---|---|
| HwidCache | null | All driver records from local HWIDs |
| HwidCacheBuilt | false | Cache complete flag |
| IndexByProvider | {} | O(1) provider lookup |
| IndexByCategory | {} | O(1) category lookup |
| IndexByArch | {} | O(1) arch lookup |
| IndexByName | {} | O(1) name/token lookup |
| IndexByHWID | {} | O(1) HWID lookup |
| IndexByDriverId | {} | O(1) driver ID lookup |

### Search.psm1

| Weight | Value |
|---|---|
| ExactMatch | 100 |
| StartsWith | 70 |
| WholeWord | 50 |
| Contains | 30 |
| HardwareID | 25 |
| ProviderMatch | 15 |
| CategoryMatch | 10 |
| VersionMatch | 5 |

### Utils.psm1

| Variable | Value |
|---|---|
| SpinnerFrames | Braille chars (0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) |
| LogPath | %TEMP%\DriverDex-YYYYMMDD.log |
| ConsoleWidth | 120 (default) |

---

## 8. Error Handling Patterns

| Pattern | Where | Description |
|---|---|---|
| Structured Error Display | Write-Err (UI) | Three-part: What failed / Reason / Fix / Log. Raw exceptions never shown. |
| CIM/WMI Fallback | Get-AllHardwareIDs, Get-InstalledDriverSnapshot | Try Get-CimInstance, catch -> Get-WmiObject (Win7 compat) |
| API Retry + Backoff | Invoke-ApiWithRetry | 3 attempts, delays 2s/4s/8s, returns null on exhaustion |
| API Fast (no retry) | Invoke-ApiFast | Single shot, 8s timeout (for cache building) |
| Download Retry | Get-DriverFile | 3 attempts, delays 2s/4s/8s, throws after exhaustion |
| Extractor Corruption | Invoke-Extractor | Detects PYI-ERROR, re-downloads binary once, retries |
| StrictMode Guard | Get-Prop | Handles both Newtonsoft JObject (PS5.1) and PSCustomObject (PS6+) |
| Nested try/catch/finally | Main | Outer: session safety net. Inner: auto-detect flow. Finally: always runs contribute prompt + cleanup |
| Best-Effort Operations | Various | -ErrorAction SilentlyContinue for non-critical: log writes, disk checks, manifest updates |
| Offline Packager Fallbacks | Invoke-OfflinePackager | USB detection timeout, inventory path resolution, folder-or-file input handling |

---

## 9. PowerShell 5.1 Compatibility Fixes

| Issue | Fix |
|---|---|
| [char] * [int] crashes | [string][char]0x... casts |
| [Math]::Max/Min returns [double] | [int] casts |
| return @() unwraps | ,@() comma operator |
| ConvertFrom-Json returns Newtonsoft JObject | Get-Prop helper |
| Where-Object may return single item | @() wrapper before .Count |
| No using namespace | Full type names everywhere |
| No class-based modules | Functions only |

---

## 10. Launcher Integration

### unimasScript.ps1 (v27.5.0)

| Feature | Details |
|---|---|
| BG Startup (lines 88-89) | Downloads + runs DriverDexBG.exe from GitHub releases |
| Menu L | DriverDex Auto Driver Install -> DriverDex.ps1 |
| Menu M | DriverDex Manual Search & Install -> DriverDex.ps1 |
| Execution | Downloads to %TEMP%\DriverDex-{guid}.ps1, runs via -File |

### windowsScripts.ps1 (v27.4.0)

| Feature | Details |
|---|---|
| BG Contribution (line 220) | Launches contribute/bg/run_bg.ps1 in hidden window |
| Menu O | DriverDex Auto Driver Installation -> DriverDex.ps1 |
| Execution | Downloads to %TEMP%\DriverDex-{guid}.ps1, runs via -File |

---

## 11. Offline Packager

### Overview
For PCs without internet access. Scans hardware on the offline machine, brings the inventory back to an online PC, and generates a driver installation package.

### Menu Entry
- **Main Menu [P]**: `Show-MainMenu` in UI.psm1 (line ~217)
- **Function**: `Invoke-OfflinePackager` in DriverDex.ps1

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

### Inventory Path Resolution
- Default: `Documents\inventory.json` (via `[Environment]::GetFolderPath('MyDocuments')`)
- Accepts file path (used directly) or folder path (auto-looks for `inventory.json` inside)

### Generated Output Files
| File | Purpose |
|---|---|
| `Install-Offline.cmd` | Double-click batch file, auto-elevates, sets PowerShell execution policy |
| `install_offline.ps1` | Recursive pnputil install: finds all `.inf` files in subfolders, installs each |
| `inventory.json` | Original scan data (copied from input) |

### scan.ps1 Inventory Data
| Field | Source |
|---|---|
| computer_name | `$env:COMPUTERNAME` |
| timestamp | ISO 8601 format |
| hardwareids | Win32_PnPEntity + pnputil /enum-devices |
| device_info | ClassGuid, VendorID, DeviceID, Name, InstanceId |
| windows_version | Win32_OperatingSystem Caption + BuildNumber |
| architecture | `$env:PROCESSOR_ARCHITECTURE` |

---

## 12. Contribute System

### Trigger
- Shown in every exit path of auto-detect flow via finally block
- Also shown after Search Engine and Force Windows Update sessions

### State Variables

| Variable | Purpose |
|---|---|
| ContribHWIDs | All hardware IDs found |
| ContribUnmatched | Devices with local drivers not in DB |
| ContribReason | no_drivers or partial |
| ContribShouldPrompt | Set false on hard pre-HWID failures |

### What Gets Submitted
- Hardware IDs (PCI\VEN_..., USB\VID_...)
- Device categories and friendly names
- Installed driver versions (Provider, Version, Date)
- Windows version and architecture

### What Does NOT Get Submitted
- Name, username, IP, files, serial numbers, MAC addresses

### Two Modes
1. **TUI**: Downloads + runs contribute/run.ps1 (interactive)
2. **Background**: Downloads + runs contribute/bg/run_bg.ps1 (silent, <30s)

---

## 13. manifest.json Schema

Each installed driver package produces:

```json
{
    "driver_id": "...",
    "display_name": "...",
    "provider": "...",
    "category": "...",
    "version": "...",
    "arch": "...",
    "matched_hwid": "...",
    "sha256_parts": [],
    "installed_on": "2026-...",
    "install_result": "success|partial|failed",
    "pnputil_exit": 0,
    "reboot_required": false,
    "generated_by": "DriverDex v2.4.0"
}
```

---

## 14. inventory.json Schema

Produced by `scan.ps1` on air-gapped PCs:

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

## 15. Known Issues

1. **Elevation URL in Utils.psm1** points to driverrun.ps1 (not DriverDex.ps1) for UAC relaunch
2. **GitHub may cache contributors** from force-pushed commits with Co-authored-By trailers
3. **DriverDex.ps1 module download** can fail if GitHub is slow; 8 sequential HTTP requests
4. **Search results can be garbled** if module imports fail silently
5. **extractor.exe 404** when driver files not uploaded to LFS storage
6. **scan.ps1 requires PowerShell 5.1+** on the air-gapped PC (standard on Win10/11)
