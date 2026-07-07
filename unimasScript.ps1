<#
  ================================================================
   Windows Scripts  -  Main Menu Launcher
   Author  : rhshourav
   GitHub  : https://github.com/rhshourav/Windows-Scripts
    Version : 27.6.2
   Notes   : iex/irm compatible, auto-elevates, single-key nav,
             launches sub-scripts in new elevated windows,
             temporarily adds LAN IPs to Local Intranet zone,
             real-time system status on every draw.

   v27.5.0 CHANGE LOG (Menu Hierarchy Refactor)
   ---------------------------------------------
   - Flat 26-item menu replaced with a 3-level hierarchy:
       Main Menu (9 critical items + 3 submenu shortcuts)
          |-- [E] More Applications        (5 items)
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
$Script:VER    = '27.6.2'
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
                # Force UTF-8 decoding explicitly: WebClient falls back to the system ANSI
                # codepage whenever it can't cleanly read charset from response headers
                # (e.g. behind a proxy/AV that strips or rewrites them), which silently
                # mangles any non-ASCII character before it ever reaches WriteAllText.
                # WriteAllText with Encoding.UTF8 then writes a UTF-8 BOM so PS5 always
                # reads the temp file as UTF-8, not Windows-1252 -- but only if $rawText
                # was decoded correctly in the first place.
                $webClient = New-Object Net.WebClient
                $webClient.Encoding = [Text.Encoding]::UTF8
                $rawText = $webClient.DownloadString($Script:SELF_URL)
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

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
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
Write-Host ' |                          __                                    |' -ForegroundColor Cyan
Write-Host ' |           | | ._  o ._ _   _.  _  (_   _ ._ o ._ _|_  _        |' -ForegroundColor Cyan
Write-Host ' |           |_| | | | | | | (_| _>  __) (_ |  | |_) |_ _>        |' -ForegroundColor Cyan
Write-Host ' |                                     |                          |' -ForegroundColor Cyan
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |              Windows Script Toolkit for Windows                |' -ForegroundColor Gray
Write-Host ' |              ----------------------------------                |' -ForegroundColor DarkGray
Write-Host ' |                                                                |' -ForegroundColor DarkCyan
Write-Host ' |________________________________________________________________|' -ForegroundColor DarkCyan
Write-Host ''
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
    # Re-save with UTF-8 BOM so PS 5.1 on Windows 10 parses Unicode correctly
    `$dBytes = [IO.File]::ReadAllBytes(`$tmpScript)
    `$bom = [byte[]]@(0xEF, 0xBB, 0xBF)
    `$out = New-Object byte[] (`$bom.Length + `$dBytes.Length)
    [Array]::Copy(`$bom, 0, `$out, 0, `$bom.Length)
    [Array]::Copy(`$dBytes, 0, `$out, `$bom.Length, `$dBytes.Length)
    [IO.File]::WriteAllBytes(`$tmpScript, `$out)
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
                @{ Key = 'E'; MenuId = 'applications'; Display = 'More Applications';        Count = 5 }
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
                '4' = @{ Title = 'File Ops (Delete/Move)';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/fileOps/fileOps.ps1'; Tag = 'NEW' }
                '5' = @{ Title = 'PyForge (Python to EXE)';  Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/PyForge/PyForge.ps1'; Tag = 'NEW' }
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

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU9JZ7aRhEvKRrIr2WTI4kT2y5
# /x2gghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
# AQsFADAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzMB4XDTI2MDcwNzA4MDE1
# N1oXDTI5MDcwNzA4MTE1N1owGzEZMBcGA1UEAwwQUkhTSE9VUkFWLUlULU9wczCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALFj11KDAqN3fhbDT9fvgrLF
# VemPYmcud3qA+9Sc4RojOjElODGXyaOlBSVmDGpmCkNRC+dnkGCLB8bYb3gsnHey
# Ud99DA8tvkTgb06+B1pigTZUmhyAwyPiu77+h224c8SsZFkmgQ/Dh2Sc2ynNocZe
# 773d6a/B4DRg7/K9xV8jFap6BP1fjaM3Do40GSL+OVnXl2ssvfFk4FyP5fc8Czz5
# MJ5IJKRFrnHv3kNcmyz5mnz0LoBQs/JtHpWg3BogIalJ2tyCiZgk0xIsz5j5UjhA
# /KepfnWGpCowJ/NJWnmOZcikFlDPggI27QNc/IbxZ035ht+Zgc7b1Cf68GmL/8UC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRJ+13W7/PcqVgZXZf87/JdXvGqxjANBgkqhkiG9w0BAQsFAAOCAQEA
# MDUJsw0AephOCByoLTFSm8hnB4I7s8ddA64vDTv4QF2TcXdrd/glByhEQexUEDpw
# lPCSbzHAmRM5X71QYNoB/CDlCoAO8BQnbegqkhAx8ubRyciwsLA4ZPp+/GFbgZaV
# khkOWpL6v6fmU3kSB5px+roqOuMjmqvbtCDlC4JH25WuDEgGJQhqpgdQSZdomWjH
# le/GnQKt4Y18ysVFvgE1lRO8x6gkJ5IJbZPJ0Q//2xCvtM0WpjXmQl1RHV/7tqDS
# fqprCQxuKiTPC64VfafzeS7IUNJMgQS73H6wuaKdeT85PIxreleNwNXfbr4O/FY3
# eqlSEZAqzKtZXfNFWPmHazCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE+jCC
# BPYCAQEwLzAbMRkwFwYDVQQDDBBSSFNIT1VSQVYtSVQtT3BzAhAQvylGgaQVhE7g
# tCp7LUPgMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBSFECuXUHj7aBgAjo9e3bphdb0KxTANBgkq
# hkiG9w0BAQEFAASCAQAbva1ngq64/OvttTYIi2SzvicNITusw53uS/U+F4v6fUnl
# gGowggzyrrsTxiayIhmZm3bvYoWVTX3JTnkp+R0z1Nyk0XtqXmtYPULcrpEL/YeM
# lvXZA66FB4sJhQQ3J3IdH7H9RLjPXNF6kSVf3MjKyiBQVnKO2qQbQU9MRdtcU+04
# Ah0iC4gl+933HgycRGogXfOSMRMPpCivPWEswhAfbnruJAo1hQq5xTBT0Ykr3ogK
# QGaKFEePwgdJ5EheyblmZRJhgybSeI9KoJpHmtV0x1uc/yUHwBoWGyYh7Yu4Qh5U
# mTX8NMUItrHJ+8XjAKQkydQMpqOg/mpR02c/yzJXoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQyNlowLwYJKoZIhvcNAQkEMSIEIOZprA/Raqntq0c6
# LzwbY52UhgiPiInLkgAfBF4762KpMA0GCSqGSIb3DQEBAQUABIICABFE3heDofri
# xrUsjPHOF6TBMkAqsQf+80gyjLe8NdK5WRreG2AKJI6Trl64lmUjwV0NqDoaoAUG
# t4EJ+YokWlMCiP13jkW4pGEK53L2H6VIod/YIMyGiYkbAVWsyhpDmd3kN2q49AS6
# aCe0VSmE5UF9BfD6qOYLstOwPnbQIHz/6p9mkFJnHffiuw362ZQ7XYXiYpXAOZGO
# HcnkNYbFK5rfW9qJZ8zN3RN54a3naARZeoWS46/vkc+6hYyduFdYyKwqE18Rru17
# 1taHyUc0NQAlMBRIN+kbVpUMbGWl5W0JNAq542g35WdLYyczez7b+2VwxoY+NpN5
# k0Ur14LdFVFZR13Fki+BHlutgFFA1rM7brn5HQlYDR7p9tKyVexhKfq8lSufsHW8
# 2PGgi5op1Mm6qD7ZMpTL/BlOnx+npqF7jbDpwl7gA9pGOI6X27VG6GA/DPSuQ1ul
# wEi4/JBkIkvcHzfRrkCTNydeRYCsm2RaXnqEZnFcCMVXm8GwirmtpwaBIsWEAF4u
# MXy0DhvOV0OrZRVwA0OnLAeSFnSOA4k6BwhQKaABTaAbtYE5atjW2UYpHSOqxLEX
# QW8NihHpTm3seXKZnufRVz0N51cIIuYCHts/QHm5ZPWc+aJ2HYeTm3ztA1vs1hnF
# a7XtJjeFH1ZFj9W4ueYFexAsf40ErU3c
# SIG # End signature block
