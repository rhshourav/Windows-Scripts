<#
# =========================================
# Driver Extractor - ASCII Safe (Robust)
# Source  : System-wide local drives (auto)
# Output  : C:\Extracted-DRivers (default)
# =========================================
# Version : v1.1.0
# Author  : rhshourav
# GitHub  : https://github.com/rhshourav
# =========================================
#>

[CmdletBinding()]
param()

# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

$ErrorActionPreference = "Stop"

# -----------------------------
# Auto-Elevate to Admin
# -----------------------------
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {

    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow

    $argsList = @()
    foreach ($arg in $MyInvocation.UnboundArguments) {
        $argsList += '"' + $arg + '"'
    }

    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($argsList -join ' ')" `
        -Verb RunAs

    exit
}

# ---------- UI ----------
function Line { Write-Host "+------------------------------------------------------+" -ForegroundColor Cyan }
function Title($t) {
    Line
    Write-Host ("| " + $t.PadRight(52) + " |") -ForegroundColor Yellow
    Line
}
function Info($k,$v) {
    $vk = if ($null -eq $v -or $v -eq "") { "N/A" } else { $v.ToString() }
    if ($vk.Length -gt 38) { $vk = $vk.Substring(0,38) }
    Write-Host ("| {0,-10}: {1,-38} |" -f $k,$vk) -ForegroundColor Gray
}
function ProgressBar($label,$pct,$start) {
    $elapsed = (Get-Date) - $start
    $eta = if ($pct -gt 0) {
        [TimeSpan]::FromSeconds(([math]::Max(0,$elapsed.TotalSeconds) / $pct) * (100 - $pct))
    } else { "??" }

    $blocks = [math]::Floor($pct/4)
    $bar = ("#" * $blocks).PadRight(25,".")
    Write-Host ("| {0,-50} |" -f $label) -ForegroundColor Cyan
    Write-Host ("| [{0}] {1,3}% ETA {2,-8} |" -f $bar,$pct,$eta) -ForegroundColor Green
}

function Show-Banner {
    Clear-Host
    $line = "============================================================"
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "| Driver Extractor - System-wide (ASCII Safe)            |" -ForegroundColor Cyan
    Write-Host "| Version : v1.1.0                                       |" -ForegroundColor Gray
    Write-Host "| Author  : rhshourav                                    |" -ForegroundColor Gray
    Write-Host "| GitHub  : https://github.com/rhshourav                 |" -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ""
}

function Confirm-YesNo($prompt) {
    $ans = (Read-Host ($prompt + " (y/N)")).Trim().ToLowerInvariant()
    return ($ans -eq "y" -or $ans -eq "yes")
}

