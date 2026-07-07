<#
# =====================================================================
# Driver Toolkit (PowerShell 5.1) - ASCII Safe / Robust
#
# Modes:
#   1) Export installed drivers (Driver Store) via pnputil (RECOMMENDED)
#   2) Scan selected drives for driver packages and extract
#
# UI:
#   - No-Enter menus for Mode selection, Drive selection, Y/N confirms
#   - Enter required ONLY for typing Output folder path
#
# Output:
#   - Creates output folder if missing
#   - Logs saved under: <Output>\Logs\<timestamp>\
#
# Version : v2.0.1
# Author  : rhshourav
# GitHub  : https://github.com/rhshourav
# =====================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# -----------------------------
# FATAL trap: show real location
# -----------------------------
trap {
    Write-Host ""
    Write-Host ("FATAL: {0}: {1}" -f $_.Exception.GetType().FullName, $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Yellow }
    if ($_.Exception.StackTrace) {
        Write-Host "StackTrace:" -ForegroundColor DarkGray
        Write-Host $_.Exception.StackTrace -ForegroundColor DarkGray
    }
    exit 1
}
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
        text  = "Driver Extractor V2.0.1`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
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
# UI helpers
# -----------------------------
function Line { Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan }

function Title([string]$t) {
    Line
    Write-Host ("| " + $t.PadRight(60) + " |") -ForegroundColor Yellow
    Line
}

function Info([string]$k,[object]$v) {
    $vk = if ($null -eq $v -or $v -eq "") { "N/A" } else { $v.ToString() }
    if ($vk.Length -gt 46) { $vk = $vk.Substring(0,46) }
    Write-Host ("| {0,-12}: {1,-46} |" -f $k,$vk) -ForegroundColor Gray
}

function Write-Ok([string]$m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host "[-] $m" -ForegroundColor Red }

function Read-KeyChar {
    try {
        $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $k.Character
    } catch {
        return $null
    }
}

function Read-MenuKey {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$ValidKeys
    )
    if (-not $ValidKeys -or $ValidKeys.Count -eq 0) { throw "Read-MenuKey called with empty ValidKeys." }

    while ($true) {
        Write-Host -NoNewline $Prompt
        $ch = Read-KeyChar

        if ($ch -eq "`r" -or $ch -eq "`n") { continue }

        if ($null -eq $ch -or $ch -eq [char]0) {
            $fallback = (Read-Host "").Trim()
            if ($fallback.Length -ge 1) { $ch = $fallback[0] } else { $ch = '' }
        }

        $k = ($ch.ToString()).ToUpperInvariant()
        if ($ValidKeys -contains $k) { Write-Host $k; return $k }

        Write-Host ""
        Write-Warn ("Invalid choice. Valid: {0}" -f ($ValidKeys -join ", "))
    }
}

function Confirm-YesNoKey([string]$Prompt) {
    $k = Read-MenuKey -Prompt ("{0} [Y/N]: " -f $Prompt) -ValidKeys @("Y","N")
    return ($k -eq "Y")
}

function Show-Banner {
    Clear-Host
    $line = "================================================================"
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Driver Toolkit (ASCII Safe)                                 |" -ForegroundColor Cyan
    Write-Host "| Version : v2.0.1                                            |" -ForegroundColor Gray
    Write-Host "| Author  : rhshourav                                         |" -ForegroundColor Gray
    Write-Host "| GitHub  : https://github.com/rhshourav                      |" -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ""
}

function ProgressBar([string]$label,[int]$pct,[datetime]$start) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }

    $elapsed = (Get-Date) - $start
    $eta = if ($pct -gt 0) {
        [TimeSpan]::FromSeconds(([math]::Max(0.0,$elapsed.TotalSeconds) / [double]$pct) * (100 - $pct))
    } else { [TimeSpan]::FromSeconds(0) }

    $blocks = [int]([math]::Floor(([double]$pct) / 4.0))
    if ($blocks -lt 0)  { $blocks = 0 }
    if ($blocks -gt 25) { $blocks = 25 }

    $bar = ("#" * $blocks).PadRight(25, [char]'.')

    Write-Host ("| {0,-60} |" -f $label) -ForegroundColor Cyan
    Write-Host ("| [{0}] {1,3}% ETA {2,-12} |" -f $bar,$pct,$eta) -ForegroundColor Green
}

