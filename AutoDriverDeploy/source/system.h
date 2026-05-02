#include <string>
#include "windows.h"
#ifndef SYSTEM_H
#define SYSTEM_H
#include "enum.h"

//{ Event
class Event
{
public:
    virtual ~Event(){}
    virtual void wait()=0;
    virtual bool isRaised()=0;
    virtual void raise()=0;
    virtual void reset()=0;
};
Event *CreateEventWr(bool manual=false);
//}

//{ ThreadAbs
typedef unsigned ( __stdcall *threadCallback)(void *arg);

class ThreadAbs
{
public:
    virtual ~ThreadAbs(){}
    virtual void start(threadCallback callback,void *arg)=0;
    virtual void join()=0;
};
ThreadAbs *CreateThread();
//}

//{ RECT
struct RECT_WR
{
    long left;
    long top;
    long right;
    long bottom;
};
//}

void get_resource(int id,void **data,size_t *size);
void mkdir_r(const wchar_t *path);
void StrFormatSize(long long val,wchar_t *buf,int len);
void ShowHelp();

typedef int (__cdecl *WINAPI5_vscwprintf)(const wchar_t * __restrict__ _Format,va_list _ArgList);

//{ System
class SystemImp
{
    ThreadAbs *narrator=nullptr;
    static Event *narratorE;
    static WStringShort str;
    static bool nar_active;

    HINSTANCE hinstLib=nullptr;
    WINAPI5_vscwprintf _vscwprintf_func=nullptr;

public:
    SystemImp();
    ~SystemImp();

    bool IsLangInstalled(int group);
    unsigned GetTickCountWr();

    bool IsScreenReaderActive();
    static unsigned int __stdcall thread_narrator(void *arg);
    void Speak(const wchar_t *str);

    int canWrite(const wchar_t *path);
    int run_command(const wchar_t* file,const wchar_t* cmd,int show,int wait);
    void benchmark();

    void deletefile(const wchar_t *filename);
    bool FileExists(const wchar_t *filename);
    void ExpandEnvVar(const wchar_t *source,wchar_t *dest,int bufsize);
    bool ChooseDir(wchar_t *path,const wchar_t *title);
    bool ChooseFile(wchar_t *filename,const wchar_t *strlist,const wchar_t *ext);
    void CreateDir(const wchar_t *filename);
    void fileDelSpec(wchar_t *filename);

    void UnregisterClass_log(const wchar_t *lpClassName,const wchar_t *func,const wchar_t *obj);
    int _vscwprintf_dll(const wchar_t * _Format,va_list _ArgList);
    std::wstring AppPath();
    int FindLatestExeVersion();
    bool SystemProtectionEnabled(State *state);
    int GetRestorePointCreationFrequency();
    void SetRestorePointCreationFrequency(int freq);
};
extern SystemImp System;
//}

//{ FileMonitor
class Filemon
{
public:
    virtual ~Filemon(){}
};

typedef void (*FileChangeCallback)(const wchar_t *szFile,int Action,int lParam);
Filemon *CreateFilemon(const wchar_t *szDirectory,int subdirs,FileChangeCallback callback);
extern int monitor_pause;
//}

#endif
