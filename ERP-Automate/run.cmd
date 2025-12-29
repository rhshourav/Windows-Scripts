@echo off
:: ==================================
:: Version: 1.0.0s
:: ==================================
setlocal EnableExtensions EnableDelayedExpansion

:: ===============================
:: Enable ANSI colors (Win10/11)
:: ===============================
for /f %%A in ('echo prompt $E ^| cmd') do set "ESC=%%A"

:: ===============================
:: Admin check (only elevate if needed)
:: ===============================
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command ^
      "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ===============================
:: Header
:: ===============================
cls
title ERP Automation (Administrator)

echo %ESC%[96m==========================================
echo   ERP Automation Tool (Admin Mode)
echo ==========================================%ESC%[0m
echo.

:: ===============================
:: Download & Run
:: ===============================
set "url=https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/ERP-Automate/run_Auto-ERP.ps1"
set "psfile=%TEMP%\run_Auto-ERP.ps1"

echo %ESC%[93m[+] Downloading script...%ESC%[0m
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; ^
 irm '%url%' -OutFile '%psfile%'"

echo %ESC%[92m[o] Download complete%ESC%[0m
echo.

echo %ESC%[93m[+] Running ERP automation...%ESC%[0m
powershell -NoProfile -ExecutionPolicy Bypass -File "%psfile%"
echo.

:: ===============================
:: Exit Screen
:: ===============================
echo %ESC%[92m==========================================
echo    ERP Automation Completed Successfully
echo ==========================================%ESC%[0m
echo.

echo %ESC%[97m Author : %ESC%[96mrhshourav%ESC%[0m
echo %ESC%[97m GitHub : %ESC%[94mhttps://github.com/rhshourav/Windows-Scripts%ESC%[0m
echo.

echo %ESC%[93mPress any key to close this window...%ESC%[0m
pause >nul

endlocal
exit
