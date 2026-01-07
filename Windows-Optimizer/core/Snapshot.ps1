<#
.SYNOPSIS
    Snapshot system state for Windows Optimizer (services, power plan, registry)

.AUTHOR
    Shourav (rhshoruav)

.VERSION
    1.0.0
#>

# -------------------------------
# Snapshot Folder
# -------------------------------
$SnapshotPath = "$PSScriptRoot\..\snapshots"
if (-not (Test-Path $SnapshotPath)) { New-Item -ItemType Directory -Force -Path $SnapshotPath | Out-Null }

function Save-Snapshot {
    try {
        $file = Join-Path $SnapshotPath ("snapshot_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")

        $data = @{
            Services   = Get-Service | Select Name, StartType, Status
            PowerPlan  = (powercfg /getactivescheme | Out-String).Trim()
            VisualFX   = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
        }

        $data | ConvertTo-Json -Depth 4 | Set-Content $file
        Write-Log "Snapshot saved: $file"
    }
    catch {
        Write-Log "Snapshot failed: $_" "ERROR"
        throw
    }
}
