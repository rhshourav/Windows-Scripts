#ifndef INSTALL_H
#define INSTALL_H

// Global vars
extern long long ar_total,ar_proceed;
extern int instflag;
extern size_t itembar_act;
extern int needreboot;
extern wchar_t extractdir[BUFLEN];

extern long long totalinstalltime,totalextracttime;

// Installer
enum INSTALLER
{
    INSTALLDRIVERS     = 1,
    OPENFOLDER         = 2,
};

void _7z_total(long long i);
int  _7z_setcomplited(long long i);
void driver_install(wchar_t *hwid,const wchar_t *inf,int *ret,int *needrb);
void removeextrainfs(wchar_t *inf);
void save_wndinfo();

#endif
