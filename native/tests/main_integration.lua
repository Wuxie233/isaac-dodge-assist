-- Exercise actual main.lua callbacks and sensor output with a minimal game API.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags','ButtonAction'})do _G[name]=enum()end
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
-- Local device streams. Only controller 0 (our keyboard) reports a value, and
-- the applied movement follows it one update later; a co-op partner on
-- controller 1 has no local device at all.
local currentAt=0
local deviceDir, appliedDir = {}, {}
local function dirAt(table_,frame) return table_[frame] or {X=0,Y=0} end
function p.GetMovementInput() return dirAt(appliedDir,currentAt) end
Input={IsButtonPressed=function()return false end,IsButtonTriggered=function()return false end}
function Input.GetActionValue(action,controller)
 if controller~=0 then return 0 end
 local value=dirAt(deviceDir,currentAt)
 if action==ButtonAction.ACTION_LEFT then return math.max(0,-value.X) end
 if action==ButtonAction.ACTION_RIGHT then return math.max(0,value.X) end
 if action==ButtonAction.ACTION_UP then return math.max(0,-value.Y) end
 if action==ButtonAction.ACTION_DOWN then return math.max(0,value.Y) end
 return 0
end
-- Mutable roster: co-op joins/leaves and lobby restarts change it mid-run.
local roster,rosterCount={p},1
function Game()return {GetNumPlayers=function()return rosterCount end,GetRoom=function()return room end,IsPaused=function()return paused end}end
Isaac={GetTime=function()return os.clock()*1000 end,GetPlayer=function(i)return roster[(i or 0)+1] or p end,
 GetRoomEntities=function()return scene end,DebugString=function(s)logs[#logs+1]=s end,
 RenderText=function()end,WorldToScreen=function(v)return v end}
dofile('mod/isaac_dodge_assist/main.lua')
local function tick() currentAt=currentAt+1; callbacks[ModCallbacks.MC_POST_UPDATE]() end
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for i=1,6 do tick()end
assert(logs[#logs]:find('|1|0|450|0,0,0,0,0,0,0,0,0|0',1,true),'empty room must release input')
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
paused=true;tick();assert(logs[#logs]:find('|0|0|450|0,0,0,0,0,0,0,0,0|0',1,true),'pause did not release')
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
-- Red poop hurts on contact; normal poop and flight do not.
local poopIndex,poopVariant=313,1 -- center (540,500)
function room:GetGridEntity(i)
 if i~=poopIndex then return nil end
 return {Position=room:GetGridPosition(i),State=0,GetType=function()return GridEntityType.GRID_POOP end,
  GetVariant=function()return poopVariant end}
end
function room:GetGridCollision(i)return i==poopIndex and GridCollisionClass.COLLISION_SOLID or 0 end
scene={};p.Position=Vector(470,500);p.Velocity=Vector(0,0)
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
-- The hazard list is refreshed at least every six updates, so a grid that
-- appears mid-room is picked up within that window and never later.
for i=1,12 do tick()end
values=packet()
assert(values[3]>0 and values[1]<=0 and values[2]<=0,'red poop contact not avoided')
poopVariant=0;tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'normal poop treated as damaging')end
poopVariant=1;p.CanFly=true;tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'flying player avoided red poop')end
p.CanFly=false
print('PASS red poop contact, normal poop and flight exclusions')
-- F9 danger preview: off by default, toggles, captures and renders lines.
local renders,loaded=0,nil
function Sprite()return {Load=function(_,path)loaded=path end,Play=function()end,
 Render=function(self,pos)assert(self.Scale.X>0 and self.Rotation==self.Rotation);renders=renders+1 end}end
function Color(r,g,b,a)return {R=r,G=g,B=b,A=a}end
Isaac.GetScreenWidth=function()return 480 end
local npc2=entity(EntityType.ENTITY_NPC,0)
function npc2:ToNPC()return self end;function npc2:IsBoss()return false end;function npc2:IsActiveEnemy()return true end
npc2.Position=Vector(560,500);npc2.Velocity=Vector(-6,0);npc2.Size=10
scene={npc2,bullet};bullet.Position=Vector(470,560);bullet.Velocity=Vector(0,-8)
p.Position=Vector(470,500)
callbacks[ModCallbacks.MC_POST_RENDER]();assert(renders==0,'preview drew while disabled')
Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_F9 end
callbacks[ModCallbacks.MC_POST_RENDER]()
Input.IsButtonTriggered=function()return false end
tick();callbacks[ModCallbacks.MC_POST_RENDER]()
assert(loaded=='gfx/iad/iad_shapes.anm2' and renders>20,'danger preview did not render: '..renders)
room.IsMirrorWorld=function()return true end
local before=renders;callbacks[ModCallbacks.MC_POST_RENDER]();assert(renders>before,'mirror world render failed')
room.IsMirrorWorld=nil
Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_F9 end
callbacks[ModCallbacks.MC_POST_RENDER]();Input.IsButtonTriggered=function()return false end
before=renders;tick();callbacks[ModCallbacks.MC_POST_RENDER]();assert(renders==before,'preview drew after toggling off')
print('PASS F9 danger preview: default off, toggle, capture, render, mirror world')
-- F10 combat modes: IAD2 precedes the IAD1 packet it names; OFF and
-- paused updates carry none.
local function f10()
 Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_F10 end
 callbacks[ModCallbacks.MC_POST_RENDER]();Input.IsButtonTriggered=function()return false end
end
local function combatPair()
 local word,seq
 local last=logs[#logs];local iad1=last:match('^IAD1|(%d+)|')
 assert(iad1,'last line is not IAD1')
 local prev=logs[#logs-1]
 seq,word=prev:match('^IAD2|(%d+)|(%d+)$')
 if seq then assert(seq==iad1,'IAD2 names another packet') end
 return word and tonumber(word)
end
scene={npc2};npc2.Position=Vector(560,500);npc2.Velocity=Vector(0,0);p.Position=Vector(400,500)
tick();assert(combatPair()==nil,'combat word while OFF')
f10();tick()
local word=assert(combatPair(),'AIM word missing')
assert(word&3==1 and (word>>6)&7==2,'AIM must shoot right: '..word)
f10();tick();word=assert(combatPair(),'AUTO word missing')
assert(word&3==2 and (word>>6)&7==2 and word&512~=0 and ((word>>2)&15)<9,'AUTO word: '..word)
Input.IsButtonPressed=function(key)return key==Keyboard.KEY_LEFT_SHIFT end
tick();assert(combatPair()==nil,'combat word while paused by Shift')
Input.IsButtonPressed=function()return false end
f10();tick();assert(combatPair()==nil,'combat word after OFF')
print('PASS F10 combat modes: IAD2 contract, AIM and AUTO words, Shift and OFF release')

-- Roster changes: a co-op partner joining or leaving must keep the sensor on
-- our player. 0.12.4 game logs parked it on "F7: SELECT YOUR PLAYER" for 5277
-- packets (twice for over a minute) until F7 was pressed by hand.
local partner={}
for key,value in pairs(p)do partner[key]=value end
partner.InitSeed=777;partner.Position=Vector(300,300);partner.ControllerIndex=1
local function lastPacket()
 local parts={}
 for part in logs[#logs]:gmatch('[^|]+')do parts[#parts+1]=part end
 return parts
end
local function expectBound(message)
 local parts=lastPacket()
 assert(parts[1]=='IAD1' and parts[4]=='1','sensor inactive after '..message..': '..logs[#logs])
 return parts
end
local function press(key)
 Input.IsButtonTriggered=function(pressed)return pressed==key end
 callbacks[ModCallbacks.MC_POST_RENDER]()
 Input.IsButtonTriggered=function()return false end
end
p.ControllerIndex=0
roster,rosterCount=({p,partner}),2
tick()
assert(expectBound('a co-op join')[5]=='0','co-op join moved the slot')
rosterCount=1;tick();assert(expectBound('a co-op leave')[5]=='0','co-op leave moved the slot')
rosterCount=2;tick();assert(expectBound('a co-op rejoin')[5]=='0','co-op rejoin moved the slot')
press(Keyboard.KEY_F7);tick()
local picked=expectBound('F7')[5]
assert(picked=='1','F7 did not cycle to the second player: '..picked)
partner.Position=Vector(560,500);partner.Velocity=Vector(0,0)
local npc3=entity(EntityType.ENTITY_NPC,0)
function npc3:ToNPC()return self end;function npc3:IsBoss()return false end;function npc3:IsActiveEnemy()return true end
npc3.Position=Vector(600,500);npc3.Velocity=Vector(0,0);npc3.Size=10
scene={npc3};tick();assert(math.min(table.unpack(packet()))>0,'bound co-op player was not planned for')
scene={};tick()
roster={p,partner};rosterCount=1;tick();assert(expectBound('a lobby restart')[5]=='0','lobby restart did not fall back to single player')
local newcomer={}
for key,value in pairs(p)do newcomer[key]=value end
newcomer.InitSeed=4242;newcomer.Position=Vector(120,120)
roster,rosterCount=({newcomer}),1
tick();assert(expectBound('a new seeded player')[5]=='0','a recycled slot stopped the sensor')
print('PASS co-op roster changes keep the bound player and fall back safely')

-- Starting an Online lobby with two players must bind by itself: the partner's
-- controller has no local device behind it, ours does, so the applied movement
-- follows the polled value only for our slot. F7 is never pressed here.
roster,rosterCount=({p,partner}),2
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
assert(lastPacket()[5]=='-1','game start kept a stale slot')
for frame=currentAt+1,currentAt+60 do
 local moving=math.floor((frame-currentAt-1)/5)%2==0
 deviceDir[frame]=moving and {X=1,Y=0} or {X=0,Y=0}
 appliedDir[frame]=deviceDir[frame-1] or {X=0,Y=0}
end
scene={}
local boundAt
for frame=1,60 do
 tick()
 if lastPacket()[4]=='1' then boundAt=boundAt or frame end
end
local bound=expectBound('device evidence')
assert(bound[5]=='0','device evidence bound slot '..bound[5]..': '..logs[#logs])
-- Six matched changes at the slowest walk cadence: about one second.
assert(boundAt and boundAt<=45,'binding took '..tostring(boundAt)..' updates')
local announced=false
for _,line in ipairs(logs)do
 if line:find('IAD BIND: auto slot=0',1,true)then announced=true end
end
assert(announced,'auto binding was not logged')
-- A partner moving on the network alone (no local device) must not steal it.
deviceDir,appliedDir={},{}
for frame=currentAt+1,currentAt+40 do appliedDir[frame]={X=0,Y=1} end
for frame=1,40 do tick() end
assert(expectBound('remote-only movement')[5]=='0','remote movement rebound the sensor')
print('PASS co-op lobby binds by device evidence without F7')
