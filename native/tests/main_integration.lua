-- Exercise actual main.lua callbacks and sensor output with a minimal game API.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags','ButtonAction'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
local callbacks,logs,scene={}, {}, {}
panelDraws,panelFrom={},'render'
function RegisterMod()return {AddCallback=function(_,kind,fn)callbacks[kind]=fn end}end
-- combatCtx: the last context the core handed to Combat.update.
function include(name)
 local m=dofile('mod/isaac_dodge_assist/'..name..'.lua')
 if name=='combat' then local update=m.update;m.update=function(state,ctx)combatCtx=ctx;return update(state,ctx)end end
 -- panelDraws: which floor panel page was drawn, and from which callback.
 if name=='map_view' then local r=m.render;m.render=function(...)panelDraws[#panelDraws+1]='map@'..panelFrom;return r(...)end end
 if name=='item_view' then local r=m.renderPage;m.renderPage=function(...)panelDraws[#panelDraws+1]='page@'..panelFrom;return r(...)end end
 return m
end
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
local game={GetNumPlayers=function()return rosterCount end,GetRoom=function()return room end,IsPaused=function()return paused end,
 GetSeeds=function()return {GetStartSeedString=function()return "ABCD 1234" end}end}
function Game()return game end
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
-- 0.25.9: each enemy shot first seen near the player is recorded once.
local shotLines=0
for _,line in ipairs(logs)do if line:find('^IAD SHOT: ') then shotLines=shotLines+1
 assert(line:find('dist=60 ',1,true) and line:find('included=true',1,true),'shot record: '..line) end end
assert(shotLines==1,'shot recorded '..shotLines..' times')
local npc=entity(EntityType.ENTITY_NPC,0)
function npc:ToNPC()return self end;function npc:IsBoss()return false end
function npc:IsActiveEnemy()return true end
npc.Position=Vector(550,480);npc.Velocity=Vector(-10,0);npc.Size=6
scene={npc};tick();values=packet()
assert(values[1]>0,'main integration missed fast contact enemy')
scene={};tick();values=packet();for _,s in ipairs(values)do assert(s==0,'stale hazard survived empty room')end
-- 0.25.2: a familiar's red creep trail (dozens of effects in the 2026-11-05
-- It Lives room) is passed over before any effect lookup, and is no hazard.
local trail={}
for i=1,40 do
 local e=entity(EntityType.ENTITY_EFFECT,EffectVariant.PLAYER_CREEP_RED)
 e.InitSeed=9000+i;e.Position=Vector(470+i,480)
 function e:ToEffect()error('harmless effect looked up') end
 trail[i]=e
end
scene=trail;tick();values=packet();for _,s in ipairs(values)do assert(s==0,'player creep treated as a hazard')end
scene={};tick()
paused=true;tick();assert(logs[#logs]:find('|0|0|450|0,0,0,0,0,0,0,0,0|0',1,true),'pause did not release')
callbacks[ModCallbacks.MC_POST_RENDER]()
callbacks[ModCallbacks.MC_PRE_GAME_EXIT]()
summaries=perfLogs()
assert(#summaries==2 and summaries[2]:find('n=2 ',1,true) and summaries[2]:find('reason=game-exit',1,true),
 'game exit discarded a short encounter')
print('PASS full main integration: creep, projectile, fast enemy, player creep skipped, IAD1 numeric contract, diagnostics, empty room and pause')
-- 0.25.5 Deathmatch (room type 30): the opponent's tear flying at us is
-- dodged; our own tear and, outside Deathmatch, the partner's are not.
local opponent=entity(EntityType.ENTITY_PLAYER,0);opponent.InitSeed=77
callbacks[ModCallbacks.MC_POST_GAME_STARTED]();paused=false
scene={};for _=1,4 do tick() end
local function tear(owner)
 local t=entity(EntityType.ENTITY_TEAR,0);t.InitSeed=owner.InitSeed*10+1
 t.SpawnerType=EntityType.ENTITY_PLAYER;t.SpawnerEntity=owner;t.Parent=owner
 t.Position=Vector(540,480);t.Velocity=Vector(-12,0);t.Size=7;t.Height=-23;t.FallingSpeed=0;t.FallingAcceleration=0
 return t
end
RoomType={ROOM_DEATHMATCH=30,ROOM_SACRIFICE=13}
local roomType=30
function room:GetType()return roomType end
scene={tear(opponent)};tick();values=packet()
assert(values[1]>0,'Deathmatch: opponent tear not dodged')
scene={};tick();scene={tear(p)};tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'Deathmatch: own tear treated as a threat')end
local function creep(owner)
 local c=entity(EntityType.ENTITY_EFFECT,EffectVariant.PLAYER_CREEP_RED)
 c.InitSeed=owner.InitSeed*10+2;c.Position=Vector(510,480);c.Size=60
 c.SpawnerType=EntityType.ENTITY_PLAYER;c.SpawnerEntity=owner;c.Parent=owner
 c.SpriteScale=Vector(1,1);c.CollisionDamage=2.0;c.IsDead=function()return false end
 function c:ToEffect()return c end
 return c
end
scene={creep(opponent)};tick();values=packet()
assert(values[1]>0,'Deathmatch: opponent player creep not dodged')
scene={};tick();scene={creep(p)};tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'Deathmatch: own player creep treated as a threat')end
roomType=1;scene={};tick();scene={tear(opponent)};tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'co-op: partner tear treated as a threat')end
scene={creep(opponent)};tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'co-op: partner player creep treated as a threat')end
RoomType=nil;room.GetType=nil;scene={};tick()
print('PASS Deathmatch: opponent tears and creep dodged, own and co-op partner not')
-- 0.25.9 mirror world: the left key walks world-right there, so the packet
-- swaps left and right (scores and blocked bits).
paused=false;callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
scene={};for _=1,4 do tick() end
bullet.Position=Vector(540,470);scene={bullet};tick();values=packet()
room.IsMirrorWorld=function()return true end
tick();local flipped=packet()
room.IsMirrorWorld=nil;bullet.Position=Vector(540,480);scene={};tick()
assert(values[2]~=values[3],'mirror test needs a sided threat')
for i,j in ipairs({1,3,2,4,5,7,6,9,8})do assert(flipped[i]==values[j],'mirror world: scores not swapped at '..i)end
print('PASS mirror world: left and right swapped in the packet')
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
local gridLine=false
for _,line in ipairs(logs)do if line:find('IAD GRID: ',1,true) then gridLine=true end end
assert(gridLine,'room grid hazards were not logged')
print('PASS red poop contact, normal poop and flight exclusions')
-- Spikes: a plain spike counts whatever its State (four logged hits were on
-- spikes the sensor never listed); timed/switch spikes at State 1 and a
-- finished retraction do not.
local spikeKind,spikeState,spikeAnim=GridEntityType.GRID_SPIKES,1,'Idle'
-- Later checks still expect the red poop room set up above.
local poopEntity,poopCollision=room.GetGridEntity,room.GetGridCollision
function room:GetGridEntity(i)
 if i~=poopIndex then return nil end
 return {Position=room:GetGridPosition(i),State=spikeState,GetType=function()return spikeKind end,
  GetVariant=function()return 0 end,
  GetSprite=function()return {GetAnimation=function()return spikeAnim end,GetFrame=function()return 12 end,
   IsFinished=function()return spikeAnim:sub(1,8)=='Unsummon' end}end}
