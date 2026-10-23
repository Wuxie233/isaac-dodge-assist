#include "../dodge_native.cpp"
#include <cassert>
static float __attribute__((thiscall)) fakeValue(void* self,int action) {return *static_cast<float*>(self)+action;}
static bool __attribute__((thiscall)) fakePressed(void*,int action) {return action==2;}
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
    double threat[9]={100,0,90,100,100,100,100,100,100};
    d=decide(threat,0,2|(3<<2)|(4<<6)|512,keys,-1);assert(d.move==1); // ...still dodged.
    keys[7]=1;d=decide(safe,0,1|(15<<2)|(1<<6),keys,-1);assert(d.move==-1 && d.fire==1); // AIM redirects a held shot.
    d=decide(safe,0,1|(15<<2)|(1<<6),idle,-1);assert(d.fire==-1); // AIM never fires on its own.
    d=decide(safe,0,2|(15<<2),idle,-1);assert(d.move==-1 && d.fire==-1); // AUTO without target.
    Shared sample{};shared=&sample;originalValue=fakeValue;originalPressed=fakePressed;
    ValueFn volatile value=reinterpret_cast<ValueFn>(valueHook);
    BoolFn volatile pressed=reinterpret_cast<BoolFn>(pressedHook);
    float base=0.125f;uintptr_t before,after;
    asm volatile("mov %%esp,%0":"=r"(before));
    for(int i=0;i<200000;++i){int a=i%32;assert(value(&base,a)==base+a);assert(pressed(&base,a)==(a==2));}
    asm volatile("mov %%esp,%0":"=r"(after));
    assert(before==after);puts("PASS ranking, combat decisions, inactive passthrough, x87 float/bool return, 200000 thiscall/fastcall pairs, balanced stack");
}
