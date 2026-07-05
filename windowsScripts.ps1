<#
  ================================================================
   Windows Scripts  -  Main Menu Launcher
   Author  : rhshourav
   GitHub  : https://github.com/rhshourav/Windows-Scripts
   Version : 27.6.0
   Notes   : iex/irm compatible, auto-elevates, single-key nav,
             launches sub-scripts in new elevated windows,
             temporarily adds LAN IPs to Local Intranet zone,
             real-time system status on every draw.

   v27.5.0 CHANGE LOG (Menu Hierarchy Refactor)
   ---------------------------------------------
   - Flat 26-item menu replaced with a 3-level hierarchy:
       Main Menu (9 critical items + 3 submenu shortcuts)
         |-- [E] More Applications        (3 items)
         |-- [S] System & Maintenance     (9 items)
         `-- [H] Hardware & Drivers       (6 items)
   - New data-driven $MenuStructure hashtable replaces the old
     flat $Actions map. Data is now fully separated from logic.
   - New navigation functions: Set-MenuLevel, Get-ParentMenu,
     Back-ToParentMenu, Get-ValidKeysForLevel, Resolve-MenuAction.
   - Show-Menu now renders any menu level, with a breadcrumb and
     context-aware help text.
   - Back navigation: 'Esc' or 'B' from any submenu returns to Main.
   - All 26 original URLs, elevation logic, remote script launcher,
     system status display, TLS 1.2 enforcement, LAN IP trust, and
     console customization are unchanged.

   HOW TO ADD A NEW SUBMENU (example - "Network Tools"):
       $MenuStructure['network'] = @{
           display_name = 'Network Tools'
           breadcrumb   = 'Main > Network'
           parent       = 'main'
           help_text    = 'Select tool  |  Esc = Back to Main  |  Q = Quit'
           items = @{
               '1' = @{ Title = 'Network Diagnostic'; Url = 'https://...' }
           }
       }
       $MenuStructure.main.submenu_shortcuts += @{
           Key = 'N'; MenuId = 'network'; Display = 'Network Tools'; Count = 1
       }
       # Done. Show-Menu and Resolve-MenuAction pick this up automatically.

   HOW TO ADD A NEW ITEM to an existing submenu (example):
       $MenuStructure.hardware.items['7'] = @{
           Title = 'Install CPU-Z'; Url = 'https://...'
       }
  ================================================================
#>

# Runtime version guard (compatible with iex irm, avoids #Requires issues)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host '' 
    Write-Host '  [!] PowerShell 5.0 or higher is required.' -ForegroundColor Red
    Write-Host '      This system has: PowerShell ' -NoNewline -ForegroundColor DarkRed
    Write-Host $PSVersionTable.PSVersion.ToString() -ForegroundColor Red
    Write-Host ''
    Write-Host '  Press any key to exit ...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 3 }
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ================================================================
#  CONSTANTS
# ================================================================
$Script:VER    = '27.6.1'
$Script:AUTHOR = 'rhshourav'
$Script:GITHUB = 'https://github.com/rhshourav/Windows-Scripts'

# URL used ONLY when launched via iex/irm and elevation is needed
$Script:SELF_URL = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1'

# LAN share host(s) to temporarily trust as Local Intranet per child window
$Script:TrustedIPs = @('192.168.18.201')

# ================================================================
#  ADMIN CHECK + AUTO-ELEVATE  (iex/irm safe)
# ================================================================
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsAdmin)) {
    try {
        Write-Host ''
        Write-Host '  [!] Requires Administrator privileges.  Relaunching elevated ...' -ForegroundColor Yellow
        Write-Host ''

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        if ([string]::IsNullOrEmpty($PSCommandPath)) {
            $tmpPath = Join-Path $env:TEMP 'WinScripts_Launcher.ps1'
            try {
                # DownloadString returns a .NET Unicode string; WriteAllText with Encoding.UTF8
                # writes a UTF-8 BOM so PS5 always reads the temp file as UTF-8, not Windows-1252.
                $rawText = (New-Object Net.WebClient).DownloadString($Script:SELF_URL)
                [IO.File]::WriteAllText($tmpPath, $rawText, [Text.Encoding]::UTF8)
                $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$tmpPath`"")
            } catch {
                $escaped = $Script:SELF_URL -replace "'", "''"
                $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command',
                    "try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {}; iex (irm '$escaped' -UseBasicParsing)")
            }
        } else {
            $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs -ErrorAction Stop

    } catch {
        Write-Host ''
        Write-Host '  [!] Elevation failed or was cancelled.' -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
        Write-Host ''
        Write-Host '  Press any key to exit ...' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 3 }
    }
    exit
}

