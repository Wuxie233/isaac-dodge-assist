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
    Shared sample{};shared=&sample;originalValue=fakeValue;originalPressed=fakePressed;
    ValueFn volatile value=reinterpret_cast<ValueFn>(valueHook);
    BoolFn volatile pressed=reinterpret_cast<BoolFn>(pressedHook);
    float base=0.125f;uintptr_t before,after;
    asm volatile("mov %%esp,%0":"=r"(before));
    for(int i=0;i<200000;++i){int a=i%32;assert(value(&base,a)==base+a);assert(pressed(&base,a)==(a==2));}
    asm volatile("mov %%esp,%0":"=r"(after));
    assert(before==after);puts("PASS ranking, inactive passthrough, x87 float/bool return, 200000 thiscall/fastcall pairs, balanced stack");
}
