# =========================================
# Winget App Installer - ASCII Safe (PS5.1 + PS7 Hardened)
# =========================================
# Version : v1.4.0
# Author  : rhshourav
# GitHub  : https://github.com/rhshourav
# Category: Windows Scripts
# =========================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

# -----------------------------
# Auto-Elevate
# -----------------------------
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {

    Start-Process powershell `
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

# -----------------------------
# UI Helpers (ASCII-safe)
# -----------------------------
function Line { Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan }
function Title([string]$t) { Line; Write-Host ("| {0,-52} |" -f $t) -ForegroundColor Yellow; Line }
function Info([string]$k,[string]$v) { Write-Host ("| {0,-14}: {1,-35} |" -f $k,$v) -ForegroundColor Gray }

function Show-Banner {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "| Winget App Installer (Hardened)                        |" -ForegroundColor Cyan
    Write-Host "| Version : v1.4.0                                       |" -ForegroundColor Gray
    Write-Host "| Author  : rhshourav                                    |" -ForegroundColor Gray
    Write-Host "| GitHub  : https://github.com/rhshourav                 |" -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Show-DownloadBox {
    param(
        [string]$Title,
        [int]$Percent,
        [string]$Status,
        [string]$ETA,
        [string]$Retry,
        [string]$Anim
    )

    try { [Console]::SetCursorPosition(0,$global:ProgressTop) } catch {}

    Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("| DOWNLOADING: {0,-39} |" -f $Title) -ForegroundColor Yellow
    Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan

    $p = [math]::Min(100,[math]::Max(0,$Percent))
    $filled = [math]::Floor($p / 4)
    $bar = ("#" * $filled).PadRight(25,".")
    if ($Anim -and $bar.Length -ge 25) { $bar = $bar.Substring(0,24) + $Anim }

    Write-Host ("| Progress : [{0}] {1,3}%              |" -f $bar,$p) -ForegroundColor Green
    Write-Host ("| Status   : {0,-39} |" -f $Status) -ForegroundColor Gray
    Write-Host ("| ETA      : {0,-39} |" -f $ETA)   -ForegroundColor DarkGray
    Write-Host ("| Retry    : {0,-39} |" -f $Retry) -ForegroundColor DarkGray
    Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan
}

function Show-WorkBox {
    param(
        [string]$Title,
        [string]$Status,
        [string]$Elapsed,
        [string]$Anim
    )

    try { [Console]::SetCursorPosition(0,$global:ProgressTop) } catch {}

    Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("| WORKING : {0,-41} |" -f $Title) -ForegroundColor Yellow
    Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan

    $a = $Anim
    if (-not $a) { $a = "#" }
    $bar = ("#" * 24) + $a

    Write-Host ("| Progress : [{0}]                  |" -f $bar) -ForegroundColor Green
    Write-Host ("| Status   : {0,-39} |" -f $Status) -ForegroundColor Gray
    Write-Host ("| Elapsed  : {0,-39} |" -f $Elapsed) -ForegroundColor DarkGray
    Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan
}

# -----------------------------
# Helpers
# -----------------------------
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.SecurityProtocolType]::Tls11 -bor `
            [Net.SecurityProtocolType]::Tls
    } catch {}
}

function Test-OsSupported {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 17763) {
        Title "FATAL ERROR"
        Info "Reason" "Windows build too old for WinGet"
        Info "Build"  "$build (need 17763+)"
        Line
        exit 1
    }
}

function Ensure-AppxServiceReady {
    $appx = Get-Service -Name AppXSvc -ErrorAction SilentlyContinue
    if (-not $appx) { throw "AppXSvc service not found. AppX framework missing/disabled." }
    if ($appx.StartType -eq "Disabled") { throw "AppXSvc is Disabled. Enable AppX framework to install MSIX/Appx packages." }
    if ($appx.Status -ne 'Running') { Start-Service -Name AppXSvc -ErrorAction SilentlyContinue }
}

function Get-Arch {
    $a = $env:PROCESSOR_ARCHITECTURE
    if ($a -eq "AMD64") { return "x64" }
    if ($a -eq "x86")   { return "x86" }
    if ($a -eq "ARM64") { return "arm64" }
    return "x64"
}

