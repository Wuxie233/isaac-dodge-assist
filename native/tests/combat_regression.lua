-- Combat assist (combat.lua): IAD2 word, aim lead, targets, goal lanes,
-- dodge priority and charge release.
local mt={};mt.__index=mt
function Vector(x,y) return setmetatable({X=x,Y=y},mt) end
function mt.__add(a,b)return Vector(a.X+b.X,a.Y+b.Y)end
function mt.__sub(a,b)return Vector(a.X-b.X,a.Y-b.Y)end
function mt.__mul(a,b)return Vector(a.X*b,a.Y*b)end
function mt:Length()return math.sqrt(self.X*self.X+self.Y*self.Y)end
function mt:LengthSquared()return self.X*self.X+self.Y*self.Y end
function mt:Distance(b)return (self-b):Length()end
function mt:Normalized()local l=self:Length();return l>0 and self*(1/l) or Vector(0,0)end
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EntityCollisionClass','GridCollisionClass','EntityFlag'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
WeaponType={WEAPON_TEARS=1,WEAPON_BRIMSTONE=2,WEAPON_LASER=3,WEAPON_KNIFE=4,WEAPON_MONSTROS_LUNGS=7,WEAPON_TECH_X=9,WEAPON_SPIRIT_SWORD=13}
local Combat=dofile('mod/isaac_dodge_assist/combat.lua')

-- 15x9 room, walls on the ring; rocks settable per cell.
local W,H=15,9
local rocks={}
local room={}
function room:GetGridWidth()return W end
function room:GetGridSize()return W*H end
function room:GetGridCollision(i)
 local x,y=i%W,i//W
 if x==0 or y==0 or x==W-1 or y==H-1 then return GridCollisionClass.COLLISION_WALL end
 return rocks[i] and GridCollisionClass.COLLISION_SOLID or 0
end
function room:GetGridIndex(p)
 local x,y=math.floor(p.X/40),math.floor(p.Y/40)
 if x<0 or y<0 or x>=W or y>=H then return -1 end
 return x+y*W
end
function room:IsPositionInRoom(p,r)r=r or 0;return p.X-r>=40 and p.X+r<=560 and p.Y-r>=40 and p.Y+r<=320 end
local function safeXY(_,_,x,y)local i=room:GetGridIndex(Vector(x,y));return i>=0 and room:GetGridCollision(i)==0 end
local directions={Vector(0,0),Vector(-1,0),Vector(1,0),Vector(0,-1),Vector(0,1),
 Vector(-1,-1):Normalized(),Vector(1,-1):Normalized(),Vector(-1,1):Normalized(),Vector(1,1):Normalized()}

local weapons={}
local p={Position=Vector(100,180),Velocity=Vector(0,0),Size=10,MoveSpeed=1,InitSeed=9,CanFly=false,ShotSpeed=1,TearRange=260}
function p:HasWeaponType(w)return weapons[w]==true end
function p:HasCollectible()return false end
local seeds=100
local function enemy(x,y,vx,vy,opts)
 seeds=seeds+1;opts=opts or {}
 local e={Type=EntityType.ENTITY_NPC,InitSeed=seeds,Position=Vector(x,y),Velocity=Vector(vx or 0,vy or 0),Size=13,HitPoints=10,
  EntityCollisionClass=EntityCollisionClass.ENTCOLL_ALL,FrameCount=10}
 function e:ToNPC()return self end
 function e:IsDead()return false end
 function e:IsActiveEnemy()return opts.active~=false end
 function e:IsVulnerableEnemy()return opts.vulnerable~=false end
 function e:HasEntityFlags(f)return opts.friendly==true and f==EntityFlag.FLAG_FRIENDLY end
 return e
end
local function owned()return false end
local frame=0
local function update(state,entities,extra)
 frame=frame+1
 local ctx={player=p,room=room,frame=frame,entities=entities,playerOwned=owned,gridSafeXY=safeXY,
  directions=directions,stride=8.6,queueDelay=0}
 for k,v in pairs(extra or {}) do ctx[k]=v end
 return Combat.decode(Combat.update(state,ctx))
end

-- Word round trip; OFF publishes nothing.
local m,mv,sh,hold=Combat.decode(Combat.word(2,8,4,true));assert(m==2 and mv==8 and sh==4 and hold)
m,mv,sh,hold=Combat.decode(Combat.word(1,nil,3,false));assert(m==1 and mv==nil and sh==3 and not hold)
local s=Combat.new()
assert(Combat.update(s,{entities={enemy(300,180)}})==0)

-- AIM: target to the right; lead turns a fast vertical mover into an up shot.
Combat.cycle(s)
m,mv,sh=update(s,{enemy(300,180)});assert(m==1 and mv==nil and sh==2,'aim right')
m,mv,sh=update(s,{enemy(220,150,0,-10)});assert(sh==3,'lead up: '..sh)
-- Online queue delay lengthens the lead.
local slow=enemy(140,180,0,-6)
m,mv,sh=update(s,{slow});assert(sh==2)
m,mv,sh=update(s,{slow},{queueDelay=4});assert(sh==3,'queue lead')

-- Targets: friendly, invulnerable, intangible and inactive enemies are ignored.
local ghost=enemy(130,180);ghost.EntityCollisionClass=EntityCollisionClass.ENTCOLL_NONE
m,mv,sh=update(s,{enemy(130,180,0,0,{friendly=true}),enemy(110,200,0,0,{vulnerable=false}),ghost,
 enemy(120,170,0,0,{active=false}),enemy(100,300)})
