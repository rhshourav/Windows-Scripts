# PowerShell Menu System Refactoring - Complete Specification

## Overview
This specification details the refactoring of the Windows Scripts menu system from a flat 26-item menu to a hierarchical structure with expandable submenus while preserving all functionality.

## Goal
- **Before**: 26 flat items in single menu level (overwhelming)
- **After**: 9 main items + 3 submenu shortcuts (organized, user-friendly)

## Current vs Desired Structure

### Current Structure (Flat, v27.4.0)
```
MAIN MENU (26 items total)
├── APPLICATIONS (Items: 1, 2, 3, 4, 5, 6, 7, 8)
├── SYSTEM & MAINTENANCE (Items: A, B, C, D, E, F, G, H, I, J, K)
└── HARDWARE & FIXES (Items: L, M, N, O, W, X, Y, Z)
```

### Desired Structure (Hierarchical, v27.5.0)
```
MAIN MENU (9 critical + 3 submenu shortcuts)
├── [1] App Setup Framework (applications)
├── [2] Office 365 (applications) 
├── [3] Office LTSC 2021 (applications)
├── [4] MS Store (LTSC) (applications)
├── [8] RICHO Printer Setup (applications)
├── [A] Activation / Edition Change (system)
├── [B] Time Sync & Format (system)
├── [O] DriverDex Auto Driver Installation (hardware)
├── [X] ERP Setup (hardware)
├── [E] More Applications (⊕3 items) ─┐
├── [S] System & Maintenance Tools (⊕9 items) ─┤
└── [H] Hardware & Driver Tools (⊕6 items) ─┘
└── [Q] Quit
```

## Files to Refactor
1. `windowsScripts.ps1` - Main menu script
2. `unimasScript.ps1` - Secondary version (similar refactoring)

## Core Implementation Requirements

### 1. Navigation State Management
```powershell
# Global navigation state
$CurrentMenuLevel = 'main'
$MenuHistory = @('main')  # Stack for back navigation
```

### 2. Hierarchical Menu Structure
```powershell
$MenuStructure = @{
    'main' = @{
        'display_name' = 'Windows Scripts Toolkit'
        'breadcrumb'   = 'Main'
        'parent'       = $null
        'help_text'    = 'S/E/H = Navigate Submenus | Q = Quit'
        'items' = @{
            '1' = @{ Title = 'App Setup Framework'; Url = '...'; Category = 'applications' }
            '2' = @{ Title = 'Office 365'; Url = '...'; Category = 'applications' }
            # ... other 7 main items
        }
        'submenu_shortcuts' = @(
            @{ Key = 'E'; MenuId = 'applications'; Display = 'More Applications'; Count = 3 }
            @{ Key = 'S'; MenuId = 'system'; Display = 'System & Maintenance Tools'; Count = 9 }
            @{ Key = 'H'; MenuId = 'hardware'; Display = 'Hardware & Driver Tools'; Count = 6 }
        )
    },
    'applications' = @{
        'display_name' = 'Additional Applications'
        'breadcrumb'   = 'Main > Applications'
        'parent'       = 'main'
        'items' = @{
            '1' = @{ Title = 'Install Edge'; Url = '...'; Category = 'applications' }
            '2' = @{ Title = 'Remove Edge'; Url = '...'; Category = 'applications' }
            '3' = @{ Title = 'Remove New Outlook'; Url = '...'; Category = 'applications' }
        }
    },
    # ... 'system' and 'hardware' submenus
}
```

### 3. Key Functions to Implement

#### Phase 1: Data Structure (30 min)
1. `Initialize-MenuStructure()` - Create hierarchical menu data
2. Copy all 26 URLs from original `$Actions` map
3. Organize into 4 menus: main, applications, system, hardware
4. Add metadata (titles, descriptions, categories)

#### Phase 2: Navigation Functions (1 hour)
1. `Set-MenuLevel()` - Change current menu level
2. `Get-ParentMenu()` - Navigate up
3. `Back-ToParentMenu()` - Return to parent (handles `<` key)
4. `Resolve-MenuAction()` - Route user input to correct action

