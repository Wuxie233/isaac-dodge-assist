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

-- A killing shot in flight makes the burst a hit. 2026-10-28: a boom fly
-- moving (-4.9,-4.9) died at (467.8,221.7) next to the player at
-- (452.8,166.2); 14 updates earlier (TRACE f=73) the player was at
-- (412.4,241.9) moving (4.1,-4.1) up-right (7), MoveSpeed 1.6, toward the
-- fly. The killing tear is placed to arrive at the recorded death.
local function tear(x,y,vx,vy,damage)
 local t=entity(EntityType.ENTITY_TEAR,0,'Idle',0)
 t.Position,t.Velocity,t.Size,t.CollisionDamage=Vector(x,y),Vector(vx,vy),7,damage
 t.SpawnerType,t.EntityCollisionClass,t.Height,t.FallingSpeed,t.FallingAcceleration=EntityType.ENTITY_PLAYER,EntityCollisionClass.ENTCOLL_ENEMIES,-24,0,0
 function t:IsActiveEnemy()return false end
 return t
end
fly.Position,fly.Velocity,fly.HitPoints=Vector(536.4,290.3),Vector(-4.9,-4.9),3
p.MoveSpeed=1.6
s,b=replay(Vector(412.4,241.9),Vector(4.1,-4.1),{fly,tear(467.8,361.7,0,-10,3.5)})
check('boom fly killed by a tear',s,b,7)
-- The same tear cannot kill a healthy fly: nothing to avoid.
fly.HitPoints=20;s=replay(Vector(412.4,241.9),Vector(4.1,-4.1),{fly,tear(467.8,361.7,0,-10,3.5)})
for _,v in ipairs(s)do assert(v==0,'tear that cannot kill made a burst')end
-- A tear flying away never reaches it.
fly.HitPoints=3;s=replay(Vector(412.4,241.9),Vector(4.1,-4.1),{fly,tear(467.8,361.7,0,10,3.5)})
assert(s[7]<HARD,'tear flying away predicted a kill')
p.MoveSpeed=1
-- 2026-10-26: Azazel's beam (8.16 per update) killed a boom fly drifting
-- into it at (219.6,298.2), 64 units from the player. Four updates earlier
-- the fly touched the beam and the player stood 42 units away: too close to
-- get out, so only the prediction is required.
local beam=entity(EntityType.ENTITY_LASER,1,'LargeRedLaser',0)
beam.Position,beam.Size,beam.CollisionDamage,beam.Timeout=Vector(230.2,251),16,8.16,8
beam.SpawnerType,beam.EntityCollisionClass=EntityType.ENTITY_PLAYER,EntityCollisionClass.ENTCOLL_ENEMIES
function beam:ToLaser()return self end;function beam:IsActiveEnemy()return false end
function beam:GetEndPoint()return Vector(230.2,467.7)end;function beam:IsCircleLaser()return false end
fly.Position,fly.Velocity,fly.HitPoints=Vector(205.6,284.6),Vector(3.5,3.4),20
s=replay(Vector(230.2,251.0),Vector(1.0,0),{fly,beam})
assert(s[3]>=HARD,'boom fly dying in our beam not predicted')
print('PASS killing shot: tear in flight and beam contact turn the burst into a hit; harmless or stray tears do not')

