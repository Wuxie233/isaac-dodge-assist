#include <windows.h>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <cstdio>

// One supported executable build. No network-device or entity-state writes.
// combat (former reserved field, 0 from hosts before 0.4) is the Lua IAD2
// word: bits 0-1 mode (1 aim, 2 auto), 2-5 move (0-8, 15 none),
// 6-8 shoot (0 none, 1-4 = actions 4-7), 9 hold fire.
struct Shared {
    uint32_t magic, version, pid, stamp, active, blocked, sequence, combat;
    double risk[9];
    volatile LONG status, polls, overrides, chosen, shots;
};
static_assert(offsetof(Shared, risk)==32 && offsetof(Shared,status)==104 && offsetof(Shared,shots)==120, "IPC layout");
static Shared* shared;
static HANDLE mutexHandle;
using ValueFn = float (__attribute__((thiscall)) *)(void*, int);
using BoolFn = bool (__attribute__((thiscall)) *)(void*, int);
static ValueFn originalValue;
static BoolFn originalPressed;
static const int dx[]={0,-1,1,0,0,-1,1,-1,1}, dy[]={0,0,0,-1,1,-1,-1,1,1};
static const int masks[]={0,1,2,4,8,5,6,9,10};
static SRWLOCK decisionLock=SRWLOCK_INIT;
// move: candidate index or -1 (original input); fire: bitmask over the
// shoot actions 4-7 or -1 (original input).
struct Decision { int move, fire; };
static Decision lastDecision{-1,-1};
static int lastChoice=-1;
static DWORD lastAt;
static void* lastDevice;
static uint32_t lastSequence;
static LONGLONG lastCounter, counterFrequency;

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

// Hands off the movement keys in AUTO: walk where Lua chose (dodge already
// included). Any shoot key in AIM/AUTO: fire toward the target instead.
// No shoot key in AUTO: fire as Lua holds/releases.
static Decision decide(const double* risk, uint32_t blocked, uint32_t combat, const float* raw, int previous) {
    int x=(raw[1]>0.1f)-(raw[0]>0.1f), y=(raw[3]>0.1f)-(raw[2]>0.1f), manual=0;
    for(int i=0;i<9;++i) if(dx[i]==x && dy[i]==y) manual=i;
    int mode=combat&3, move=(combat>>2)&15, shoot=(combat>>6)&7;
    bool hold=(combat>>9)&1;
    Decision d{rank(risk,blocked,manual,x,y,previous),-1};
    if(mode==2 && manual==0 && move<9) d.move=move;
    bool firing=raw[4]>0.1f || raw[5]>0.1f || raw[6]>0.1f || raw[7]>0.1f;
    if(mode>=1 && mode<=2 && shoot>=1 && shoot<=4) {
        if(firing) d.fire=1<<(shoot-1);
        else if(mode==2) d.fire=hold ? 1<<(shoot-1) : 0;
    }
    return d;
}
static Decision choose(void* device) {
    const Decision none{-1,-1};
    DWORD pid=0; GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    if (!shared || pid!=GetCurrentProcessId() || (GetAsyncKeyState(VK_LSHIFT)&0x8000)) return none;
    Shared sample{};
    DWORD wait=WaitForSingleObject(mutexHandle,0);
    if (wait==WAIT_ABANDONED) { shared->active=0; ReleaseMutex(mutexHandle); return none; }
    if (wait!=WAIT_OBJECT_0) return none;
    memcpy(&sample, shared, 104);
    ReleaseMutex(mutexHandle);
    DWORD now=GetTickCount();
    if(sample.magic!=0x32444149 || sample.version!=1 || sample.pid!=pid || !sample.active || now-sample.stamp>120) return none;
    if(!TryAcquireSRWLockExclusive(&decisionLock)) return none;
    // Share one decision among the action queries of a single input poll.
    // GetTickCount moves in ~16ms steps and could hold a decision across a
    // 60Hz player tick; a new packet or 4ms on the performance counter ends it.
    LARGE_INTEGER counter; QueryPerformanceCounter(&counter);
    if(!counterFrequency){LARGE_INTEGER f;QueryPerformanceFrequency(&f);counterFrequency=f.QuadPart;}
    if(lastDevice==device && lastSequence==sample.sequence &&
       (counter.QuadPart-lastCounter)*250<counterFrequency) {
        Decision result=lastDecision; ReleaseSRWLockExclusive(&decisionLock); return result;
    }
    float raw[8]; for(int i=0;i<8;++i) raw[i]=originalValue(device,i);
    int previous=(lastDevice==device && now-lastAt<=120) ? lastChoice : -1;
    lastDecision=decide(sample.risk,sample.blocked,sample.combat,raw,previous);
    lastChoice=lastDecision.move;
    lastAt=now; lastDevice=device; lastSequence=sample.sequence; lastCounter=counter.QuadPart;
    InterlockedExchange(&shared->chosen,lastChoice);
    Decision result=lastDecision; ReleaseSRWLockExclusive(&decisionLock); return result;
}
static int overridden(void* self, int action) {
    Decision d=choose(self);
    if(action<4) return d.move<0 ? -1 : (masks[d.move]>>action)&1;
    return d.fire<0 ? -1 : (d.fire>>(action-4))&1;
}
static float __attribute__((fastcall)) valueHook(void* self, void*, int action) {
    if(action>=0 && action<8) {
        if(action<4) InterlockedIncrement(&shared->polls);
        int value=overridden(self,action);
        if(value>=0){InterlockedIncrement(action<4 ? &shared->overrides : &shared->shots);return value?1.f:0.f;}
    }
    return originalValue(self,action);
}
static bool __attribute__((fastcall)) pressedHook(void* self, void*, int action) {
    if(action>=0 && action<8) {
        int value=overridden(self,action);
        if(value>=0) return value!=0;
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
