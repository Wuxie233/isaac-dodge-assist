-- Replays of 2026-10-30 hits (sensor 0.12.6) through the real main.lua:
-- positions, velocities and animation frames are taken from IAD DIAG
-- HISTORY/TRACE a few updates before each hit. 0.12.6 scored every direction
-- safe; now the hit must be predicted while an escape still exists.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags','ButtonAction','NpcState'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
EntityCollisionClass.ENTCOLL_NONE=0
local callbacks,logs,scene={}, {}, {}
function RegisterMod()return {AddCallback=function(_,kind,fn)callbacks[kind]=fn end}end
function include(name)return dofile('mod/isaac_dodge_assist/'..name..'.lua')end
-- A 1x1 room: walls at x 60..580, y 140..420, centre (320,280).
local room={}
function room:GetGridWidth()return 15 end
function room:GetGridSize()return 135 end
function room:GetGridEntity()return nil end
function room:GetGridCollision()return 0 end
-- Vanilla 1x1 layout: 15x9 cells, cell 0 centred at (40,120), walls on the rim.
function room:GetGridIndex(p)return math.floor((p.X-20)/40)+math.floor((p.Y-100)/40)*15 end
function room:GetGridPosition(i)return Vector((i%15)*40+40,math.floor(i/15)*40+120)end
function room:IsPositionInRoom(p,margin)margin=margin or 0
 return p.X>=60+margin and p.X<=580-margin and p.Y>=140+margin and p.Y<=420-margin end
function room:GetCenterPos()return Vector(320,280)end
function room:GetTopLeftPos()return Vector(60,140)end
function room:GetBottomRightPos()return Vector(580,420)end
local p={Type=EntityType.ENTITY_PLAYER,Variant=0,SubType=0,Position=Vector(320,280),Velocity=Vector(0,0),
 Size=10,MoveSpeed=1,InitSeed=9,CanFly=false,Damage=3.5,TearRange=260,MaxFireDelay=10}
function p:GetPlayerType()return -1 end
function p:GetSubPlayer()return nil end
function p:IsSubPlayer()return false end
function p:IsDead()return false end
function p:IsCoopGhost()return false end
function p:AreControlsEnabled()return true end
function p:ToPlayer()return self end
function p.GetMovementInput()return Vector(0,0)end
Input={IsButtonPressed=function()return false end,IsButtonTriggered=function()return false end,
 GetActionValue=function()return 0 end}