# -----------------------------
# Settings
# -----------------------------
$DefaultOut = "C:\Extracted-DRivers"

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
# Core helpers
# -----------------------------
function Ensure-Dir([string]$path) {
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
    foreach ($d in $disks) {
        if ($d.DriveType -in 2,3) {
            $root = ($d.DeviceID + "\")
            if (Test-Path -LiteralPath $root) {
                $targets += [pscustomobject]@{
                    DeviceID  = $d.DeviceID     # e.g. "C:"
                    Root      = $root           # e.g. "C:\"
                    DriveType = $d.DriveType    # 2 removable, 3 fixed
                    Volume    = $d.VolumeName
                }
            }
        }
    }
    return $targets
}

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

# -----------------------------
# NEW: Drive multi-selector (numbers and/or letters)
# -----------------------------
function Choose-Drives {
    param([Parameter(Mandatory)] $Drives)

    if (-not $Drives -or $Drives.Count -eq 0) { return @() }

    while ($true) {
        Title "DRIVE SELECTION"
        Write-Host "| Select drives by number or letter. Multi-select ok.   |" -ForegroundColor Gray
        Write-Host "| Examples: 1,3     OR     C,D     OR     1,D     OR all |" -ForegroundColor Gray
        Write-Host "| Press Enter for ALL. Type Q to cancel.                |" -ForegroundColor Gray
        Line

        for ($i=0; $i -lt $Drives.Count; $i++) {
            $d = $Drives[$i]
            $t = if ($d.DriveType -eq 3) { "Fixed" } else { "Removable" }
            $vol = if ([string]::IsNullOrWhiteSpace($d.Volume)) { "" } else { $d.Volume }
            Write-Host ("| {0,2}. {1,-3} {2,-9} {3,-33} |" -f ($i+1), $d.DeviceID, $t, ($d.Root + " " + $vol)) -ForegroundColor Gray
        }
        Line

        $rawSel = (Read-Host "Select drives").Trim()
        if ([string]::IsNullOrWhiteSpace($rawSel)) { return @($Drives) }

        $lower = $rawSel.Trim().ToLowerInvariant()
        if ($lower -eq "q" -or $lower -eq "quit" -or $lower -eq "exit") { return @() }
        if ($lower -eq "all") { return @($Drives) }

        $tokens = $lower -split '[,; ]+' | Where-Object { $_ -and $_.Trim() -ne "" }
        $picked = New-Object System.Collections.Generic.List[object]

        foreach ($tok in $tokens) {
            $t = $tok.Trim()

            # numeric index
            if ($t -match '^\d+$') {
                $idx = [int]$t
                if ($idx -ge 1 -and $idx -le $Drives.Count) {
                    $picked.Add($Drives[$idx-1]) | Out-Null
                }
                continue
            }

            # drive letter "c" or "c:"
            if ($t -match '^[a-z](:)?$') {
                $letter = ($t[0].ToString().ToUpperInvariant() + ":")
                $match = $Drives | Where-Object { $_.DeviceID -eq $letter } | Select-Object -First 1
                if ($match) { $picked.Add($match) | Out-Null }
                continue
            }
        }

        $picked = @($picked | Select-Object -Unique)
        if ($picked.Count -gt 0) {
            Title "SELECTED DRIVES"
            foreach ($d in $picked) {
                $t = if ($d.DriveType -eq 3) { "Fixed" } else { "Removable" }
                Write-Host ("| {0,-3} {1,-9} {2,-37} |" -f $d.DeviceID, $t, ($d.Root + " " + $d.Volume)) -ForegroundColor Gray
            }
            Line
            if (Confirm-YesNo "Proceed with these selected drives?") {
                return @($picked)
            }
            # else loop again
            continue
        }

        Write-Host "Invalid selection. Use numbers, letters, or 'all'." -ForegroundColor Yellow
    }
}

# -----------------------------
# FAST-ish scan with pruning (manual recursion)
# -----------------------------
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
        try {
            $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        } catch {
            continue
        }

        foreach ($it in $items) {
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

    return $found
}

# -----------------------------
# Output selection (default always exists)
# -----------------------------
function Choose-OutputRoot([string]$DefaultPath) {
    Title "OUTPUT LOCATION"
    Info "Default" $DefaultPath
    Write-Host "| Press Enter to keep default, or type custom path      |" -ForegroundColor Gray
    Line
    $custom = Read-Host "Output folder"
    if ([string]::IsNullOrWhiteSpace($custom)) { return $DefaultPath }
    return $custom.Trim().Trim('"').Trim("'")
}

# -----------------------------
# Extractors
# -----------------------------
function Extract-With7Zip([string]$pkg,[string]$outDir,[string]$sevenZip) {
    if (-not $sevenZip) { return @{Ok=$false; Note="7-Zip not available"} }
    $r = Invoke-ProcessWithTimeout -FilePath $sevenZip -ArgumentList @("x","-y",("-o{0}" -f $outDir),$pkg) -TimeoutSeconds 300
    if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) {
        return @{Ok=$true; Note="Extracted (7-Zip)"} 
    }
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
    if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) {
        return @{Ok=$true; Note="CAB extracted (expand.exe)"}
    }
    return @{Ok=$false; Note=("CAB failed exit={0} timeout={1}" -f $r.ExitCode,$r.TimedOut)}
}

function Extract-Msi([string]$pkg,[string]$outDir) {
    $args = @("/a",$pkg,"/qn",("TARGETDIR={0}" -f $outDir))
    $r = Invoke-ProcessWithTimeout -FilePath "msiexec.exe" -ArgumentList $args -TimeoutSeconds 300
    if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) {
        return @{Ok=$true; Note="MSI extracted (msiexec /a)"}
    }
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
        Start-Sleep -Milliseconds 400
        if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and (Has-AnyFiles $outDir)) {
            return @{Ok=$true; Note=("EXE extracted (switch: {0})" -f ($args -join " ")) }
        }
    }

    return @{Ok=$false; Note="EXE not extractable silently. Install 7-Zip or extract manually."}
}

