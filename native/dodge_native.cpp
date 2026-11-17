#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#ifdef min
#undef min
#endif
#ifdef max
#undef max
#endif
#include <cstdint>
#include <cmath>
#include <cstring>
#include <cstdio>
#include "game_structs.hpp"
#include "native_planner.hpp"

// One supported executable build. Zero network-device or game-entity writes.
// combat (former reserved field, 0 from hosts before 0.4) is the Lua IAD2
// word: bits 0-1 mode (1 aim, 2 auto), 2-5 move (0-8, 15 none),
// 6-8 shoot (0 none, 1-4 = actions 4-7), 9 hold fire.
// Extended v2 fields (bytes 128..191) activate 60Hz direct memory prediction
// when extMagic == Shared::kExtMagic ("NAT2").
using iad::Shared;
static Shared* shared;
static void* mappedView;
static SIZE_T mappedViewBytes;
static uintptr_t exeBase;
static bool peMatched;
static HANDLE mutexHandle;
static iad::LocalProcessReader localMem;
static iad::ThreatScene cachedScene;
using ValueFn = float (__attribute__((thiscall)) *)(void*, int);
using BoolFn = bool (__attribute__((thiscall)) *)(void*, int);
static ValueFn originalValue;
static BoolFn originalPressed;
static const int dx[]={0,-1,1,0,0,-1,1,-1,1}, dy[]={0,0,0,-1,1,-1,-1,1,1};
static const int masks[]={0,1,2,4,8,5,6,9,10};
static const int mirrorPerm[]={0,2,1,3,4,6,5,8,7};
static SRWLOCK decisionLock=SRWLOCK_INIT;
// move: candidate index or -1 (original input); fire: bitmask over the
// shoot actions 4-7 or -1 (original input).
struct Decision { int move, fire; };
// One cached answer for every action query in the same short window. The raw
// value and pressed arrays are sampled once too: a passthrough answer must
// not read live input again while the game is still building one input frame.
struct Poll {
    Decision decision{-1,-1};
    float raw[8]{};
    bool pressed[8]{};
};
static Poll lastPoll;
static bool lastPollValid;
static int lastChoice=-1;
static DWORD lastAt;
static void* lastDevice;
static LONGLONG lastCounter, counterFrequency;

// Keyboard directions are binary, so only an actual key-down level (>0.5) is a
// manual override; analog noise must not masquerade as a key, and opposite keys cancel.
static int decodeManualDir(const float* raw, int& outX, int& outY) {
    outX = (raw[1] > 0.5f) - (raw[0] > 0.5f);
    outY = (raw[3] > 0.5f) - (raw[2] > 0.5f);
    for (int i = 1; i < 9; ++i) {
        if (dx[i] == outX && dy[i] == outY) return i;
    }
    return 0;
}

// Any shoot key in AIM/AUTO: fire toward the target instead.
// No shoot key in AUTO: fire as Lua holds/releases.
static int computeFireMask(uint32_t combat, const float* raw) {
    int mode = combat & 3, shoot = (combat >> 6) & 7;
    bool hold = (combat >> 9) & 1;
    bool firing = raw[4] > 0.5f || raw[5] > 0.5f || raw[6] > 0.5f || raw[7] > 0.5f;
    if (mode >= 1 && mode <= 2 && shoot >= 1 && shoot <= 4) {
        if (firing) return 1 << (shoot - 1);
        if (mode == 2) return hold ? (1 << (shoot - 1)) : 0;
    }
    return -1;
}

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
    if(best==manual) return -1; // No safer direction: keep the real key.
    if(risk[manual]<=0) return -1; // Safe manual movement always wins.
    // Retain the last escape only within the same damage score. The 65536
    // tolerance is 64 endpoint-cost units; never retain a worse damage tier.
    if(previous>=0 && previous<9 && !(blocked&(1u<<previous)) &&
       risk[previous]<risk[manual] &&
       std::floor(risk[previous]/1048576.0)==std::floor(risk[best]/1048576.0) &&
       risk[previous]<=risk[best]+65536.0) return previous;
    return best;
}