function Resolve-WingetPath {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

# -----------------------------
# Transcript Logging
# -----------------------------
$global:WorkRoot = Join-Path $env:ProgramData "rhshourav\WindowsScripts\WingetInstaller"
$global:LogRoot  = Join-Path $global:WorkRoot "Logs"
Ensure-Dir $global:WorkRoot
Ensure-Dir $global:LogRoot

$global:TranscriptPath = Join-Path $global:LogRoot ("install_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $global:TranscriptPath -Force | Out-Null } catch {}

# -----------------------------
# Themed Add-AppxPackage (suppresses ugly built-in progress)
# -----------------------------
function Invoke-AppxPackageThemed {
    param(
        [Parameter(Mandatory=$true)][string]$TitleText,
        [Parameter(Mandatory=$true)][string]$Path,
        [string[]]$DependencyPath = $null
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Appx/msix path not found: $Path"
    }

    $frames = @('|','/','-','\')
    $i = 0
    $start = Get-Date
    $global:ProgressTop = [Console]::CursorTop

    $job = Start-Job -ScriptBlock {
        param($p, $deps)
        $ErrorActionPreference = "Stop"
        $ProgressPreference = "SilentlyContinue"
        $VerbosePreference  = "SilentlyContinue"

        if ($deps -and $deps.Count -gt 0) {
            Add-AppxPackage -Path $p -DependencyPath $deps -ErrorAction Stop | Out-Null
        } else {
            Add-AppxPackage -Path $p -ErrorAction Stop | Out-Null
        }
    } -ArgumentList $Path, $DependencyPath

    try {
        while ($job.State -eq "Running") {
            $elapsed = (Get-Date) - $start
            Show-WorkBox -Title $TitleText -Status "Processing..." -Elapsed $elapsed.ToString() -Anim $frames[$i % $frames.Count]
            $i++
            Start-Sleep -Milliseconds 200
        }

        Receive-Job -Job $job -ErrorAction Stop | Out-Null

        $elapsed = (Get-Date) - $start
        Show-WorkBox -Title $TitleText -Status "Completed" -Elapsed $elapsed.ToString() -Anim " "
        Write-Host ""
    }
    finally {
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# -----------------------------
# Download with fallback chain (HttpClient -> IWR -> BITS -> WebClient)
# -----------------------------
function Download-File {
    param(
        [Parameter(Mandatory=$true)] [string]$Url,
        [Parameter(Mandatory=$true)] [string]$Destination,
        [Parameter(Mandatory=$true)] [string]$Name,
        [int]$MaxRetry = 3,
        [int]$MinBytes = 4096
    )

    Ensure-Dir -Path (Split-Path -Parent $Destination)
    Enable-Tls12

    $frames = @('|','/','-','\')
    $retry = 0

    do {
        $retry++
        $global:ProgressTop = [Console]::CursorTop
        $start = Get-Date
        $i = 0

        try { if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue } } catch {}
        $tmp = "$Destination.download"
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}

        try {
            $used = ""
            $haveHttpClient = $false

            try {
                Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
                $t = [Type]::GetType("System.Net.Http.HttpClientHandler, System.Net.Http", $false)
                if ($t) { $haveHttpClient = $true }
            } catch { $haveHttpClient = $false }

            if ($haveHttpClient) {
                $used = "HttpClient"
                $handler = New-Object System.Net.Http.HttpClientHandler
                $handler.AllowAutoRedirect = $true
                $client = New-Object System.Net.Http.HttpClient($handler)
                $client.Timeout = [TimeSpan]::FromMinutes(30)

                $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
                if (-not $response.IsSuccessStatusCode) {
                    throw ("HTTP {0} {1}" -f [int]$response.StatusCode, $response.ReasonPhrase)
                }

                $total = $null
                try { $total = $response.Content.Headers.ContentLength } catch { $total = $null }

                $inStream = $response.Content.ReadAsStreamAsync().Result
                $outStream = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

                try {
                    $buffer = New-Object byte[] 65536
                    $readTotal = 0L
                    while ($true) {
                        $read = $inStream.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) { break }

                        $outStream.Write($buffer, 0, $read)
                        $readTotal += $read

                        $pct = 0
                        if ($total -and $total -gt 0) { $pct = [math]::Round(($readTotal / $total) * 100) }

                        $elapsed = (Get-Date) - $start
                        $eta = if ($pct -gt 0) { [TimeSpan]::FromSeconds(($elapsed.TotalSeconds / $pct) * (100 - $pct)) } else { "--:--" }

                        $status = if ($total -and $total -gt 0) {
                            "{0:N1} MB / {1:N1} MB ({2})" -f ($readTotal/1MB),($total/1MB),$used
                        } else {
                            "{0:N1} MB / ? ({1})" -f ($readTotal/1MB),$used
                        }

                        Show-DownloadBox -Title $Name -Percent $pct -Status $status -ETA $eta -Retry "$retry / $MaxRetry" -Anim $frames[$i % $frames.Count]
                        $i++
                    }
                }
                finally {
                    try { $outStream.Close() } catch {}
                    try { $inStream.Close() } catch {}
                    try { $response.Dispose() } catch {}
                    try { $client.Dispose() } catch {}
                }

                Move-Item -LiteralPath $tmp -Destination $Destination -Force
            }
            else {
                # Invoke-WebRequest
                try {
                    $used = "Invoke-WebRequest"
                    Show-DownloadBox -Title $Name -Percent 0 -Status "Starting... ($used)" -ETA "--:--" -Retry "$retry / $MaxRetry" -Anim $frames[$i % $frames.Count]
                    $i++
                    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
                    Show-DownloadBox -Title $Name -Percent 100 -Status "Completed ($used)" -ETA "00:00" -Retry "$retry / $MaxRetry" -Anim " "
                    Write-Host ""
                }
                catch {
                    # BITS
                    try {
                        $used = "BITS"
                        try { Start-Service BITS -ErrorAction SilentlyContinue } catch {}
                        Start-BitsTransfer -Source $Url -Destination $Destination -ErrorAction Stop
                    }
                    catch {
                        # WebClient
                        $used = "WebClient"
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("User-Agent","rhshourav-WindowsScripts")
                        $wc.DownloadFile($Url, $Destination)
                    }
                }
            }

            if (-not (Test-Path -LiteralPath $Destination)) { throw "Downloaded file not found: $Destination" }
            $len = (Get-Item -LiteralPath $Destination).Length
            if ($len -lt $MinBytes) { throw "Downloaded file too small ($len bytes): $Destination" }
            return
        }
        catch {
            $msg = $_.Exception.Message
            if (-not $msg -or $msg.Trim().Length -eq 0) { $msg = ($_ | Out-String).Trim() }

            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}
            try { if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue } } catch {}

            Start-Sleep -Seconds (2 * $retry)
            if ($retry -ge $MaxRetry) {
                throw ("Download failed after {0} attempts: {1}. Last error: {2}" -f $MaxRetry, $Name, $msg)
            }
        }
    } until ($retry -ge $MaxRetry)
}

# -----------------------------
# Winget execution (timeout protected)
# -----------------------------
function Invoke-WingetCapture {
    param(
        [Parameter(Mandatory=$true)][string]$WingetExe,
        [Parameter(Mandatory=$true)][string[]]$Args,
        [int]$TimeoutSec = 30
    )

    $outFile = Join-Path $env:TEMP ("winget_out_{0}.txt" -f ([Guid]::NewGuid().ToString("N")))
    $errFile = Join-Path $env:TEMP ("winget_err_{0}.txt" -f ([Guid]::NewGuid().ToString("N")))

    try {
        $p = Start-Process -FilePath $WingetExe -ArgumentList $Args -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            return @{ TimedOut=$true; ExitCode=$null; StdOut=""; StdErr="Timed out after $TimeoutSec sec" }
        }

        $stdout = ""; $stderr = ""
        try { if (Test-Path $outFile) { $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path $errFile) { $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } } catch {}

        return @{ TimedOut=$false; ExitCode=$p.ExitCode; StdOut=$stdout; StdErr=$stderr }
    }
    finally {
        try { if (Test-Path $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

function Winget-BestEffortInit {
    param([string]$WingetExe)
    try { Invoke-WingetCapture -WingetExe $WingetExe -Args @("--version") -TimeoutSec 10 | Out-Null } catch {}
    try { Invoke-WingetCapture -WingetExe $WingetExe -Args @("source","update","--disable-interactivity") -TimeoutSec 60 | Out-Null } catch {}
}

function Disable-WingetMsStoreSource {
    param([Parameter(Mandatory=$true)][string]$WingetExe)

    Write-Host "[*] Hard-disabling winget msstore source (best-effort)..." -ForegroundColor DarkCyan
    try { & $WingetExe source disable --name msstore --disable-interactivity | Out-Null } catch {}
    try { & $WingetExe source remove  --name msstore --disable-interactivity | Out-Null } catch {}
    try { & $WingetExe source update --disable-interactivity | Out-Null } catch {}

    try {
        Write-Host "[*] Current winget sources:" -ForegroundColor DarkCyan
        & $WingetExe source list
        Write-Host ""
    } catch {}
}

# -----------------------------
# Installed-app detection (Winget + Registry + Known EXE paths)
# -----------------------------
function Test-RegistryInstalled {
    param([Parameter(Mandatory=$true)][string[]]$NamePatterns)

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($p in $paths) {
        try {
            $items = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            foreach ($it in $items) {
                $dn = $it.DisplayName
                if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                foreach ($pat in $NamePatterns) { if ($dn -match $pat) { return $true } }
            }
        } catch {}
    }
    return $false
}

function Test-ExeInstalled {
    param([Parameter(Mandatory=$true)][string[]]$Paths)
    foreach ($p in $Paths) { try { if (Test-Path -LiteralPath $p) { return $true } } catch {} }
    return $false
}

function Test-AppInstalled {
    param(
        [Parameter(Mandatory=$true)][string]$WingetExe,
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Name
    )

    # Winget list by ID (timeout-protected; source forced)
    try {
        if ($WingetExe -and (Test-Path -LiteralPath $WingetExe)) {
            $r = Invoke-WingetCapture -WingetExe $WingetExe -Args @("list","--id",$Id,"-e","--source","winget","--disable-interactivity") -TimeoutSec 12
            if (-not $r.TimedOut -and $r.StdOut -and $r.StdOut -match [regex]::Escape($Id)) { return $true }
        }
    } catch {}

    # Registry + known paths
    $patterns = @()
    $exePaths = @()

    switch -Regex ($Id) {
        '^Google\.Chrome$' {
            $patterns = @('(?i)\bGoogle Chrome\b')
            $exePaths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
        }
        '^7zip\.7zip$' {
            $patterns = @('(?i)\b7-?Zip\b')
            $exePaths = @("$env:ProgramFiles\7-Zip\7zFM.exe","${env:ProgramFiles(x86)}\7-Zip\7zFM.exe")
        }
        '^Greenshot\.GreenShot$' {
            $patterns = @('(?i)\bGreenshot\b')
            $exePaths = @("$env:ProgramFiles\Greenshot\Greenshot.exe","${env:ProgramFiles(x86)}\Greenshot\Greenshot.exe")
        }
        '^Adobe\.Acrobat\.Reader\.64-bit$' {
            $patterns = @('(?i)\bAdobe Acrobat Reader\b','(?i)\bAcrobat Reader\b')
            $exePaths = @("$env:ProgramFiles\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe","${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe")
        }
        '^Foxit\.FoxitReader$' {
            $patterns = @('(?i)\bFoxit PDF Reader\b','(?i)\bFoxit Reader\b')
            $exePaths = @("$env:ProgramFiles\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe","${env:ProgramFiles(x86)}\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe")
        }
        default {
            if ($Name) { $patterns = @("(?i)" + [regex]::Escape($Name)) }
        }
    }

    if ($patterns.Count -gt 0 -and (Test-RegistryInstalled -NamePatterns $patterns)) { return $true }
    if ($exePaths.Count -gt 0 -and (Test-ExeInstalled -Paths $exePaths)) { return $true }
    return $false
}

# -----------------------------
# Windows App Runtime 1.8 (required by current App Installer)
# -----------------------------
function Test-WindowsAppRuntime18Installed {
    try {
        $pkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "Microsoft.WindowsAppRuntime.1.8*" -or $_.PackageFamilyName -like "Microsoft.WindowsAppRuntime.1.8*"
        }
        return ($pkgs -and $pkgs.Count -gt 0)
    } catch { return $false }
}

function Ensure-WindowsAppRuntime18 {
    param([string]$WorkRoot)

    if (Test-WindowsAppRuntime18Installed) { return }

    Title "INSTALLING WINDOWS APP RUNTIME 1.8"
    Line

    $arch = Get-Arch
    $runtimeUrl = "https://aka.ms/windowsappsdk/1.8/1.8.260101001/windowsappruntimeinstall-x64.exe"
    if ($arch -eq "x86")   { $runtimeUrl = "https://aka.ms/windowsappsdk/1.8/1.8.260101001/windowsappruntimeinstall-x86.exe" }
    if ($arch -eq "arm64") { $runtimeUrl = "https://aka.ms/windowsappsdk/1.8/1.8.260101001/windowsappruntimeinstall-arm64.exe" }

    $runtimeExe = Join-Path $WorkRoot ("WindowsAppRuntimeInstall-{0}.exe" -f $arch)
    Download-File -Url $runtimeUrl -Destination $runtimeExe -Name ("Windows App Runtime 1.8 ({0})" -f $arch) -MinBytes 1000000

    $p = Start-Process -FilePath $runtimeExe -ArgumentList "--quiet --force" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Windows App Runtime installer failed (ExitCode=$($p.ExitCode))." }

    Start-Sleep -Seconds 2
    if (-not (Test-WindowsAppRuntime18Installed)) { throw "Windows App Runtime install ran but was not detected." }
}

# -----------------------------
# Dependencies ZIP for DesktopAppInstaller
# -----------------------------
function Get-DependenciesArchFolder {
    param([string]$Root,[string]$Arch)

    $dirs = @()
    try { $dirs = Get-ChildItem -Path $Root -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $Arch } } catch {}
    foreach ($d in $dirs) {
        try {
            $hasAppx = Get-ChildItem -Path $d.FullName -Filter "*.appx" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hasAppx) { return $d.FullName }
        } catch {}
    }
    return $null
}

function Ensure-DesktopAppInstallerDependencies {
    param([string]$WorkRoot)

    $arch = Get-Arch
    $depsZip = Join-Path $WorkRoot "DesktopAppInstaller_Dependencies.zip"
    $depsDir = Join-Path $WorkRoot "DesktopAppInstaller_Dependencies"

    Title "FETCHING WINGET DEPENDENCIES"
    Info "Arch" $arch
    Line

    Download-File -Url "https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.zip" `
        -Destination $depsZip -Name "DesktopAppInstaller Dependencies" -MinBytes 1000000

    try { if (Test-Path -LiteralPath $depsDir) { Remove-Item -LiteralPath $depsDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    Ensure-Dir $depsDir
    Expand-Archive -Path $depsZip -DestinationPath $depsDir -Force

    $archFolder = Get-DependenciesArchFolder -Root $depsDir -Arch $arch
    if (-not $archFolder) { throw "Could not locate dependencies folder for arch '$arch' inside $depsDir" }

    $vclibs = @(Get-ChildItem -Path $archFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Microsoft.VCLibs*.appx" } | Sort-Object Name)
    $xaml   = @(Get-ChildItem -Path $archFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Microsoft.UI.Xaml*.appx" } | Sort-Object Name)

    Title "INSTALLING DEPENDENCIES"
    Info "Folder" $archFolder
    Line

    $all = @()
    foreach ($f in $vclibs) { Invoke-AppxPackageThemed -TitleText ("Install {0}" -f $f.Name) -Path $f.FullName; $all += $f.FullName }
    foreach ($f in $xaml)   { Invoke-AppxPackageThemed -TitleText ("Install {0}" -f $f.Name) -Path $f.FullName; $all += $f.FullName }
    return $all
}

# -----------------------------
# Ensure WinGet (DesktopAppInstaller)
# -----------------------------
function Ensure-WinGet {
    $wgPath = Resolve-WingetPath
    if ($wgPath) { return $wgPath }

    Title "WINGET NOT FOUND - INSTALLING"
    Info "Method" "GitHub MSIX + Dependency ZIP"
    Line

    Test-OsSupported
    Ensure-AppxServiceReady

    $workRoot = $global:WorkRoot

    $depPaths = Ensure-DesktopAppInstallerDependencies -WorkRoot $workRoot
    Ensure-WindowsAppRuntime18 -WorkRoot $workRoot

    $ai = Join-Path $workRoot "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    Download-File -Url "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" `
        -Destination $ai -Name "Microsoft DesktopAppInstaller (WinGet)" -MinBytes 1000000

    Invoke-AppxPackageThemed -TitleText "Install DesktopAppInstaller (WinGet)" -Path $ai -DependencyPath $depPaths

    Start-Sleep -Seconds 2
    $wgPath = Resolve-WingetPath
    if (-not $wgPath) { throw "WinGet install completed but winget.exe is still unavailable." }
    return $wgPath
}

# -----------------------------
# Themed Winget Install (no "freeze")
# -----------------------------
function Invoke-WingetInstallThemed {
    param(
        [Parameter(Mandatory=$true)] [string]$WingetExe,
        [Parameter(Mandatory=$true)] [string]$Id,
        [Parameter(Mandatory=$true)] [string]$Name,
        [int]$TimeoutSec = 1800
    )

    $args = @(
        "install",
        "--id", $Id,
        "-e",
        "--source", "winget",  # FORCE community source only
        "--scope", "machine",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity",
        "--silent"
    )

    $outFile = Join-Path $env:TEMP ("winget_install_out_{0}.txt" -f ([Guid]::NewGuid().ToString("N")))
    $errFile = Join-Path $env:TEMP ("winget_install_err_{0}.txt" -f ([Guid]::NewGuid().ToString("N")))

    $frames = @('|','/','-','\')
    $i = 0
    $start = Get-Date
    $global:ProgressTop = [Console]::CursorTop

    $p = $null
    try {
        $p = Start-Process -FilePath $WingetExe -ArgumentList $args -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        while (-not $p.HasExited) {
            $elapsed = (Get-Date) - $start
            Show-WorkBox -Title ("Installing {0}" -f $Name) -Status "winget running..." -Elapsed $elapsed.ToString() -Anim $frames[$i % $frames.Count]
            $i++

            if ($elapsed.TotalSeconds -ge $TimeoutSec) {
                try { $p.Kill() } catch {}
                throw "winget install timed out after $TimeoutSec seconds."
            }

            Start-Sleep -Milliseconds 250
        }

        # Clear the work box with a completed state
        $elapsed = (Get-Date) - $start
        Show-WorkBox -Title ("Installing {0}" -f $Name) -Status "Completed" -Elapsed $elapsed.ToString() -Anim " "
        Write-Host ""

        $stdout = ""
        $stderr = ""
        try { if (Test-Path $outFile) { $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path $errFile) { $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } } catch {}

        # Show winget output so the user sees "everything"
        if ($stdout -and $stdout.Trim().Length -gt 0) { Write-Host $stdout.Trim() -ForegroundColor Gray }
        if ($stderr -and $stderr.Trim().Length -gt 0) { Write-Host $stderr.Trim() -ForegroundColor DarkYellow }

        if ($p.ExitCode -ne 0) {
            throw ("winget install failed (ExitCode={0})" -f $p.ExitCode)
        }
    }
    finally {
        try { if (Test-Path $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

# -----------------------------
# START
# -----------------------------
Show-Banner
$StartTime = Get-Date

Title "PRECHECK"
Info "User" $env:USERNAME
Info "Host" $env:COMPUTERNAME
Info "OS"   ([Environment]::OSVersion.VersionString)
Info "PS"   ($PSVersionTable.PSVersion.ToString())
Info "Arch" (Get-Arch)
Info "Log"  $global:TranscriptPath
Line

Title "OPTIONS"
do { $ans = Read-Host "Skip apps that are already installed? (Y/N)" } until ($ans -match '^[YyNn]$')
$SkipInstalledApps = ($ans -match '^[Yy]$')
Info "SkipInstalled" ($SkipInstalledApps.ToString())
Line

Title "CHECKING / INSTALLING WINGET"
$WingetExe = $null
try {
    $WingetExe = Ensure-WinGet
    Info "Winget" "Available"
    Info "Path"  $WingetExe
    Line
}
catch {
    Title "WINGET INSTALL FAILED"
    Info "Error" $_.Exception.Message
    Line
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

Winget-BestEffortInit -WingetExe $WingetExe
Disable-WingetMsStoreSource -WingetExe $WingetExe

# -----------------------------
# APPS
# -----------------------------
$RequiredApps = @(
    @{ Name="Greenshot";     Id="Greenshot.GreenShot" },
    @{ Name="Google Chrome"; Id="Google.Chrome" },
    @{ Name="7-Zip";         Id="7zip.7zip" }
)

$OptionalApps = @(
    @{ Name="Adobe Reader";  Id="Adobe.Acrobat.Reader.64-bit" },
    @{ Name="Foxit Reader";  Id="Foxit.FoxitReader" }
)

Title "OPTIONAL APPS"
Write-Host "Install optional apps?" -ForegroundColor Yellow
Write-Host "  1) Install both Adobe Reader + Foxit Reader" -ForegroundColor Gray
Write-Host "  2) Install Adobe Reader only" -ForegroundColor Gray
Write-Host "  3) Install Foxit Reader only" -ForegroundColor Gray
Write-Host "  4) Skip optional apps" -ForegroundColor Gray
do { $opt = Read-Host "Choose (1-4)" } until ($opt -match '^[1-4]$')
Line

$ChosenOptional = @()
switch ($opt) {
    '1' { $ChosenOptional = $OptionalApps }
    '2' { $ChosenOptional = @($OptionalApps[0]) }
    '3' { $ChosenOptional = @($OptionalApps[1]) }
    '4' { $ChosenOptional = @() }
}

Title "APPLICATION INSTALLATION"
$Installed = @()
$Skipped   = @()
$Failed    = @()

$AllApps = @()
$AllApps += $RequiredApps
$AllApps += $ChosenOptional

foreach ($app in $AllApps) {
    $name = [string]$app.Name
    $id   = [string]$app.Id

    try {
        Write-Host "[*] Checking: $name ($id)" -ForegroundColor DarkCyan

        if ($SkipInstalledApps) {
            if (Test-AppInstalled -WingetExe $WingetExe -Id $id -Name $name) {
                Write-Host "[=] Skipping (already installed): $name" -ForegroundColor Yellow
                $Skipped += $name
                Write-Host ""
                continue
            }
        }

        Write-Host "[*] Installing: $name ($id)" -ForegroundColor Cyan
        Invoke-WingetInstallThemed -WingetExe $WingetExe -Id $id -Name $name -TimeoutSec 1800

        Write-Host "[+] Installed:  $name" -ForegroundColor Green
        $Installed += $name
    }
    catch {
        Write-Host "[-] Failed:     $name -> $($_.Exception.Message)" -ForegroundColor Red
        $Failed += $name
    }

    Write-Host ""
}

Title "INSTALL SUMMARY"
$elapsed = (Get-Date) - $StartTime

Info "Installed" ($(if ($Installed.Count) { $Installed -join ", " } else { "(none)" }))
Info "Skipped"   ($(if ($Skipped.Count)   { $Skipped -join ", "   } else { "(none)" }))
Info "Failed"    ($(if ($Failed.Count)    { $Failed -join ", "    } else { "(none)" }))
Info "Elapsed"   $elapsed.ToString()
Info "Log"       $global:TranscriptPath
Line

Write-Host "| All operations completed                              |" -ForegroundColor Green
Line

try { Stop-Transcript | Out-Null } catch {}
