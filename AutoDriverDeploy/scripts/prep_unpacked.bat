@echo off
for /f "tokens=*" %%a in ('dir /b /od "%~dp0SDI_R*.exe"') do set "SDIEXE=%%a"
echo %SDIEXE%

for /F %%i in ('dir /b drivers\*.7z') do %SDIEXE% -7z x drivers\%%i -y -odrivers\%%~ni
rem for /F %%i in ('dir /b drivers\*.7z') do %SDIEXE% -7z x drivers\%%i -y -odrivers\%%~ni -ir!*.inf -ir!*.cat
del indexes\SDI\unpacked.bin
echo -keepunpackedindex >> sdi.cfg