-- Every exploder death (and every boom fly variant, to check which really
-- explode) is recorded with the distance and how late the prediction was.
fly.HitPoints,fly.Position,fly.Velocity=3,Vector(536.4,290.3),Vector(-4.9,-4.9)
replay(Vector(412.4,241.9),Vector(4.1,-4.1),{fly,tear(467.8,361.7,0,-10,3.5)})
fly.Position=Vector(500.4,290.3)
callbacks[ModCallbacks.MC_POST_NPC_DEATH](nil,fly)
assert(logs[#logs]:match('^IAD BURST: source='..EntityType.ENTITY_BOOMFLY..'%.0%.0 pos=500%.4,290%.3 player=412%.4,241%.9 dist=100%.4 late=%-12 hp=3%.0$'),logs[#logs])
local red=entity(EntityType.ENTITY_BOOMFLY,1,'Fly',0);red.HitPoints=0
callbacks[ModCallbacks.MC_POST_NPC_DEATH](nil,red)
assert(logs[#logs]:find('^IAD BURST: source='..EntityType.ENTITY_BOOMFLY..'%.1%.0 .* late=none'),'red boom fly death not recorded')
local count=#logs
callbacks[ModCallbacks.MC_POST_NPC_DEATH](nil,entity(EntityType.ENTITY_GAPER,0,'Walk',0))
assert(#logs==count,'non-exploder death recorded')
print('PASS IAD BURST: exploder and boom fly deaths recorded with distance and prediction lag')

-- Chain knockback: a blast pushes the later bombs inside it away from it.
-- Until measured, a pushed bomb's blast covers 80 along the push and its
-- timing is widened by 3 updates; a chain follows every push in order.
local NpcHazards=dofile('mod/isaac_dodge_assist/npc_hazards.lua')
local function fused(x,y,frame,rm)
 local b=entity(EntityType.ENTITY_BOMB,BombVariant.BOMB_TROLL,'Pulse',frame)
 b.Position,b.Velocity,b.Size,b.RadiusMultiplier,b.ExplosionDamage=Vector(x,y),Vector(0,0),16,rm or 1,10
 function b:ToBomb()return self end;function b:IsActiveEnemy()return false end
 return b
end
local function near(v,x,y)return math.abs(v.X-x)<0.01 and math.abs(v.Y-y)<0.01 end
local single=NpcHazards.bombChain({fused(200,280,50)})
assert(#single==1 and single[1].radius==78 and single[1].from==7 and single[1].to==9 and not single[1].sweep,'lone bomb blast changed')
-- A (8 updates) pushes B (28) right; B's swept blast then pushes C (48).
local chain=NpcHazards.bombChain({fused(330,280,10),fused(240,280,30),fused(200,280,50)})
assert(#chain==3,'chain lost a bomb')
local a,bb,c=chain[1],chain[2],chain[3]
assert(near(a.position,200,280) and not a.sweep,'first blast moved')
assert(near(bb.position,240,280) and bb.sweep and near(bb.sweep,80,0) and bb.from==24 and bb.to==32,'pushed bomb not swept right')
assert(c.sweep and near(c.sweep,80,0) and c.from==44 and c.to==52,'second link of the chain not pushed')
-- Out of reach, or detonating together: no push.
chain=NpcHazards.bombChain({fused(200,280,50),fused(400,280,30)})
assert(not chain[1].sweep and not chain[2].sweep,'distant bomb pushed')
chain=NpcHazards.bombChain({fused(200,280,50),fused(240,280,50)})
assert(not chain[1].sweep and not chain[2].sweep,'simultaneous bombs pushed')
-- Right on top: the direction is unknown, so the blast grows instead.
chain=NpcHazards.bombChain({fused(200,280,50),fused(200,280,30)})
assert(chain[2].radius==78+80 and not chain[2].sweep,'stacked bomb not grown')
-- Only the first 8 detonations are chained; later ones keep a plain blast.
local many={}
for i=1,10 do many[i]=fused(200+i*10,280,58-i*5) end
chain=NpcHazards.bombChain(many)
assert(#chain==10 and not chain[10].sweep and chain[8].sweep,'chain limit')
-- Through the sensor: standing at (360,345) is clear of B where it lies
-- (136 away) but not where A's blast sends it.
local function bombLines(from)
 local n=0;for i=from,#logs do if logs[i]:find('^IAD BOMB: ') then n=n+1 end end;return n
end
local mark=#logs
s,b=replay(Vector(360,345),Vector(0,0),{fused(200,280,56),fused(240,280,48)})
check('pushed bomb',s,b,1)
-- Every update with two or more bombs records each one for the push model.
assert(bombLines(mark)>=2,'IAD BOMB not recorded')
local sample;for i=mark,#logs do if logs[i]:find('^IAD BOMB: ') then sample=logs[i] end end
assert(sample:match('^IAD BOMB: f=%d+ id=%d+ var=%d+ pos=240%.0,280%.0 vel=0%.00,0%.00 anim=Pulse:48 rm=1%.00$'),sample)
mark=#logs
s=replay(Vector(360,345),Vector(0,0),{fused(240,280,48)})
assert(s[1]<HARD,'lone bomb 136 away predicted as a hit')
assert(bombLines(mark)==0,'a lone resting bomb was recorded')
-- A lone bomb on the move is recorded too (friction).
local rolling=fused(240,280,48);rolling.Velocity=Vector(3,0);mark=#logs
replay(Vector(360,345),Vector(0,0),{rolling})
assert(bombLines(mark)>=1,'rolling bomb not recorded')
print('PASS chain knockback: pushed blasts swept along the push, chained in order, limits and replay')
for _,line in ipairs(logs)do assert(not line:find('IAD LOADER: core error',1,true),line)end