#### Phase 3: Display Functions (45 min)
1. `Show-MenuBreadcrumb()` - Display "Main > Applications > Install Edge"
2. Enhance `Show-Menu()` to accept `MenuLevel` parameter
3. Display submenu indicators in main menu (⊕ 3 items)
4. Show item counts for all submenus

#### Phase 4: Main Loop Modifications (30 min)
1. Integrate new navigation state machine
2. Replace flat `$Actions` lookup with `Resolve-MenuAction()` routing
3. Handle special keys: `<` (back), `Q` (quit), submenu keys (E/S/H)
4. Preserve all existing error handling

### 4. Menu Item Transitions

| Old Key | New Location | New Key |
|---------|--------------|---------|
| 1, 2, 3, 4, 8 | Main Menu | 1, 2, 3, 4, 8 |
| A, B | Main Menu | A, B |
| O, X | Main Menu | O, X |
| 5, 6, 7 | Applications Submenu | 1, 2, 3 |
| C, D, E, F, G, H, I, J, K | System Submenu | 1, 2, 3, 4, 5, 6, 7, 8, 9 |
| L, M, N, W, Y, Z | Hardware Submenu | 1, 2, 3, 4, 5, 6 |

## Key Functions to Preserve

### From Original windowsScripts.ps1
- `Test-IsAdmin()` - Admin check + auto-elevation
- `Start-RemoteScript()` - Remote script launcher
- `Get-SystemStatus()` - Real-time system status display
- `Set-ConsoleCompact()` - Console customization
- `Show-Logo()` - ASCII art logo
- `Write-Rule()` - Line formatting
- `Write-Section()` - Section headers
- `Write-Item()` - Menu item formatting
- All system status logic
- All error handling
- All security features (TLS, IP trust, elevation)

## Implementation Checklist

### Phase 1: Preparation
- [ ] Backup original `windowsScripts.ps1` and `unimasScript.ps1`
- [ ] Review README.md for requirements
- [ ] Create test plan

### Phase 2: Core Navigation (Critical Path)
- [ ] Implement `Initialize-MenuStructure()`
- [ ] Implement `Set-MenuLevel()`
- [ ] Implement `Get-ParentMenu()`
- [ ] Implement `Back-ToParentMenu()`
- [ ] Implement `Resolve-MenuAction()`
- [ ] Test basic navigation

### Phase 3: Display Enhancement
- [ ] Implement `Show-MenuBreadcrumb()`
- [ ] Enhance `Show-Menu()` to accept MenuLevel
- [ ] Add submenu indicators in main menu
- [ ] Test display on all levels

### Phase 4: Integration
- [ ] Replace `$Actions` lookup in main loop
- [ ] Add submenu key handling (E/S/H)
- [ ] Add back button handling (`<`)
- [ ] Preserve all existing functionality

### Phase 5: Testing (Complete)
Test all 7 scenarios:
1. Main menu display + submenu shortcuts
2. Submenu navigation (E/S/H)
3. Submenu item execution
4. Back navigation from submenus
5. System status on all levels
6. Quit from any menu
7. Error handling + performance

## Success Criteria

All 12 criteria must pass:

| ✅ Criteria | Description |
|------------|-------------|
| 1 | Main menu shows 9 items + 3 submenu shortcuts |
| 2 | Submenu navigation works via E/S/H keys |
| 3 | Submenu items use consistent numeric keys (1-9) |
| 4 | Back navigation (`<`) works from all submenus |
| 5 | All 26 scripts execute from correct locations |
| 6 | System status displays on all menu levels |
| 7 | Quit (`Q`) works from any menu level |
| 8 | Performance < 500ms per menu draw |
| 9 | Security: all admin elevation, TLS, IP trust |
| 10 | Breadcrumb shows navigation path |
| 11 | Error messages helpful and context-aware |
| 12 | Code well-documented for maintainers |

## Migration Phases

### Phase 1: Data Structure Only
1. Create `$MenuStructure` hashtable with hierarchical structure
2. Copy all 26 URLs from original `$Actions`
3. Organize into 4 menus: main, applications, system, hardware
4. Build with exactly matching URLs

### Phase 2: Navigation Core
1. Implement 4 navigation functions
2. Test basic navigation between menus
3. Replace main loop action routing

