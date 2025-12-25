@echo off
setlocal

:: -------------------------------
:: Elevation check
:: -------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command ^
      "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: -------------------------------
:: Elevated section
:: -------------------------------
set "url=https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1"
set "psfile=%TEMP%\run_Auto-ERP.ps1"

echo Downloading script...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; ^
 irm '%url%' -OutFile '%psfile%'"

echo.
echo Launching PowerShell (Admin)...
echo.

:: 🔥 Run in a NEW PowerShell window that CANNOT be closed
start "" powershell -NoExit -ExecutionPolicy Bypass -File "%psfile%"

echo.
echo PowerShell launched.
echo This window will remain open.
pause
endlocal
