#include "../dodge_native.cpp"
#include <cassert>
static float __attribute__((thiscall)) fakeValue(void* self,int action) {return *static_cast<float*>(self)+action;}
static bool __attribute__((thiscall)) fakePressed(void*,int action) {return action==2;}
static float mutableValue[8];
static bool mutablePressed[8];
static float __attribute__((thiscall)) changingValue(void*,int action) {return mutableValue[action];}
static bool __attribute__((thiscall)) changingPressed(void*,int action) {return mutablePressed[action];}
int main(){
    double safe[9]={};assert(rank(safe,0,0,0,0)==-1);
    double danger[9]={100,0,90,100,100,100,100,100,100};
    assert(rank(danger,0,0,0,0)==1);assert(rank(danger,1<<1,0,0,0)==2);
    danger[0]=0;assert(rank(danger,0,0,0,0)==-1);
    danger[0]=100;danger[1]=NAN;assert(rank(danger,0,0,0,0)==-1);
    double stable[9]={104857600, -500000, -510000, 104857600,104857600,104857600,104857600,104857600,104857600};
    assert(rank(stable,0,0,0,0,1)==1); // Small endpoint changes do not reverse escape.
    assert(rank(stable,1<<1,0,0,0,1)==2); // Blocked previous route is abandoned.
    stable[1]=1048576;assert(rank(stable,0,0,0,0,1)==2); // Never trade safety for persistence.
    stable[0]=-1;assert(rank(stable,0,0,0,0,1)==-1); // Safe manual input immediately wins.
    // Combat word: mode | move<<2 | shoot<<6 | hold<<9.
    float idle[8]={},keys[8]={};keys[1]=1;
    Decision d=decide(safe,0,0,idle,-1);assert(d.move==-1 && d.fire==-1); // No combat word: passthrough.
    d=decide(safe,0,2|(3<<2)|(2<<6)|512,idle,-1);assert(d.move==3 && d.fire==2); // AUTO walks up, holds right.
    d=decide(safe,0,2|(3<<2)|(2<<6),idle,-1);assert(d.fire==0); // AUTO release frame.
    d=decide(safe,0,2|(3<<2)|(2<<6)|512,keys,-1);assert(d.move==-1); // Manual movement wins (safe).
    float analog[8]={};analog[0]=0.2f;
    d=decide(safe,0,2|(3<<2)|(2<<6)|512,analog,-1);assert(d.move==3); // Analog noise is not a manual key.
    float bothKeys[8]={};bothKeys[0]=bothKeys[1]=1;
    d=decide(safe,0,2|(3<<2)|(2<<6)|512,bothKeys,-1);assert(d.move==3); // Opposite keys cancel, AUTO continues.
    float leftOnly[8]={};leftOnly[0]=1;
    d=decide(safe,0,2|(3<<2)|(2<<6)|512,leftOnly,-1);assert(d.move==-1); // Manual left suppresses AUTO.
    d=decide(safe,0,0,leftOnly,-1);assert(d.move==-1); // Manual left is preserved without combat.
    double threat[9]={100,0,90,100,100,100,100,100,100};
    d=decide(threat,0,2|(3<<2)|(4<<6)|512,keys,-1);assert(d.move==1); // ...still dodged.
    d=decide(safe,0,1024,keys,-1);assert(d.move==-1); // Pitfall soft-brake removed: manual movement passes through unbraked.
    d=decide(threat,0,1024,keys,-1);assert(d.move==1); // Real threat dodge overrides manual input.
    d=decide(safe,0,2|(15<<2),idle,-1);assert(d.move==-1 && d.fire==-1); // AUTO without target.
    // Raw values and pressed edges must be frozen together. A later query in
    // the same short window must not observe changed physical input, even
    // when the decision says passthrough.
    originalValue=changingValue;originalPressed=changingPressed;
    for(int i=0;i<8;++i){mutableValue[i]=i*0.125f;mutablePressed[i]=(i%2)==0;}
    float rawBase=0;Poll snap;sampleRaw(&rawBase,snap.raw,snap.pressed);
    for(int i=0;i<8;++i){mutableValue[i]=9.f;mutablePressed[i]=!mutablePressed[i];}
    for(int i=0;i<8;++i){assert(snap.raw[i]==i*0.125f);assert(snap.pressed[i]==((i%2)==0));}
    Poll answer;answer.decision=Decision{1,2};
    assert(overridden(answer,0)==1 && overridden(answer,1)==0 && overridden(answer,2)==0 && overridden(answer,3)==0);
    assert(overridden(answer,4)==0 && overridden(answer,5)==1 && overridden(answer,6)==0 && overridden(answer,7)==0);
    for(int move=0;move<9;++move){
        Poll direction{};direction.decision=Decision{move,-1};
        for(int action=0;action<4;++action){
            int expected=(masks[move]>>action)&1;
            assert(overridden(direction,action)==expected);
        }
        for(int a=0;a<4;++a)for(int b=a+1;b<4;++b){
            bool opposite=(a==0&&b==1)||(a==2&&b==3);
            if(opposite)assert(!(overridden(direction,a)&&overridden(direction,b)));
        }
    }
    lastPollValid=false;lastDevice=&rawBase;lastCounter=1000000;counterFrequency=1000000;
    assert(!reusable(&rawBase,1000001,counterFrequency));
    lastPollValid=true;assert(reusable(&rawBase,1002999,counterFrequency));
    assert(!reusable(&rawBase,1003000,counterFrequency));
    lastPollValid=false;
    // Inactive IPC (lobby, F7, host closed): every query reads the original
    // function live, with no 3ms snapshot in between, and clears nativeMode to 0.
    Shared idleShared{};shared=&idleShared;
    idleShared.extMagic=Shared::kExtMagic;idleShared.nativeMode=1;
    ValueFn volatile liveValue=reinterpret_cast<ValueFn>(valueHook);
    BoolFn volatile livePressed=reinterpret_cast<BoolFn>(pressedHook);
    originalValue=changingValue;originalPressed=changingPressed;
    mutableValue[0]=0.25f;mutablePressed[0]=false;
    assert(liveValue(&rawBase,0)==0.25f && !livePressed(&rawBase,0));
    assert(idleShared.nativeMode==0); // cleared on inactive poll
    mutableValue[0]=1.f;mutablePressed[0]=true;
    assert(liveValue(&rawBase,0)==1.f && livePressed(&rawBase,0)); // no stale snapshot
    assert(!lastPollValid); // nothing was sampled or cached
    // Active, fresh plan: the window snapshot still applies (0.4.2 contract).
    idleShared.magic=Shared::kMagic;idleShared.version=1;idleShared.active=1;idleShared.stamp=GetTickCount();
    mutableValue[0]=0.5f;
    assert(liveValue(&rawBase,0)==0.5f);
    mutableValue[0]=0.75f;
    assert(liveValue(&rawBase,0)==0.5f); // same poll window answers alike
    idleShared.active=0;idleShared.nativeMode=2;
    assert(liveValue(&rawBase,0)==0.75f && idleShared.nativeMode==0);
    lastPollValid=false;
    Shared sample{};shared=&sample;originalValue=fakeValue;originalPressed=fakePressed;
    ValueFn volatile value=reinterpret_cast<ValueFn>(valueHook);
    BoolFn volatile pressed=reinterpret_cast<BoolFn>(pressedHook);
    float base=0.125f;uintptr_t before,after;
    asm volatile("mov %%esp,%0":"=r"(before));
    for(int i=0;i<200000;++i){int a=i%32;assert(value(&base,a)==base+a);assert(pressed(&base,a)==(a==2));}
    asm volatile("mov %%esp,%0":"=r"(after));
    assert(before==after);

    // V2 ABI + native decision fusion + mirror + AUTO wall-block & soft-warning checks
    assert(sizeof(Shared)==192 && offsetof(Shared,extMagic)==128 && offsetof(Shared,nativeMode)==148);
    {
        iad::PlanResult pr{};
        pr.valid=true; pr.danger=true; pr.bestDir=1; // world Left
        for(int i=0;i<9;++i){pr.straightScores[i]=iad::PlanResult::kHard; pr.scores[i]=iad::PlanResult::kHard;}
        pr.straightScores[0]=100.0 * iad::PlanResult::kScale; pr.scores[0]=pr.straightScores[0];
        pr.straightScores[1]=-10.0; pr.scores[1]=-10.0;
        float idleR[8]{};
        Decision d1=fuseNativeDecision(pr, 0, idleR, false);
        assert(d1.move==1 && d1.fire==-1);
        Decision dMirror=fuseNativeDecision(pr, 0, idleR, true);
        assert(dMirror.move==2 && dMirror.fire==-1); // local Right moves world Left in mirror
        // AUTO wants local Right (move=2) -> world Right (dir=2, hard danger) => dodges Left (1)
        Decision dAuto=fuseNativeDecision(pr, 2u|(2u<<2)|(1u<<6)|(1u<<9), idleR, false);
        assert(dAuto.move==1 && dAuto.fire==1);
        // When bestDir==-1 (idle 0 is safe) and AUTO wants unsafe dir 2 => hold still (move=0)
        iad::PlanResult prHold{}; prHold.valid=true; prHold.danger=true; prHold.bestDir=-1;
        prHold.straightScores[0]=-10.0; prHold.straightScores[2]=iad::PlanResult::kHard;
        Decision dHold=fuseNativeDecision(prHold, 2u|(2u<<2), idleR, false);
        assert(dHold.move==0);
        // Stale AUTO move into wall when !danger must NOT drive into blocked wall
        iad::PlanResult prWall{}; prWall.valid=true; prWall.danger=false; prWall.bestDir=-1; prWall.blockedMask=(1<<2);
        Decision dWall=fuseNativeDecision(prWall, 2u|(2u<<2), idleR, false);
        assert(dWall.move==0);
        // Soft-warning-only zone (all directions in [10..50]*kScale): AUTO keeps walking instead of freezing at 0!
        iad::PlanResult prSoft{}; prSoft.valid=true; prSoft.danger=true; prSoft.bestDir=1;
        for(int i=0;i<9;++i){prSoft.straightScores[i]=20.0*iad::PlanResult::kScale; prSoft.scores[i]=prSoft.straightScores[i];}
        prSoft.straightScores[1]=10.0*iad::PlanResult::kScale; prSoft.scores[1]=prSoft.straightScores[1];
        Decision dSoft=fuseNativeDecision(prSoft, 2u|(3u<<2), idleR, false);
        assert(dSoft.move==3);
        // Crossed AUTO-avoid cell (600000*kScale) exceeds +500*kScale slack -> AUTO detours!
        prSoft.straightScores[3]=600000.0*iad::PlanResult::kScale;
        Decision dPed=fuseNativeDecision(prSoft, 2u|(3u<<2), idleR, false);
        assert(dPed.move==1);
        // Manual Right key in safe AUTO case passes through (-1)
        float rightHeld[8]{0.f,1.f};
        iad::PlanResult prRightSafe{}; prRightSafe.valid=true; prRightSafe.danger=false; prRightSafe.bestDir=-1;
        Decision dMan=fuseNativeDecision(prRightSafe, 2u|(1u<<2), rightHeld, false);
        assert(dMan.move==-1);
    }
    puts("PASS ranking, combat decisions, raw/pressed poll snapshot, 3ms reuse boundary, inactive live passthrough, v2 ABI & fusion, x87 float/bool return, 200000 thiscall/fastcall pairs, balanced stack");
}
