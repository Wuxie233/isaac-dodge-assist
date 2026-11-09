local logs={}
Isaac={DebugString=function(line)logs[#logs+1]=line end}
local D=dofile('mod/isaac_dodge_assist/diagnostics.lua')
D.reset()
assert(#logs==0,'empty reset logged a fake sample')
D.performance(4,10,2,3,5,100)
D.performance(9,20,4,6,10,200)
D.reset('room')
assert(#logs==1,'short room discarded its performance samples')
assert(logs[1]:find('frame=9 n=2 avgMs=15.00 maxMs=20.00 scanMs=3.00 fieldMs=4.50 planMs=7.50 terrainCalls=150.0',1,true),logs[1])
assert(logs[1]:find('reason=room',1,true),logs[1])
D.reset('room')
assert(#logs==1,'empty reset duplicated previous room')
for i=1,90 do D.performance(i,1,0.2,0.3,0.5,10) end
assert(#logs==2 and logs[2]:find('n=90',1,true),'full aggregate missing')
D.reset('room')
assert(#logs==2,'full aggregate emitted twice')
D.performance(91,3,1,1,1,20)
D.flushPerformance('game-exit')
assert(#logs==3 and logs[3]:find('n=1',1,true) and logs[3]:find('reason=game-exit',1,true))
D.flushPerformance('game-exit')
assert(#logs==3,'exit emitted twice')
print('PASS short-room and game-exit performance flush, exact averages and no duplicates')
-- 0.25.9 IAD SHOT: each enemy shot once, only near the player, capped per
-- room and counted again after a room change.
local function vec(x,y)return {X=x,Y=y,Distance=function(a,b)return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2)end}end
ProjectileFlags={EXPLODE=2}
local function shot(seed,x)
 return {Type=9,Variant=0,SubType=0,InitSeed=seed,FrameCount=2,SpawnerType=42,Position=vec(x,0),Velocity=vec(1,0),
  Size=5,EntityCollisionClass=4,ProjectileFlags=0,Height=-20,FallingSpeed=0,FallingAccel=0,
  GetSprite=function()return {GetAnimation=function()return 'Move'end,GetFrame=function()return 0 end}end,
  IsDead=function()return false end,ToProjectile=function(self)return self end,HasProjectileFlags=function()return false end}
end
local me={Position=vec(0,0)}
logs={}
D.shot(5,shot(1,60),me,true);D.shot(6,shot(1,50),me,true);D.shot(6,shot(2,400),me,false)
assert(#logs==1 and logs[1]:find('^IAD SHOT: frame=5 age=2 dist=60 9%.0%.0#1') and logs[1]:find('spawnerType=42 included=true',1,true),
 'shot record: '..tostring(logs[1]))
for i=3,60 do D.shot(7,shot(i,10),me,false) end
assert(#logs==40,'shot cap: '..#logs)
D.reset('room');logs={}
D.shot(1,shot(1,60),me,true);assert(#logs==1,'shot not recorded after a room change')
print('PASS IAD SHOT: first sight near the player, once per shot, capped per room')
