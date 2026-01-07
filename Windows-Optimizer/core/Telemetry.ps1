<#
.SYNOPSIS
    Telemetry module for Windows Optimizer (enabled by default)

.AUTHOR
    Shourav (rhshoruav)

.VERSION
    1.0.0
#>

$Global:TelemetryEnabled = $true
$Global:TelemetryEndpoint = "https://cryocore.rhshourav02.workers.dev/message"
$Global:TelemetryToken = "shourav"

# Persistent opt-out check
$key = "HKCU:\Software\WindowsOptimizer"
if (Test-Path $key) {
    $flag = Get-ItemProperty $key -Name "TelemetryDisabled" -ErrorAction SilentlyContinue
    if ($flag.TelemetryDisabled -eq 1) { $Global:TelemetryEnabled = $false }
}

function Show-TelemetryNotice {
    if (-not $Global:TelemetryEnabled) { return }

    Write-Host ""
    Write-Host "NOTICE: Telemetry is ENABLED by default."
    Write-Host "This tool will send limited, non-sensitive system metadata to the developer for improvement purposes."
    Write-Host ""
    Write-Host "Collected Data:"
    Write-Host "- Username"
    Write-Host "- PC Name"
    Write-Host "- Domain/Workgroup"
    Write-Host "- Local IPv4 addresses"
    Write-Host "- Selected optimization profile"
    Write-Host "- Timestamp"
    Write-Host ""
    Write-Host "Type DISABLE to permanently turn off telemetry, or press Enter to continue."

    $choice = Read-Host "Choice"
    if ($choice -match '^(DISABLE|disable)$') { Disable-Telemetry }
}

function Disable-Telemetry {
    $Global:TelemetryEnabled = $false
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "TelemetryDisabled" -Value 1 -Type DWord
    Write-Log "Telemetry permanently disabled by user"
}

function Send-Telemetry {
    param([string]$ProfileName)
    if (-not $Global:TelemetryEnabled) { return }

    try {
        $payload = @{
            token = $Global:TelemetryToken
            text  = @"
System Info:
User Name: $env:USERNAME
PC Name: $env:COMPUTERNAME
Domain Name: $env:USERDOMAIN
Local IP(s): $(
    Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '127.*' } |
    ForEach-Object { $_.IPAddress } -join ', '
)
Optimization Profile: $ProfileName
Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $Global:TelemetryEndpoint -Method Post -ContentType "application/json" -Body $payload -ErrorAction Stop
        Write-Log "Telemetry sent for profile: $ProfileName"
    }
    catch {
        Write-Log "Telemetry failed: $_" "WARN"
    }
}
