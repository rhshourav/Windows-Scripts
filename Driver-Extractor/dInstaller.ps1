<#
# =========================================
# Driver Installer - ASCII Safe (Robust)
# Installs INF drivers via PnPUtil
# =========================================
# Version : v1.0.0
# Author  : rhshourav
# GitHub  : https://github.com/rhshourav
# Default : C:\Extracted-DRivers\Extracted
# =========================================
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$DriverRoot = "C:\Extracted-DRivers\Extracted"
)

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

    $dry = if ($DryRun) { "-DryRun" } else { "" }
    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $dry -DriverRoot `"$DriverRoot`" $($argsList -join ' ')" `
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
    Write-Host "| Driver Installer - INF (PnPUtil)                       |" -ForegroundColor Cyan
    Write-Host "| Version : v1.0.0                                       |" -ForegroundColor Gray
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
# Helpers
# -----------------------------
function Ensure-Root([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Driver root not found: $path"
    }
}

function Get-InfList([string]$root) {
    # Prefer unique paths; exclude printer class drivers is optional—keeping everything by default
    return Get-ChildItem -LiteralPath $root -Recurse -Force -Filter *.inf -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName -Unique
}

function Invoke-PnpUtilAddInstall([string]$infPath) {
    # /add-driver "<inf>" /install
    # Returns: object with exitcode and output
    $out = & pnputil.exe /add-driver "`"$infPath`"" /install 2>&1
    $code = $LASTEXITCODE
    return @{
        ExitCode = $code
        Output   = ($out | Out-String).Trim()
    }
}

function Is-SuccessOutput([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    # pnputil output varies by version/language; use heuristic keywords
    return ($text -match "(?i)driver package added|published name|successfully|completed")
}

# -----------------------------
# MAIN
# -----------------------------
Show-Banner

Title "CONFIG"
Info "DryRun" $DryRun
Info "DefaultRoot" "C:\Extracted-DRivers\Extracted"
Line

# Allow user to override root without forcing it
$root = $DriverRoot
$resp = Read-Host ("Driver root folder [Enter to use: {0}]" -f $root)
if (-not [string]::IsNullOrWhiteSpace($resp)) {
    $root = $resp.Trim().Trim('"').Trim("'")
}

Ensure-Root $root

Title "DISCOVERY"
Info "Root" $root
$infs = Get-InfList $root
Info "INF Files" $infs.Count
Line

if ($infs.Count -eq 0) {
    Write-Host "No INF files found. Nothing to install." -ForegroundColor Yellow
    exit 0
}

if ($DryRun) {
    Title "DRY RUN (PREVIEW)"
    Write-Host "| No changes will be made. Showing sample INF paths.    |" -ForegroundColor Gray
    Line
    $infs | Select-Object -First 25 | ForEach-Object {
        $p = $_
        if ($p.Length -gt 56) { $p = "..." + $p.Substring($p.Length-53) }
        Write-Host ("| {0,-52} |" -f $p) -ForegroundColor DarkGray
    }
    Line
    if ($infs.Count -gt 25) {
        Write-Host ("| ... and {0} more                                      |" -f ($infs.Count-25)) -ForegroundColor Gray
        Line
    }
    exit 0
}

if (-not (Confirm-YesNo "Install drivers from ALL INF files found?")) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# Logging
$logDir = Join-Path $env:ProgramData ("rhshourav\DriverInstaller\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logOk  = Join-Path $logDir "installed_ok.txt"
$logBad = Join-Path $logDir "installed_failed.txt"

# Install loop
Title "INSTALLATION"
$start = Get-Date
$total = $infs.Count
$i = 0

$ok = New-Object System.Collections.Generic.List[string]
$bad = New-Object System.Collections.Generic.List[string]

foreach ($inf in $infs) {
    $i++
    $pct = [math]::Round(($i / $total) * 100)
    $leaf = Split-Path $inf -Leaf
    $label = ("{0}/{1}: {2}" -f $i,$total,$leaf)
    if ($label.Length -gt 50) { $label = $label.Substring(0,50) }

    ProgressBar $label $pct $start
    Start-Sleep -Milliseconds 80

    try {
        $r = Invoke-PnpUtilAddInstall -infPath $inf

        # Consider success if exit code = 0 OR output suggests success
        if ($r.ExitCode -eq 0 -or (Is-SuccessOutput $r.Output)) {
            $ok.Add($inf) | Out-Null
            Add-Content -Path $logOk -Value $inf
        } else {
            $bad.Add(("{0} :: exit={1}" -f $inf,$r.ExitCode)) | Out-Null
            Add-Content -Path $logBad -Value ("{0}`n{1}`n---" -f $inf, $r.Output)
        }
    } catch {
        $bad.Add(("{0} :: {1}" -f $inf,$_.Exception.Message)) | Out-Null
        Add-Content -Path $logBad -Value ("{0}`n{1}`n---" -f $inf,$_.Exception.Message)
    }

    try { [Console]::SetCursorPosition(0,[Console]::CursorTop - 2) } catch {}
}

ProgressBar "Driver install complete" 100 $start
Line

# Summary
Title "RUN SUMMARY"
Info "Installed" $ok.Count
Info "Failed"    $bad.Count
Info "LogDir"    $logDir
Line

if ($bad.Count -gt 0) {
    Title "FAILURES (TOP)"
    $bad | Select-Object -First 10 | ForEach-Object {
        $msg = $_
        if ($msg.Length -gt 56) { $msg = $msg.Substring(0,56) }
        Write-Host ("| {0,-52} |" -f $msg) -ForegroundColor Yellow
    }
    Line
    Write-Host "Some failures are normal (unsigned/incompatible drivers)." -ForegroundColor Yellow
}

Write-Host "Done." -ForegroundColor Green
