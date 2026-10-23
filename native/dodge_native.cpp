#include <windows.h>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <cstdio>

// One supported executable build. No network-device or entity-state writes.
struct Shared {
    uint32_t magic, version, pid, stamp, active, blocked, sequence, reserved;
    double risk[9];
    volatile LONG status, polls, overrides, chosen;
};
static_assert(offsetof(Shared, risk)==32 && offsetof(Shared,status)==104, "IPC layout");
static Shared* shared;
static HANDLE mutexHandle;
using ValueFn = float (__attribute__((thiscall)) *)(void*, int);
using BoolFn = bool (__attribute__((thiscall)) *)(void*, int);
static ValueFn originalValue;
static BoolFn originalPressed;
static const int dx[]={0,-1,1,0,0,-1,1,-1,1}, dy[]={0,0,0,-1,1,-1,-1,1,1};
static const int masks[]={0,1,2,4,8,5,6,9,10};
static SRWLOCK decisionLock=SRWLOCK_INIT;
static int lastChoice=-1;
static DWORD lastAt;
static void* lastDevice;

static int rank(const double* risk, uint32_t blocked, int manual, int x, int y, int previous=-1) {
    int best=manual;
    bool finite=true;for(int i=0;i<9;++i) finite=finite && std::isfinite(risk[i]);
    if(finite && risk[manual]>0) {
        double score=risk[manual];
        for(int i=0;i<9;++i) {
            if(blocked & (1u<<i)) continue;
            double value=risk[i]+3*(std::abs(dx[i]-x)+std::abs(dy[i]-y));
            if(value<score){score=value;best=i;}
        }
    }
    if(best==manual || risk[best]>=risk[manual]) return -1;
    // Retain the last escape only within the same damage score. The 65536
    // tolerance is 64 endpoint-cost units; never retain a worse damage tier.
    if(previous>=0 && previous<9 && !(blocked&(1u<<previous)) &&
       risk[previous]<risk[manual] &&
       std::floor(risk[previous]/1048576.0)==std::floor(risk[best]/1048576.0) &&
       risk[previous]<=risk[best]+65536.0) return previous;
    return best;
}

static int choose(void* device) {
    DWORD pid=0; GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    if (!shared || pid!=GetCurrentProcessId() || (GetAsyncKeyState(VK_LMENU)&0x8000)) return -1;
    Shared sample{};
    DWORD wait=WaitForSingleObject(mutexHandle,0);
    if (wait==WAIT_ABANDONED) { shared->active=0; ReleaseMutex(mutexHandle); return -1; }
    if (wait!=WAIT_OBJECT_0) return -1;
    memcpy(&sample, shared, 104);
    ReleaseMutex(mutexHandle);
    DWORD now=GetTickCount();
    if(sample.magic!=0x32444149 || sample.version!=1 || sample.pid!=pid || !sample.active || now-sample.stamp>120) return -1;
    if(!TryAcquireSRWLockExclusive(&decisionLock)) return -1;
    if(lastDevice==device && now-lastAt<16) {
        int result=lastChoice; ReleaseSRWLockExclusive(&decisionLock); return result;
    }
    float raw[4]; for(int i=0;i<4;++i) raw[i]=originalValue(device,i);
    int x=(raw[1]>0.1f)-(raw[0]>0.1f), y=(raw[3]>0.1f)-(raw[2]>0.1f), manual=0;
    for(int i=0;i<9;++i) if(dx[i]==x && dy[i]==y) manual=i;
    int previous=(lastDevice==device && now-lastAt<=120) ? lastChoice : -1;
    lastChoice=rank(sample.risk,sample.blocked,manual,x,y,previous);
    lastAt=now; lastDevice=device;
    InterlockedExchange(&shared->chosen,lastChoice);
    int result=lastChoice; ReleaseSRWLockExclusive(&decisionLock); return result;
}
static float __attribute__((fastcall)) valueHook(void* self, void*, int action) {
    if(action>=0 && action<4) {
        InterlockedIncrement(&shared->polls);
        int direction=choose(self);
        if(direction>=0){InterlockedIncrement(&shared->overrides);return (masks[direction]&(1<<action))?1.f:0.f;}
    }
    return originalValue(self,action);
}
static bool __attribute__((fastcall)) pressedHook(void* self, void*, int action) {
    if(action>=0 && action<4) {
        int direction=choose(self);
        if(direction>=0) return (masks[direction]&(1<<action))!=0;
    }
    return originalPressed(self,action);
}
static DWORD WINAPI start(void*) {
    wchar_t name[96];swprintf(name,96,L"Local\\IsaacDodgeNative-%lu",GetCurrentProcessId());
    HANDLE mapping=OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,name);
    if(!mapping)return 1;
    shared=static_cast<Shared*>(MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(Shared)));
    if(!shared){CloseHandle(mapping);return 2;}
    swprintf(name,96,L"Local\\IsaacDodgeNativeLock-%lu",GetCurrentProcessId());
    mutexHandle=OpenMutexW(SYNCHRONIZE|MUTEX_MODIFY_STATE,FALSE,name);
    if(!mutexHandle){InterlockedExchange(&shared->status,-1);return 3;}
    auto base=reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    auto dos=reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto pe=reinterpret_cast<IMAGE_NT_HEADERS*>(base+dos->e_lfanew);
    if(pe->FileHeader.TimeDateStamp!=0x69e6e3a7 || pe->OptionalHeader.SizeOfImage!=0x92c000) {
        InterlockedExchange(&shared->status,-2);return 4;
    }
    // Keyboard vtable only: network device has a different table at RVA 0x778030.
    auto table=reinterpret_cast<void**>(base+0x7a1678);
    originalPressed=reinterpret_cast<BoolFn>(base+0x61e8d0);
    originalValue=reinterpret_cast<ValueFn>(base+0x61ea20);
    if(table[12]!=reinterpret_cast<void*>(originalPressed) || table[14]!=reinterpret_cast<void*>(originalValue)) {
        InterlockedExchange(&shared->status,-3);return 5;
    }
    DWORD oldProtect;
    if(!VirtualProtect(table+12,12,PAGE_READWRITE,&oldProtect)) {InterlockedExchange(&shared->status,-4);return 6;}
    InterlockedExchangePointer(table+12,reinterpret_cast<void*>(pressedHook));
    InterlockedExchangePointer(table+14,reinterpret_cast<void*>(valueHook));
    DWORD ignored;VirtualProtect(table+12,12,oldProtect,&ignored);
    InterlockedExchange(&shared->status,1);
    // Remain mapped until game exit; stale/disabled IPC always calls originals.
    // Unloading during an in-flight callback would be unsafe.
    return 0;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID) {
    if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(module);HANDLE t=CreateThread(nullptr,0,start,nullptr,0,nullptr);if(t)CloseHandle(t);}
    return TRUE;
}