# ================================================================
#  CONSOLE SETUP
# ================================================================
if (-not ('ConsoleNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ConsoleNative
{
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct SMALL_RECT
    {
        public short Left;
        public short Top;
        public short Right;
        public short Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX
    {
        public uint cbSize;
        public uint nFont;
        public COORD dwFontSize;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]
        public string FaceName;
    }

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetCurrentConsoleFontEx(
        IntPtr consoleOutput,
        bool maximumWindow,
        ref CONSOLE_FONT_INFOEX consoleCurrentFontEx);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
}
"@
}

function Set-ConsoleCompact {
    param(
        [int]$Width = 105,
        [int]$Height = 72,
        [int]$FontW = 6,
        [int]$FontH = 10
    )

    try {
        $raw = $Host.UI.RawUI
        $hwnd = [ConsoleNative]::GetConsoleWindow()

        # Keep the window smaller, not fullscreen
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][ConsoleNative]::MoveWindow($hwnd, 40, 40, 980, 760, $true)
            Start-Sleep -Milliseconds 100
        }

        # Buffer must be larger than the window
        $raw.BufferSize = New-Object Management.Automation.Host.Size($Width, 2000)
        $raw.WindowSize = New-Object Management.Automation.Host.Size($Width, $Height)

        # Try to set a smaller console font (classic console host only)
        try {
            $hOut = [ConsoleNative]::GetStdHandle(-11) # STD_OUTPUT_HANDLE
            $font = New-Object ConsoleNative+CONSOLE_FONT_INFOEX
            $font.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]([ConsoleNative+CONSOLE_FONT_INFOEX]))
            $font.nFont = 0
            $font.dwFontSize = New-Object ConsoleNative+COORD
            $font.dwFontSize.X = [int16]$FontW
            $font.dwFontSize.Y = [int16]$FontH
            $font.FontFamily = 54
            $font.FontWeight = 400
            $font.FaceName = "Consolas"
            [void][ConsoleNative]::SetCurrentConsoleFontEx($hOut, $false, [ref]$font)
        } catch {}

        try { $raw.WindowTitle = "Windows Scripts v$($Script:VER) | $env:COMPUTERNAME" } catch {}
    }
    catch {
        try { cmd /c "mode con: cols=105 lines=72" | Out-Null } catch {}
    }
}

Set-ConsoleCompact -Width 105 -Height 62 -FontW 6 -FontH 10
Clear-Host

