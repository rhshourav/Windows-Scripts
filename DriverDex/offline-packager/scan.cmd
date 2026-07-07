@echo off
:: DriverDex Offline Scanner - Double-click launcher
:: Elevates to Admin if needed, then runs the scanner
NET SESSION >nul 2>&1
if %errorLevel% NEQ 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'am_admin' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan.ps1"
pause