function Game()return {GetNumPlayers=function()return 1 end,GetRoom=function()return room end,IsPaused=function()return false end}end
Isaac={GetTime=function()return os.clock()*1000 end,GetPlayer=function()return p end,
 GetRoomEntities=function()return scene end,DebugString=function(s)logs[#logs+1]=s end,
 RenderText=function()end,WorldToScreen=function(v)return v end}
dofile('mod/isaac_dodge_assist/main.lua')
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
local function entity(typ,variant,animation,frame)
 local e={Type=typ,Variant=variant,SubType=0,InitSeed=typ*100+variant,SpawnerType=-1,
 Position=Vector(0,0),Velocity=Vector(0,0),Size=13,Scale=1,SpriteScale=Vector(1,1),SizeMulti=Vector(1,1),
 CollisionDamage=1,EntityCollisionClass=EntityCollisionClass.ENTCOLL_ALL,SpriteOffset=Vector(0,0),
 HitPoints=10,State=0,StateFrame=0,I1=0}
 for _,k in ipairs({'ToNPC','ToProjectile','ToBomb','ToLaser','ToEffect'})do e[k]=function()return nil end end
 function e:IsDead()return false end;function e:HasEntityFlags()return false end
 function e:IsActiveEnemy()return true end;function e:IsBoss()return false end
 function e:GetSprite()return {GetAnimation=function()return e.animation end,GetFrame=function()return e.frame end,
  WasEventTriggered=function()return false end,IsFinished=function()return false end}end
 e.animation,e.frame=animation or 'Idle',frame or 0
 return e
end
local SCALE,HARD=1048576,1000000*1048576
local function packet()
 local parts={};for part in logs[#logs]:gmatch('[^|]+')do parts[#parts+1]=part end
 assert(parts[1]=='IAD1','no IAD1 packet')
 local s={};for n in parts[7]:gmatch('[^,]+')do s[#s+1]=assert(tonumber(n))end
 return s,tonumber(parts[8])
end
-- Enter a fresh room, then replay one update with the given scene.
local function replay(position,velocity,entities)
 callbacks[ModCallbacks.MC_POST_NEW_ROOM]()
 scene={};p.Position,p.Velocity=Vector(320,280),Vector(0,0)
 for _=1,5 do callbacks[ModCallbacks.MC_POST_UPDATE]()end
 p.Position,p.Velocity=position,velocity;scene=entities
 callbacks[ModCallbacks.MC_POST_UPDATE]()
 return packet()
end
local function check(name,scores,blocked,stay)
 assert(scores[stay]>=HARD,name..': staying put was not predicted as a hit ('..scores[stay]..')')
 local best=math.huge
 for i,s in ipairs(scores)do if blocked&(1<<(i-1))==0 then best=math.min(best,s)end end
 assert(best<HARD,name..': no escape left (best '..best..')')
end
-- Mom's arm out of a door. Every hit landed on ArmOpen frame 7; the sensor
-- sees frame 0 seven updates earlier. Positions/velocities are the recorded
-- TRACE seven updates before each hit (MoveSpeed 1.5 in that run), and the
-- checked candidate is the key actually held then (1 idle,2 L,3 R,4 U,5 D,
-- 6 LU,7 RU,8 LD,9 RD).
local function mom(x,y,frame)
 local m=entity(EntityType.ENTITY_MOM,0,'ArmOpen',frame)
 m.Position,m.Size,m.EntityCollisionClass,m.CollisionDamage=Vector(x,y),47.25,EntityCollisionClass.ENTCOLL_NONE,0
 function m:ToNPC()return self end;function m:IsBoss()return true end
 return m
end
p.MoveSpeed=1.5
for _,case in ipairs({
 {'bottom door',320,425,Vector(270.7,340.2),Vector(3.9,3.2),9},
 -- Running at the door at ~5/update and already at the edge of the reach:
 -- no stop is possible in seven updates, so only the prediction is required.
 {'left door',55,280,Vector(143.3,288.1),Vector(-5.4,0),2,true},
 {'top door',320,135,Vector(304.8,224.4),Vector(0.6,-5.1),4,true},
 {'bottom door again',320,425,Vector(397.8,342.7),Vector(-2.9,1.9),8}}) do
 local s,b=replay(case[4],case[5],{mom(case[2],case[3],0)})
 if case[7] then assert(s[case[6]]>=HARD,'mom '..case[1]..': hit not predicted')
 else check('mom '..case[1],s,b,case[6]) end
end
p.MoveSpeed=1
-- A finished arm (frame 30) and other door animations are not hazards.
s=replay(Vector(312.4,355.8),Vector(0,0),{mom(320,425,30)})
for _,v in ipairs(s)do assert(v==0,'retracted arm still scored')end
s=replay(Vector(312.4,355.8),Vector(0,0),{mom(320,425,2)});assert(s[1]>=HARD,'arm in reach not a hit')
local eye=mom(320,425,2);eye.animation='Eye'
s=replay(Vector(312.4,355.8),Vector(0,0),{eye})
for _,v in ipairs(s)do assert(v==0,'Mom eye animation scored as an arm')end
print('PASS Mom door arm: four replayed hits predicted, two with an escape; retracted arm and eye ignored')

-- Rage Creep on the right wall (575,262.5) hit on Attack frame 16 with the
-- player at (410.7,277.0). On Attack frame 4 the player was at
-- (345.4,301.8) and turned RU (7) into the beam's row.
local creep=entity(EntityType.ENTITY_RAGE_CREEP,0,'Attack',4)
creep.Position=Vector(575,262.5);function creep:ToNPC()return self end
s,b=replay(Vector(345.4,301.8),Vector(2.0,0.1),{creep})
check('rage creep',s,b,7)
creep.animation='Walk';s=replay(Vector(345.4,262.5),Vector(0,0),{creep})
assert(s[1]<HARD,'walking rage creep predicted a beam')
print('PASS Rage Creep: wall beam predicted before it appears; walking creep ignored')

-- Troll bomb rolling left at 4.2/update exploded on Pulse frame 58 at
-- (103.2,320) with the player at (102.1,370.5), cornered at the bottom-left
-- wall. On frame 40 (18 updates earlier, beyond the 14-update window) the
-- player was at (89.5,356.7); stopping there (idle) is inside the blast.
local bomb=entity(EntityType.ENTITY_BOMB,BombVariant.BOMB_TROLL,'Pulse',40)
bomb.Position,bomb.Velocity,bomb.Size=Vector(178.8,320),Vector(-4.2,0),16
bomb.ExplosionDamage,bomb.RadiusMultiplier=10,1
function bomb:ToBomb()return self end;function bomb:IsActiveEnemy()return false end
s,b=replay(Vector(89.5,356.7),Vector(-2.5,2.4),{bomb})
check('troll bomb',s,b,1)
-- Early in the fuse it is only a warning.
bomb.frame=5;s=replay(Vector(97.6,370),Vector(0,0),{bomb})
assert(s[1]>0 and s[1]<HARD,'early fuse must warn, not hit ('..s[1]..')')
print('PASS bomb blast: imminent detonation is a hit, an early fuse only warns')

-- A boom fly one shot from death warns within its burst radius; a healthy
-- one does not add the warning.
local fly=entity(EntityType.ENTITY_BOOMFLY,0,'Fly',1)
fly.Position,fly.HitPoints,fly.EntityCollisionClass,fly.CollisionDamage=Vector(260,280),3,EntityCollisionClass.ENTCOLL_NONE,0
function fly:ToNPC()return self end
s=replay(Vector(320,280),Vector(0,0),{fly})
assert(s[1]>0 and s[1]<HARD,'dying boom fly gave no warning')
fly.HitPoints=20;s=replay(Vector(320,280),Vector(0,0),{fly})
for _,v in ipairs(s)do assert(v==0,'healthy boom fly warned')end
print('PASS death burst: dying exploder warns, healthy one does not')
