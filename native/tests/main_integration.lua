-- Exercise actual main.lua callbacks and sensor output with a minimal game API.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
local callbacks,logs,scene={}, {}, {}
function RegisterMod()return {AddCallback=function(_,kind,fn)callbacks[kind]=fn end}end
function include(name)return dofile('mod/isaac_dodge_assist/'..name..'.lua')end
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
dofile('mod/isaac_dodge_assist/main.lua')
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
local creep=entity(EntityType.ENTITY_EFFECT,EffectVariant.CREEP_RED)
function creep:ToEffect()return self end
scene={creep};tick();tick()
local function packet()
 local line=logs[#logs];local parts={}
 for part in line:gmatch('[^|]+')do parts[#parts+1]=part end
 assert(parts[1]=='IAD1' and #parts==8 and parts[4]=='1','invalid IAD1 contract')
 local s={};for number in parts[7]:gmatch('[^,]+')do
  local n=assert(tonumber(number));assert(n==n and math.abs(n)<2^53 and n%1==0,'non-finite/imprecise score');s[#s+1]=n
 end
 assert(#s==9 and tonumber(parts[8])>=0 and tonumber(parts[8])<512)
 return s
end
local values=packet();local best=math.min(table.unpack(values))
assert(values[1]>best and values[1]>0,'main integration did not favor escape from creep')
callbacks[ModCallbacks.MC_ENTITY_TAKE_DMG](nil,p,1,0,{Entity=creep})
local plannerFound=false
for _,line in ipairs(logs)do
 assert(not line:find('IAD DIAG ERROR',1,true),'diagnostics failed: '..line)
 if line:find('IAD DIAG DECISION:',1,true) and line:find('planner=steps=',1,true) then plannerFound=true end
end
assert(plannerFound,'new planner diagnostics missing from hit record')
local function perfLogs()
 local found={}
 for _,line in ipairs(logs)do if line:find('IAD PERF:',1,true)then found[#found+1]=line end end
 return found
end
callbacks[ModCallbacks.MC_POST_NEW_ROOM]()
local summaries=perfLogs()
assert(#summaries==1 and summaries[1]:find('n=2 ',1,true) and summaries[1]:find('reason=room',1,true),
 'room transition discarded a short encounter')
callbacks[ModCallbacks.MC_POST_NEW_ROOM]()
assert(#perfLogs()==1,'empty room transition repeated old performance data')
scene={}
for i=1,3 do tick()end -- Existing room-entry input gate.
local bullet=entity(EntityType.ENTITY_PROJECTILE,0)
function bullet:ToProjectile()return self end
function bullet:HasProjectileFlags()return false end
bullet.Height=-20;bullet.FallingSpeed=0;bullet.FallingAccel=-0.1
bullet.Position=Vector(540,480);bullet.Velocity=Vector(-12,0);bullet.Size=4
scene={bullet};tick();values=packet()
assert(values[1]>0,'main integration missed approaching projectile')
local npc=entity(EntityType.ENTITY_NPC,0)
function npc:ToNPC()return self end;function npc:IsBoss()return false end
function npc:IsActiveEnemy()return true end
npc.Position=Vector(550,480);npc.Velocity=Vector(-10,0);npc.Size=6
scene={npc};tick();values=packet()
assert(values[1]>0,'main integration missed fast contact enemy')
scene={};tick();values=packet();for _,s in ipairs(values)do assert(s==0,'stale hazard survived empty room')end
paused=true;tick();assert(logs[#logs]:find('|0|0|250|0,0,0,0,0,0,0,0,0|0',1,true),'pause did not release')
callbacks[ModCallbacks.MC_POST_RENDER]()
callbacks[ModCallbacks.MC_PRE_GAME_EXIT]()
summaries=perfLogs()
assert(#summaries==2 and summaries[2]:find('n=2 ',1,true) and summaries[2]:find('reason=game-exit',1,true),
 'game exit discarded a short encounter')
print('PASS full main integration: creep, projectile, fast enemy, IAD1 numeric contract, diagnostics, empty room and pause')
-- An explosive projectile can hurt from outside its small body hitbox and
-- when its current height/collision class prevents direct body collision.
paused=false;scene={}
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for i=1,4 do tick()end
local explosive=entity(EntityType.ENTITY_PROJECTILE,0)
function explosive:ToProjectile()return self end
function explosive:HasProjectileFlags(flag)return flag==ProjectileFlags.EXPLODE end
explosive.Position=Vector(550,480);explosive.Size=4
explosive.Height=-80;explosive.FallingSpeed=0;explosive.FallingAccel=-0.1
explosive.EntityCollisionClass=EntityCollisionClass.ENTCOLL_NONE
scene={explosive};tick();values=packet()
assert(values[1]>0 and math.min(table.unpack(values))<values[1],
 'explosive projectile outside body collision has no evacuation warning')
callbacks[ModCallbacks.MC_ENTITY_TAKE_DMG](nil,p,1,4,{Entity=explosive})
local sourceRecorded=false
for _,line in ipairs(logs)do
 if line:find('IAD DIAG HIT:',1,true) and line:find('explode=true height=-80',1,true) then sourceRecorded=true end
 assert(not line:find('IAD DIAG ERROR',1,true),'source diagnostics failed')
end
assert(sourceRecorded,'explosive source flags/height missing from damage record')
function explosive:HasProjectileFlags()return false end
tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'ordinary high projectile received explosion warning')end
function explosive:HasProjectileFlags(flag)return flag==ProjectileFlags.EXPLODE end
explosive.SpawnerType=EntityType.ENTITY_PLAYER
tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'player-owned projectile received hostile explosion warning')end
explosive.SpawnerType=-1
function explosive:IsDead()return true end
tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'expired projectile retained explosion warning')end
local smoke=entity(EntityType.ENTITY_EFFECT,EffectVariant.BOMB_EXPLOSION)
function smoke:ToEffect()return self end
scene={smoke};tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'lingering explosion graphics retained damage')end
print('PASS explosive projectile warning and ordinary/friendly/expired/smoke exclusions')