end
function room:GetGridCollision()return 0 end
for i=1,7 do tick()end
values=packet()
assert(values[3]>0 and values[1]<=0,'plain spike at State 1 not avoided')
spikeAnim='Unsummon';tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'retracted spike treated as damaging')end
spikeAnim,spikeKind='Idle',GridEntityType.GRID_SPIKES_ONOFF;tick();values=packet()
for _,s in ipairs(values)do assert(s==0,'disabled on/off spike treated as damaging')end
spikeState=0;tick();values=packet()
assert(values[3]>0,'active on/off spike not avoided')
-- Spiked rocks hurt on touch; flying players pass over them.
spikeKind,spikeState=GridEntityType.GRID_ROCK_SPIKED,1
function room:GetGridCollision(i)return i==poopIndex and GridCollisionClass.COLLISION_SOLID or 0 end
for i=1,7 do tick()end
values=packet()
assert(values[3]>0 and values[1]<=0,'spiked rock contact not avoided')
p.CanFly=true;tick();values=packet()
assert(values[3]>0 and values[1]<=0,'flying player must still avoid a spiked rock')
p.CanFly=false
function room:GetGridCollision()return 0 end
spikeKind,spikeState=GridEntityType.GRID_SPIKES_ONOFF,0
p.Position=Vector(530,500);callbacks[ModCallbacks.MC_ENTITY_TAKE_DMG](nil,p,1,128,{})
local gridHit
for i=#logs-3,#logs do if logs[i]:find('IAD DIAG GRID: ',1,true) then gridHit=logs[i] end end
assert(gridHit and gridHit:find(' s=0 Idle:12@540.0,500.0',1,true),'spike hit did not record the grid cell')
p.Position=Vector(470,500)
room.GetGridEntity,room.GetGridCollision=poopEntity,poopCollision
print('PASS spikes: plain spike at any State, on/off State 1 and retracted exclusions, spiked rock and flight, grid hit record')
-- 0.20: AUTO keeps off Sacrifice Room spikes even when flying (they hurt
-- flyers) and off item pedestals and shop items; the dodge field leaves both
-- alone, since stepping on them is the player's choice.
RoomType={ROOM_DEFAULT=1,ROOM_SACRIFICE=13}
PickupVariant={PICKUP_COLLECTIBLE=100}
local roomType=RoomType.ROOM_SACRIFICE
function room:GetType()return roomType end
function room:GetGridEntity(i)
 if i~=poopIndex then return nil end
 return {Position=room:GetGridPosition(i),State=0,GetType=function()return GridEntityType.GRID_SPIKES end,
  GetVariant=function()return 0 end,
  GetSprite=function()return {GetAnimation=function()return 'Idle' end,GetFrame=function()return 0 end,IsFinished=function()return false end}end}
