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
EntityType.ENTITY_PLAYER=1
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
local p={Type=EntityType.ENTITY_PLAYER,Position=Vector(100,180),Velocity=Vector(0,0),Size=10,MoveSpeed=1,InitSeed=9,CanFly=false,ShotSpeed=1,TearRange=260}
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
-- Brimstone: after a release, stay released while waiting for the beam
-- (here none comes: 4 updates), then charge again.
local first=holds(28)
assert(first==string.rep('H',21)..'rrrrrrH','first charge pattern: '..first)
assert(s.bias==2,'no beam after release: bias '..s.bias)
-- need 24 now: release, the beam comes out and lasts; no hold until it ends.
s.held=22
assert(holds(3)=='Hrr')
local beam=attack(EntityType.ENTITY_LASER,{MaxDistance=0})
local during=holds(10,{target,beam})
assert(during=='rrrrrrrrrr','held during the beam: '..during)
assert(s.bias==1 and s.checkAt==nil,'beam seen: bias '..s.bias)
beam.dead=true
local after=holds(3)
assert(after=='rHH','charge resumes one update after the beam: '..after)
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
-- A normal tear weapon must keep firing even when entity ownership is not
-- observable (the 2026-10-25 co-op baby run regressed into charge mode).
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
local normal=holds(120)
assert(not normal:find('r'),'normal tears released without attack evidence: '..normal)
assert(s.weapon=='tears' and s.stalled,'silent normal weapon changed firing mode')
-- Co-op baby shots may be parented to the main twin. Match its controller,
-- never another player or a similarly indexed entity from the other player.
assert(holds(30,{target}):sub(1,2)=='HH','continued silent hold')
p.ControllerIndex=7
local mainTwin={Index=99,ControllerIndex=7,Type=EntityType.ENTITY_PLAYER}
local remote={Index=99,ControllerIndex=8,Type=EntityType.ENTITY_PLAYER}
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
update(s,{target})
update(s,{target,attack(EntityType.ENTITY_TEAR,{Parent=mainTwin,SpawnerEntity=nil})})
assert(s.quiet==0,'main-twin tear was not observed')
update(s,{target,attack(EntityType.ENTITY_TEAR,{Parent=remote,SpawnerEntity=nil})})
assert(s.quiet==1,'remote player tear counted as our attack')
-- Conflicting links: a remote shot must be rejected even when its Parent is
-- the local main twin. Traversal order must not decide ownership.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
update(s,{target})
update(s,{target,attack(EntityType.ENTITY_TEAR,{Parent=mainTwin,SpawnerEntity=remote})})
assert(s.quiet==1,'remote SpawnerEntity hidden by local Parent')
p.ControllerIndex=nil
weapons={}
-- Picking up a charge weapon after tear auto-fire must discard the old
-- evidence and start charging rather than holding forever.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
for i=1,8 do
 local list={target}
 if i>=6 then list[2]=attack(EntityType.ENTITY_TEAR) end
 update(s,list)
end
assert(s.autoFireAt,'tear auto-fire setup')
weapons[WeaponType.WEAPON_BRIMSTONE]=true
assert(holds(45):find('r'),'Brimstone inherited stale tear auto-fire evidence')
weapons={}
-- Pending release/check state must not survive a mode cycle or an empty
-- interval: neither may fire immediately or add a false charge bias.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
local released=false
for i=1,40 do
 local _,_,_,h=update(s,{target})
 if not h then released=true;break end
end
assert(released,'Brimstone never released')
for i=1,10 do update(s,{}) end
local bias=s.bias
update(s,{target})
assert(s.bias==bias,'empty interval charged a failed release')
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
released=false
for i=1,40 do
 local _,_,_,h=update(s,{target})
 if not h then released=true;break end
