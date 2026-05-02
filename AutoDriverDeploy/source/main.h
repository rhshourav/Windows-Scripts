#ifndef MAIN_H
#define MAIN_H

//{ Defines
class Manager;
class wFont;
class Matcher;
class Hwidmatch;
class Canvas;
class Console_t;
class Combobox;

extern class Popup_t *Popup;

#include "resources.h"

// Misc
#define APPTITLE            L"Snappy Driver Installer " TEXT(SVN_REV2)
#define VER_MARKER          "SDW"
#define VER_STATE           0x102
#define VER_INDEX           0x205

// Mode
enum INVALIDATE
{
    INVALIDATE_INDEXES  =1,
    INVALIDATE_SYSINFO  =2,
    INVALIDATE_DEVICES  =4,
    INVALIDATE_MANAGER  =8,
};

// Popup window
enum FLOATING_TYPE
{
    FLOATING_NONE       =0,
    FLOATING_TOOLTIP    =1,
    FLOATING_SYSINFO    =2,
    FLOATING_CMPDRIVER  =3,
    FLOATING_DRIVERLST  =4,
    FLOATING_ABOUT      =5,
    FLOATING_DOWNLOAD   =6,
};

// kb panels
enum KB_ID
{
    KB_NONE           =  0,
    KB_FIELD          =  1,
    KB_LANG           =  2,
    KB_THEME          =  3,
    KB_EXPERT         =  4,
    KB_INSTALL        =  5,
    KB_ACTIONS        =  6,
    KB_PANEL1         =  7,
    KB_PANEL2         =  8,
    KB_PANEL3         =  9,
    KB_PANEL_CHK      = 10,
};

// Mouse state
enum MOUSE_STATE
{
    MOUSE_NONE         = 0,
    MOUSE_CLICK        = 1,
    MOUSE_MOVE         = 2,
    MOUSE_SCROLL       = 3,
};

// Messages
enum MessagesWND
{
    WM_BUNDLEREADY     = WM_APP+1,
    WM_UPDATELANG      = WM_APP+2,
    WM_UPDATETHEME     = WM_APP+3,
};
//}

//{ Global variables

// Manager
extern int volatile installmode;
extern int invaidate_set;
extern int num_cores;
extern bool emptydrp;
extern HINSTANCE ghInst;
extern CRITICAL_SECTION sync;
extern Console_t *Console;

// Popup
class Popup_t
{
    Popup_t(const Popup_t&)=delete;
    Popup_t &operator=(const Popup_t&)=delete;

private:
    Canvas *canvasPopup=nullptr;
    int floating_type=0;
    int floating_x=1,floating_y=1;
    bool wait=false;
    int horiz_sh=0;

public:
    HWND hPopup=nullptr;
    Popup_t();
    ~Popup_t();
    void init();
    void drawpopup(size_t itembar,int str_id,int type,int x,int y,HWND hwnd);
    void popup_resize(int x,int y);
    void onHover();
    void onLeave();
    void setMirroring();
    void setTransparency();
    void getPos(long int *x,long int *y);

    int  getShift(){ return horiz_sh; }
    void AddShift(int v);

    wFont *hFontP;
    wFont *hFontBold;
    size_t floating_itembar=0;
    int floating_str_id=0;

    LRESULT PopupProcedure2(HWND hwnd,UINT message,WPARAM wParam,LPARAM lParam);
};
LRESULT CALLBACK PopupProcedure(HWND hwnd,UINT message,WPARAM wParam,LPARAM lParam);

// Console
class Console_t
{
public:
    virtual ~Console_t(){}
    virtual void Show()=0;
    virtual void Hide()=0;
};

// Window
class MainWindow_t
{
    MainWindow_t(const MainWindow_t&)=delete;
    void operator=(const MainWindow_t&)=delete;

private:
    Canvas *canvasMain;
    Canvas *canvasField;
    static const wchar_t classMain[];
    static const wchar_t classField[];
    static const wchar_t classPopup[];

    int mousex=-1,mousey=-1,mousedown=MOUSE_NONE,mouseclick=0;
    int scrollvisible=0;
    size_t field_lasti;
    int field_lastz;

    wFont *hFont;

    friend class Popup_t;

public:
    int main1x_c,main1y_c;
    int mainx_c,mainy_c;

    HWND hMain,hField;
    Combobox *hLang;
    Combobox *hTheme;
    int offset_target;
    int ctrl_down;
    int space_down;
    int shift_down;

    int kbpanel,kbfield,kbinstall;

private:
    static LRESULT CALLBACK WndProcMainCallback(HWND,UINT,WPARAM,LPARAM);
    static LRESULT CALLBACK WndProcFieldCallback(HWND,UINT,WPARAM,LPARAM);
    LRESULT WndProcCommon(HWND hwnd,UINT uMsg,WPARAM wParam,LPARAM lParam);
    LRESULT WndProcMain(HWND,UINT,WPARAM,LPARAM);
    LRESULT WndProcField(HWND,UINT,WPARAM,LPARAM);

public:
    void MainLoop(int nCmd);
    void lang_refresh();
    void theme_refresh();
    void redrawfield();
    void redrawmainwnd();

    void tabadvance(int v);
    void arrowsAdvance(int v);

    // Commands
    void snapshot();
    void extractto();
    void selectDrpDir();

    // Scrollbar
    void setscrollrange(int y);
    int  getscrollpos();
    void setscrollpos(int pos);

    void ShowProgressInTaskbar(bool show,long long complited=0,long long total=0);

    MainWindow_t();
    ~MainWindow_t();
};
extern MainWindow_t MainWindow;

//}

// Subroutes
void drp_callback(const wchar_t *szFile,int action,int lParam);
void invalidate(int v);

// Misc
void escapeAmpUrl(wchar_t *buf,const wchar_t *source);
void escapeAmp(wchar_t *buf,const wchar_t *source);

// GUI Helpers
HWND CreateWindowMF(const wchar_t *type,const wchar_t *name,HWND hwnd,intptr_t id,DWORD f);
void GetRelativeCtrlRect(HWND hWnd,RECT *rc);
void setMirroring(HWND hwnd);
void setMirroringEdit(HWND hwnd);
void checktimer(const wchar_t *str,long long t,int uMsg);

// GUI
BOOL CALLBACK LicenseProcedure(HWND hwnd,UINT Message,WPARAM wParam,LPARAM lParam);

//#include "debug_new.h"
void* operator new(size_t size, const char* file, int line);
void* operator new[](size_t size, const char* file, int line);
/*#define DEBUG_NEW new(__FILE__, __LINE__)
#define new DEBUG_NEW
namespace nvwa {extern size_t total_mem_alloc;}*/
//}

#endif
