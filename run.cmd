@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ==========================================================
:: Windows Scripts Launcher (Admin)
:: - Internet check (Cloudflare)
:: - raw.githubusercontent.com reachability check
:: - PS < 5.1 OR Windows < 10 -> warning (15s) then continue
:: - Robust download + execute
:: ==========================================================

:: ===============================
:: Enable ANSI colors (best-effort)
:: ===============================
for /f %%A in ('echo prompt $E ^| cmd') do set "ESC=%%A"

:: ===============================
:: Admin check (elevate only if needed)
:: Use cmd /k so Admin window does NOT auto-close
:: ===============================
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -Verb RunAs -ArgumentList '/k','""%~f0""'"
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
:: Pre-flight: PowerShell exists
:: ===============================
where powershell.exe >nul 2>&1
if not "%errorlevel%"=="0" (
  echo %ESC%[91m[!] PowerShell not found. Cannot continue.%ESC%[0m
  call :Hold 20
  goto :END
)

:: ===============================
:: Internet check (Cloudflare)
:: ===============================
echo %ESC%[93m[+] Checking internet connectivity (Cloudflare)...%ESC%[0m
call :Dots 3

set "TEST_URL=https://www.cloudflare.com/cdn-cgi/trace"
set "TEST_METHOD=GET"
set "TEST_TIMEOUT_MS=7000"
call :TestUrl
if not "%errorlevel%"=="0" (
  echo %ESC%[91m[!] Internet check FAILED.%ESC%[0m
  echo %ESC%[90m    Allow HTTPS to: www.cloudflare.com%ESC%[0m
  call :Hold 45
  goto :END
)
echo %ESC%[92m[OK] Internet reachable%ESC%[0m
echo.

:: ===============================
:: raw.githubusercontent.com check
:: ===============================
echo %ESC%[93m[+] Checking access to raw.githubusercontent.com...%ESC%[0m
call :Dots 3

set "TEST_URL=https://raw.githubusercontent.com/"
set "TEST_METHOD=HEAD"
set "TEST_TIMEOUT_MS=7000"
call :TestUrl
if not "%errorlevel%"=="0" (
  echo %ESC%[91m[!] raw.githubusercontent.com check FAILED.%ESC%[0m
  echo %ESC%[90m    Likely proxy/firewall/DNS restriction.%ESC%[0m
  echo %ESC%[90m    Contact: rhshourav.gitbub.io/contact%ESC%[0m
  call :Hold 45
  goto :END
)
echo %ESC%[92m[OK] raw.githubusercontent.com reachable%ESC%[0m
echo.

:: ===============================
:: Compatibility warning (non-blocking)
:: ===============================
call :CompatibilityWarning

:: ===============================
:: Download + Run
:: ===============================
set "DL_URL=https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/windowsScripts.ps1"
set "DL_OUT=%TEMP%\windowsScripts.ps1"

echo %ESC%[93m[+] Downloading: windowsScripts.ps1%ESC%[0m
echo %ESC%[90m    %DL_URL%%ESC%[0m

call :DownloadFile
if not "%errorlevel%"=="0" (
  echo %ESC%[91m[!] Download failed.%ESC%[0m
  echo %ESC%[90m    URL : %DL_URL%%ESC%[0m
  echo %ESC%[90m    OUT : %DL_OUT%%ESC%[0m
  call :Hold 45
  goto :END
)

if not exist "%DL_OUT%" (
  echo %ESC%[91m[!] Download failed: file not found:%ESC%[0m
  echo %ESC%[90m    %DL_OUT%%ESC%[0m
  call :Hold 45
  goto :END
)

echo %ESC%[92m[OK] Download complete%ESC%[0m
echo.

echo %ESC%[93m[+] Running Windows Scripts menu...%ESC%[0m
powershell -NoProfile -ExecutionPolicy Bypass -File "%DL_OUT%"
set "rc=%errorlevel%"
echo.

if "%rc%"=="0" (
  echo %ESC%[92m==========================================
  echo   Windows Scripts finished (ExitCode: %rc%)
  echo ==========================================%ESC%[0m
) else (
  echo %ESC%[91m==========================================
  echo   Windows Scripts ended with errors (ExitCode: %rc%)
  echo ==========================================%ESC%[0m
)
echo.

echo %ESC%[97m Author : %ESC%[96mrhshourav%ESC%[0m
echo %ESC%[97m GitHub  : %ESC%[94mhttps://github.com/rhshourav/Windows-Scripts%ESC%[0m
echo.

:END
echo %ESC%[93mPress any key to close this window...%ESC%[0m
pause >nul
endlocal
exit /b


:: ==========================================================
:: Functions
:: ==========================================================

:TestUrl
:: Uses env vars: TEST_URL, TEST_METHOD, TEST_TIMEOUT_MS
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$u=$env:TEST_URL; $m=$env:TEST_METHOD; $to=[int]$env:TEST_TIMEOUT_MS; ^
 try { ^
   try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch {} ^
   $req=[System.Net.HttpWebRequest]::Create($u); ^
   $req.Method=$m; ^
   $req.Timeout=$to; ^
   $req.ReadWriteTimeout=$to; ^
   $req.AllowAutoRedirect=$true; ^
   $resp=$req.GetResponse(); ^
   $code=[int]$resp.StatusCode; ^
   $resp.Close(); ^
   if($code -ge 200 -and $code -lt 500){ exit 0 } else { exit 1 } ^
 } catch { exit 1 }"
exit /b %errorlevel%


:DownloadFile
:: Uses env vars: DL_URL, DL_OUT
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$u=$env:DL_URL; $o=$env:DL_OUT; ^
 try { ^
   try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch {} ^
   $wc=New-Object Net.WebClient; ^
   $wc.Headers.Add('User-Agent','WindowsScripts-Launcher'); ^
   $wc.DownloadFile($u,$o); ^
   exit 0 ^
 } catch { ^
   try { ^
     if(Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue){ ^
       Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop; ^
       exit 0 ^
     } else { ^
       exit 1 ^
     } ^
   } catch { exit 1 } ^
 }"
exit /b %errorlevel%


:CompatibilityWarning
set "WARN="
powershell -NoProfile -Command "if($PSVersionTable.PSVersion -ge [version]'5.1'){exit 0}else{exit 1}"
if not "%errorlevel%"=="0" set "WARN=1"

powershell -NoProfile -Command "if([Environment]::OSVersion.Version.Major -ge 10){exit 0}else{exit 1}"
if not "%errorlevel%"=="0" set "WARN=1"

if defined WARN (
  echo %ESC%[91m============================================================%ESC%[0m
  echo %ESC%[91m Intended script might not work perfectly on this system.%ESC%[0m
  echo %ESC%[97m Contact: %ESC%[96mrhshourav.gitbub.io/contact%ESC%[0m
  echo %ESC%[91m============================================================%ESC%[0m
  call :Countdown 15
  echo.
)
exit /b 0


:Dots
set "N=%~1"
if "%N%"=="" set "N=3"
for /l %%i in (1,1,%N%) do (
  <nul set /p "=."
  timeout /t 1 /nobreak >nul
)
echo.
exit /b 0


:Countdown
set "S=%~1"
if "%S%"=="" set "S=15"
for /l %%i in (%S%,-1,1) do (
  echo %ESC%[90m  %%i...%ESC%[0m
  timeout /t 1 /nobreak >nul
)
exit /b 0


:Hold
set "T=%~1"
if "%T%"=="" set "T=30"
echo.
echo %ESC%[90mHolding window for %T% seconds...%ESC%[0m
timeout /t %T% /nobreak >nul
exit /b 0