end
assert(released,'Brimstone never released before cycle')
Combat.cycle(s);Combat.cycle(s);Combat.cycle(s)
local _,_,_,h=update(s,{target})
assert(h,'pending release survived mode cycle')
weapons={}
-- Queued movement moves the shot origin; current position would aim right.
p.Position,p.Velocity=Vector(100,180),Vector(2.5,0)
s=Combat.new();Combat.cycle(s)
local _,_,aimed=update(s,{enemy(200,89)},{queueDelay=4})
assert(aimed==3,'queued shooter displacement ignored: '..tostring(aimed))
p.Velocity=Vector(0,0)
-- Azazel: the laser length caps the standing distance.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
weapons[WeaponType.WEAPON_BRIMSTONE]=true
update(s,{target});update(s,{target,attack(EntityType.ENTITY_LASER,{MaxDistance=110})})
assert(s.laserReach==110 and s.info.goalX,'laser reach recorded')
assert(math.abs(s.info.goalX-400)+math.abs(s.info.goalY-180)<=110,'goal inside the laser')
weapons={}
print('PASS charge timing from MaxFireDelay, release check, beam wait, fire evidence, laser reach')

-- 0.14: firing continuity, target dwell, goal stickiness, hazard pathing.
-- Neptunus fires while held: not a charge hint.
CollectibleType={COLLECTIBLE_CHOCOLATE_MILK=69,COLLECTIBLE_CURSED_EYE=316,COLLECTIBLE_NEPTUNUS=597}
local items={}
function p:HasCollectible(id)return items[id]==true end
items[597]=true
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
assert(not holds(60):find('r'),'Neptunus treated as a charge weapon')
items={}
-- Proven auto-fire survives a room/no-target interval (0.12.6 re-learned it
-- 83 times in one session); a weapon change still clears it.
items[69]=true
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
for i=1,8 do
 local list={target}
 if i>=6 then list[2]=attack(EntityType.ENTITY_TEAR) end
 update(s,list)
end
assert(s.provenAuto and s.weapon=='tears','auto-fire evidence not learned')
for i=1,200 do update(s,{}) end
assert(not holds(40):find('r'),'auto-fire proof lost after an empty interval')
items={}
-- Target dwell: a slightly closer newcomer does not steal the target.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
p.Position=Vector(100,180)
local first,second=enemy(300,180),enemy(330,180)
update(s,{first});assert(s.targetSeed==first.InitSeed)
second.Position=Vector(100,300) -- 120 away vs 200: better, not twice as good
update(s,{first,second});assert(s.targetSeed==first.InitSeed,'target switched inside dwell')
second.Position=Vector(100,240) -- 60 vs 200: more than twice as good
update(s,{first,second});assert(s.targetSeed==second.InitSeed,'clearly better target ignored')
-- Goal side is sticky for the same target.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
local still=enemy(300,180)
update(s,{still});local side=s.goalSide
assert(side,'goal side recorded')
p.Position=Vector(300+(side==2 and 40 or -40),180)
for i=1,5 do update(s,{still}) end
assert(s.goalSide==side,'goal side flipped without reason')
-- AUTO pathing treats hazard cells (spikes) as walls.
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
p.Position=Vector(100,180)
local hazard={}
for y=1,7 do hazard[room:GetGridIndex(Vector(180,y*40+20))]=true end
local _,mv=update(s,{enemy(460,180)},{hazardCells=hazard})
assert(s.info.goalX==nil or s.info.goalX<180,'goal behind a spike wall: '..tostring(s.info.goalX))
-- A long hold that still fired nothing is not a short charge: no bias.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
s=Combat.new();Combat.cycle(s);Combat.cycle(s)
p.Position=Vector(100,300)
s.held=60;update(s,{enemy(400,60)})        -- misaligned: keeps holding past need
p.Position=Vector(100,180)
for i=1,8 do update(s,{target}) end
assert(s.bias==0,'long failed hold raised the bias: '..s.bias)
-- A new bound player starts from zero bias and no auto-fire proof.
s.bias,s.provenAuto=12,true;Combat.forget(s)
assert(s.bias==0 and not s.provenAuto,'forget kept old weapon evidence')
weapons={}
-- Tears inherit 1.3x sideways velocity (2026-11-02 IAD AIM samples).
p.Position,p.Velocity=Vector(100,180),Vector(0,0)
local shoot,aligned=Combat.aim(p,enemy(300,180),0)
assert(shoot==2 and aligned,'standing still: straight right shot')
p.Velocity=Vector(0,4) -- walking down 4/tick: a right tear drifts 5.2/update
shoot,aligned=Combat.aim(p,enemy(300,180),0)
assert(shoot==2 and not aligned,'drifting tear counted as on target')
shoot,aligned=Combat.aim(p,enemy(300,242),0) -- 12 updates x 5.2 below the row
assert(shoot==2 and aligned,'drift toward the target not used: '..shoot..' '..tostring(aligned))
p.Velocity=Vector(-3,0) -- walking away from a right shot takes nothing off
local _,_,ax=Combat.aim(p,enemy(260,180),0)
assert(ax==260,'backward motion changed the lead')
p.Velocity=Vector(0,0)
print('PASS 0.16 combat: charge bias only for threshold releases, forget on rebind, tear drift in aim')
print('PASS 0.14 combat: Neptunus hint, persistent auto-fire proof, target dwell, sticky goal side, hazard pathing')