# ================================================================
#  TELEMETRY
# ================================================================
try {
    $localIPs = @()
    try {
        $localIPs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique
    } catch {}

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $body = (@{
        token = 'shourav'
        text  = "Windows Scripts v$($Script:VER)`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}


# ================================================================
#  REAL-TIME SYSTEM STATUS  (Highly resilient to WMI/CIM failures)
# ================================================================
function Get-SystemStatus {
    $line1 = New-Object System.Collections.ArrayList
    $line2 = New-Object System.Collections.ArrayList

    # --- 1. CPU ---
    try {
        $cpu = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $cpu) { throw "Null CPU" }
        [void]$line1.Add("CPU: $($cpu)%")
    } catch {
        try {
            $cpu = (Get-WmiObject -Class Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -eq $cpu) { throw "Null CPU" }
            [void]$line1.Add("CPU: $($cpu)%")
        } catch { [void]$line1.Add("CPU: N/A") }
    }

    # --- 2. RAM ---
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $tot = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
        $fre = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
        $use = $tot - $fre
        $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
        [void]$line1.Add("RAM: ${use}/${tot}GB ($pct%)")
    } catch {
        try {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            $tot = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
            $fre = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
            $use = $tot - $fre
            $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
            [void]$line1.Add("RAM: ${use}/${tot}GB ($pct%)")
        } catch { [void]$line1.Add("RAM: N/A") }
    }

    # --- 3. DISK (C:) ---
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $tot = [math]::Round($disk.Size / 1GB, 1)
        $fre = [math]::Round($disk.FreeSpace / 1GB, 1)
        $use = $tot - $fre
        $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
        [void]$line1.Add("C: ${use}/${tot}GB ($pct%)")
    } catch {
        try {
            $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $tot = [math]::Round($disk.Size / 1GB, 1)
            $fre = [math]::Round($disk.FreeSpace / 1GB, 1)
            $use = $tot - $fre
            $pct = if ($tot -gt 0) { [math]::Round(($use / $tot) * 100) } else { 0 }
            [void]$line1.Add("C: ${use}/${tot}GB ($pct%)")
        } catch { [void]$line1.Add("C: N/A") }
    }

    # --- 4. UPTIME ---
    $bootTime = $null
    try {
        $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        try {
            $osWmi = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            $bootTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($osWmi.LastBootUpTime)
        } catch {}
    }
    if ($bootTime) {
        $up = (Get-Date) - $bootTime
        [void]$line2.Add(("UP: {0}d {1:D2}h {2:D2}m" -f $up.Days, $up.Hours, $up.Minutes))
    } else {
        [void]$line2.Add("UP: N/A")
    }

    # --- 5. IP ADDRESS ---
    try {
        $ip = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
               Where-Object { $_.IPAddress[0] -notmatch '^169\.|^127\.' } | Select-Object -First 1).IPAddress[0]
        if (!$ip) { throw "No IP" }
        [void]$line2.Add("IP: $ip")
    } catch {
        try {
            $ip = (Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
                   Where-Object { $_.IPAddress[0] -notmatch '^169\.|^127\.' } | Select-Object -First 1).IPAddress[0]
            if (!$ip) { throw "No IP" }
            [void]$line2.Add("IP: $ip")
        } catch {
            try {
                $ip = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 -ExpandProperty IPAddressToString
                if ($ip) { [void]$line2.Add("IP: $ip") } else { [void]$line2.Add("IP: N/A") }
            } catch { [void]$line2.Add("IP: N/A") }
        }
    }

    return @(
        ($line1 -join '   |   '),
        ($line2 -join '   |   ')
    )
}

# ================================================================
#  DISPLAY HELPERS
# ================================================================
$Script:LINE_WIDTH = 75

function Write-Rule {
    param([string]$Char = '-', [string]$Color = 'DarkCyan')
    Write-Host ('  ' + ($Char * $Script:LINE_WIDTH)) -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("  " + ('-' * $Title.Length)) -ForegroundColor DarkYellow
}

function Write-Item {
    param([string]$Key, [string]$Desc, [string]$Tag = '')
    Write-Host '  ' -NoNewline
    Write-Host " $Key " -ForegroundColor Black -BackgroundColor DarkGreen -NoNewline
    Write-Host '  ' -NoNewline
    Write-Host $Desc -ForegroundColor White -NoNewline
    if ($Tag) { Write-Host "  $Tag" -ForegroundColor DarkGray } else { Write-Host '' }
}

# ================================================================
#  LOGO  (Large ASCII Art matching requested style)
# ================================================================
function Show-Logo {
    Write-Host ''
Write-Host '  ________________________________________________________________' -ForegroundColor DarkCyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |                                __                              |' -ForegroundColor Cyan
Write-Host ' | \    / o ._   _|  _        _  (_   _ ._ o ._ _|_  _            |' -ForegroundColor Cyan
Write-Host ' |  \/\/  | | | (_| (_) \/\/ _>  __) (_ |  | |_) |_ _>            |' -ForegroundColor Cyan
Write-Host ' |                                           |                    |' -ForegroundColor Cyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |              Windows Script Toolkit for Windows                |' -ForegroundColor Gray
Write-Host ' |              ----------------------------------                |' -ForegroundColor DarkGray
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |________________________________________________________________|' -ForegroundColor DarkCyan
Write-Host ''
}

