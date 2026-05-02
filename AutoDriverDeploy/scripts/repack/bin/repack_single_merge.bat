@echo off
Set dict=%2
if "%2"=="" Set dict=32
if not "%1"=="" goto continue
echo Run 'repack_all_XX.bat' instead
echo.
pause
exit

:continue
rd temp /s /q
md temp
bin\7za.exe x %1 -o"temp" -r >nul
del out\%1 -y
set path=%CD%;%PATH%
cd temp
call ..\bat\%1.bat
rem ..\bin\7za.exe a ..\out\%1 -mmt=off -m0=BCJ2 -m1=LZMA2:d%dict%m:fb273 -m2=LZMA2:d512k -m3=LZMA2:d512k -mb0:1 -mb0s1:2 -mb0s2:3 *.ini -ir!*.inf -ir!*.cat -ir!*.nfo -ir!*.url -ir!*.txt
rem ..\bin\7za.exe a ..\out\%1 -mmt=off -m0=BCJ2 -m1=LZMA2:d%dict%m:fb273 -m2=LZMA2:d512k -m3=LZMA2:d512k -mb0:1 -mb0s1:2 -mb0s2:3 -xr!*.inf -xr!*.cat -x!*.ini -x!*.nfo -x!*.url -x!*.txt
cd ..
