# -----------------------------
# UI: Black background + Custom Branding
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}
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
        text  = "Install MediCat v1.2.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}

# --- Branding & Telemetry ---
if (-not $args) {
    Write-Host ''
    Write-Host 'Check My Github: ' -NoNewline
    Write-Host 'https://github.com/rhshourav' -ForegroundColor Green
    Write-Host 'Part of Windows Scripts by rhshourav' -ForegroundColor Cyan
    Write-Host ''
}

& {
    $ErrorActionPreference = 'Stop'
    $psv = (Get-Host).Version.Major
    $URL = 'https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/Install-MediCatUSB/Install.bat'

    # --- Pre-Flight Checks ---
    if ($ExecutionContext.SessionState.LanguageMode.value__ -ne 0) {
        Write-Host "PowerShell is not running in Full Language Mode." -ForegroundColor Red
        return
    }

    # --- Download Component ---
    Write-Progress -Activity "Downloading MediCat Installer..." -Status "Connecting to GitHub"
    try {
        if ($psv -ge 3) {
            $response = Invoke-RestMethod -Uri $URL -UseBasicParsing
        } else {
            $wc = New-Object Net.WebClient
            $response = $wc.DownloadString($URL)
        }
    } catch {
        Write-Host "Failed to retrieve script: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    Write-Progress -Activity "Downloading..." -Completed

    # --- File Normalization ---
    $response = $response -replace "`r?`n", "`r`n"
    $response = $response.TrimEnd() + "`r`n`r`n"

    # --- Setup Execution Path ---
    $rand = [guid]::NewGuid().Guid.Substring(0,8)
    $isAdmin = ([Security.Principal.WindowsIdentity]::GetCurrent().Groups -match 'S-1-5-32-544')
    
    $FilePath = if ($isAdmin) {
        "$env:SystemRoot\Temp\MediCat_$rand.bat"
    } else {
        "$env:USERPROFILE\AppData\Local\Temp\MediCat_$rand.bat"
    }

    # --- Save and Execute ---
    try {
        $response | Out-File $FilePath -Encoding ASCII -Force
        
        $env:ComSpec = "$env:SystemRoot\System32\cmd.exe"
        
        # Start the batch file as Admin
        Start-Process `
            -FilePath $env:ComSpec `
            -ArgumentList "/c `"$FilePath`"" `
            -Verb RunAs -Wait
    }
    finally {
        # Cleanup temporary files
        if (Test-Path $FilePath) { Remove-Item $FilePath -Force }
    }
}
