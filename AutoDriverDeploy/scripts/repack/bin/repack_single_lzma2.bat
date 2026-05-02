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
bin\7za.exe x %1 -o"temp" -r
del out\%1 -y
call bat\%1.bat
cd temp
..\bin\7za.exe a ..\out\%1 -ms=512m -mmt=2 -m0=LZMA2:d%dict%m:fb273 -ir!*.inf -ir!*.cat -ir!*.nfo -ir!*.url
..\bin\7za.exe a ..\out\%1 -ms=512m -mmt=2 -m0=BCJ2 -m1=LZMA2:d%dict%m:fb273 -m2=LZMA2:d512k:fb273 -m3=LZMA2:d512k:fb273 -mb0:1 -mb0s1:2 -mb0s2:3 -mqs=on -xr!*.inf -xr!*.cat -x!*.nfo -x!*.url
cd ..
