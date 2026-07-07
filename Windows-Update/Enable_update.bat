@echo off
:: ============================================================
:: Full Windows Update Enable Script
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
echo  Enabling Windows Update completely...
echo =============================================
echo.

:: =======================
:: 1. Enable and Start Services
:: =======================
sc config wuauserv start= demand
sc config bits start= demand
sc config dosvc start= demand
sc config WaaSMedicSvc start= demand
sc config UsoSvc start= demand

net start wuauserv >nul 2>&1
net start bits >nul 2>&1
net start dosvc >nul 2>&1
net start WaaSMedicSvc >nul 2>&1
net start UsoSvc >nul 2>&1

:: =======================
:: 2. Restore Registry Settings
:: =======================
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableOSUpgrade /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /f >nul 2>&1

:: Set WaaSMedicSvc back to manual
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" /v Start /t REG_DWORD /d 3 /f

:: =======================
:: 3. Re-enable Scheduled Tasks
:: =======================
schtasks /Change /TN "\Microsoft\Windows\WindowsUpdate\Scheduled Start" /Enable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\WindowsUpdate\Automatic App Update" /Enable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan" /Enable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker" /Enable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask" /Enable >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\Reboot" /Enable >nul 2>&1

:: =======================
:: 4. Remove Firewall Block (Optional – uncomment if you added it before)
:: =======================
:: netsh advfirewall firewall delete rule name="Block Windows Update"

echo.
echo ✅ Windows Update has been fully enabled.
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
