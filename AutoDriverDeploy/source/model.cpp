#include "com_header.h"
#include "common.h"
#include "logging.h"
#include "system.h"
#include "settings.h"
#include "indexing.h"
#include "matcher.h"
#include "manager.h"
#include "update.h"

#include <windows.h>

// Depend on Win32API
#include "enum.h"
#include "main.h"
#include "model.h"

extern Event *deviceupdate_event;
extern volatile int deviceupdate_exitflag;
extern int bundle_display;
extern int bundle_shadow;

//{ Bundle
unsigned int __stdcall Bundle::thread_scandevices(void *arg)
{
    State *state=static_cast<State *>(arg);

    if((invaidate_set&INVALIDATE_DEVICES)==0)return 0;

    if(Settings.statemode==STATEMODE_REAL)state->scanDevices();
    if(Settings.statemode==STATEMODE_EMUL)state->load(Settings.state_file);

    return 0;
}

unsigned int __stdcall Bundle::thread_loadindexes(void *arg)
{
    Collection *collection=static_cast<Collection *>(arg);

    if(invaidate_set&INVALIDATE_INDEXES)collection->updatedir();
    return 0;
}

unsigned int __stdcall Bundle::thread_getsysinfo(void *arg)
{
    State *state=static_cast<State *>(arg);

    if(Settings.statemode==STATEMODE_REAL&&invaidate_set&INVALIDATE_SYSINFO)
        state->getsysinfo_slow();
    return 0;
}

Bundle::Bundle()
{
    matcher=CreateMatcher();
    bundle_init();
}

Bundle::~Bundle()
{
    delete matcher;
}

unsigned int __stdcall Bundle::thread_loadall(void *arg)
{
    Bundle *bundle=static_cast<Bundle *>(arg);

    InitializeCriticalSection(&sync);
    while(1)
    {
        // Wait for an update request
        deviceupdate_event->wait();
        if(deviceupdate_exitflag)break;
        bundle[bundle_shadow].bundle_init();
            /*static long long prmem;
            Log.print_con("Total mem:%ld KB(%ld)\n",nvwa::total_mem_alloc/1024,nvwa::total_mem_alloc-prmem);
            prmem=nvwa::total_mem_alloc;*/

        // Update bundle
        Log.print_con("*** START *** %d,%d [%d]\n",bundle_display,bundle_shadow,invaidate_set);
        bundle[bundle_shadow].bundle_prep();
        bundle[bundle_shadow].bundle_load(&bundle[bundle_display]);

        // Check if the state has been udated during scanning
        int cancel_update=0;
        if(!(Settings.flags&FLAG_NOGUI))
        if(deviceupdate_event->isRaised())cancel_update=1;

        if(cancel_update)
        {
            Log.print_con("*** CANCEL ***\n\n");
            deviceupdate_event->raise();
        }
        else
        {
            Log.print_con("*** FINISH primary ***\n\n");
            invaidate_set&=~(INVALIDATE_DEVICES|INVALIDATE_INDEXES|INVALIDATE_SYSINFO);

            if((Settings.flags&FLAG_NOGUI)&&(Settings.flags&FLAG_AUTOINSTALL)==0)
            {
                // NOGUI mode
                manager_g->matcher=bundle[bundle_shadow].matcher;
                manager_g->populate();
                manager_g->filter(Settings.filters);
                bundle[bundle_shadow].bundle_lowprioirity();
                break;
            }
            else // GUI mode
            {
                if(MainWindow.hMain)SendMessage(MainWindow.hMain,WM_BUNDLEREADY,(WPARAM)&bundle[bundle_shadow],(LPARAM)&bundle[bundle_display]);
            }

            // Save indexes, write info, etc
            Log.print_con("{2Sync\n");
            EnterCriticalSection(&sync);

            bundle[bundle_shadow].bundle_lowprioirity();
            Log.print_con("*** FINISH secondary ***\n\n");

            // Swap display and shadow bundle
            bundle_display^=1;
            bundle_shadow^=1;
            Log.print_con("}2Sync\n");
            bundle[bundle_shadow].bundle_init();
            LeaveCriticalSection(&sync);
        }
    }

    DeleteCriticalSection(&sync);
    return 0;
}

void Bundle::bundle_init()
{
    state.init();
    collection.init(Settings.drp_dir,Settings.index_dir,Settings.output_dir);
    matcher->init(&state,&collection);
}

void Bundle::bundle_prep()
{
    state.getsysinfo_fast();
}
void Bundle::bundle_load(Bundle *pbundle)
{
    ThreadAbs *thandle0=CreateThread();
    ThreadAbs *thandle1=CreateThread();
    ThreadAbs *thandle2=CreateThread();

    Timers.start(time_test);

    // Copy data from shadow if it's not updated
    if((invaidate_set&INVALIDATE_DEVICES)==0)
    {
        state=pbundle->state;
        Timers.reset(time_devicescan);
        if(invaidate_set&INVALIDATE_SYSINFO)state.getsysinfo_fast();
    }
    if((invaidate_set&INVALIDATE_SYSINFO)==0)state.getsysinfo_slow(&pbundle->state);
    if((invaidate_set&INVALIDATE_INDEXES)==0){collection=pbundle->collection;Timers.reset(time_indexes);}

    thandle0->start(&thread_scandevices,&state);
    thandle1->start(&thread_loadindexes,&collection);
    thandle2->start(&thread_getsysinfo,&state);
    thandle0->join();
    thandle1->join();
    thandle2->join();
    delete thandle0;
    delete thandle1;
    delete thandle2;

    /*if((invaidate_set&INVALIDATE_DEVICES)==0)
    {
        state=pbundle->state;time_devicescan=0;}*/

    state.isnotebook_a();
    state.genmarker();
    matcher->getState()->textas.shrink();
    matcher->populate();
    Timers.stop(time_test);
}

void Bundle::bundle_lowprioirity()
{
    Timers.stoponce(time_startup,time_total);
    Timers.print();

    MainWindow.redrawmainwnd();

    collection.printstats();
    state.print();
    matcher->print();
    manager_g->print_hr();

    #ifdef USE_TORRENT
    if(Settings.flags&FLAG_CHECKUPDATES&&!Timers.get(time_chkupdate))Updater->checkUpdates();
    #endif

    collection.save();
    Log.gen_timestamp();
    WStringShort filename;
    filename.sprintf(L"%s\\%sstate.snp",Settings.log_dir,Log.getTimestamp());
    state.save(filename.Get());

    if(Settings.flags&COLLECTION_PRINT_INDEX)
    {
        Log.print_con("Saving humanreadable indexes...");
        collection.print_index_hr();
        Settings.flags&=~COLLECTION_PRINT_INDEX;
        Log.print_con("DONE\n");
    }
}
//}