end
function room:GetGridCollision()return 0 end
scene={};p.CanFly=true
for i=1,7 do tick()end
assert(combatCtx.hazardCells[poopIndex],'flying AUTO may walk on a sacrifice spike')
for _,v in ipairs(packet())do assert(v==0,'sacrifice spike entered the dodge field of a flyer')end
roomType=RoomType.ROOM_DEFAULT;tick()
assert(not combatCtx.hazardCells[poopIndex],'flying AUTO avoids an ordinary spike')
p.CanFly=false
local function pickup(variant,subtype,x,price)
 local e=entity(EntityType.ENTITY_PICKUP,variant);e.SubType,e.Position,e.Price=subtype,Vector(x,300),price
 function e:ToPickup()return self end
 return e
end
scene={pickup(100,12,300,0),pickup(100,0,380,0),pickup(10,1,460,5),pickup(10,1,540,0)}
tick()
local cells=combatCtx.hazardCells
local function at(x)return cells[room:GetGridIndex(Vector(x,300))]==true end
assert(at(300) and not at(380) and at(460) and not at(540),'pedestal/shop cells: '..tostring(at(300))..tostring(at(380))..tostring(at(460))..tostring(at(540)))
RoomType,PickupVariant,room.GetType=nil,nil,nil
room.GetGridEntity,room.GetGridCollision=poopEntity,poopCollision
print('PASS AUTO hazard cells: sacrifice spikes for flyers, item pedestals and shop items')
-- F9 danger preview: off by default, toggles, captures and renders lines.
-- The first sprite made from here on is the HUD's (its status dot draws
-- every frame); only the preview's renders are counted.
local renders,loaded,made=0,nil,0
function Sprite()
 made=made+1;local mine=made
 return {Load=function(_,path)loaded=path end,Play=function()end,
  Render=function(self,pos)assert(self.Scale.X>0 and self.Rotation==self.Rotation);if mine>1 then renders=renders+1 end end}
end
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
f10();tick();local word=assert(combatPair(),'AUTO word missing')
assert(word&3==2 and (word>>6)&7==2 and word&512~=0 and ((word>>2)&15)<9,'AUTO word: '..word)
-- Left Shift toggles: one press pauses (surviving a room change), holding
-- is not needed, the next press resumes.
local function shift()
 Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_GRAVE_ACCENT end
 callbacks[ModCallbacks.MC_POST_RENDER]();Input.IsButtonTriggered=function()return false end
