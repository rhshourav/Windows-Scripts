<#
.SYNOPSIS
    Restore system state from snapshot for Windows Optimizer

.AUTHOR
    Shourav (rhshoruav)

.VERSION
    1.0.0
#>

function Restore-Snapshot {
    $snapshotFiles = Get-ChildItem "$PSScriptRoot\..\snapshots" -Filter "*.json" | Sort-Object LastWriteTime -Descending

    if ($snapshotFiles.Count -eq 0) {
        Write-Host "No snapshots found to restore." -ForegroundColor Yellow
        Write-Log "Restore attempted but no snapshots found" "WARN"
        return
    }

    $latest = $snapshotFiles[0].FullName
    Write-Host "Restoring snapshot: $latest" -ForegroundColor Cyan
    Write-Log "Restoring snapshot: $latest"

    try {
        $data = Get-Content $latest | ConvertFrom-Json

        # Restore services
        foreach ($svc in $data.Services) {
            try {
                Set-Service -Name $svc.Name -StartupType $svc.StartType -ErrorAction SilentlyContinue
                if ($svc.Status -eq "Running") { Start-Service $svc.Name -ErrorAction SilentlyContinue }
                if ($svc.Status -eq "Stopped") { Stop-Service $svc.Name -ErrorAction SilentlyContinue }
            }
            catch { Write-Log "Failed to restore service $($svc.Name): $_" "WARN" }
        }

        # Restore VisualFX
        if ($data.VisualFX) {
            foreach ($prop in $data.VisualFX.PSObject.Properties) {
                Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
                                 -Name $prop.Name -Value $prop.Value -ErrorAction SilentlyContinue
            }
        }

        Write-Log "Snapshot restoration completed"
        Write-Host "Restoration completed." -ForegroundColor Green
    }
    catch {
        Write-Log "Snapshot restoration failed: $_" "ERROR"
        Write-Host "Restoration failed." -ForegroundColor Red
    }
}