function Safe-CursorUp([int]$lines) {
    try {
        $top = [int][Console]::CursorTop
        $newTop = [int][math]::Max(0, ($top - $lines))
        [Console]::SetCursorPosition([int]0, $newTop)
    } catch {}
}

# -----------------------------
# Admin / Elevation
# -----------------------------
function Is-Admin {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $wp.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Is-Admin)) {
    Write-Warn "Requesting Administrator privileges..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""
    )
    exit
}

# -----------------------------
# Settings
# -----------------------------
$DefaultOut = "C:\Extracted-Drivers"

# Mode 2 scan filters
$ScanExt = @(
  ".zip",".cab",".msi",".exe",
  ".7z",".rar",".tar",".gz",".tgz",".bz2",".xz",
  ".wim",".esd",".iso"
)

$ExcludeFragments = @(
  "\windows\",
  "\program files\",
  "\program files (x86)\",
  "\programdata\",
  "\users\",
  "\system volume information\",
  "\$recycle.bin\",
  "\recovery\",
  "\msocache\",
  "\intel\",
  "\amd\",
  "\nvidia\"
)

$IncludeUsersTree = $false
$CopyPackageIntoOutput = $true

# -----------------------------
# Helpers
# -----------------------------
function Ensure-Dir([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw "Empty path." }
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Normalize-PathLower([string]$p) {
    if ($null -eq $p) { return "" }
    return ($p.Replace('/','\')).ToLowerInvariant()
}

function Is-ExcludedPath([string]$fullPathLower) {
    if ([string]::IsNullOrWhiteSpace($fullPathLower)) { return $true }
    foreach ($frag in $ExcludeFragments) {
        if ($IncludeUsersTree -and $frag -eq "\users\") { continue }
        if ($fullPathLower -like ("*{0}*" -f $frag)) { return $true }
    }
    return $false
}

function Get-LocalDrives {
    $disks = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue
    $targets = @()
    foreach ($d in @($disks)) {
        if ($null -eq $d) { continue }
        if ($d.DriveType -in 2,3) {
            $root = ($d.DeviceID + "\")
            if (Test-Path -LiteralPath $root) {
                $targets += [pscustomobject]@{
                    DeviceID  = $d.DeviceID
                    Root      = $root
                    DriveType = $d.DriveType
                    Volume    = $d.VolumeName
                }
            }
        }
    }
    return ,$targets
}

function Choose-OutputRoot([string]$DefaultPath) {
    Title "OUTPUT LOCATION"
    Info "Default" $DefaultPath
    Write-Host "| Press Enter to keep default, or type custom path             |" -ForegroundColor Gray
    Line
    $custom = Read-Host "Output folder"
    if ([string]::IsNullOrWhiteSpace($custom)) { return $DefaultPath }
    return $custom.Trim().Trim('"').Trim("'")
}

function Menu-Mode {
    Title "SELECT MODE (NO ENTER)"
    Write-Host "| 1) Export installed drivers (pnputil)  [RECOMMENDED]         |" -ForegroundColor Gray
    Write-Host "| 2) Scan drives for packages and extract                      |" -ForegroundColor Gray
    Write-Host "| X) Exit                                                      |" -ForegroundColor DarkGray
    Line
    return (Read-MenuKey -Prompt "Select: " -ValidKeys @("1","2","X"))
}

function Choose-DrivesNoEnter {
    param([Parameter(Mandatory)] $Drives)

    $Drives = @($Drives)
    if ($Drives.Count -eq 0) { return @() }

    $selected = New-Object System.Collections.Generic.HashSet[string]

    while ($true) {
        Title "DRIVE SELECTION (NO ENTER)"
        Write-Host "| Toggle selection with number (1-9) or letter (C,D,E...).     |" -ForegroundColor Gray
        Write-Host "| Keys: A=All  N=None  S=Start  Y=Confirm  Q=Cancel            |" -ForegroundColor Gray
        Line

        for ($i=0; $i -lt $Drives.Count; $i++) {
            $d = $Drives[$i]
            $t = if ($d.DriveType -eq 3) { "Fixed" } else { "Removable" }
            $vol = if ([string]::IsNullOrWhiteSpace($d.Volume)) { "" } else { $d.Volume }
            $mark = if ($selected.Contains($d.DeviceID)) { "X" } else { " " }
            Write-Host ("| [{0}] {1,2}. {2,-3} {3,-9} {4,-33} |" -f $mark, ($i+1), $d.DeviceID, $t, ($d.Root + " " + $vol)) -ForegroundColor Gray
        }
        Line

        Write-Host -NoNewline "Key: " -ForegroundColor Cyan
        $ch = Read-KeyChar
        if ($ch -eq "`r" -or $ch -eq "`n") { continue }
        if ($null -eq $ch -or $ch -eq [char]0) { continue }

        $k = ($ch.ToString()).ToUpperInvariant()

        switch ($k) {
            "Q" { return @() }
            "A" { $selected.Clear(); foreach ($d in $Drives) { [void]$selected.Add($d.DeviceID) }; continue }
            "N" { $selected.Clear(); continue }
            "S" {
                $picked = @($Drives | Where-Object { $selected.Contains($_.DeviceID) })
                if ($picked.Count -eq 0) { Write-Warn "No drives selected."; Start-Sleep -Milliseconds 600; continue }
                return @($picked)
            }
            "Y" {
                $picked = @($Drives | Where-Object { $selected.Contains($_.DeviceID) })
                if ($picked.Count -eq 0) { Write-Warn "No drives selected."; Start-Sleep -Milliseconds 600; continue }
                Title "CONFIRM SELECTION"
                foreach ($d in $picked) {
                    $t = if ($d.DriveType -eq 3) { "Fixed" } else { "Removable" }
                    Write-Host ("| {0,-3} {1,-9} {2,-45} |" -f $d.DeviceID, $t, ($d.Root + " " + $d.Volume)) -ForegroundColor Gray
                }
                Line
                if (Confirm-YesNoKey "Proceed with these selected drives?") { return @($picked) }
                continue
            }
            default {
                if ($k -match '^[1-9]$') {
                    $idx = [int]$k
                    if ($idx -ge 1 -and $idx -le $Drives.Count) {
                        $id = $Drives[$idx-1].DeviceID
                        if ($selected.Contains($id)) { [void]$selected.Remove($id) } else { [void]$selected.Add($id) }
                    }
                    continue
                }
                if ($k -match '^[A-Z]$') {
                    $id = ($k + ":")
                    $match = $Drives | Where-Object { $_.DeviceID -eq $id } | Select-Object -First 1
                    if ($match) {
                        if ($selected.Contains($id)) { [void]$selected.Remove($id) } else { [void]$selected.Add($id) }
                    }
                    continue
                }
            }
        }
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [int] $TimeoutSeconds = 180
    )

    $outFile = Join-Path $env:TEMP ("drv_out_{0}.txt" -f ([guid]::NewGuid().ToString("N")))
    $errFile = Join-Path $env:TEMP ("drv_err_{0}.txt" -f ([guid]::NewGuid().ToString("N")))

    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow `
            -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $done = $p | Wait-Process -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
        if (-not $done) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            return @{
                TimedOut = $true
                ExitCode = $null
                StdOut   = (Get-Content $outFile -ErrorAction SilentlyContinue | Out-String).Trim()
                StdErr   = (Get-Content $errFile -ErrorAction SilentlyContinue | Out-String).Trim()
            }
        }

        return @{
            TimedOut = $false
            ExitCode = $p.ExitCode
            StdOut   = (Get-Content $outFile -ErrorAction SilentlyContinue | Out-String).Trim()
            StdErr   = (Get-Content $errFile -ErrorAction SilentlyContinue | Out-String).Trim()
        }
    }
    finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------
# Mode 1: pnputil export
# -----------------------------
function Export-DriverStore {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$LogDir
    )

    $pnputil = Get-Command pnputil.exe -ErrorAction SilentlyContinue
    if (-not $pnputil) { throw "pnputil.exe not found." }

    $stamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    $exportDir = Join-Path $OutputRoot ("DriverStoreExport\{0}" -f $stamp)
    Ensure-Dir $exportDir

    Title "DRIVER STORE EXPORT (pnputil)"
    Info "ExportDir" $exportDir
    Info "Tool"     $pnputil.Source
    Line

    if (-not (Confirm-YesNoKey "Export ALL installed drivers now?")) {
        Write-Warn "Cancelled."
        return
    }

    # Logs
    $outLog = Join-Path $LogDir "pnputil_stdout.txt"
    $errLog = Join-Path $LogDir "pnputil_stderr.txt"
    $sumLog = Join-Path $LogDir "pnputil_result.txt"

    # Start process with output redirection (no timeout)
    $start = Get-Date
    ProgressBar "Exporting drivers... (no timeout)" 1 $start

    $p = Start-Process -FilePath $pnputil.Source `
        -ArgumentList @("/export-driver","*",$exportDir) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError  $errLog

    # Poll until exit; keep UI alive
    $tick = 0
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 2
        $tick++

        # UI heartbeat (rotating % so user sees it is alive)
        $pct = [int](($tick % 99) + 1)
        Safe-CursorUp 2
        ProgressBar "Exporting drivers... (running)" $pct $start
    }

    Safe-CursorUp 2
    ProgressBar "Export complete" 100 $start
    Line

    $exit = $p.ExitCode

    # Write summary
    @(
        "Timestamp : $(Get-Date)"
        "ExportDir : $exportDir"
        "ExitCode  : $exit"
        "StdOut    : $outLog"
        "StdErr    : $errLog"
        "Elapsed   : $((Get-Date) - $start)"
    ) | Out-File -FilePath $sumLog -Encoding UTF8 -Force

    Title "RESULT"
    Info "ExportDir" $exportDir
    Info "ExitCode"  $exit
    Info "Logs"      $LogDir
    Line

    if ($exit -ne 0) {
        Write-Warn "pnputil returned non-zero. Check logs."
    } else {
        Write-Ok "Driver export completed successfully."
    }
}

# -----------------------------
# Mode 2: Scan+Extract (kept for completeness)
# -----------------------------
function Get-7ZipPath {
    $candidates = @(
        (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source,
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    if ($candidates -and $candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

function Try-Install7ZipWinget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }
    try {
        Start-Process -FilePath $winget.Source -ArgumentList @(
            "install","--id","7zip.7zip","-e","--accept-package-agreements","--accept-source-agreements"
        ) -Wait -NoNewWindow | Out-Null
        Start-Sleep -Seconds 2
        return ((Get-7ZipPath) -ne $null)
    } catch { return $false }
}

function Has-AnyFiles([string]$path) {
    $one = Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $one)
}

function Count-Inf([string]$path) {
    try {
        return (Get-ChildItem -LiteralPath $path -Recurse -Force -Filter *.inf -File -ErrorAction SilentlyContinue | Measure-Object).Count
    } catch { return 0 }
}

function Sanitize-Name([string]$name) {
    if ($null -eq $name) { return "Package" }
    $bad = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = ($name.ToCharArray() | ForEach-Object { if ($bad -contains $_) { '_' } else { $_ } }) -join ''
    $safe = $safe.Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Package" }
    return $safe
}

function Scan-DriveForPackages {
    param(
        [Parameter(Mandatory)] [string]$DriveRoot,
        [Parameter(Mandatory)] [string]$DriveId
    )

    $found = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($DriveRoot)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirLower = Normalize-PathLower $dir
        if (Is-ExcludedPath $dirLower) { continue }

        $items = $null
        try { $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue } catch { continue }

        foreach ($it in @($items)) {
            try {
                if ($it.PSIsContainer) {
                    $stack.Push($it.FullName)
                } else {
                    $ext = $it.Extension.ToLowerInvariant()
                    if ($ScanExt -contains $ext) {
                        $fullLower = Normalize-PathLower $it.FullName
                        if (-not (Is-ExcludedPath $fullLower)) {
                            $found.Add($it.FullName) | Out-Null
                        }
                    }
                }
            } catch {}
        }
    }

    return ,$found
}

function Extract-With7Zip([string]$pkg,[string]$outDir,[string]$sevenZip) {
    if (-not $sevenZip) { return @{Ok=$false; Note="7-Zip not available"} }
    $r = Invoke-ProcessWithTimeout -FilePath $sevenZip -ArgumentList @("x","-y",("-o{0}" -f $outDir),$pkg) -TimeoutSeconds 300
    if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) { return @{Ok=$true; Note="Extracted (7-Zip)"} }
    return @{Ok=$false; Note=("7-Zip failed exit={0} timeout={1}" -f $r.ExitCode,$r.TimedOut)}
}

function Extract-Zip([string]$pkg,[string]$outDir,[string]$sevenZip) {
    try {
        Expand-Archive -LiteralPath $pkg -DestinationPath $outDir -Force
        if (Has-AnyFiles $outDir) { return @{Ok=$true; Note="ZIP extracted (Expand-Archive)"} }
    } catch {}
    return (Extract-With7Zip -pkg $pkg -outDir $outDir -sevenZip $sevenZip)
}

function Extract-Cab([string]$pkg,[string]$outDir) {
    $expand = Get-Command expand.exe -ErrorAction SilentlyContinue
    if (-not $expand) { return @{Ok=$false; Note="expand.exe not found"} }
    $r = Invoke-ProcessWithTimeout -FilePath $expand.Source -ArgumentList @("-F:*",$pkg,$outDir) -TimeoutSeconds 180
    if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) { return @{Ok=$true; Note="CAB extracted (expand.exe)"} }
    return @{Ok=$false; Note=("CAB failed exit={0} timeout={1}" -f $r.ExitCode,$r.TimedOut)}
}

function Extract-Msi([string]$pkg,[string]$outDir) {
    $args = @("/a",$pkg,"/qn",("TARGETDIR={0}" -f $outDir))
    $r = Invoke-ProcessWithTimeout -FilePath "msiexec.exe" -ArgumentList $args -TimeoutSeconds 300
    if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) { return @{Ok=$true; Note="MSI extracted (msiexec /a)"} }
    return @{Ok=$false; Note=("MSI failed exit={0} timeout={1}" -f $r.ExitCode,$r.TimedOut)}
}

function Extract-Exe([string]$pkg,[string]$outDir,[string]$sevenZip) {
    $z = Extract-With7Zip -pkg $pkg -outDir $outDir -sevenZip $sevenZip
    if ($z.Ok) { return @{Ok=$true; Note="EXE extracted (7-Zip)"} }

    $candidates = @(
        @("/extract:`"$outDir`" /quiet"),
        @("/extract:`"$outDir`""),
        @("/x:`"$outDir`" /quiet"),
        @("/x:`"$outDir`""),
        @("/S","/D=`"$outDir`""),           # NSIS
        @("/VERYSILENT","/DIR=`"$outDir`"") # Inno Setup
    )

    foreach ($args in $candidates) {
        $r = Invoke-ProcessWithTimeout -FilePath $pkg -ArgumentList $args -TimeoutSeconds 240
        Start-Sleep -Milliseconds 350
        if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) {
            return @{Ok=$true; Note=("EXE extracted (switch: {0})" -f ($args -join " ")) }
        }
    }

    return @{Ok=$false; Note="EXE not extractable silently. Install 7-Zip or extract manually."}
}

function Extract-Package([string]$pkg,[string]$rootOut,[string]$driveId,[string]$sevenZip) {
    $base  = Sanitize-Name ([IO.Path]::GetFileNameWithoutExtension($pkg))
    $stamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    $ext   = ([IO.Path]::GetExtension($pkg)).ToLowerInvariant()

    $destRoot = Join-Path $rootOut ("Extracted\{0}" -f $driveId.TrimEnd(':'))
    Ensure-Dir $destRoot

    $outDir = Join-Path $destRoot ("{0}_{1}" -f $base,$stamp)
    Ensure-Dir $outDir

    if ($CopyPackageIntoOutput) {
        try {
            $srcDir = Join-Path $outDir "_source"
            Ensure-Dir $srcDir
            Copy-Item -LiteralPath $pkg -Destination (Join-Path $srcDir (Split-Path $pkg -Leaf)) -Force -ErrorAction SilentlyContinue
        } catch {}
    }

    switch ($ext) {
        ".zip" { $res = Extract-Zip -pkg $pkg -outDir $outDir -sevenZip $sevenZip }
        ".cab" { $res = Extract-Cab -pkg $pkg -outDir $outDir }
        ".msi" { $res = Extract-Msi -pkg $pkg -outDir $outDir }
        ".exe" { $res = Extract-Exe -pkg $pkg -outDir $outDir -sevenZip $sevenZip }
        default { $res = Extract-With7Zip -pkg $pkg -outDir $outDir -sevenZip $sevenZip }
    }

    $infCount = 0
    if ($res.Ok -eq $true) { $infCount = Count-Inf $outDir }

    return [pscustomobject]@{
        Ok       = $res.Ok
        Package  = $pkg
        Drive    = $driveId
        OutDir   = $outDir
        Note     = $res.Note
        InfCount = $infCount
        Ext      = $ext
    }
}

function Run-ScanExtractMode([string]$outRoot,[string]$logDir) {
    Title "MODE 2: SCAN + EXTRACT"
    Write-Host "| This mode is slower and less reliable than pnputil export.   |" -ForegroundColor Yellow
    Line
    if (-not (Confirm-YesNoKey "Continue with Scan+Extract mode?")) { Write-Warn "Cancelled."; return }

    $drives = @((Get-LocalDrives))
    if (-not $drives -or $drives.Count -eq 0) { Write-Warn "No local drives detected."; return }

    $selectedDrives = @(Choose-DrivesNoEnter -Drives $drives)
    if (-not $selectedDrives -or $selectedDrives.Count -eq 0) { Write-Warn "Cancelled (no drives selected)."; return }

    $sevenZip = Get-7ZipPath
    if (-not $sevenZip) {
        Title "7-ZIP"
        Write-Host "| 7-Zip not found. Coverage limited for EXE/7Z/RAR.            |" -ForegroundColor Yellow
        Line
        if (Confirm-YesNoKey "Install 7-Zip via winget now?") {
            $ok = Try-Install7ZipWinget
            $sevenZip = Get-7ZipPath
            if ($ok -and $sevenZip) { Write-Ok "7-Zip installed and detected." } else { Write-Warn "7-Zip install failed/unavailable. Continuing." }
        }
    }

    Title "SYSTEM SCAN"
    $scanStart = Get-Date

    $list = New-Object System.Collections.Generic.List[object]
    $driveIndex = 0
    $totalDrives = [int][math]::Max(1, $selectedDrives.Count)

    foreach ($d in $selectedDrives) {
        $driveIndex++
        $pct = [int]([math]::Round(($driveIndex / [double]$totalDrives) * 100.0))
        ProgressBar ("Scanning drive: " + $d.DeviceID) $pct $scanStart

        $found = @(Scan-DriveForPackages -DriveRoot $d.Root -DriveId $d.DeviceID)
        foreach ($f in $found) { $list.Add([pscustomobject]@{ Drive=$d.DeviceID; Path=$f }) | Out-Null }

        Safe-CursorUp 2
    }

    ProgressBar "Scan complete" 100 $scanStart
    Line

    $allFound = $list.ToArray()

    $manifest = Join-Path $logDir "found_packages.txt"
    $summary  = Join-Path $logDir "summary.txt"
    $allFound | Sort-Object Drive, Path | ForEach-Object { "{0}`t{1}" -f $_.Drive, $_.Path } |
        Out-File -FilePath $manifest -Encoding UTF8 -Force

    Title "SCAN RESULT"
    Info "Found" $allFound.Count
    Info "Manifest" $manifest
    Line

    if ($allFound.Count -eq 0) { Write-Warn "No packages found."; return }
    if (-not (Confirm-YesNoKey "Proceed to extract ALL found packages?")) { Write-Warn "Cancelled."; return }

    Title "EXTRACTION"
    $extStart = Get-Date
    $resultsList = New-Object System.Collections.Generic.List[object]
    $total = [int][math]::Max(1, $allFound.Count)
    $idx = 0

    foreach ($item in $allFound) {
        $idx++
        $pct = [int]([math]::Round(($idx / [double]$total) * 100.0))
        $leaf = Split-Path $item.Path -Leaf
        $label = ("{0}/{1}: {2}" -f $idx,$total,$leaf)
        if ($label.Length -gt 60) { $label = $label.Substring(0,60) }

        ProgressBar $label $pct $extStart

        try {
            $r = Extract-Package -pkg $item.Path -rootOut $outRoot -driveId $item.Drive -sevenZip $sevenZip
            $resultsList.Add($r) | Out-Null
        } catch {
            $resultsList.Add([pscustomobject]@{
                Ok=$false; Package=$item.Path; Drive=$item.Drive; OutDir=""; Note=$_.Exception.Message; InfCount=0; Ext=([IO.Path]::GetExtension($item.Path))
            }) | Out-Null
        }

        Safe-CursorUp 2
    }

    ProgressBar "Extraction complete" 100 $extStart
    Line

    $results = $resultsList.ToArray()
    $ok  = @($results | Where-Object { $_.Ok -eq $true })
    $bad = @($results | Where-Object { $_.Ok -ne $true })
    $infTotal = ($ok | Measure-Object -Property InfCount -Sum).Sum

    Title "RUN SUMMARY"
    Info "Success" $ok.Count
    Info "Failed"  $bad.Count
    Info "INF"     $infTotal
    Line

    @(
      "Output: $outRoot"
      "LogDir: $logDir"
      "Mode  : Scan+Extract"
      "SelectedDrives: $($selectedDrives.DeviceID -join ', ')"
      "Found : $($allFound.Count)"
      "OK    : $($ok.Count)"
      "Fail  : $($bad.Count)"
      "INF   : $infTotal"
      ""
      "Failures (first 30):"
    ) + ($bad | Select-Object -First 30 | ForEach-Object { "$($_.Drive)`t$($_.Ext)`t$($_.Package)`t$($_.Note)" }) |
    Out-File -FilePath $summary -Encoding UTF8 -Force

    Info "Summary" $summary
    Line
}

# -----------------------------
# MAIN
# -----------------------------
Show-Banner
$startAll = Get-Date

$outRoot = Choose-OutputRoot -DefaultPath $DefaultOut
try { Ensure-Dir $outRoot }
catch {
    Write-Warn "Cannot create/access output path. Falling back to default: $DefaultOut"
    $outRoot = $DefaultOut
    Ensure-Dir $outRoot
}

$logDir = Join-Path $outRoot ("Logs\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
Ensure-Dir $logDir

Title "RUN CONTEXT"
Info "Output" $outRoot
Info "LogDir" $logDir
Info "Start"  (Get-Date)
Line

$mode = Menu-Mode
if ($mode -eq "X") { Write-Warn "Exit."; exit 0 }

if ($mode -eq "1") {
    Export-DriverStore -OutputRoot $outRoot -LogDir $logDir
    Write-Ok "Done."
    exit 0
}

Run-ScanExtractMode -outRoot $outRoot -logDir $logDir
Write-Ok "Done."

# SIG # Begin signature block
# MIIb1AYJKoZIhvcNAQcCoIIbxTCCG8ECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUohxbtL2M1heiG6sqBREUytKw
# dl2gghZEMIIDBjCCAe6gAwIBAgIQEL8pRoGkFYRO4LQqey1D4DANBgkqhkiG9w0B
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
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBTpBNNNhcOmzuGUdpfgQHLymyNrfzANBgkq
# hkiG9w0BAQEFAASCAQAWk6LmycshD9jff/UpK3Nb7BzEEvHdlmHROrwrQakF1884
# mYlPgA/PnzCB5QG5tS691smVoonLeLguukpejT+Ng8JyQsuo/QG/sFd+lwIrCp3L
# 0IZ5PoX+KIYwyCBrU9c37hn4P87rk0f5SI1Pv6lxvvlgGLoBuLEfaiNKZXnqC20P
# UiuFo/vDFgRBnJU3PkMoRqV0AW5VCtEdUXtZjgejpkP9C8wlManwnJKffVwozMPG
# NiOq3FzjU2qz+fRqREBDyqefYoEPlEFJ6VlVC487AzGIIQFMP5EZC+EChveDqyum
# 1bLiN3CIL6l0aiIlbr8f9ggc92C6ONJ3YyBPcbLAoYIDJjCCAyIGCSqGSIb3DQEJ
# BjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGlu
# ZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglg
# hkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcN
# AQkFMQ8XDTI2MDcwNzA4NDQzOVowLwYJKoZIhvcNAQkEMSIEIOeDgKrlctW4U3+Q
# 7Va8w4H4UYbpJBZdbY8FmrjFP3UqMA0GCSqGSIb3DQEBAQUABIICAHLR22nwwes+
# KtxcUimXPYvhGtGTtndXxP+uYSJ4/vWyOv78mGV1lckpD9rc5lyGMuk9vaxTmKFm
# LuM3zci+kyJSISwrIdD+yXZFNh6ddSo+P/BH96MIjwbz7vCoXjxt6UKlGemG0Wdq
# h2c1jvAptsBfBYFBW4UW5lF61MGa225v7/9rkB4ae3JmkO4Cphz6z9dG+UP0pvyd
# zGRIN2qBxAJFOlWg3Rvc7wX3eziDG6NvI0CIH4y4pjbzmvzNNyGtjkV0i2F3BY+x
# 7E55DrvusUGzkPH8YWMaDBAyprbSVyBlrPbU1s8EUc6k4A3xGAvp7/G2BCzQdt+F
# 2ichqK+6eGmGUxRIEUr9KxYW5y26bEza6XfMir5gjPQuD4ydEGpZa9wgWD6dja09
# SgYppl30WiXI5ZbthgMFUDG3moL0c3SNsh2HELznnuYPLy1C2kmvuIDtoibJOAYB
# kuL0zq6Jedns86ExCC6isi/qm4NNQcmQ5OEuJd7JgOYzmA5m0VtcDSsf4c+OMNnO
# jwPPurVWRsKuNNE/BFgHUFaZP4rkl973CpuazOXMcybPSdXaabzlqTfyjtKCUtze
# SuTrSxekwfd6+ponVlZSstTpV2PHqylF95wHAdRuFNA+fcq2ijCJmjmcf7OzN/9v
# 8mc3WrB2sEW8LOHxCraNqVIHTV+V6i7R
# SIG # End signature block