end
shift();tick();assert(combatPair()==nil,'combat word while paused by Shift')
assert(logs[#logs]:find('|0|',1,true),'Shift pause still active')
callbacks[ModCallbacks.MC_POST_NEW_ROOM]();for i=1,5 do tick()end
assert(combatPair()==nil and logs[#logs]:find('|0|',1,true),'Shift pause lost on room change')
local paused=false;for _,line in ipairs(logs)do if line=='IAD STATE: PAUSED' then paused=true end end
assert(paused,'pause state not reported')
shift();tick();assert(combatPair(),'second Shift press did not resume')
f10();tick();assert(combatPair()==nil,'combat word after OFF')
print('PASS F10 combat modes: IAD2 contract, AUTO word, Shift toggle (room-persistent) and OFF release')

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

-- Run markers let the host archive one file per run: begin (new or
-- continued), pause on a saving exit, end on death, victory or a quit.
local function runLines(action)
 local from=#logs+1;action()
 local found={}
 for i=from,#logs do if logs[i]:find('^IAD RUN ') then found[#found+1]=logs[i] end end
 return table.concat(found,'\n')
end
roster,rosterCount={p},1
local G=ModCallbacks
assert(runLines(function()callbacks[G.MC_POST_GAME_STARTED](nil,false)end)==
 'IAD RUN begin continued=false player=-1 seed=ABCD1234','new run marker')
assert(runLines(function()callbacks[G.MC_PRE_GAME_EXIT](nil,true)end)=='IAD RUN pause','saving exit is a pause')
assert(runLines(function()callbacks[G.MC_POST_GAME_STARTED](nil,true)end)==
 'IAD RUN begin continued=true player=-1 seed=ABCD1234','continued run marker')
assert(runLines(function()callbacks[G.MC_POST_GAME_END](nil,true)end)=='IAD RUN end reason=death','death ends the run')
assert(runLines(function()callbacks[G.MC_PRE_GAME_EXIT](nil,false)end)=='','exit after death ends it twice')
callbacks[G.MC_POST_GAME_STARTED](nil,false)
assert(runLines(function()callbacks[G.MC_POST_GAME_END](nil,false)end)=='IAD RUN end reason=win','victory ends the run')
callbacks[G.MC_POST_GAME_STARTED](nil,false)
assert(runLines(function()callbacks[G.MC_PRE_GAME_EXIT](nil,false)end)=='IAD RUN end reason=quit','unsaved exit is a quit')
print('PASS run markers: begin/continue, pause on saving exit, end on death, win and quit')
for _,line in ipairs(logs)do assert(not line:find('IAD LOADER: core error',1,true),line)end

-- 0.25.5 floor panel: shown while Tab (the map button) is held, the stats
-- page toggled by F5; with the shader loaded both are drawn from its
-- callback, above the HUD and the game's own map.
local G2=ModCallbacks
local tab=false
Input.IsButtonPressed=function(key)return tab and key==Keyboard.KEY_TAB end
Isaac.GetFrameCount=function()return currentAt end
local function render(from)
 panelDraws={};panelFrom=from or 'render';callbacks[G2.MC_POST_RENDER]();return table.concat(panelDraws,',')
end
assert(render()=='','panel drawn with Tab up')
tab=true;assert(render()=='map@render','Tab held: no floor panel')
tab=false;Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_F5 end
assert(render()=='page@render','F5 did not open the stats page')
Input.IsButtonTriggered=function()return false end
assert(render()=='page@render','stats page closed by itself')
-- The shader callback has run: the panel waits for it.
panelFrom='shader';callbacks[G2.MC_GET_SHADER_PARAMS](nil,'IAD-RenderAboveHUD')
tab=true;assert(render()=='','panel drawn under the HUD while the shader runs')
panelDraws={};panelFrom='shader';callbacks[G2.MC_GET_SHADER_PARAMS](nil,'IAD-RenderAboveHUD')
assert(table.concat(panelDraws,',')=='map@shader','panel not drawn from the shader callback')
panelDraws={};callbacks[G2.MC_GET_SHADER_PARAMS](nil,'Another-Shader');assert(#panelDraws==0,'drawn for another shader')
tab=false;Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_F5 end;render()
Input.IsButtonTriggered=function()return false end;Input.IsButtonPressed=function()return false end
print('PASS floor panel: Tab held, F5 stats page, drawn from the shader callback when it runs')

-- 0.26+: Repentance enemies (Grudge/Pon/Mother), DIRT_PILE warning, curving
-- projectiles, Closed 5.52 Spiked Chest + Sacrifice Spike manual soft-brake
-- (release stops, sustained hold bypasses), Jacob/Esau twin support, and
-- Curse of the Unknown HP breakdown HUD.
paused=false;scene={};p.CanFly=false;p.Position=Vector(470,480);p.Velocity=Vector(0,0);p.Size=13
deviceDir,appliedDir={},{}
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for i=1,4 do tick() end
local grudge=entity(877,0);function grudge:ToNPC()return self end;function grudge:IsActiveEnemy()return true end
grudge.Position=Vector(580,480);grudge.Velocity=Vector(0,0);grudge.Size=13
scene={grudge};tick();values=packet()
assert(values[1]>0 and math.min(values[4],values[5])<values[1],'Grudge cardinal ambusher not dodged')
local pon=entity(840,0);function pon:ToNPC()return self end;function pon:IsActiveEnemy()return true end
pon.Position=Vector(510,480);pon.Velocity=Vector(-12,0);pon.Size=14
function pon:GetSprite()return {GetAnimation=function()return 'Jump' end,GetFrame=function()return 2 end}end
scene={pon};tick();values=packet()
assert(values[1]>0,'Pon hop not dodged')
local mother=entity(912,0);function mother:ToNPC()return self end;function mother:IsBoss()return true end;function mother:IsActiveEnemy()return true end
mother.Position=Vector(470,380);mother.Velocity=Vector(0,10);mother.Size=28
function mother:GetSprite()return {GetAnimation=function()return 'DashDown' end,GetFrame=function()return 4 end}end
scene={mother};tick();values=packet()
assert(values[1]>0,'Mother downward dash warning missed')
local dirt=entity(EntityType.ENTITY_EFFECT,EffectVariant.DIRT_PILE);function dirt:ToEffect()return self end
dirt.Position=Vector(495,480)
scene={dirt};tick();values=packet()
assert(values[1]>0,'DIRT_PILE pre-jet warning not avoided')
local curved=entity(EntityType.ENTITY_PROJECTILE,0);function curved:ToProjectile()return self end
curved.Height=-20;curved.FallingSpeed=0;curved.FallingAccel=-0.1
curved.Position=Vector(520,504);curved.Velocity=Vector(-12,0);curved.Size=4
function curved:HasProjectileFlags(flag)return flag==ProjectileFlags.CURVE_LEFT end
scene={curved};tick();values=packet()
assert(values[1]>0,'curving projectile extra safety radius missing')
function curved:HasProjectileFlags()return false end
tick();values=packet()
assert(values[1]<=0,'straight projectile with offset triggered curve margin at rest')
print('PASS Repentance enemies (Grudge/Pon/Mother), DIRT_PILE warning and curving tear margin')

-- Manual mode skips pitfall soft-brake (bit 10 = 1024 never emitted in IAD2),
-- while Sacrifice spikes and closed 5.52 Spiked Chests remain in hazardCells for AUTO.
RoomType={ROOM_DEFAULT=1,ROOM_SACRIFICE=13}
PickupVariant={PICKUP_COLLECTIBLE=100,PICKUP_SPIKEDCHEST=52,PICKUP_MIMICCHEST=54}
local rt=RoomType.ROOM_SACRIFICE
function room:GetType()return rt end
function room:GetGridEntity(i)
 if i~=poopIndex then return nil end
 return {Position=room:GetGridPosition(i),State=0,GetType=function()return GridEntityType.GRID_SPIKES end,
  GetVariant=function()return 0 end,
  GetSprite=function()return {GetAnimation=function()return 'Idle' end,GetFrame=function()return 0 end,IsFinished=function()return false end}end}
end
function room:GetGridCollision()return 0 end
scene={};p.Position=Vector(500,500)
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for i=1,7 do tick() end
assert(combatCtx.hazardCells[poopIndex]==true,'Sacrifice spike missing from hazardCells')
deviceDir={[currentAt+1]={X=1,Y=0},[currentAt+2]={X=1,Y=0}}
tick();local bw=combatPair()
assert(not bw or (bw&1024)==0,'Sacrifice spike must not trigger manual soft-brake: '..tostring(bw))
deviceDir={}
for i=1,10 do tick() end
for i=1,16 do deviceDir[currentAt+i]={X=1,Y=0} end
for i=1,16 do
 tick()
 local w=combatPair()
 assert(not w or (w&1024)==0,'manual hold must never emit bit 1024: '..tostring(w))
end
rt=RoomType.ROOM_DEFAULT;deviceDir={}
local chest=entity(EntityType.ENTITY_PICKUP,52);chest.SubType=1;chest.Position=Vector(540,500)
function chest:ToPickup()return self end
scene={chest};for i=1,3 do tick() end
assert(combatCtx.hazardCells[poopIndex]==true,'closed 5.52 Spiked Chest missing from hazardCells')
deviceDir={[currentAt+1]={X=1,Y=0}}
tick();bw=combatPair()
assert(not bw or (bw&1024)==0,'closed 5.52 Spiked Chest must not trigger manual soft-brake: '..tostring(bw))
deviceDir={};scene={}
RoomType,PickupVariant,room.GetType=nil,nil,nil
room.GetGridEntity,room.GetGridCollision=poopEntity,poopCollision
print('PASS manual mode skips pitfall soft-brake (Sacrifice spike + closed 5.52 chest)')

-- Jacob & Esau twin support: unblocked and steady walking binds Jacob cleanly.
local origGetPlayerType=p.GetPlayerType
p.GetPlayerType=function()return PlayerType.PLAYER_JACOB end
partner.GetPlayerType=function()return PlayerType.PLAYER_ESAU end
roster,rosterCount={p,partner},2
local beforeJacobLog=#logs
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for i=1,35 do
 local f=currentAt+i
 deviceDir[f]={X=1,Y=0};appliedDir[f]={X=1,Y=0}
end
for i=1,35 do tick() end
for i=beforeJacobLog+1,#logs do
 assert(not logs[i]:find('UNSUPPORTED CHARACTER',1,true),'Jacob marked unsupported: '..logs[i])
end
assert(expectBound('Jacob & Esau steady walk')[5]=='0','Jacob did not bind over Esau on steady movement')
p.GetPlayerType=origGetPlayerType;partner.GetPlayerType=nil
roster,rosterCount={p},1;deviceDir,appliedDir={}
print('PASS Jacob & Esau twin support and steady directional auto-binding')

-- Curse of the Unknown: reads Red/Rotten/Bone/Soul/Black/Eternal/Broken HP onto HUD.
local savedGetLevel=game.GetLevel
local savedRenderText=Isaac.RenderText
LevelCurse={CURSE_OF_THE_UNKNOWN=8}
game.GetLevel=function()return {GetCurses=function()return 8 end}end
function p:GetHearts()return 5 end
function p:GetMaxHearts()return 6 end
function p:GetRottenHearts()return 1 end
function p:GetBoneHearts()return 1 end
function p:GetSoulHearts()return 5 end
function p:GetBlackHearts()return 1 end
function p:GetEternalHearts()return 1 end
function p:GetBrokenHearts()return 1 end
local hudLines={}
Isaac.RenderText=function(txt)hudLines[#hudLines+1]=txt end
callbacks[ModCallbacks.MC_POST_RENDER]()
Isaac.RenderText=savedRenderText;game.GetLevel=savedGetLevel;LevelCurse=nil
p.GetHearts,p.GetMaxHearts,p.GetRottenHearts,p.GetBoneHearts,p.GetSoulHearts,p.GetBlackHearts,p.GetEternalHearts,p.GetBrokenHearts=nil,nil,nil,nil,nil,nil,nil,nil
local joined=table.concat(hudLines,' | ')
assert(joined:find('Red 1.5/3',1,true),'Curse HP red missing: '..joined)
assert(joined:find('Rot 1',1,true) and joined:find('Bone 1',1,true) and joined:find('Soul 1.5',1,true)
 and joined:find('Black 1',1,true) and joined:find('Et +1',1,true) and joined:find('Brk 1',1,true),
 'Curse HP breakdown wrong: '..joined)
print('PASS Curse of the Unknown read-only HP breakdown HUD')

-- Helper to parse latest IAD1 packet.
local function parseIad1()
 local line=logs[#logs]
 local scoresStr,blk=line:match('^IAD1|%d+|%d+|%d+|%d+|%d+|([^|]+)|(%d+)$')
 assert(scoresStr,'unexpected IAD1 line: '..tostring(line))
 local sc={}
 for v in scoresStr:gmatch('[^,]+') do sc[#sc+1]=tonumber(v) end
 return sc,tonumber(blk)
end

-- 1) Online co-op ControllerIndex >= 2 (virtual netplay slot): physical device 0 + WASD fallback
-- must keep local player bound (lag > 0) and prevent remote slot 1 steal.
do
 callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
 scene={};tick();tick()
 local savedGetAction=Input.GetActionValue
 local savedIsPressed=Input.IsButtonPressed
 p.ControllerIndex=4;p.Position=Vector(320,280);p.Velocity=Vector(0,0)
 partner.ControllerIndex=5;partner.Position=Vector(200,280);partner.Velocity=Vector(0,0)
 roster,rosterCount={p,partner},2
 local lag4,remotePartner={{X=1,Y=0},{X=0,Y=1},{X=-1,Y=0},{X=0,Y=-1}},{}
 -- Poll via Keyboard WASD only on controller 0 (GetActionValue returns 0 even on 0 to verify WASD fallback),
 -- while virtual controller 4/5 have synced remote partner movement with 0 lag.
 Input.GetActionValue=function(act,ctrl)
  if ctrl>=2 then
   local v=dirAt(remotePartner,currentAt)
   if act==ButtonAction.ACTION_LEFT then return math.max(0,-v.X) end
   if act==ButtonAction.ACTION_RIGHT then return math.max(0,v.X) end
   if act==ButtonAction.ACTION_UP then return math.max(0,-v.Y) end
   if act==ButtonAction.ACTION_DOWN then return math.max(0,v.Y) end
  end
  return 0
 end
 Input.IsButtonPressed=function(key,ctrl)
  if ctrl~=0 then return false end
  local v=dirAt(deviceDir,currentAt)
  if v.X>0 and key==Keyboard.KEY_D then return true end
  if v.X<0 and key==Keyboard.KEY_A then return true end
  if v.Y<0 and key==Keyboard.KEY_W then return true end
  if v.Y>0 and key==Keyboard.KEY_S then return true end
  return false
 end
 deviceDir,appliedDir={},{}
 local baseF=currentAt
 for i=1,80 do
  local seq=lag4[((math.floor((i-1)/6))%4)+1]
  local pseq=lag4[((math.floor((i-1)/5)+1)%4)+1]
  deviceDir[baseF+i]=seq
  appliedDir[baseF+i+3]=seq
  remotePartner[baseF+i]=pseq
 end
 local savedPartnerPos=partner.Position
 local baseTick=currentAt
 for i=1,80 do
  local rv=dirAt(remotePartner,baseTick+i)
  partner.Velocity=Vector(rv.X*3,rv.Y*3)
  tick()
 end
 local sawBoundZero=false
 for i=#logs,math.max(1,#logs-15),-1 do
  if logs[i]:find('IAD PLAYER BOUND: slot=0 ',1,true) then sawBoundZero=true end
 end
 local boundLine
 for _,l in ipairs(logs) do if l:find('IAD PLAYER BOUND:',1,true) then boundLine=l end end
 -- Check via expectBound-equivalent: last BIND/UNBIND event before end.
 assert(expectBound('online virtual ControllerIndex >= 2')[5]=='0','virtual ControllerIndex>=2 lost binding to slot 1: '..tostring(boundLine))
 Input.GetActionValue=savedGetAction;Input.IsButtonPressed=savedIsPressed
 p.ControllerIndex=0;partner.ControllerIndex=1;partner.Position=savedPartnerPos;partner.Velocity=Vector(0,0)
 roster,rosterCount={p},1;deviceDir,appliedDir={}
 callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
 print('PASS online virtual ControllerIndex>=2 reads physical slot 0 + WASD without remote steal')
end

-- 2) 1ASNDQW3 missed hazards + Beast sky/magma + CanFly ROCK vs GRID_LOCK + AUTO-only hazardCells.
do
 local savedRoom=room
 local savedEnt={ENTITY_BOOMFLY=EntityType.ENTITY_BOOMFLY,ENTITY_PROJECTILE=EntityType.ENTITY_PROJECTILE,
  ENTITY_DOGMA=EntityType.ENTITY_DOGMA,ENTITY_THE_BEAST=EntityType.ENTITY_THE_BEAST,ENTITY_FIREPLACE=EntityType.ENTITY_FIREPLACE}
 local savedGrid={GRID_LOCK=GridEntityType.GRID_LOCK,GRID_SPIKES=GridEntityType.GRID_SPIKES}
 local savedPos,savedFly=p.Position,p.CanFly
 EntityType.ENTITY_BOOMFLY=EntityType.ENTITY_BOOMFLY or 25
 EntityType.ENTITY_PROJECTILE=EntityType.ENTITY_PROJECTILE or 9
 EntityType.ENTITY_DOGMA=EntityType.ENTITY_DOGMA or 950
 EntityType.ENTITY_THE_BEAST=EntityType.ENTITY_THE_BEAST or 951
 GridEntityType.GRID_LOCK=GridEntityType.GRID_LOCK or 11
 scene={};for _=1,5 do tick() end

 -- 2a) 9.0.0 high-arc ENTCOLL_NONE lobbed tear (1ASNDQW3 Hit #26 / frame 206): must score non-zero threat before landing.
 p.Position=Vector(320,280);p.Velocity=Vector(0,0);p.CanFly=false
 local lob=entity(EntityType.ENTITY_PROJECTILE,0)
 lob.Position=Vector(320,280);lob.Velocity=Vector(0,0);lob.Size=6
 lob.EntityCollisionClass=EntityCollisionClass.ENTCOLL_NONE
 lob.Height=-70.0;lob.FallingSpeed=5.3;lob.FallingAccel=1.320;lob.ProjectileFlags=0
 function lob:ToProjectile()return self end
 function lob:HasProjectileFlags()return false end
 scene={lob};tick()
 local sc=parseIad1()
 assert(sc[1]>0,'9.0.0 ENTCOLL_NONE high-arc lob must produce idle threat score: '..tostring(sc[1]))
 lob.Height=-59.95;lob.FallingSpeed=14.62;lob.FallingAccel=1.60
 tick()
 sc=parseIad1()
 assert(sc[1]>0,'9.0.0 ENTCOLL_NONE falling tear at height=-59.95 must score > 0: '..tostring(sc[1]))

 -- 2b) 950.2.0 Dogma RingLoop:4 (Hit #31): IsActiveEnemy=false, IsBoss=true, ENTCOLL_PLAYERONLY(4), CollisionDamage=1.
 local ring=entity(EntityType.ENTITY_DOGMA,2)
 ring.Position=Vector(320,280);ring.Velocity=Vector(0,0);ring.Size=40
 ring.EntityCollisionClass=4;ring.CollisionDamage=1
 function ring:ToNPC()return self end
 function ring:IsActiveEnemy()return false end
 function ring:IsBoss()return true end
 function ring:GetSprite()return {GetAnimation=function()return 'RingLoop' end,GetFrame=function()return 4 end}end
 scene={ring};tick()
 sc=parseIad1()
 assert(sc[1]>0,'950.2.0 RingLoop boss contact threat must score > 0: '..tostring(sc[1]))

 -- 2c) 25.6.0 Tainted Boom Fly dead=true Explode:24 at 100.88px (Hit #25).
 local tbf=entity(EntityType.ENTITY_BOOMFLY,6)
 tbf.Position=Vector(220,280);tbf.Velocity=Vector(0,0);tbf.Size=20
 function tbf:ToNPC()return self end
 function tbf:IsDead()return true end
 function tbf:GetSprite()return {GetAnimation=function()return 'Explode' end,GetFrame=function()return 24 end}end
 p.Position=Vector(320.88,280)
 scene={tbf};tick()
 sc=parseIad1()
 assert(sc[1]>0,'25.6.0 dead Explode:24 at 100.88px must threaten idle: '..tostring(sc[1]))

 -- 2d) 951 Beast Room 16.666: sky bounds + magma floor + never blocked=510.
 local beast=entity(EntityType.ENTITY_THE_BEAST,0)
 beast.Position=Vector(520,320);beast.Size=166;beast.CollisionDamage=0;beast.EntityCollisionClass=0
 function beast:ToNPC()return self end
 function beast:IsBoss()return true end
 local beastRoom={
  GetType=function()return 5 end,
  GetTopLeftPos=function()return Vector(60,140)end,
  GetBottomRightPos=function()return Vector(580,420)end,
  GetCenterPos=function()return Vector(320,280)end,
  GetClampedPosition=function(_,v)return v end,
  GetGridWidth=function()return 15 end,
  GetGridSize=function()return 135 end,
  GetGridPosition=function(_,i)return Vector((i%15)*40+40,math.floor(i/15)*40+120)end,
  GetGridIndex=function()return -1 end,
  GetGridCollision=function()return GridCollisionClass.COLLISION_NONE end,
  GetGridEntity=function()return nil end,
  IsPositionInRoom=function()return false end,
 }
 room=beastRoom;p.CanFly=true;p.Position=Vector(566.4,464.9);p.Velocity=Vector(0,0)
 scene={beast};tick()
 local bSc,bBlk=parseIad1()
 assert(bBlk~=510,'Beast sky must not lock blocked=510: blk='..tostring(bBlk))
 assert(bSc[1]>0,'Beast magma floor at Y=464.9 must warn idle position: '..tostring(bSc[1]))
 assert(bSc[4]<bSc[1],'Beast magma escape UP must score better than idle')

 -- 2e) AUTO mode preserves hazardCells avoidance (Sacrifice spikes) after manual brake removal.
 room=savedRoom;p.Position=Vector(320,280);p.Velocity=Vector(0,0);p.CanFly=false
 local gridSize=room:GetGridSize()
 local oldGC,oldGE,oldGT=room.GetGridCollision,room.GetGridEntity,room.GetType
 local spkIdx=room:GetGridIndex(Vector(360,280))
 GridEntityType.GRID_SPIKES=GridEntityType.GRID_SPIKES or 8
 room.GetType=function()return RoomType and RoomType.ROOM_SACRIFICE or 13 end
 room.GetGridCollision=function(self,i)if i==spkIdx then return GridCollisionClass.COLLISION_NONE end;return oldGC(self,i)end
 room.GetGridEntity=function(self,i)
  if i==spkIdx then return {GetType=function()return GridEntityType.GRID_SPIKES end,Position=Vector(360,280),State=0,
   GetSprite=function()return {GetAnimation=function()return 'Idle' end}end} end
  return oldGE and oldGE(self,i) or nil
 end
 local blocker=entity(EntityType.ENTITY_GAPER or 10,0);blocker.Position=Vector(560,280);function blocker:ToNPC()return self end;function blocker:IsActiveEnemy()return true end
 f10() -- switch to AUTO
 scene={blocker};tick()
 local aw=combatPair()
 assert(aw and (aw&3)==2 and ((aw>>2)&15)~=2,'AUTO combat should not walk straight RIGHT into Sacrifice spike: word='..tostring(aw))
 f10() -- back to OFF

 room.GetType,room.GetGridCollision,room.GetGridEntity=oldGT,oldGC,oldGE
 room=savedRoom;scene={};p.Position,p.CanFly=savedPos,savedFly
 EntityType.ENTITY_BOOMFLY,EntityType.ENTITY_PROJECTILE,EntityType.ENTITY_DOGMA,EntityType.ENTITY_THE_BEAST,EntityType.ENTITY_FIREPLACE=
  savedEnt.ENTITY_BOOMFLY,savedEnt.ENTITY_PROJECTILE,savedEnt.ENTITY_DOGMA,savedEnt.ENTITY_THE_BEAST,savedEnt.ENTITY_FIREPLACE
 GridEntityType.GRID_LOCK,GridEntityType.GRID_SPIKES=savedGrid.GRID_LOCK,savedGrid.GRID_SPIKES
 callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
 print('PASS 1ASNDQW3 hazards (9.0.0 lob, 950.2.0 RingLoop, 25.6.0 Explode, Beast sky+magma) & AUTO hazardCells')
end
