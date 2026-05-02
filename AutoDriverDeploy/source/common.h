
#ifndef COMMON_H
#define COMMON_H

#include <unordered_map>
#include <vector>

// Global vars
extern int trap_mode;

// Vector templates
template <class T>
char *vector_save(std::vector<T> *v,char *p)
{
    size_t used=v->size()*sizeof(T);
    size_t val=v->size();

    int *pi=reinterpret_cast<int *>(p);
    *pi++=static_cast<int>(used);p+=sizeof(int);
    *pi++=static_cast<int>(val);p+=sizeof(int);
    memcpy(p,&v->front(),used);p+=used;
    return p;
}

template <class T>
char *vector_load(std::vector<T> *v,char *p)
{
    size_t sz=0,num=0;

    int *pi=reinterpret_cast<int *>(p);
    sz=*pi++;p+=sizeof(int);
    num=*pi++;p+=sizeof(int);
    if(!num)num=sz;
    v->resize(num);
    memcpy(v->data(),p,sz);p+=sz;
    return p;
}

template <class T>
class loadable_vector:public std::vector<T>
{
public:
    char *savedata(char *p){return vector_save(this,p);}
    char *loaddata(char *p){return vector_load(this,p);}
};

// Strings
void strsub(wchar_t *str,const wchar_t *pattern,const wchar_t *rep);
void strtoupper(const char *s,size_t len);
void strtolower(const char *s,size_t len);
size_t unicode2ansi(const unsigned char *s,char *out,size_t size);
int _wtoi_my(const wchar_t *str);

class WString_dyn
{
protected:
    wchar_t *buf_dyn=nullptr;
    wchar_t *buf_cur;
    size_t len;
    bool debug;

public:
    WString_dyn(size_t sz,wchar_t *buf,bool debug_=false):buf_cur(buf),len(sz),debug(debug_){}
    virtual ~WString_dyn(){delete[] buf_dyn;}
    void Resize(size_t size);

    void sprintf(const wchar_t *format,...);
    void vsprintf(const wchar_t *format,va_list args);
    void append(const wchar_t *str);
    void strcpy(const wchar_t *str);

    wchar_t *GetV()const{return buf_cur;}
    const wchar_t *Get()const{return buf_cur;}
    size_t Length()const{return len;}
};

class WString:public WString_dyn
{
    const static int size=BUFLEN;
    wchar_t buf[size];
public:
    WString(bool debug_=false):WString_dyn(size,buf,debug_){*buf=0;}
};

class WStringShort:public WString_dyn
{
    const static int size=128;
    wchar_t buf[size];
public:
    WStringShort(bool debug_=false):WString_dyn(size,buf,debug_){*buf=0;}
};

// Version
class Version
{
    int d,m,y;
    int v1,v2,v3,v4;

public:
    int  setDate(int d_,int m_,int y_);
    void setVersion(int v1_,int v2_,int v3_,int v4_);
    void setInvalid(){y=v1=-1;}
    int  GetV1()const{return v1;}
    void str_date(WStringShort &buf,bool invariant=false)const;
    void str_version(WStringShort &buf)const;

    Version():d(0),m(0),y(0),v1(-2),v2(0),v3(0),v4(0){}
    Version(int d1,int m1,int y1):d(d1),m(m1),y(y1),v1(-2),v2(0),v3(0),v4(0){}

    friend class datum;
    friend int cmpdate(const Version *t1,const Version *t2);
    friend int cmpversion(const Version *t1,const Version *t2);
};
int cmpdate(const Version *t1,const Version *t2);
int cmpversion(const Version *t1,const Version *t2);

// Txt
class Txt
{
    std::unordered_map<std::string,size_t> dub;
    loadable_vector<char> text;

public:
    size_t getSize()const{return text.size();}
    const char *get(ofst offset)const{return &text[offset];}
    char *getV(ofst offset)const{ return const_cast<char *>(&text[offset]); }
    const wchar_t *getw(ofst offset)const{ return reinterpret_cast<const wchar_t *>(&text[offset]); }
    wchar_t *getwV(ofst offset)const{ return const_cast<wchar_t *>(reinterpret_cast<const wchar_t *>(&text[offset])); }
    const wchar_t *getw2(ofst offset)const{ return reinterpret_cast<const wchar_t *>(&text[offset-(text[0]?2:0)]); }

    size_t strcpy(const char *mem);
    size_t strcpyw(const wchar_t *mem);
    size_t t_memcpy(const char *mem,size_t sz);
    size_t t_memcpyz(const char *mem,size_t sz);
    size_t memcpyz_dup(const char *mem,size_t sz);
    size_t alloc(size_t sz);

    char *savedata(char *p){return text.savedata(p);}
    char *loaddata(char *p){return text.loaddata(p);};

    Txt();
    void reset(size_t sz);
    void shrink();
};

// Hashtable
class Hashitem
{
    int key;
    int value;
    int next;
    int valuelen;

public:
    Hashitem():key(0),value(0),next(0),valuelen(0){}

    friend class Hashtable;
};

class Hashtable
{
    int findnext_v;
    int findstr;
    int size;
    loadable_vector<Hashitem> items;

public:
	ofst getSize()const{ return static_cast<ofst>(items.size()); }

    static unsigned gethashcode(const char *s,size_t sz);
    void reset(size_t size);
    char *savedata(char *p);
    char *loaddata(char *p);
    void additem(int key,int value);
    int  find(int vl,int *isfound);
    int  findnext(int *isfound);
};

// 7-zip
size_t  encode(char *dest,size_t dest_sz,const char *src,size_t src_sz);
size_t  decode(char *dest,size_t dest_sz,const char *src,size_t src_sz);
void registerall();

namespace NArchive{
namespace N7z{
        extern void register7z();
}}
extern int  Extract7z(const wchar_t *str);
extern void registerBCJ();
extern void registerBCJ2();
extern void registerBranch();
extern void registerCopy();
extern void registerLZMA();
extern void registerLZMA2();

#endif