### Phase 3: Display Enhancements
1. Add breadcrumb navigation
2. Enhance main display function
3. Add submenu indicators and counts

### Phase 4: Complete Integration
1. Replace flat menu with hierarchical
2. Test all 26 scripts work correctly
3. Verify system status at all levels
4. Test error handling

### Phase 5: Final Testing & Documentation
1. Run all 7 test scenarios
2. Verify performance (< 500ms)
3. Document all changes
4. Create migration guide

## Testing Scenarios

### Scenario 1: Main Menu Display
- [ ] 9 main items visible
- [ ] 3 submenu shortcuts with item counts (⊕3, ⊕9, ⊕6)
- [ ] System status at top
- [ ] Help text clear: "S/E/H = Navigate Submenus | Q = Quit"

### Scenario 2: Submenu Navigation
- [ ] Press [E] → Navigate to Applications submenu
- [ ] Breadcrumb shows "Main > Applications"
- [ ] Menu shows 3 items with keys [1], [2], [3]
- [ ] Press [<] → Return to Main Menu

### Scenario 3: Submenu Item Execution
- [ ] Press [E] → Applications submenu
- [ ] Press [1] → Execute Install Edge script
- [ ] Verify URL resolves correctly
- [ ] Close subwindow and return to submenu

### Scenario 4: Back Navigation
- [ ] Press [S] → System submenu
- [ ] Press [<] → Return to Main Menu
- [ ] Press [B] → Execute Activation tool
- [ ] Press [S] again → System submenu
- [ ] Press [<] → Main Menu (again)

### Scenario 5: System Status
- [ ] Main menu shows system status
- [ ] Applications submenu shows system status
- [ ] System submenu shows system status
- [ ] Hardware submenu shows system status

### Scenario 6: Quit Function
- [ ] Press [Q] from Main menu → Exit
- [ ] Press [E] → Applications submenu
- [ ] Press [Q] from submenu → Exit
- [ ] Press [S] → System submenu
- [ ] Press [Q] from System submenu → Exit

### Scenario 7: Edge Cases
- [ ] Press main menu key ([1]) while in submenu → No action, error message
- [ ] Press invalid key ([9] in applications submenu) → Error message
- [ ] Press [<] from Main menu → Error message
- [ ] All error messages are helpful

## Performance Requirements

- **Menu Draw Time**: < 500ms (same as original)
- **State Transition**: < 100ms between menus
- **Script Execution**: No change (same remote launching)
- **System Status**: < 100ms (preserve existing optimizations)

## Backward Compatibility

### Must Preserve
- ✅ Auto-elevation logic
- ✅ Remote script launcher
- ✅ System status display
- ✅ Admin checks
- ✅ TLS 1.2 protocol
- ✅ LAN IP zone trust
- ✅ Console customization
- ✅ Error handling
- ✅ iex/irm compatibility

### Interface Changes Only
- ✅ Menu display (hierarchical instead of flat)
- ✅ Navigation (single keys still work)
- ✅ Submenu indicators (new visual elements)
- ✅ Breadcrumb display (new navigation aid)
- ✅ Help text (updated for new structure)

## Design Principles

### Single-Key Navigation
- No multi-key combinations
- All actions still single key
- Submenu shortcuts are single keys (E/S/H)
- Back navigation is single key (`<`)

### Minimal Learning Curve
- Obvious submenu indicators (⊕ 3 items)
- Clear breadcrumb shows location
- Consistent key mappings (1-9 in submenus)
- Help text explains options

### Resilient Design
- All existing error handling preserved
- Graceful fallback for invalid inputs
- Maintain same security features
- Preserve performance characteristics

### Professional Appearance
- Keep same color scheme
- Maintain ASCII art logo
- Consistent formatting
- Professional error messages

## Optional Enhancements (Post-MVP)

1. **Search**: Ctrl+F to search through menu items
2. **Recent**: Track recently used items
3. **Favorites**: Pin frequently used scripts
4. **Config**: Menu configuration file (YAML/JSON)
5. **Multi-column**: Compact main menu layout
6. **Item Counts**: Always show submenu item counts

