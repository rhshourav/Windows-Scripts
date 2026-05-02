
#ifndef MODEL_H
#define MODEL_H

class State;
class Collection;
class Matcher;

//Bundle
class Bundle
{
    Bundle(const Bundle&)=delete;
	Bundle &operator = (const Bundle&) = delete;

    State state;
    Collection collection;
    Matcher *matcher;

private:
    static unsigned int __stdcall thread_scandevices(void *arg);
    static unsigned int __stdcall thread_loadindexes(void *arg);
    static unsigned int __stdcall thread_getsysinfo(void *arg);

public:
    Bundle();
    ~Bundle();

    Matcher *getMatcher(){return matcher;}

    static unsigned int __stdcall thread_loadall(void *arg);

    void bundle_init();
    void bundle_prep();
    void bundle_load(Bundle *pbundle);
    void bundle_lowprioirity();
};

#endif
