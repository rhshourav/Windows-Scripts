@echo off
setlocal

:: ================================
:: Relaunch as admin (single visible window)
:: ================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command ^
      "Start-Process '%~f0' -Verb RunAs -WindowStyle Normal"
    exit
)

:: ================================
:: ADMIN CONTEXT (only window user sees)
:: ================================
cls
echo =====================================
echo ERP Automation - Administrator Mode
echo =====================================
echo.

set "url=https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1"
set "psfile=%TEMP%\run_Auto-ERP.ps1"

echo Downloading script...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; ^
 irm '%url%' -OutFile '%psfile%'"

echo.
echo Running ERP automation...
echo.

:: 🔥 SAME WINDOW, NO EXTRA TERMINALS
powershell -NoProfile -NoExit -ExecutionPolicy Bypass -File "%psfile%"

echo.
echo Script finished.
pause
endlocal