## Code Structure After Refactoring

### Main Script Structure
```powershell
# ================================================================
#  CONSTANTS & SETUP
# ================================================================
$Script:VER = '27.5.0'
$Script:AUTHOR = 'rhshourav'
$Script:GITHUB = 'https://github.com/rhshourav/Windows-Scripts'
$Script:SELF_URL = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/windowsScripts.ps1'
$Script:TrustedIPs = @('192.168.18.201')
# ... admin check, console setup, telemetry, DriverDex BG

# ================================================================
#  MENU STRUCTURE (NEW HIERARCHICAL)
# ================================================================
$MenuStructure = @{ # 515 lines of hierarchical menu data }

# ================================================================
#  NAVIGATION FUNCTIONS (NEW)
# ================================================================
function Initialize-MenuStructure { ... }
function Set-MenuLevel { ... }
function Get-ParentMenu { ... }
function Back-ToParentMenu { ... }
function Resolve-MenuAction { ... }
function Show-MenuBreadcrumb { ... }

# ================================================================
#  DISPLAY FUNCTIONS (ENHANCED)
# ================================================================
function Show-Menu { ... } # Now accepts MenuLevel parameter
function Show-Menu { ... } # Original preserved

# ================================================================
#  CORE FUNCTIONS (PRESERVED)
# ================================================================
function Get-SystemStatus { ... }
function Start-RemoteScript { ... }
function Test-IsAdmin { ... }
function Set-ConsoleCompact { ... }

# ================================================================
#  MAIN LOOP (MODIFIED)
# ================================================================
while ($true) {
    Show-Menu -MenuLevel $Script:CurrentMenuLevel
    
    # ... input handling updated to use Resolve-MenuAction
    
    switch ($action) {
        'quit' { break }
        'navigate' { Start-Sleep -Milliseconds 300 }
        'execute' { Start-RemoteScript $item.Url $item.Title }
        'invalid' { Write-Host "  [?] No action for key : [$choice]" }
    }
}
```

## Next Steps

### Phase 1: Initial Setup
1. [ ] Read complete specification
2. [ ] Backup original scripts
3. [ ] Create test environment
4. [ ] Plan implementation phases

### Phase 2: Core Navigation
1. [ ] Implement basic menu structure
2. [ ] Test page navigation
3. [ ] Implement display functions
4. [ ] Test full navigation

### Phase 3: Complete Integration
1. [ ] Replace main menu loop
2. [ ] Test all 26 scripts
3. [ ] Performance testing
4. [ ] Documentation

### Phase 4: Final Validation
1. [ ] Run all 7 test scenarios
2. [ ] Verify success criteria
3. [ ] Deploy refactored version
4. [ ] Update documentation

## Resources

### References
- `windowsScripts.ps1:1-616` - Original script structure
- `unimasScript.ps1:1-515` - Secondary script
- `README.md` - Current requirements

### Examples to Study
- `MENU_STRUCTURE_EXAMPLES.md` - Code patterns
- `NAVIGATION_FLOWCHART.md` - Visual diagrams
- `REFACTORING_PROMPT.md` - Detailed requirements

## Critical Path

This refactoring is **not trivial** and requires careful implementation. The critical path is:

1. **Phase 1** (30 min): Menu structure only - copy all URLs correctly
2. **Phase 2** (1 hour): Navigation functions - implement the state machine
3. **Phase 3** (45 min): Display functions - breadcrumb + submenu indicators
4. **Phase 4** (30 min): Main loop replacement - integrate everything
5. **Phase 5** (1-2 hours): Testing - all 7 scenarios
6. **Phase 6** (30 min): Documentation & final validation

**Total Critical Path: 4-7 hours**

## Conclusion

This refactoring transforms the Windows Scripts menu from an overwhelming 26-item flat list into a clean, organized hierarchical interface that's both user-friendly and maintainable. All existing functionality is preserved while significantly improving the user experience.

The key is to follow the conservative approach: implement only what's necessary to achieve the hierarchical structure without changing any execution logic, security features, or performance characteristics.

Complete success requires meticulous attention to detail, thorough testing, and maintaining the high-quality standards that the original script represents.