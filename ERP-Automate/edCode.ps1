Clear-Host

# ----- Author / Info -----
$author = 'rhshourav'
$github = 'github.com/rhshourav'

Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "  Base64 Encode / Decode Tool"             -ForegroundColor Yellow
Write-Host "  Author : $author"                      -ForegroundColor Green
Write-Host "  GitHub : $github"                      -ForegroundColor Green
Write-Host "===========================================`n" -ForegroundColor Cyan
Write-Host "Type EXIT at any prompt to quit.`n" -ForegroundColor Magenta

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
