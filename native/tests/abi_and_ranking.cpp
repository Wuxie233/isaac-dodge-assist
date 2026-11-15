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
    d=decide(safe,0,1024,keys,-1);assert(d.move==0); // Manual pitfall soft-brake stops safe movement.
    d=decide(safe,1u,1024,keys,-1);assert(d.move==-1); // Do not brake onto a blocked idle cell.
    d=decide(threat,0,1024,keys,-1);assert(d.move==1); // Real threat dodge overrides soft-brake.
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
    // function live, with no 3ms snapshot in between.
    Shared idleShared{};shared=&idleShared;
    ValueFn volatile liveValue=reinterpret_cast<ValueFn>(valueHook);
    BoolFn volatile livePressed=reinterpret_cast<BoolFn>(pressedHook);
    originalValue=changingValue;originalPressed=changingPressed;
    mutableValue[0]=0.25f;mutablePressed[0]=false;
    assert(liveValue(&rawBase,0)==0.25f && !livePressed(&rawBase,0));
    mutableValue[0]=1.f;mutablePressed[0]=true;
    assert(liveValue(&rawBase,0)==1.f && livePressed(&rawBase,0)); // no stale snapshot
    assert(!lastPollValid); // nothing was sampled or cached
    // Active, fresh plan: the window snapshot still applies (0.4.2 contract).
    idleShared.magic=0x32444149;idleShared.version=1;idleShared.active=1;idleShared.stamp=GetTickCount();
    mutableValue[0]=0.5f;
    assert(liveValue(&rawBase,0)==0.5f);
    mutableValue[0]=0.75f;
    assert(liveValue(&rawBase,0)==0.5f); // same poll window answers alike
    idleShared.active=0;assert(liveValue(&rawBase,0)==0.75f);
    lastPollValid=false;
    Shared sample{};shared=&sample;originalValue=fakeValue;originalPressed=fakePressed;
    ValueFn volatile value=reinterpret_cast<ValueFn>(valueHook);
    BoolFn volatile pressed=reinterpret_cast<BoolFn>(pressedHook);
    float base=0.125f;uintptr_t before,after;
    asm volatile("mov %%esp,%0":"=r"(before));
    for(int i=0;i<200000;++i){int a=i%32;assert(value(&base,a)==base+a);assert(pressed(&base,a)==(a==2));}
    asm volatile("mov %%esp,%0":"=r"(after));
    assert(before==after);puts("PASS ranking, combat decisions, raw/pressed poll snapshot, 3ms reuse boundary, inactive live passthrough, x87 float/bool return, 200000 thiscall/fastcall pairs, balanced stack");
}