# ================================================================
#  FULL MENU DRAW  (hierarchy-aware: renders any menu level)
# ================================================================
function Show-Menu {
    param(
        [string]$MenuLevel = $Script:CurrentMenuLevel
    )

    try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'White' } catch {}
    Clear-Host

    Show-Logo

    # Meta bar
    Write-Host "  Author : $($Script:AUTHOR)   Version : $($Script:VER)" -ForegroundColor DarkCyan
    Write-Host "  GitHub : $($Script:GITHUB)" -ForegroundColor DarkCyan
    Write-Rule '=' 'Cyan'

    # System status (live multi-line arrays from Get-SystemStatus) - shown on every level
    $statusLines = Get-SystemStatus
    foreach ($line in $statusLines) {
        Write-Host "  $line" -ForegroundColor DarkGreen
    }
    Write-Rule '-' 'DarkCyan'

    Write-Host "  HOST : $env:COMPUTERNAME   USER : $env:USERNAME @ $env:USERDOMAIN" -ForegroundColor Gray
    Write-Rule '=' 'Cyan'
    Write-Host ''

    $menuData = $MenuStructure[$MenuLevel]
    if (-not $menuData) {
        # Defensive fallback - should never happen, but never crash the menu
        $MenuLevel = 'main'
        $menuData  = $MenuStructure['main']
    }

    # Breadcrumb (submenus only)
    if ($MenuLevel -ne 'main') {
        Write-Host '  Location : ' -NoNewline -ForegroundColor Cyan
        Write-Host $menuData.breadcrumb -ForegroundColor Yellow
        Write-Host ''
    }

    # Section title for this level
    Write-Section ($menuData.display_name.ToUpperInvariant())

    # Back link (submenus only)
    if ($MenuLevel -ne 'main') {
        Write-Item 'Esc' 'Back to Main Menu'
        Write-Host ''
    }

    # Items for this level (sorted so numeric/alpha keys draw in a stable order)
    foreach ($key in ($menuData.items.Keys | Sort-Object)) {
        $item = $menuData.items[$key]
        $tag  = if ($item.ContainsKey('Tag')) { $item.Tag } else { '' }
        Write-Item $key $item.Title $tag
    }

    # Submenu shortcuts (main menu only)
    if ($MenuLevel -eq 'main' -and $menuData.ContainsKey('submenu_shortcuts')) {
        Write-Host ''
        Write-Section 'QUICK ACCESS SUBMENUS'
        foreach ($submenu in $menuData.submenu_shortcuts) {
            Write-Item $submenu.Key "$($submenu.Display)" "[>> $($submenu.Count) items]"
        }
    }

    Write-Host ''
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Q ' -ForegroundColor Black -BackgroundColor DarkRed -NoNewline
    Write-Host '  Quit' -ForegroundColor Red
    Write-Host ''
    Write-Host "  $($menuData.help_text)" -ForegroundColor Green
    Write-Host ''
    Write-Host -NoNewline '  Select > ' -ForegroundColor Green
}