// Hands off the movement keys in AUTO: walk where Lua chose (dodge already
// included). Soft hazards are avoided by AUTO via hazardCells; manual movement
// is never braked.
static Decision decide(const double* risk, uint32_t blocked, uint32_t combat, const float* raw, int previous) {
    int x = 0, y = 0;
    int manual = decodeManualDir(raw, x, y);
    const bool hasManual = (x != 0 || y != 0);
    int mode = combat & 3, move = (combat >> 2) & 15;
    Decision d{rank(risk, blocked, manual, x, y, previous), computeFireMask(combat, raw)};
    if (mode == 2 && move < 9) {
        if (!hasManual) d.move = move;
        else if (d.move >= 0 && risk[manual] > 0) d.move = d.move;
        else d.move = -1;
    }
    return d;
}

// The cached window is a safety boundary, not a claim about the engine's
// real input-poll boundary: mid-poll packets, focus or ` changes can
// still split a poll longer than 3ms, and two distinct polls closer than 3ms
// share this snapshot. It does make every value and pressed answer (including
// passthrough) come from one raw sample, which the 0.4.1 decision-only cache
// did not.
static int mirrorDir(int dir) {
    return (dir >= 0 && dir < 9) ? mirrorPerm[dir] : dir;
}

// Note: VirtualQuery RegionSize is page-rounded (>= 4096), so mappedViewBytes
// only guards OS page readability; sample.extMagic == Shared::kExtMagic ("NAT2",
// zero in v1 mappings) is the authoritative V2 protocol gate.
static bool hasV2View() {
    return shared && ((static_cast<const void*>(shared) != mappedView) || mappedViewBytes >= sizeof(Shared));
}

static Decision fuseNativeDecision(const iad::PlanResult& plan, uint32_t combat, const float* raw, bool mirror) {
    int x = 0, y = 0;
    int manualLocal = decodeManualDir(raw, x, y);
    const bool hasManual = (x != 0 || y != 0);
    int mode = combat & 3, autoLocalMove = (combat >> 2) & 15;

    int localBest = (plan.bestDir >= 0 && plan.bestDir < 9)
        ? (mirror ? mirrorDir(plan.bestDir) : plan.bestDir)
        : -1;
    Decision d{localBest, computeFireMask(combat, raw)};

    if (mode == 2 && autoLocalMove < 9) {
        int manualWorld = mirror ? mirrorDir(manualLocal) : manualLocal;
        int autoWorld = mirror ? mirrorDir(autoLocalMove) : autoLocalMove;
        bool autoUnblocked = (autoWorld == 0) || ((plan.blockedMask & (1 << autoWorld)) == 0);
        bool autoSafe = autoUnblocked;
        if (autoSafe && plan.danger) {
            // Match combat.lua:882-887: require <= 0 when a safe direction exists;
            // allow +500*kScale slack when only soft warnings exist so AUTO keeps moving!
            double least = 1e30;
            for (int i = 0; i < 9; ++i) {
                if (i > 0 && (plan.blockedMask & (1 << i)) != 0) continue;
                if (plan.straightScores[i] < least) least = plan.straightScores[i];
            }
            double limit = 0.0;
            if (least <= 0.0) {
                limit = 0.0;
            } else if (least < iad::PlanResult::kHard) {
                limit = least + 500.0 * iad::PlanResult::kScale;
            } else {
                limit = least;
            }
            autoSafe = (plan.straightScores[autoWorld] <= limit);
        }
        if (!hasManual) {
            d.move = autoSafe ? autoLocalMove : (localBest >= 0 ? localBest : 0);
        } else if (d.move >= 0 && plan.straightScores[manualWorld] > 0.0) {
            d.move = d.move;
        } else {
            d.move = -1;
        }
    }
    return d;
}

