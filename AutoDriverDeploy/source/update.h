
#ifndef UPDATE_H
#define UPDATE_H

// Declarations
class Updater_t;
class Canvas;

// Global variables
extern Updater_t *Updater;

// Updater
class Updater_t
{
public:
    int numfiles=0;
    static int torrentport,downlimit,uplimit,connections;

public:
    virtual ~Updater_t(){}

    virtual void ShowProgress(wchar_t *buf)=0;
    virtual void ShowPopup(Canvas &canvas)=0;

    virtual void checkUpdates()=0;
    virtual void resumeDownloading()=0;
    virtual void pause()=0;

    virtual bool isTorrentReady()=0;
    virtual bool isPaused()=0;
    virtual bool isUpdateCompleted()=0;

    virtual int  Populate(int flags)=0;
    virtual void SetFilePriority(const wchar_t *name,int pri)=0;
    virtual void SetLimits()=0;
    virtual void OpenDialog()=0;
};
Updater_t *CreateUpdater();

#endif
