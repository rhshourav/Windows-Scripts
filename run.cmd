@echo off
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
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ===============================
:: Header
:: ===============================
cls
title Windows Scripts (Administrator)

echo %ESC%[96m==========================================
echo   Windows Scripts Launcher (Admin Mode)
echo ==========================================%ESC%[0m
echo.

:: ===============================
:: Download & Run
:: ===============================
set "url=https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1"
set "psfile=%TEMP%\windowsScripts.ps1"

echo %ESC%[93m[+] Downloading: windowsScripts.ps1 ...%ESC%[0m
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; ^
  try { irm '%url%' -OutFile '%psfile%' -UseBasicParsing } catch { iwr '%url%' -OutFile '%psfile%' -UseBasicParsing }"

if not exist "%psfile%" (
  echo %ESC%[91m[!] Download failed. File not found: %psfile%%ESC%[0m
  echo %ESC%[93mPress any key to close...%ESC%[0m
  pause >nul
  endlocal
  exit /b 1
)

echo %ESC%[92m[✔] Download complete%ESC%[0m
echo.

echo %ESC%[93m[+] Running Windows Scripts menu...%ESC%[0m
powershell -NoProfile -ExecutionPolicy Bypass -File "%psfile%"
set "rc=%errorlevel%"
echo.

:: ===============================
:: Exit Screen
:: ===============================
if "%rc%"=="0" (
  echo %ESC%[92m==========================================
  echo    Windows Scripts finished (ExitCode: %rc%)
  echo ==========================================%ESC%[0m
) else (
  echo %ESC%[91m==========================================
  echo    Windows Scripts ended with errors (ExitCode: %rc%)
  echo ==========================================%ESC%[0m
)
echo.

echo %ESC%[97m Author : %ESC%[96mrhshourav%ESC%[0m
echo %ESC%[97m GitHub  : %ESC%[94mhttps://github.com/rhshourav/Windows-Scripts%ESC%[0m
echo.

echo %ESC%[93mPress any key to close this window...%ESC%[0m
pause >nul

endlocal
exit /b %rc%