-- 0.17: no killing shot that would blow an exploder up next to us. With
-- 3.5-damage tears (speed 10) a 3-HP exploder 80 away dies 8 updates later
-- at 80: too close, so AUTO holds fire. At 200, or with 20 HP left, or for
-- an ordinary enemy, it fires.
local function exploderEnemy(x,y,hp,chase)
 local e=enemy(x,y);e.HitPoints,e.exploder,e.chaser=hp,true,chase;return e
end
local blast={exploder=function(e)return e.exploder==true end,chaser=function(e)return e.chaser==true end}
local function fires(target)
 local s=Combat.new();Combat.cycle(s);Combat.cycle(s)
 local held=false
 for _=1,4 do local _,_,_,h=update(s,{target},blast);held=h end
 return held
end
p.Position,p.Velocity,p.Damage=Vector(100,180),Vector(0,0),3.5
assert(not fires(exploderEnemy(180,180,3)),'fired a killing shot at an exploder 80 away')
assert(fires(exploderEnemy(300,180,3)),'held fire at a distant exploder')
assert(fires(exploderEnemy(180,180,20)),'held fire at a healthy exploder')
local plain=enemy(180,180);plain.HitPoints=3
assert(fires(plain),'held fire at an ordinary dying enemy')
-- Its motion counts: 200 away but closing at 12/update, it is next to us
-- by the time the tear lands.
local closing=exploderEnemy(300,180,3);closing.Velocity=Vector(-12,0)
assert(not fires(closing),'fired at an exploder that will be next to us when it dies')
-- Chasing exploders are kept 150 away, other exploders 130: with the target
-- at (200,180) and an exploder just behind it, the goal moves further out
-- for a Mulliboom than for a boom fly.
local function goalGap(neighbour)
 local s=Combat.new();Combat.cycle(s);Combat.cycle(s)
 update(s,{enemy(200,180),neighbour},blast)
 assert(s.info.targetX==200,'target changed')
 return Vector(s.info.goalX,s.info.goalY):Distance(neighbour.Position)-neighbour.Size
end
local chasing,drifting=goalGap(exploderEnemy(220,180,20,true)),goalGap(exploderEnemy(220,180,20,false))
assert(chasing>=137 and drifting<137,'chaser standoff '..chasing..' vs '..drifting)
-- A chasing exploder far away is shot first, before it closes in.
local function targetX(other)
 local s=Combat.new();Combat.cycle(s);Combat.cycle(s)
 update(s,{enemy(270,180),other},blast)
 return s.info.targetX
end
assert(targetX(exploderEnemy(290,140,20,true))==290,'distant chaser not shot first')
assert(targetX(exploderEnemy(290,140,20,false))==270,'drifting exploder preferred over a nearer enemy')
-- A charge (Brimstone) keeps charging instead of releasing the killing
-- beam while the exploder is too close, and releases once it is not.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
local function released(target,n)
 local s=Combat.new();Combat.cycle(s);Combat.cycle(s)
 for _=1,n do local _,_,_,h=update(s,{target},blast);if not h then return true end end
 return false
end
assert(not released(exploderEnemy(180,180,3),30),'charge released a killing beam next to an exploder')
assert(released(exploderEnemy(300,180,3),30),'charge never released at a distant exploder')
weapons={}
-- A chasing exploder as the target is also engaged from 150.
local s=Combat.new();Combat.cycle(s);Combat.cycle(s)
update(s,{exploderEnemy(300,180,20,true)},blast)
assert(Vector(s.info.goalX,s.info.goalY):Distance(Vector(300,180))>=150,'chasing target engaged closer than 150')
print('PASS 0.17 combat: no killing shot at a nearby exploder, chasing exploders kept 150 away and shot first')