function Extract-Package([string]$pkg,[string]$rootOut,[string]$driveId,[string]$sevenZip) {
    $base = Sanitize-Name ([IO.Path]::GetFileNameWithoutExtension($pkg))
    $stamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    $ext = ([IO.Path]::GetExtension($pkg)).ToLowerInvariant()

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

# -----------------------------
# MAIN
# -----------------------------
Show-Banner
$startAll = Get-Date

$outRoot = Choose-OutputRoot -DefaultPath $DefaultOut
try { Ensure-Dir $outRoot } catch { $outRoot = $DefaultOut; Ensure-Dir $outRoot }

$logDir = Join-Path $outRoot ("Logs\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
Ensure-Dir $logDir
$manifest = Join-Path $logDir "found_packages.txt"
$summary  = Join-Path $logDir "summary.txt"

Title "RUN CONTEXT"
Info "Output" $outRoot
Info "LogDir" $logDir
Info "Start"  (Get-Date)
Line

# Drives
$drives = Get-LocalDrives
if (-not $drives -or $drives.Count -eq 0) {
    Write-Host "No local fixed/removable drives detected." -ForegroundColor Yellow
    exit 1
}

# NEW: select drives (multi)
$selectedDrives = Choose-Drives -Drives $drives
if (-not $selectedDrives -or $selectedDrives.Count -eq 0) {
    Write-Host "Cancelled (no drives selected)." -ForegroundColor Yellow
    exit 0
}

# 7-Zip (optional)
$sevenZip = Get-7ZipPath
if (-not $sevenZip) {
    Title "7-ZIP"
    Write-Host "| 7-Zip not found. Extraction coverage will be limited. |" -ForegroundColor Yellow
    Write-Host "| Optional: install via winget to improve success rate. |" -ForegroundColor Yellow
    Line
    if (Confirm-YesNo "Install 7-Zip via winget now?") {
        $ok = Try-Install7ZipWinget
        $sevenZip = Get-7ZipPath
        if ($ok -and $sevenZip) {
            Write-Host "7-Zip installed and detected." -ForegroundColor Green
        } else {
            Write-Host "7-Zip install failed/unavailable. Continuing." -ForegroundColor Yellow
        }
    }
}

# -----------------------------
# SCAN (only selected drives)
# -----------------------------
Title "SYSTEM SCAN"
$scanStart = Get-Date
$allFound = New-Object System.Collections.Generic.List[object]
$driveIndex = 0
$totalDrives = $selectedDrives.Count

foreach ($d in $selectedDrives) {
    $driveIndex++
    $pct = [math]::Round(($driveIndex / $totalDrives) * 100)
    ProgressBar ("Scanning drive: " + $d.DeviceID) $pct $scanStart

    $found = Scan-DriveForPackages -DriveRoot $d.Root -DriveId $d.DeviceID

    foreach ($f in $found) {
        $allFound.Add([pscustomobject]@{ Drive=$d.DeviceID; Path=$f }) | Out-Null
    }

    try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
}

ProgressBar "Scan complete" 100 $scanStart
Line

# Save manifest
$allFound | Sort-Object Drive, Path | ForEach-Object { "{0}`t{1}" -f $_.Drive, $_.Path } | Out-File -FilePath $manifest -Encoding UTF8 -Force

Title "SCAN RESULT"
Info "Found" $allFound.Count
Info "Manifest" $manifest
Line

if ($allFound.Count -eq 0) {
    Write-Host "No packages found with configured extensions/exclusions." -ForegroundColor Yellow
    exit 0
}

if (-not (Confirm-YesNo "Proceed to copy+extract all found packages?")) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# -----------------------------
# EXTRACT
# -----------------------------
Title "EXTRACTION"
$extStart = Get-Date
$results = New-Object System.Collections.Generic.List[object]
$total = $allFound.Count
$idx = 0

foreach ($item in $allFound) {
    $idx++
    $pct = [math]::Round(($idx / $total) * 100)
    $leaf = Split-Path $item.Path -Leaf
    $label = ("{0}/{1}: {2}" -f $idx,$total,$leaf)
    if ($label.Length -gt 50) { $label = $label.Substring(0,50) }

    ProgressBar $label $pct $extStart
    Start-Sleep -Milliseconds 80

    try {
        $r = Extract-Package -pkg $item.Path -rootOut $outRoot -driveId $item.Drive -sevenZip $sevenZip
        $results.Add($r) | Out-Null
    } catch {
        $results.Add([pscustomobject]@{
            Ok=$false; Package=$item.Path; Drive=$item.Drive; OutDir=""; Note=$_.Exception.Message; InfCount=0; Ext=([IO.Path]::GetExtension($item.Path))
        }) | Out-Null
    }

    try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
}

ProgressBar "Extraction complete" 100 $extStart
Line

# -----------------------------
# SUMMARY
# -----------------------------
$ok = @($results | Where-Object { $_.Ok -eq $true })
$bad = @($results | Where-Object { $_.Ok -ne $true })
$infTotal = ($ok | Measure-Object -Property InfCount -Sum).Sum

Title "RUN SUMMARY"
Info "Success" $ok.Count
Info "Failed"  $bad.Count
Info "INF"     $infTotal
Info "Elapsed" ((Get-Date) - $startAll)
Line

@(
  "Output: $outRoot"
  "LogDir: $logDir"
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

Write-Host "Done." -ForegroundColor Green
