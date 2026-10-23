local mt={};mt.__index=mt
function Vector(x,y) return setmetatable({X=x,Y=y},mt) end
function mt.__add(a,b)return Vector(a.X+b.X,a.Y+b.Y)end
function mt.__sub(a,b)return Vector(a.X-b.X,a.Y-b.Y)end
function mt.__mul(a,b)return Vector(a.X*b,a.Y*b)end
function mt:LengthSquared()return self.X*self.X+self.Y*self.Y end
function mt:Length()return math.sqrt(self:LengthSquared()) end
function mt:Dot(b)return self.X*b.X+self.Y*b.Y end
function mt:Resized(n)local l=self:Length();return l>0 and self*(n/l) or Vector(0,0)end
function mt:Normalized()return self:Resized(1)end
function mt:Distance(b)return (self-b):Length()end
function mt:Rotated(a)local r=math.rad(a);return Vector(self.X*math.cos(r)-self.Y*math.sin(r),self.X*math.sin(r)+self.Y*math.cos(r))end
-- Exercise actual main.lua callbacks and sensor output with a minimal game API.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
local callbacks,logs,scene={}, {}, {}
function RegisterMod()return {AddCallback=function(_,kind,fn)callbacks[kind]=fn end}end
local modRoot=os.getenv('IAD_TEST_MOD_ROOT') or 'mod/isaac_dodge_assist/'
function include(name)return dofile(modRoot..name..'.lua')end
local room={}
function room:GetGridWidth()return 25 end
function room:GetGridSize()return 625 end
function room:GetGridEntity()return nil end
function room:GetGridCollision()return 0 end
function room:GetGridIndex(p)return math.floor(p.X/40)+math.floor(p.Y/40)*25 end
function room:GetGridPosition(i)return Vector((i%25)*40+20,math.floor(i/25)*40+20)end
function room:IsPositionInRoom(p)return p.X>=0 and p.X<1000 and p.Y>=0 and p.Y<1000 end
local p={Type=EntityType.ENTITY_PLAYER,Variant=0,SubType=0,Position=Vector(480,480),Velocity=Vector(0,0),Size=5,MoveSpeed=1,InitSeed=9,CanFly=false}
function p:GetPlayerType()return -1 end
function p:GetSubPlayer()return nil end
function p:IsSubPlayer()return false end
function p:IsDead()return false end
function p:IsCoopGhost()return false end
function p:AreControlsEnabled()return true end
function p:ToPlayer()return self end
local paused=false
function Game()return {GetNumPlayers=function()return 1 end,GetRoom=function()return room end,IsPaused=function()return paused end}end
Input={IsButtonPressed=function()return false end,IsButtonTriggered=function()return false end}
Isaac={GetTime=function()return os.clock()*1000 end,GetPlayer=function()return p end,
 GetRoomEntities=function()return scene end,DebugString=function(s)logs[#logs+1]=s end,
 RenderText=function()end,WorldToScreen=function(v)return v end}
dofile(modRoot..'main.lua')
local function tick()callbacks[ModCallbacks.MC_POST_UPDATE]()end
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for i=1,6 do tick()end
assert(logs[#logs]:find('|1|0|250|0,0,0,0,0,0,0,0,0|0',1,true),'empty room must release input')
local function entity(typ,variant)
 local e={Type=typ,Variant=variant,SubType=0,InitSeed=typ*100+variant,SpawnerType=-1,
 Position=Vector(480,480),Velocity=Vector(0,0),Size=30,Scale=1,SpriteScale=Vector(1,1),SizeMulti=Vector(1,1),
 CollisionDamage=1,EntityCollisionClass=EntityCollisionClass.ENTCOLL_ALL,SpriteOffset=Vector(0,0)}
 for _,k in ipairs({'ToNPC','ToProjectile','ToBomb','ToLaser','ToEffect'})do e[k]=function()return nil end end
 function e:IsDead()return false end;function e:HasEntityFlags()return false end
 function e:IsActiveEnemy()return false end
 function e:GetSprite()return {GetAnimation=function()return 'Idle' end,GetFrame=function()return 0 end}end
 return e
end

local counts,allocated={},0
local originalVector=Vector
Vector=function(x,y)allocated=allocated+1;return originalVector(x,y)end
for k,fn in pairs(room)do if type(fn)=='function' then
 room[k]=function(...)counts[k]=(counts[k] or 0)+1;return fn(...)end
end end
local function run(name,n)
 counts={};allocated=0;collectgarbage('collect');local start=os.clock()
 for i=1,n do tick()end
 local elapsed=(os.clock()-start)*1000/n
 local total=0;for _,v in pairs(counts)do total=total+v end
 print(string.format('BENCH %s ms=%.3f roomCalls=%d vectors=%d',name,elapsed,total/n,allocated/n))
 for _,k in ipairs({'IsPositionInRoom','GetGridIndex','GetGridCollision','GetGridEntity'})do print(k..'='..((counts[k] or 0)/n))end
 if os.getenv('PERF_ASSERT') then
  assert(total/n<1500,'excess native room calls')
  assert((counts.IsPositionInRoom or 0)/n<500,'excess repeated room-boundary calls')
  assert(allocated/n<2000,'excess Vector allocations')
 end
end
local creep=entity(EntityType.ENTITY_EFFECT,EffectVariant.CREEP_RED)
function creep:ToEffect()return self end
scene={creep};run('one pool',100)
scene={}
for i=1,200 do
 local e=entity(EntityType.ENTITY_EFFECT,EffectVariant.CREEP_RED)
 function e:ToEffect()return self end
 e.Position=Vector(300+(i%20)*22,300+math.floor(i/20)*22);e.Size=18;e.InitSeed=1000+i;scene[#scene+1]=e
end
run('200 pools',100)
scene={}
for i=1,30 do
 local e=entity(EntityType.ENTITY_PROJECTILE,0)
 function e:ToProjectile()return self end;function e:HasProjectileFlags()return false end
 e.Position=Vector(500+i*2,480);e.Velocity=Vector(-12,0);e.Size=4;e.Height=-20;e.FallingSpeed=0;e.FallingAccel=-0.1;e.InitSeed=2000+i
 scene[#scene+1]=e
end
run('30 projectiles',100)
-- Snapshot and sample real laser geometry through the complete sensor callback.
-- Separate straight beams, many sample segments, and angular sweep slices.
local function lasers(samples,rotation)
 scene={}
 for i=1,4 do
  local e=entity(EntityType.ENTITY_LASER,1)
  e.InitSeed=3000+i;e.Size=8;e.Radius=0;e.RotationDelay=0
  e.IsActiveRotating=rotation~=0;e.RotationSpd=rotation;e.AngleDegrees=(i-1)*90;e.Timeout=60
  local points={}
  for j=1,samples do
   local u=(j-1)/(samples-1)
   points[j]=e.Position+Vector(600*u,samples>2 and math.sin(u*math.pi*2)*35 or 0):Rotated(e.AngleDegrees)
  end
  function points:Get(k)return self[k+1]end
  function e:ToLaser()return self end
  function e:IsCircleLaser()return false end
  function e:GetSamples()return points end
  function e:GetEndPoint()return points[#points]end
  scene[#scene+1]=e
 end
end
lasers(2,0);run('4 straight lasers',10)
lasers(16,0);run('4 curved lasers',10)
lasers(16,2);run('4 rotating curved lasers',10)
-- Optional release artifact: compare every transmitted score and blocked mask
-- with the prior version, excluding sequence/time/diagnostic text.
if os.getenv('IAD_SCORE_OUTPUT') then
 local file=assert(io.open(os.getenv('IAD_SCORE_OUTPUT'),'w'))
 for _,line in ipairs(logs)do
  local data=line:match('^IAD1|%d+|%d+|(.*)$')
  if data then file:write(data,'\n')end
 end
 file:close()
end
