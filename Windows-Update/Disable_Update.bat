@echo off
:: ============================================================
:: Full Windows Update Disable Script
:: Works on Windows 10/11
:: Requires Administrator Privileges
:: Created By rhshourav V.1.0
:: ============================================================

:: =======================
:: Check for Administrator
:: =======================
>nul 2>&1 net session
if %errorlevel% neq 0 (
    echo This script requires administrative privileges.
    echo Requesting elevation...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo =============================================
echo  Disabling Windows Update completely...
echo =============================================
echo.

:: =======================
:: 1. Stop and Disable Services
:: =======================
net stop wuauserv >nul 2>&1
net stop bits >nul 2>&1
net stop dosvc >nul 2>&1
net stop WaaSMedicSvc >nul 2>&1
net stop UsoSvc >nul 2>&1

sc config wuauserv start= disabled
sc config bits start= disabled
sc config dosvc start= disabled
sc config WaaSMedicSvc start= disabled
sc config UsoSvc start= disabled

:: =======================
:: 2. Registry Tweaks (Disable AU)
:: =======================
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableOSUpgrade /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f

:: Disable Windows Update Medic from repairing itself
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" /v Start /t REG_DWORD /d 4 /f

:: =======================
:: 3. Disable Scheduled Tasks
:: =======================
schtasks /Change /TN "\Microsoft\Windows\WindowsUpdate\Scheduled Start" /Disable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\WindowsUpdate\Automatic App Update" /Disable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan" /Disable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker" /Disable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask" /Disable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\Reboot" /Disable >nul 2>&1

:: =======================
:: 4. Firewall Block (Optional – uncomment if you want)
:: =======================
:: netsh advfirewall firewall add rule name="Block Windows Update" dir=out action=block remoteip=13.107.4.50,13.107.5.50 enable=yes

echo.
echo ✅ Windows Update has been disabled from Services, Registry, and Tasks.
echo.

:: =======================
:: 5. Ask for Reboot
:: =======================
choice /C YN /M "Do you want to reboot now? (Y/N)"
if errorlevel 2 goto skip
if errorlevel 1 goto reboot

:reboot
echo Rebooting system...
shutdown /r /t 5
goto end

:skip
echo Skipped reboot. Please restart manually to apply changes.

:end
pause
