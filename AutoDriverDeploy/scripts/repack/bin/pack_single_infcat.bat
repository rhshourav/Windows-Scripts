cd %1
del ..\out\%1.7z
..\bin\7za.exe a ..\out\%1.7z -ir!*.inf -ir!*.cat
cd ..