assert(sh==4 and s.info.targetY==300,'only the hostile below counts')
-- Hysteresis: keep the current target unless another is clearly closer.
local a,b=enemy(300,180),enemy(100,320)
update(s,{a,b});assert(s.targetSeed==b.InitSeed)
b.Position=Vector(100,350);update(s,{a,b});assert(s.targetSeed==b.InitSeed,'kept')
b.Position=Vector(100,600);update(s,{a,b});assert(s.targetSeed==a.InitSeed,'switched')
print('PASS combat word, aim lead with queue, target filters and hysteresis')

-- AUTO: goal on the target row/column with a clear lane.
Combat.cycle(s);assert(s.mode==2)
p.Position=Vector(100,100)
local t=enemy(300,180)
m,mv,sh,hold=update(s,{t})
assert(m==2 and hold and s.info.goalX,'auto goal')
assert(math.abs(s.info.goalX-300)<1 or math.abs(s.info.goalY-180)<1,'goal aligned')
-- A rock between goal and target closes that lane.
local gx,gy=s.info.goalX,s.info.goalY
local mx,my=(gx+300)/2,(gy+180)/2
rocks[room:GetGridIndex(Vector(mx,my))]=true
s.grid=nil
update(s,{t})
assert(not (math.abs(s.info.goalX-gx)<1 and math.abs(s.info.goalY-gy)<1),'blocked lane abandoned')
rocks={};s.grid=nil
-- Walking heads toward the goal when everything is safe.
p.Position=Vector(100,180)
m,mv=update(s,{enemy(400,180)})
assert(mv and directions[mv+1].X>0,'walk toward the row goal: '..tostring(mv))
-- Dodge first: only one safe direction.
local scores={}
for i=1,9 do scores[i]=5000000*1048576 end
scores[5]=-1048576+100
m,mv=update(s,{enemy(400,180)},{scores=scores,blocked=0})
assert(mv==4,'safe direction wins over the goal')
-- All hard: the least risky open direction.
for i=1,9 do scores[i]=(3000000+i)*1048576 end
m,mv=update(s,{enemy(400,180)},{scores=scores,blocked=1})
assert(mv==1,'least hard risk among open: '..tostring(mv))
print('PASS auto goal lanes, rock lane switch, goal walking, dodge priority')

-- Charge weapons: full after ceil(MaxFireDelay)+2 updates, released once
-- aligned for two updates; a release with no attack adds bias, an attack
-- removes some; the next charge waits for the beam to end.
p.Index,p.MaxFireDelay=1,19.5
local nextIndex=1000
local function attack(kind,extra)
 nextIndex=nextIndex+1
 local e={Type=kind,Index=nextIndex,InitSeed=nextIndex,FrameCount=0,SpawnerEntity=p,dead=false}
 function e:ToNPC()return nil end
 function e:IsDead()return self.dead end
 function e:ToLaser()return self end
 for k,v in pairs(extra or {})do e[k]=v end
 return e
end
weapons[WeaponType.WEAPON_BRIMSTONE]=true
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
p.Position=Vector(100,180)
local target=enemy(400,180)
local function holds(n,entities)
 local pattern={}
 for i=1,n do local _,_,_,h=update(s,entities or {target});pattern[i]=h and 'H' or 'r' end
 return table.concat(pattern)
end
local first=holds(24)
assert(first==string.rep('H',21)..'rrH','first charge pattern: '..first)
holds(4)
assert(s.bias==3,'no beam after release: bias '..s.bias)
-- need 25 now: release, then a laser comes out.
s.held=24
assert(holds(3)=='rrH')
local beam=attack(EntityType.ENTITY_LASER,{MaxDistance=0})
update(s,{target,beam})
assert(s.bias==2.5 and s.checkAt==nil,'beam seen: bias '..s.bias)
for _=1,10 do update(s,{target,beam}) end
assert(s.held==0,'charging waits for the beam')
beam.dead=true
-- Not aligned: keep holding at full charge.
p.Position=Vector(100,300)
s.held=200
local _,_,_,h=update(s,{enemy(400,60)})
assert(h,'misaligned charge is held')
p.Position=Vector(100,180)
-- The hint says charge, but tears come out of an unbroken hold: auto-fire.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
for i=1,8 do
 local list={target}
 if i>=6 then list[2]=attack(EntityType.ENTITY_TEAR) end
 update(s,list)
end
assert(s.weapon=='tears' and s.autoFireAt,'evidence beats the hint')
assert(holds(30,{target,attack(EntityType.ENTITY_TEAR)}):find('r')==nil,'auto-fire holds')
weapons={}
-- The hint says tears, but a long hold produces nothing: charging.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
holds(50)
assert(s.stalled and s.weapon=='charge','a silent hold switches to charge')
-- Azazel: the laser length caps the standing distance.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
weapons[WeaponType.WEAPON_BRIMSTONE]=true
update(s,{target});update(s,{target,attack(EntityType.ENTITY_LASER,{MaxDistance=110})})
assert(s.laserReach==110 and s.info.goalX,'laser reach recorded')
assert(math.abs(s.info.goalX-400)+math.abs(s.info.goalY-180)<=110,'goal inside the laser')
weapons={}
print('PASS charge timing from MaxFireDelay, release check, beam wait, fire evidence, laser reach')
