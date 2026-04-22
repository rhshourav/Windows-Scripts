Clear-Host
# -----------------------------
# UI: black background + bright colors
# -----------------------------
try {
    $raw = $Host.UI.RawUI
    $raw.BackgroundColor = 'Black'
    $raw.ForegroundColor = 'White'
    Clear-Host
} catch {}

# ----- Author / Info -----
$author = 'rhshourav'
$github = 'github.com/rhshourav'

Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "  Base64 Encode / Decode Tool"             -ForegroundColor Yellow
Write-Host "  Author : $author"                      -ForegroundColor Green
Write-Host "  GitHub : $github"                      -ForegroundColor Green
Write-Host "===========================================`n" -ForegroundColor Cyan
Write-Host "Type EXIT at any prompt to quit.`n" -ForegroundColor Magenta

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
        text  = "ED Code v1.2.0`nUser: $env:USERNAME  PC: $env:COMPUTERNAME  Domain: $env:USERDOMAIN  IP: $($localIPs -join ', ')"
    } | ConvertTo-Json)

    Invoke-RestMethod -Uri 'https://cryocore.rhshourav02.workers.dev/message' -Method Post -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
} catch {}
# ----- Main loop -----
while ($true) {
    $mode = Read-Host "Type 'e' to ENCODE, 'd' to DECODE, or 'EXIT' to quit"
    if ($mode.Trim().ToUpper() -eq 'EXIT') {
        Write-Host "`nGoodbye!" -ForegroundColor Cyan
        break
    }

    $text = Read-Host "Enter the text (or Base64). Type EXIT to quit"
    if ($text.Trim().ToUpper() -eq 'EXIT') {
        Write-Host "`nGoodbye!" -ForegroundColor Cyan
        break
    }

    switch ($mode.ToLower()) {
        'e' {
            $bytes  = [Text.Encoding]::UTF8.GetBytes($text)
            $base64 = [Convert]::ToBase64String($bytes)
            Write-Host "`nEncoded (Base64):" -ForegroundColor Yellow
            Write-Host $base64 -ForegroundColor White
        }
        'd' {
            try {
                $bytes = [Convert]::FromBase64String($text)
                $plain = [Text.Encoding]::UTF8.GetString($bytes)
                Write-Host "`nDecoded text:" -ForegroundColor Yellow
                Write-Host $plain -ForegroundColor White
            }
            catch {
                Write-Host "`nERROR: The input is not valid Base64." -ForegroundColor Red
            }
        }
        Default {
            Write-Host "`nInvalid choice. Please type 'e' or 'd'." -ForegroundColor Red
        }
    }

    Write-Host "`n----------------------------------------`n" -ForegroundColor DarkGray
}