# ================================================================
#  REMOTE SCRIPT LAUNCHER
# ================================================================
function Start-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Title
    )

    try {
        # Ensure TLS 1.2 is used for the session
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

        # Prepare the Trusted IPs for the child window
        # (Using the variable name from your v3.0.0 script)
        $ipsLiteral = ($Script:TrustedIPs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','

        # This is the exact logic from your script, formatted for encoding
        $innerScript = @"
`$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- TEMP: Add LAN IP(s) to Local Intranet Zone (HKCU) ---
`$__ZoneKeys = New-Object System.Collections.Generic.List[string]
function Add-IntranetIP([string]`$ip) {
    `$base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges'
    `$k    = Join-Path `$base ('Range_' + [guid]::NewGuid().ToString('N'))
    New-Item -Path `$k -Force | Out-Null
    New-ItemProperty -Path `$k -Name ':Range' -Value `$ip -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$k -Name '*' -Value 1 -PropertyType DWord -Force | Out-Null
    `$__ZoneKeys.Add(`$k) | Out-Null
}
foreach (`$ip in @($ipsLiteral)) { Add-IntranetIP `$ip }

# Register the cleanup event to remove Registry keys on exit
Register-EngineEvent PowerShell.Exiting -MessageData `$__ZoneKeys -Action {
    foreach (`$k in `$Event.MessageData) {
        Remove-Item -Path `$k -Recurse -Force -ErrorAction SilentlyContinue
    }
} | Out-Null

# --- UI Setup ---
try {
    `$Host.UI.RawUI.BackgroundColor = 'Black'
    `$Host.UI.RawUI.ForegroundColor = 'White'
    try { `$Host.UI.RawUI.WindowTitle = '$Title' } catch {}
    Clear-Host
} catch {}

Write-Host ''
Write-Host '  +--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  |  $Title" -ForegroundColor Cyan
Write-Host '  +--------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host ''

# --- Execution ---
try {
    Write-Host '  [>] Downloading and executing...' -ForegroundColor Gray
    `$tmpScript = Join-Path $env:TEMP ('DriverDex-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    (New-Object Net.WebClient).DownloadFile('$Url', `$tmpScript)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$tmpScript
    Remove-Item -LiteralPath `$tmpScript -Force -ErrorAction SilentlyContinue
} catch {
    Write-Host ''
    Write-Host '  [!] Script execution error:' -ForegroundColor Red
    Write-Host "      `$(`$_.Exception.Message)" -ForegroundColor DarkRed
}

Write-Host ''
Write-Host '  [Done] Press Enter to close this window ...' -ForegroundColor DarkGray
`$null = Read-Host
"@

        # CONVERT TO BASE64: This is the critical fix.
        # It bypasses all command-line parsing issues.
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($innerScript)
        $encodedCommand = [Convert]::ToBase64String($bytes)

        $argList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand
        )

        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Normal

        Write-Host ''
        Write-Host "  [+] Launched : $Title" -ForegroundColor Green

    } catch {
        Write-Host ''
        Write-Host "  [!] Failed to launch : $Title" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}
# ================================================================
#  HIERARCHICAL MENU STRUCTURE
#  Data is fully separated from navigation/execution logic.
#  All 26 original URLs are preserved exactly; only their menu
#  location and key changed (see v27.5.0 change log above).
# ================================================================
function Initialize-MenuStructure {
    <#
    .SYNOPSIS
        Builds and returns the hierarchical $MenuStructure hashtable.
    .DESCRIPTION
        Single source of truth for every menu level: main menu plus
        the three submenus (applications, system, hardware). Adding
        a new submenu or item never requires touching navigation or
        display code - see the header comment for the pattern.
    #>
    return @{

        # ============================================================
        # MAIN MENU  -  9 critical items + 3 submenu shortcuts
        # ============================================================
        'main' = @{
            display_name = 'Windows Scripts Toolkit'
            breadcrumb   = 'Main'
            parent       = $null
            help_text    = 'Single key to launch  |  E/S/H = submenus  |  Q = Quit'
            items = @{
                '1' = @{ Title = 'App Setup Framework';              Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1' }
                '2' = @{ Title = 'Office 365';                       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1' }
                '3' = @{ Title = 'Office LTSC 2021';                 Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1' }
                '4' = @{ Title = 'Microsoft Store (LTSC)';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1' }
                '5' = @{ Title = 'RICHO Printer Setup';               Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/aoRICHO.ps1' }
                '6' = @{ Title = 'Activation / Edition Change';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run' }
                '7' = @{ Title = 'Time Sync & Format';                Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1' }
                '8' = @{ Title = 'DriverDex Auto Driver Installation'; Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DriverDex/DriverDex.ps1'; Tag = 'NEW' }
                '9' = @{ Title = 'ERP Automate Setup';                Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1' }
            }
            submenu_shortcuts = @(
                @{ Key = 'E'; MenuId = 'applications'; Display = 'More Applications';        Count = 3 }
                @{ Key = 'H'; MenuId = 'hardware';       Display = 'Hardware & Drivers';       Count = 6 }
                @{ Key = 'S'; MenuId = 'system';        Display = 'System & Maintenance';     Count = 9 }
            )
        }

        # ============================================================
        # SUBMENU: MORE APPLICATIONS   (old keys 5, 6, 7)
        # ============================================================
        'applications' = @{
            display_name = 'More Applications'
            breadcrumb   = 'Main > More Applications'
            parent       = 'main'
            help_text    = 'Select tool  |  Esc or B = Back to Main  |  Q = Quit'
            items = @{
                '1' = @{ Title = 'Install Edge';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1' }
                '2' = @{ Title = 'Remove Edge';             Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1' }
                '3' = @{ Title = 'Remove New Outlook';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1' }
            }
        }

        # ============================================================
        # SUBMENU: SYSTEM & MAINTENANCE   (old keys C-K)
        # ============================================================
        'system' = @{
            display_name = 'System & Maintenance Tools'
            breadcrumb   = 'Main > System & Maintenance'
            parent       = 'main'
            help_text    = 'Select tool  |  Esc or B = Back to Main  |  Q = Quit'
            items = @{
                '1' = @{ Title = 'Remove Duplicate Files'; Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1' }
                '2' = @{ Title = 'IP Config';                Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1' }
                '3' = @{ Title = 'Disk Manager';             Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1' }
                '4' = @{ Title = 'Install MediCatUSB';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/installMUSVB.ps1' }
                '5' = @{ Title = 'Windows Tuner';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1' }
                '6' = @{ Title = 'Windows Optimizer';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1' }
                '7' = @{ Title = 'Disable Updates';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1' }
                '8' = @{ Title = 'Enable Updates';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1' }
                '9' = @{ Title = 'Upgrade to Win 11';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1' }
            }
        }

        # ============================================================
        # SUBMENU: HARDWARE & DRIVERS   (old keys L, M, N, W, Y, Z)
        # ============================================================
        'hardware' = @{
            display_name = 'Hardware & Driver Tools'
            breadcrumb   = 'Main > Hardware & Drivers'
            parent       = 'main'
            help_text    = 'Select tool  |  Esc or B = Back to Main  |  Q = Quit'
            items = @{
                '1' = @{ Title = 'Extract Drivers';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1' }
                '2' = @{ Title = 'Install Extracted Drivers';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1' }
                '3' = @{ Title = 'ERP Font Install';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1'; Tag = 'NEW' }
                '4' = @{ Title = 'WARDEN [Registry Nexus]';     Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1' }
                '5' = @{ Title = 'Intel Interrupt Fix';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1' }
                '6' = @{ Title = 'WPT Interrupt Fix';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1' }
            }
        }
    }
}

$MenuStructure = Initialize-MenuStructure

# ================================================================
#  NAVIGATION STATE MACHINE
# ================================================================
$Script:CurrentMenuLevel = 'main'
$Script:MenuHistory      = @('main')   # stack, ready for deeper nesting later
$Script:NeedsRedraw      = $true       # only Show-Menu when something actually changed

function Set-MenuLevel {
    <#
    .SYNOPSIS
        Switches the active menu level if it exists in $MenuStructure.
    #>
    param([Parameter(Mandatory)][string]$MenuId)

    if ($MenuStructure.ContainsKey($MenuId)) {
        $Script:CurrentMenuLevel = $MenuId
        $Script:MenuHistory += $MenuId
        return $true
    }
    return $false
}

function Get-ParentMenu {
    <#
    .SYNOPSIS
        Returns the parent menu id for the current (or given) level.
    #>
    param([string]$MenuLevel = $Script:CurrentMenuLevel)
    return $MenuStructure[$MenuLevel].parent
}

function Back-ToParentMenu {
    <#
    .SYNOPSIS
        Navigates from the current submenu back to its parent (Main).
    #>
    $parent = Get-ParentMenu
    if ($parent) {
        Set-MenuLevel -MenuId $parent
        return $true
    }
    return $false
}

function Get-ValidKeysForLevel {
    <#
    .SYNOPSIS
        Returns every key that means something at the given menu level -
        item keys, submenu-shortcut keys, back key(s), and quit - useful
        for input validation and for building help/error text.
    #>
    param([string]$MenuLevel = $Script:CurrentMenuLevel)

    $menuData = $MenuStructure[$MenuLevel]
    $keys = New-Object System.Collections.Generic.List[string]

    foreach ($k in $menuData.items.Keys) { [void]$keys.Add($k) }

    if ($MenuLevel -eq 'main' -and $menuData.ContainsKey('submenu_shortcuts')) {
        foreach ($sm in $menuData.submenu_shortcuts) { [void]$keys.Add($sm.Key) }
    }

    if ($MenuLevel -ne 'main') { [void]$keys.Add('Esc'); [void]$keys.Add('B') }

    [void]$keys.Add('Q')
    return $keys
}

function Resolve-MenuAction {
    <#
    .SYNOPSIS
        Decides what a keypress means for the current menu level.
    .OUTPUTS
        One of: 'quit' | 'navigate' | 'execute' | 'invalid'
        Navigation state ($Script:CurrentMenuLevel) is updated in place
        for 'navigate' results; the main loop only needs to re-draw.
    #>
    param(
        [Parameter(Mandatory)][string]$UserInput,
        [string]$CurrentLevel = $Script:CurrentMenuLevel
    )

    $key      = $UserInput.ToUpperInvariant()
    $menuData = $MenuStructure[$CurrentLevel]

    # --- Global commands (work at every level) ---
    if ($key -eq 'Q') { return 'quit' }

    # --- Back navigation (submenus only; 'Esc' or 'B') ---
    if (($key -eq 'ESC' -or $key -eq 'B') -and $CurrentLevel -ne 'main') {
        [void](Back-ToParentMenu)
        return 'navigate'
    }

    # --- Submenu shortcuts (main menu only) ---
    if ($CurrentLevel -eq 'main' -and $menuData.ContainsKey('submenu_shortcuts')) {
        foreach ($submenu in $menuData.submenu_shortcuts) {
            if ($key -eq $submenu.Key) {
                [void](Set-MenuLevel -MenuId $submenu.MenuId)
                return 'navigate'
            }
        }
    }

    # --- Executable item in the current menu ---
    if ($menuData.items.ContainsKey($key)) {
        return 'execute'
    }

    # --- Nothing matched ---
    return 'invalid'
}

# ================================================================
#  MAIN LOOP
# ================================================================
while ($true) {
    if ($Script:NeedsRedraw) {
        Show-Menu -MenuLevel $Script:CurrentMenuLevel
        $Script:NeedsRedraw = $false
    }

    try {
        $keyInfo = [Console]::ReadKey($true)
        if ($keyInfo.Key -eq [ConsoleKey]::Escape) { $choice = 'ESC' }
        else { $choice = $keyInfo.KeyChar.ToString().ToUpperInvariant() }
    } catch {
        try {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.Key -eq [ConsoleKey]::Escape) { $choice = 'ESC' }
            else { $choice = ($key.Character.ToString()).ToUpperInvariant() }
        } catch {
            try {
                # Last resort - only reached in hosts with NO console key API at all
                # (PowerShell ISE, VS Code's PowerShell Integrated Console, redirected
                # input). This is the one case where pressing Enter is unavoidable.
                $choice = (Read-Host).Trim().ToUpperInvariant()
                if ($choice.Length -gt 1) { $choice = $choice.Substring(0,1) }
            } catch {
                Start-Sleep -Milliseconds 300
                continue
            }
        }
    }

    $action = Resolve-MenuAction -UserInput $choice -CurrentLevel $Script:CurrentMenuLevel

    switch ($action) {

        'quit' {
            Clear-Host
            Write-Host ''
            Write-Host '  Goodbye.' -ForegroundColor Cyan
            Write-Host ''
            Start-Sleep -Milliseconds 500
            exit
        }

        'navigate' {
            # $Script:CurrentMenuLevel was already updated by Resolve-MenuAction.
            $Script:NeedsRedraw = $true
        }

        'execute' {
            $menuData = $MenuStructure[$Script:CurrentMenuLevel]
            $item     = $menuData.items[$choice]
            Start-RemoteScript -Url $item.Url -Title $item.Title
            Start-Sleep -Milliseconds 700
            $Script:NeedsRedraw = $true
        }

        'invalid' {
            # Key isn't mapped to anything on this menu level - ignore it
            # completely. No message, no sleep, no redraw; just go back
            # to waiting for the next keypress.
        }
    }
}