static Decision evaluate(void* device, DWORD now, const float* raw) {
    const Decision none{-1,-1};
    DWORD pid=0; GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    // Pausing is the sensor's ` toggle (Lua 0.25.5); holding Left Shift no
    // longer hands control back, it was too easy to hit by accident.
    if (pid!=GetCurrentProcessId()) return none;
    Shared sample{};
    DWORD wait=WaitForSingleObject(mutexHandle,0);
    if (wait==WAIT_ABANDONED) { shared->active=0; ReleaseMutex(mutexHandle); return none; }
    if (wait!=WAIT_OBJECT_0) return none;
    bool v2View = hasV2View();
    memcpy(&sample, shared, v2View ? sizeof(Shared) : 104u);
    ReleaseMutex(mutexHandle);
    if(sample.magic!=Shared::kMagic || sample.version!=1 || sample.pid!=pid || !sample.active || now-sample.stamp>120) return none;
    int previous=(lastDevice==device && now-lastAt<=120) ? lastChoice : -1;

    if (v2View && sample.extMagic == Shared::kExtMagic) {
        if ((sample.luaFlags & Shared::kFlagPaused) != 0) {
            if (shared->active) InterlockedExchange(&shared->nativeMode, 0);
            return none;
        }
        bool canNative = peMatched && exeBase != 0 &&
                         (sample.luaFlags & Shared::kFlagNativeEnabled) != 0 &&
                         sample.boundSeed != 0;
        if (canNative) {
            LARGE_INTEGER t0{}, t1{};
            QueryPerformanceCounter(&t0);
            localMem.resetCache();
            if (iad::collectThreatScene(localMem, exeBase, sample.boundSeed, sample.luaFlags,
                                        sample.horizonMs, sample.queueDelay, 60, cachedScene)) {
                int x = 0, y = 0;
                int manualLocal = decodeManualDir(raw, x, y);
                bool hasManual = (x != 0 || y != 0);
                bool mirror = cachedScene.grid.mirror;
                int rawWorld = mirror ? mirrorDir(manualLocal) : manualLocal;
                int prevWorld = (previous >= 0 && previous < 9) ? (mirror ? mirrorDir(previous) : previous) : -1;
                int mode = sample.combat & 3;
                // Manual WASD is never blocked from Sacrifice Room spikes or shop items, even in AUTO mode
                bool allowPickups = (mode != 2) || hasManual;
                iad::PlanResult plan = iad::solveNativePlan(cachedScene, rawWorld, prevWorld, allowPickups);
                Decision d = fuseNativeDecision(plan, sample.combat, raw, mirror);
                QueryPerformanceCounter(&t1);
                LONG micros = counterFrequency > 0
                    ? static_cast<LONG>(((t1.QuadPart - t0.QuadPart) * 1000000LL) / counterFrequency)
                    : 0;
                LONG threats = static_cast<LONG>(cachedScene.bullets.size() + cachedScene.discs.size() + cachedScene.lasers.size());
                LONG chosenFlag = (d.move >= 0 ? (d.move & 15) : 15) | (plan.usedTurn ? 16 : 0);
                if (shared->active) {
                    InterlockedExchange(&shared->nativeMode, 1);
                    InterlockedExchange(&shared->nativeThreats, threats);
                    InterlockedExchange(&shared->nativeMicros, micros);
                    InterlockedIncrement(&shared->nativeFrames);
                    InterlockedExchange(&shared->nativeChosen, chosenFlag);
                }
                return d;
            }
            if (cachedScene.paused || cachedScene.passthrough) {
                if (shared->active) InterlockedExchange(&shared->nativeMode, 0);
                return none;
            }
        }
        if (shared->active) InterlockedExchange(&shared->nativeMode, 2);
    }

    return decide(sample.risk,sample.blocked,sample.combat,raw,previous);
}
static void sampleRaw(void* device, float* raw, bool* pressed) {
    for(int i=0;i<8;++i) {
        raw[i]=originalValue(device,i);
        pressed[i]=originalPressed(device,i);
    }
}
static bool reusable(void* device, LONGLONG counter, LONGLONG frequency) {
    return lastPollValid && lastDevice==device &&
        (counter-lastCounter)*1000<frequency*3;
}
static Poll choose(void* device) {
    Poll result{};
    if (!shared) { sampleRaw(device,result.raw,result.pressed); return result; }
    AcquireSRWLockExclusive(&decisionLock);
    LARGE_INTEGER counter; QueryPerformanceCounter(&counter);
    if(!counterFrequency){LARGE_INTEGER f;QueryPerformanceFrequency(&f);counterFrequency=f.QuadPart;}
    if(reusable(device,counter.QuadPart,counterFrequency)) {
        result=lastPoll;
    } else {
        sampleRaw(device,result.raw,result.pressed);
        DWORD now=GetTickCount();
        result.decision=evaluate(device,now,result.raw);
        lastPoll=result; lastPollValid=true;
        lastChoice=result.decision.move; lastAt=now; lastDevice=device; lastCounter=counter.QuadPart;
        InterlockedExchange(&shared->chosen,result.decision.move);
    }
    ReleaseSRWLockExclusive(&decisionLock);
    return result;
}
// Lock-free hint: does the host currently publish an active, fresh plan?
// When it does not (lobby, F7, pause, sensor off, host closed), every query
// goes straight to the original function, exactly as without the DLL. The
// 2026-10-29 Online desync happened in that state while 0.4.3 still served
// 3ms raw snapshots; inactive play no longer shifts any read in time.
static bool engaged() {
    if(!shared) return false;
    const volatile Shared* s=shared;
    bool ok = s->magic==Shared::kMagic && s->version==1 && s->active && GetTickCount()-s->stamp<=120;
    if(!ok && hasV2View() && s->extMagic==Shared::kExtMagic && s->nativeMode!=0) {
        InterlockedExchange(&shared->nativeMode, 0);
    }
    return ok;
}
static int overridden(const Poll& poll, int action) {
    const Decision& d=poll.decision;
    if(action<4) return d.move<0 ? -1 : (masks[d.move]>>action)&1;
    return d.fire<0 ? -1 : (d.fire>>(action-4))&1;
}
static float __attribute__((fastcall)) valueHook(void* self, void*, int action) {
    if(action>=0 && action<8) {
        if(shared && action<4) InterlockedIncrement(&shared->polls);
        if(!engaged()) return originalValue(self,action);
        Poll poll=choose(self);
        int value=overridden(poll,action);
        if(value>=0){InterlockedIncrement(action<4 ? &shared->overrides : &shared->shots);return value?1.f:0.f;}
        return poll.raw[action];
    }
    return originalValue(self,action);
}
static bool __attribute__((fastcall)) pressedHook(void* self, void*, int action) {
    if(action>=0 && action<8) {
        if(!engaged()) return originalPressed(self,action);
        Poll poll=choose(self);
        int value=overridden(poll,action);
        if(value>=0) return value!=0;
        return poll.pressed[action];
    }
    return originalPressed(self,action);
}
static DWORD WINAPI start(void*) {
    wchar_t name[96];swprintf(name,96,L"Local\\IsaacDodgeNative-%lu",GetCurrentProcessId());
    HANDLE mapping=OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,name);
    if(!mapping)return 1;
    mappedView=MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,0);
    if(!mappedView){CloseHandle(mapping);return 2;}
    MEMORY_BASIC_INFORMATION mbi{};
    if(VirtualQuery(mappedView,&mbi,sizeof(mbi))==sizeof(mbi)) {
        mappedViewBytes=mbi.RegionSize;
    }
    if(mappedViewBytes<128){UnmapViewOfFile(mappedView);mappedView=nullptr;CloseHandle(mapping);return 2;}
    shared=static_cast<Shared*>(mappedView);
    swprintf(name,96,L"Local\\IsaacDodgeNativeLock-%lu",GetCurrentProcessId());
    mutexHandle=OpenMutexW(SYNCHRONIZE|MUTEX_MODIFY_STATE,FALSE,name);
    if(!mutexHandle){InterlockedExchange(&shared->status,-1);return 3;}
    auto base=reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    auto dos=reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto pe=reinterpret_cast<IMAGE_NT_HEADERS*>(base+dos->e_lfanew);
    if(pe->FileHeader.TimeDateStamp!=iad::Offsets::kExpectedTimestamp ||
       pe->OptionalHeader.SizeOfImage!=iad::Offsets::kExpectedImageSize) {
        InterlockedExchange(&shared->status,-2);return 4;
    }
    exeBase=base;
    peMatched=true;
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
