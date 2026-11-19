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
EntityType.ENTITY_PLAYER=1;EntityType._next=10
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

-- Word round trip & OFF <-> AUTO toggle (AIM and bit-1024 brake removed).
local word=Combat.word(2,8,4,true,true)
assert((word&1024)==0,'manual brake bit 1024 must not be emitted')
local m,mv,sh,hold,brk=Combat.decode(word)
assert(m==2 and mv==8 and sh==4 and hold and brk==nil,'decode returns 4 fields without brake')
local wm,wmv,wsh,whold,wbrk=Combat.decode(Combat.mirror(Combat.word(2,1,1,true)))
assert(wm==2 and wmv==2 and wsh==2 and whold and wbrk==nil,'mirror preserves 4 combat fields')
local s=Combat.new()
assert(Combat.update(s,{entities={enemy(300,180)}})==0)
assert(Combat.cycle(s)==2 and Combat.cycle(s)==0,'F10 toggles OFF <-> AUTO')

-- AUTO: lead turns a fast vertical mover into an up shot; queue delay lengthens it.
Combat.cycle(s)
m,mv,sh=update(s,{enemy(300,180)});assert(m==2 and mv~=nil and sh==2,'auto shoot right')
m,mv,sh=update(s,{enemy(220,150,0,-10)});assert(sh==3,'lead up: '..sh)
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

-- AUTO: goal on the target row/column with a clear lane (wide off-axis shot
-- at (100,100)->(300,180) holds fire until aligned, then fires on-row).
s=Combat.new();Combat.cycle(s);assert(s.mode==2)
p.Position=Vector(100,100)
local t=enemy(300,180)
m,mv,sh,hold=update(s,{t})
assert(m==2 and not hold and s.info.goalX,'auto goal')
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
s=Combat.new();Combat.cycle(s)
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
s=Combat.new();Combat.cycle(s)
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
s=Combat.new();Combat.cycle(s)
local normal=holds(120)
assert(not normal:find('r'),'normal tears released without attack evidence: '..normal)
assert(s.weapon=='tears' and s.stalled,'silent normal weapon changed firing mode')
-- Co-op baby shots may be parented to the main twin. Match its controller,
-- never another player or a similarly indexed entity from the other player.
assert(holds(30,{target}):sub(1,2)=='HH','continued silent hold')
p.ControllerIndex=7
local mainTwin={Index=99,ControllerIndex=7,Type=EntityType.ENTITY_PLAYER}
local remote={Index=99,ControllerIndex=8,Type=EntityType.ENTITY_PLAYER}
s=Combat.new();Combat.cycle(s)
update(s,{target})
update(s,{target,attack(EntityType.ENTITY_TEAR,{Parent=mainTwin,SpawnerEntity=nil})})
assert(s.quiet==0,'main-twin tear was not observed')
update(s,{target,attack(EntityType.ENTITY_TEAR,{Parent=remote,SpawnerEntity=nil})})
assert(s.quiet==1,'remote player tear counted as our attack')
-- Conflicting links: a remote shot must be rejected even when its Parent is
-- the local main twin. Traversal order must not decide ownership.
s=Combat.new();Combat.cycle(s)
update(s,{target})
update(s,{target,attack(EntityType.ENTITY_TEAR,{Parent=mainTwin,SpawnerEntity=remote})})
assert(s.quiet==1,'remote SpawnerEntity hidden by local Parent')
p.ControllerIndex=nil
weapons={}
-- Picking up a charge weapon after tear auto-fire must discard the old
-- evidence and start charging rather than holding forever.
s=Combat.new();Combat.cycle(s)
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
s=Combat.new();Combat.cycle(s)
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
s=Combat.new();Combat.cycle(s)
released=false
for i=1,40 do
 local _,_,_,h=update(s,{target})
 if not h then released=true;break end
end
assert(released,'Brimstone never released before cycle')
Combat.cycle(s);Combat.cycle(s)
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
s=Combat.new();Combat.cycle(s)
weapons[WeaponType.WEAPON_BRIMSTONE]=true
update(s,{target});update(s,{target,attack(EntityType.ENTITY_LASER,{MaxDistance=110})})
assert(s.laserReach==110 and s.info.goalX,'laser reach recorded')
-- 0.20 hit-and-run: early in the charge it waits further out on the line,
-- and closes in to strike from inside the laser as the charge fills.
local early=math.abs(s.info.goalX-400)+math.abs(s.info.goalY-180)
assert(early>110 and early<=131,'early charge does not wait outside the laser: '..early)
while s.releaseIn>3 do update(s,{target}) end
update(s,{target})
assert(math.abs(s.info.goalX-400)+math.abs(s.info.goalY-180)<=110,'goal inside the laser')
weapons={}
print('PASS charge timing from MaxFireDelay, release check, beam wait, fire evidence, laser reach')

-- 0.14: firing continuity, target dwell, goal stickiness, hazard pathing.
-- Neptunus fires while held: not a charge hint.
CollectibleType={COLLECTIBLE_CHOCOLATE_MILK=69,COLLECTIBLE_CURSED_EYE=316,COLLECTIBLE_NEPTUNUS=597}
local items={}
function p:HasCollectible(id)return items[id]==true end
items[597]=true
s=Combat.new();Combat.cycle(s)
assert(not holds(60):find('r'),'Neptunus treated as a charge weapon')
items={}
-- Proven auto-fire survives a room/no-target interval (0.12.6 re-learned it
-- 83 times in one session); a weapon change still clears it.
items[69]=true
s=Combat.new();Combat.cycle(s)
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
s=Combat.new();Combat.cycle(s)
p.Position=Vector(100,180)
local first,second=enemy(300,180),enemy(330,180)
update(s,{first});assert(s.targetSeed==first.InitSeed)
second.Position=Vector(100,300) -- 120 away vs 200: better, not twice as good
update(s,{first,second});assert(s.targetSeed==first.InitSeed,'target switched inside dwell')
second.Position=Vector(100,240) -- 60 vs 200: more than twice as good
update(s,{first,second});assert(s.targetSeed==second.InitSeed,'clearly better target ignored')
-- Goal side is sticky for the same target.
s=Combat.new();Combat.cycle(s)
local still=enemy(300,180)
update(s,{still});local side=s.goalSide
assert(side,'goal side recorded')
p.Position=Vector(300+(side==2 and 40 or -40),180)
for i=1,5 do update(s,{still}) end
assert(s.goalSide==side,'goal side flipped without reason')
-- AUTO pathing treats hazard cells (spikes) as walls.
s=Combat.new();Combat.cycle(s)
p.Position=Vector(100,180)
local hazard={}
for y=1,7 do hazard[room:GetGridIndex(Vector(180,y*40+20))]=true end
local _,mv=update(s,{enemy(460,180)},{hazardCells=hazard})
assert(s.info.goalX==nil or s.info.goalX<180,'goal behind a spike wall: '..tostring(s.info.goalX))
-- A long hold that still fired nothing is not a short charge: no bias.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
s=Combat.new();Combat.cycle(s)
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
 local s=Combat.new();Combat.cycle(s)
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
 local s=Combat.new();Combat.cycle(s)
 update(s,{enemy(200,180),neighbour},blast)
 assert(s.info.targetX==200,'target changed')
 return Vector(s.info.goalX,s.info.goalY):Distance(neighbour.Position)-neighbour.Size
end
local chasing,drifting=goalGap(exploderEnemy(220,180,20,true)),goalGap(exploderEnemy(220,180,20,false))
assert(chasing>=137 and drifting<137,'chaser standoff '..chasing..' vs '..drifting)
-- A chasing exploder far away is shot first, before it closes in.
local function targetX(other)
 local s=Combat.new();Combat.cycle(s)
 update(s,{enemy(270,180),other},blast)
 return s.info.targetX
end
assert(targetX(exploderEnemy(290,140,20,true))==290,'distant chaser not shot first')
assert(targetX(exploderEnemy(290,140,20,false))==270,'drifting exploder preferred over a nearer enemy')
-- A charge (Brimstone) keeps charging instead of releasing the killing
-- beam while the exploder is too close, and releases once it is not.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
local function released(target,n)
 local s=Combat.new();Combat.cycle(s)
 for _=1,n do local _,_,_,h=update(s,{target},blast);if not h then return true end end
 return false
end
assert(not released(exploderEnemy(180,180,3),30),'charge released a killing beam next to an exploder')
assert(released(exploderEnemy(300,180,3),30),'charge never released at a distant exploder')
weapons={}
-- A chasing exploder as the target is also engaged from 150.
local s=Combat.new();Combat.cycle(s)
update(s,{exploderEnemy(300,180,20,true)},blast)
assert(Vector(s.info.goalX,s.info.goalY):Distance(Vector(300,180))>=150,'chasing target engaged closer than 150')
print('PASS 0.17 combat: no killing shot at a nearby exploder, chasing exploders kept 150 away and shot first')

-- 0.18: a beam (Brimstone) arrives at once. Aim it at where the target is
-- when the queued release lands, with no tear flight or tear drift; it is
-- on target when the target overlaps the beam and is within its reach.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
p.Position,p.Velocity=Vector(100,180),Vector(0,0)
-- Crossing the row at 6/update: a tear would need ~15 updates of lead, the
-- beam none.
local shoot,aligned=Combat.aim(p,enemy(250,180,0,6),0,{reach=260})
assert(shoot==2 and aligned,'beam led like a slow tear: '..shoot..' '..tostring(aligned))
-- Walking sideways does not drift a beam.
p.Velocity=Vector(0,4)
shoot,aligned=Combat.aim(p,enemy(250,184),0,{reach=260})
assert(shoot==2 and aligned,'beam drifted with the player')
p.Velocity=Vector(0,0)
shoot,aligned=Combat.aim(p,enemy(250,214),0,{reach=260})
assert(shoot==2 and not aligned,'34 off the row counted as a beam hit')
shoot,aligned=Combat.aim(p,enemy(250,180),0,{reach=120})
assert(not aligned,'target beyond the beam reach counted as a hit')
-- The online queue delays the release: lead by it.
shoot,aligned=Combat.aim(p,enemy(250,180,0,10),3,{reach=260})
assert(not aligned,'queued release must lead a moving target')
shoot,aligned=Combat.aim(p,enemy(250,150,0,10),3,{reach=260})
assert(shoot==2 and aligned,'queued release lead missing')
-- A capped beam's reach belongs to that weapon: a new weapon forgets it.
s=Combat.new();Combat.cycle(s)
s.laserReach,s.hint,s.hintTick=110,'tears',-100
update(s,{enemy(400,180)})
assert(s.laserReach==nil,'old beam reach kept after a weapon change')
-- Tech X rings fly: they are aimed like tears, not like an instant beam.
weapons={[WeaponType.WEAPON_TECH_X]=true}
p.Position,p.Velocity=Vector(100,180),Vector(0,0)
s=Combat.new();Combat.cycle(s)
update(s,{enemy(250,180,0,6)})
assert(s.info.aimY>200,'Tech X aimed without lead: '..s.info.aimY)
weapons={}
print('PASS 0.18 combat: beam aim is instant, width and reach bound')

-- 0.18 AUTO stats: damage our own attacks deal, and target changes while
-- the old target is still alive (flicker, not kills).
s=Combat.new();Combat.cycle(s)
p.Position,p.ControllerIndex=Vector(100,180),0
local a,b=enemy(300,180),enemy(100,300)
update(s,{a,b})
local first=s.targetSeed
Combat.dealt(s,p,{Entity=attack(EntityType.ENTITY_TEAR)},3.5)
Combat.dealt(s,p,{Entity=attack(EntityType.ENTITY_TEAR,{SpawnerEntity={Type=EntityType.ENTITY_PLAYER,ControllerIndex=1}})},9)
Combat.dealt(s,p,{},2)
assert(s.stats.dealt==3.5,'dealt counts only our attacks: '..tostring(s.stats.dealt))
-- Out of AUTO (F10 on to OFF) nothing more is counted for the room.
s.mode=0;Combat.dealt(s,p,{Entity=attack(EntityType.ENTITY_TEAR)},5);s.mode=2
assert(s.stats.dealt==3.5,'damage counted outside AUTO')
-- The target dies: a switch, not a retarget.
local alive={a,b};for i,e in ipairs(alive)do if e.InitSeed==first then table.remove(alive,i) break end end
update(s,alive)
assert(s.stats.switches==1 and (s.stats.retargets or 0)==0,'kill counted as a retarget')
-- Both alive and the other becomes much closer: a retarget.
s=Combat.new();Combat.cycle(s)
local far,near=enemy(300,180),enemy(500,300)
update(s,{far,near})
assert(s.targetSeed==far.InitSeed,'setup: nearer target first')
near.Position=Vector(130,180)
for _=1,40 do update(s,{far,near}) end
assert(s.stats.retargets==1,'retarget not counted: '..tostring(s.stats.retargets))
print('PASS 0.18 combat stats: dealt damage from our attacks only, retargets apart from kills')

-- 0.19: a Brimstone release is worth the damage it deals to everything in
-- the beam (each enemy capped at its health), so a charged beam goes where
-- it hits the most and may wait a few updates for an enemy walking in.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
p.MaxFireDelay,p.Damage,p.Velocity=19.5,3.5,Vector(0,0)
local function hp(e,v)e.HitPoints=v;return e end
-- Charge, then report the first release: update count and shoot axis.
local function release(list,limit,extra)
 local s=Combat.new();Combat.cycle(s)
 for i=1,limit do
  local _,_,sh,h=update(s,type(list)=='function' and list(i) or list,extra)
  if not h then return i,sh,s end
 end
 return nil,nil,s
end
p.Position=Vector(300,180)
-- One enemy right (nearest, the target) and three in a row on the left.
local at,sh=release({hp(enemy(380,180),20),hp(enemy(200,180),20),hp(enemy(160,178),20),hp(enemy(120,183),20)},40)
assert(at and sh==1,'beam not sent through the row of three: '..tostring(sh))
-- Alone, the nearest is shot.
at,sh=release({hp(enemy(380,180),20)},40)
assert(at and sh==2,'single target missed: '..tostring(sh))
-- Waiting: B walks down into A's row and reaches it about 9 updates after
-- the charge is full. The beam waits for both instead of hitting A alone.
p.Position=Vector(100,180)
local A=hp(enemy(300,180),20)
local alone=release({A},60)
local function walking(i)
 local B=hp(enemy(220,180-25-5*(31-i),0,5),20);B.InitSeed=777
 return {A,B}
end
local waited=release(walking,60)
assert(alone and waited and waited>alone and waited<=alone+15,'no wait for the second enemy: '..tostring(alone)..' '..tostring(waited))
-- ...but never longer than the cap when nothing better comes.
local function leaving(i)
 local B=hp(enemy(220,60-3*i,0,-3),20);B.InitSeed=778
 return {A,B}
end
local capped=release(leaving,60)
assert(capped and capped<=alone+1,'waited for an enemy that never comes: '..tostring(alone)..' '..tostring(capped))
-- A beam that would kill a nearby exploder on the way is not that axis.
p.Position=Vector(300,180)
local fly=hp(exploderEnemy(240,180,3),3)
at,sh=release({hp(enemy(420,180),20),fly,hp(enemy(150,180),20),hp(enemy(110,180),20)},40,blast)
assert(at and sh~=1,'beam killed an exploder next to us')
-- Standing: with two enemies sharing a row, the goal lines the beam up with
-- both rather than with the lone nearest one.
p.Position=Vector(100,180)
local s=Combat.new();Combat.cycle(s)
update(s,{hp(enemy(220,260),20),hp(enemy(320,100),20),hp(enemy(440,100),20)})
assert(s.info.goalY and math.abs(s.info.goalY-100)<1,'goal not on the two-enemy row: '..tostring(s.info.goalX)..','..tostring(s.info.goalY))
weapons={}
-- Plan while charging: spots are judged by where the enemies will be when
-- the charge is full. E2 walks up into E1's row (y=100) and gets there as
-- the charge (22 updates) completes; right now each enemy stands alone, so
-- E4 shares the nearest target E3's row now but walks off it. Judged now,
-- E3's row holds two; judged at release, E1's row does.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
p.Position=Vector(100,180)
s=Combat.new();Combat.cycle(s)
local E1,E2,E3,E4=hp(enemy(300,100),20),hp(enemy(420,100+3*22,0,-3),20),hp(enemy(200,260),20),hp(enemy(120,260,0,3),20)
update(s,{E3,E1,E2,E4})
assert(s.info.goalY and math.abs(s.info.goalY-100)<10,'goal off the release-time row: '..tostring(s.info.goalX)..','..tostring(s.info.goalY))
-- The spot left of E1 is worth one enemy now and two at release.
local ctx0={player=p,exploder=function()return false end}
local now,atRelease=Combat.spotValue(s,ctx0,p,{E1,E2,E3,E4},92,100,0),Combat.spotValue(s,ctx0,p,{E1,E2,E3,E4},92,100,22)
assert(atRelease>now*1.8,'release-time payoff not used: '..now..' vs '..atRelease)
-- A spot we cannot reach before the beam is ready (plus the wait cap) is
-- worth less than one we can.
weapons={}
print('PASS 0.19 combat: Brimstone payoff picks the axis, waits for walkers (capped), spares exploders, lines up the goal at release time')

-- 0.20: a hit drops a Brimstone charge (2026-11-05: 3 of 3 releases after a
-- hit fired nothing), so the count restarts instead of releasing early.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
p.Position,p.Velocity=Vector(100,180),Vector(0,0)
s=Combat.new();Combat.cycle(s)
for i=1,20 do update(s,{enemy(100,40)}) end
assert(s.weapon=='charge' and s.held>5,'not charging: '..tostring(s.weapon)..' '..s.held)
Combat.hurt(s)
assert(s.held==0,'hit kept the charge')
-- Other charged weapons keep it (no evidence either way).
weapons={[WeaponType.WEAPON_MONSTROS_LUNGS]=true}
s=Combat.new();Combat.cycle(s)
for i=1,6 do update(s,{enemy(100,40)}) end
local held=s.held;Combat.hurt(s)
assert(held>0 and s.held==held,'a non-Brimstone charge was reset')
-- While our beam is out it follows us: step across with the enemy it hits.
weapons[WeaponType.WEAPON_BRIMSTONE]=true
s=Combat.new();Combat.cycle(s)
local walker=enemy(220,200,0,4)
update(s,{walker})
s.beamAxis=2
update(s,{walker,attack(EntityType.ENTITY_LASER,{MaxDistance=0})})
-- Same row, same distance (120; a free goal would stand 208 off).
assert(s.info.goalY and math.abs(s.info.goalY-200)<1 and math.abs(s.info.goalX-100)<1,'beam not kept on the enemy: '..tostring(s.info.goalX)..','..tostring(s.info.goalY))
weapons={}
-- AUTO never walks across an item pedestal (a hazard cell next to us),
-- even when the walk would end past it.
s=Combat.new();Combat.cycle(s)
p.Position=Vector(100,180)
local _,mv=update(s,{enemy(460,180)},{stride=20,hazardCells={[room:GetGridIndex(Vector(140,180))]=true}})
assert(mv~=2,'walked right over the pedestal')
local _,free=update(s,{enemy(460,180)},{stride=20})
assert(free==2,'open path not taken: '..tostring(free))
print('PASS 0.20 combat: hit restarts a Brimstone charge, beam follows its enemy, pedestals avoided')
-- 0.25.9 (B78YY60D Stone Head barrage): with threats about, AUTO keeps its
-- last safe direction over one a little cheaper; in a quiet room only the
-- small nudge applies.
local costs={50,30,22,60,60,60,60,60,60}
local st={lastMove=2}
assert(Combat.chooseMove(st,{scores={0,-1048576,-1048576,5*1048576,0,0,0,0,0},blocked=0},costs)==2,'threatened: last direction kept')
assert(Combat.chooseMove(st,{scores={0,0,0,0,0,0,0,0,0},blocked=0},costs)==3,'quiet: cheaper direction taken')
assert(Combat.chooseMove(st,{scores={0,-1048576,-1048576,5*1048576,0,0,0,0,0},blocked=2},costs)==3,'blocked last direction not kept')
print('PASS 0.25.9 combat: AUTO keeps its direction while threatened')

-- 0.26+: Deathmatch EntityPlayer targeting, infinite Brimstone standoff vs
-- Azazel laserReach, Dr. Fetus blast/obstacle guard (even when flying),
-- Epic Fetus crosshair tracking, Spirit Sword / Bone melee alignment,
-- Mom's Knife distance-scaled partial charge, and Haemolacria lob + splash.
weapons={};rocks={};items={}
p.Position,p.Velocity,p.CanFly=Vector(100,180),Vector(0,0),false
p.MaxFireDelay,p.TearRange,p.ShotSpeed=19.5,260,1
WeaponType.WEAPON_BOMBS=5
WeaponType.WEAPON_ROCKETS=8
WeaponType.WEAPON_BONE=11
EffectVariant=EffectVariant or {TARGET=30}
CollectibleType.COLLECTIBLE_HAEMOLACRIA=531

-- Deathmatch: opponent EntityPlayer is targeted while own player entity is ignored.
s=Combat.new();Combat.cycle(s)
local opp={Type=EntityType.ENTITY_PLAYER,InitSeed=777,Position=Vector(340,180),Velocity=Vector(0,0),
 Size=10,HitPoints=10,EntityCollisionClass=EntityCollisionClass.ENTCOLL_ALL}
function opp:ToNPC()return nil end;function opp:IsDead()return false end;function opp:IsVulnerable()return true end
function opp:HasEntityFlags()return false end
update(s,{p,opp},{deathmatch=true})
assert(s.targetSeed==777,'Deathmatch did not target opponent player: '..tostring(s.targetSeed))

-- Infinite Brimstone standoff (>= 200) vs Azazel laserReach=110.
weapons={[WeaponType.WEAPON_BRIMSTONE]=true}
s=Combat.new();Combat.cycle(s);p.Position=Vector(100,180)
local farTarget=enemy(500,180)
update(s,{farTarget})
assert(s.info.goalX and math.abs(s.info.goalX-500)+math.abs(s.info.goalY-180)>=200,
 'infinite Brimstone walked up too close: goal=('..tostring(s.info.goalX)..','..tostring(s.info.goalY)..')')
s.laserReach=110
while (s.releaseIn or 99)>3 do update(s,{farTarget}) end
update(s,{farTarget})
assert(s.info.goalX and math.abs(s.info.goalX-500)+math.abs(s.info.goalY-180)<=110,
 'capped Azazel Brimstone stayed outside reach')
weapons={}

-- Dr. Fetus (WEAPON_BOMBS): blocks unsafe close shot (< 115) and solid rock
-- in the bomb lane (< 60px ahead) even when the player has flight.
weapons={[WeaponType.WEAPON_BOMBS]=true}
s=Combat.new();Combat.cycle(s);p.CanFly=true;p.Position=Vector(100,180)
local _,_,shClose,holdClose=update(s,{enemy(180,180)})
assert(not holdClose,'Dr. Fetus fired inside self-blast range: sh='..tostring(shClose))
rocks[room:GetGridIndex(Vector(140,180))]=true;s.grid=nil
local _,_,shWall,holdWall=update(s,{enemy(360,180)})
assert(not holdWall,'flying Dr. Fetus bombed into nearby solid rock: sh='..tostring(shWall))
rocks={};s.grid=nil
local _,_,shOpen,holdOpen=update(s,{enemy(360,180)})
assert(shOpen==2 and holdOpen,'Dr. Fetus refused open long-range lane')
p.CanFly=false;weapons={}

-- Epic Fetus (WEAPON_ROCKETS): tracks EffectVariant.TARGET toward enemy and
-- stops firing if crosshair sits within self-blast radius (< 90).
weapons={[WeaponType.WEAPON_ROCKETS]=true}
s=Combat.new();Combat.cycle(s);p.Position=Vector(100,180)
local crossSafe={Type=EntityType.ENTITY_EFFECT,Variant=EffectVariant.TARGET,InitSeed=555,
 Position=Vector(340,180),SpawnerEntity=p}
function crossSafe:ToNPC()return nil end;function crossSafe:IsDead()return false end
local _,_,shRkt,holdRkt=update(s,{enemy(340,300),crossSafe})
assert(shRkt==4 and holdRkt,'Epic Fetus did not steer crosshair down toward enemy: '..tostring(shRkt))
crossSafe.Position=Vector(140,180)
local _,_,shDanger,holdDanger=update(s,{enemy(340,180),crossSafe})
assert(not holdDanger,'Epic Fetus kept firing while crosshair was on top of player')
weapons={}

-- Melee (Spirit Sword & Forgotten Bone): swings only when aligned within reach.
for _,w in ipairs({WeaponType.WEAPON_SPIRIT_SWORD, WeaponType.WEAPON_BONE}) do
 weapons={[w]=true}
 s=Combat.new();Combat.cycle(s);p.Position=Vector(100,180)
 local _,_,shFar,holdFar=update(s,{enemy(340,180)})
 assert(not holdFar,'melee weapon swung at out-of-range enemy: sh='..tostring(shFar))
 local _,_,shHit,holdHit=update(s,{enemy(160,180)})
 assert(shHit==2 and holdHit,'melee weapon failed to swing at in-range target: '..w)
end
weapons={}

-- Mom's Knife: close enemy uses partial charge (~0.4*need) while far waits full need.
weapons={[WeaponType.WEAPON_KNIFE]=true}
p.MaxFireDelay=19.5
s=Combat.new();Combat.cycle(s);p.Position=Vector(100,180)
local closePat=holds(12,{enemy(170,180)})
assert(closePat:find('r')~=nil,'close Mom\'s Knife waited for full charge: '..closePat)
s=Combat.new();Combat.cycle(s)
local farPat=holds(15,{enemy(400,180)})
assert(farPat:find('r')==nil,'far Mom\'s Knife released too early: '..farPat)
weapons={}

-- Haemolacria: ignores rocks when picking targets and prefers clustered splash.
items[CollectibleType.COLLECTIBLE_HAEMOLACRIA]=true
s=Combat.new();Combat.cycle(s);p.Position=Vector(100,180)
for y=1,7 do rocks[room:GetGridIndex(Vector(180,y*40+20))]=true end
s.grid=nil
local shielded=enemy(260,180) -- 160 away behind rock
local openFar=enemy(290,260)  -- ~206 away, open
update(s,{shielded,openFar})
assert(s.targetSeed==shielded.InitSeed,'Haemolacria avoided rock-behind nearer enemy')
rocks={};s.grid=nil
s=Combat.new();Combat.cycle(s)
local solo=enemy(260,100) -- ~179 away
local c1=enemy(290,180);local c2=enemy(310,180);local c3=enemy(290,200) -- 190 away, clustered
update(s,{solo,c1,c2,c3})
assert(s.targetSeed==c1.InitSeed or s.targetSeed==c2.InitSeed or s.targetSeed==c3.InitSeed,
 'Haemolacria did not prefer clustered splash targets: solo='..solo.InitSeed..' picked='..tostring(s.targetSeed))
items={}
print('PASS 0.26+ combat: Deathmatch player, Brimstone standoff, Dr./Epic Fetus, Spirit Sword/Bone, Knife partial charge, Haemolacria')

-- 0.27+ combat: target hysteresis (3-tick vote + rock grace), tear fire gating (rock & wide miss), firing-line deadband.
-- 1) Marginal retarget needs 3 ticks after dwell; <0.5x threat switches immediately.
s=Combat.new();Combat.cycle(s);p.Position,p.Velocity,p.Damage=Vector(100,180),Vector(0,0),3.5
local curE,altE=enemy(340,180),enemy(250,180) -- cur=240, alt=150: 150 < 240*0.7-20=148? Use cur=350 (d=250, lim=155, half=125), alt=245 (d=145)
curE.Position,altE.Position=Vector(350,180),Vector(245,180)
update(s,{curE});s.tick=40
update(s,{curE,altE});assert(s.targetSeed==curE.InitSeed,'marginal retarget switched on tick 1')
update(s,{curE,altE});assert(s.targetSeed==curE.InitSeed,'marginal retarget switched on tick 2')
update(s,{curE,altE});assert(s.targetSeed==altE.InitSeed,'marginal retarget failed to switch on tick 3')
-- Urgent <0.5x switches on tick 1.
local urgent=enemy(150,180) -- d=50 < 145*0.5=72.5
update(s,{altE,urgent});assert(s.targetSeed==urgent.InitSeed,'urgent <0.5x target did not switch immediately')

-- 2) Tear fire gating: solid rock blocks plain tears but not spectral; wide long-range miss gates unless another enemy is on-lane or homing.
s=Combat.new();Combat.cycle(s);p.Position,p.Velocity=Vector(100,180),Vector(0,0)
rocks[room:GetGridIndex(Vector(140,180))]=true;s.grid=nil
local _,_,shBlk,holdBlk=update(s,{enemy(260,180)})
assert(shBlk==2 and not holdBlk,'plain tear fired straight into rock ahead')
for _=1,50 do
 local _,_,_,hGated=update(s,{enemy(260,180)})
 assert(not hGated,'rock-gated tear fired during sustained occlusion')
end
assert(s.streak==0 and s.quiet==0 and not s.stalled,
 'post-fireControl rock gate inflated streak/stall: streak='..tostring(s.streak)..' quiet='..tostring(s.quiet)..' stalled='..tostring(s.stalled))
TearFlags=TearFlags or {TEAR_SPECTRAL=1,TEAR_HOMING=4}
p.TearFlags=TearFlags.TEAR_SPECTRAL
local _,_,shSpec,holdSpec=update(s,{enemy(260,180)})
assert(shSpec==2 and holdSpec,'spectral tear blocked by rock gate')
p.TearFlags=0;rocks={};s.grid=nil

s=Combat.new();Combat.cycle(s);p.Position,p.Velocity=Vector(100,180),Vector(0,0)
local wideT=enemy(300,260) -- d~215, miss=80 > size(13)+14
local _,_,_,holdWide=update(s,{wideT})
assert(not holdWide,'plain tear fired on wide long-range miss')
local onLane=enemy(260,180) -- right along shoot=2 lane while still targeting wideT? keep wideT as current target inside dwell
s=Combat.new();Combat.cycle(s);update(s,{wideT})
local onLaneFar=enemy(320,180) -- further than wideT so wideT stays target, sits on shoot=2 lane
local _,_,shLane,holdLane=update(s,{wideT,onLaneFar})
assert(shLane==2 and holdLane,'wide-miss gate suppressed shot that hits another enemy on lane')
TearFlags.TEAR_HOMING=TearFlags.TEAR_HOMING or 4
p.TearFlags=TearFlags.TEAR_HOMING
local _,_,_,holdHoming=update(s,{wideT})
assert(holdHoming,'homing tear suppressed by wide-miss gate')
p.TearFlags=0

-- 3) Firing-line deadband: when aligned, clear, in range, and uncrowded, stay on the line instead of perpendicular grid jitter.
s=Combat.new();Combat.cycle(s);p.Position,p.Velocity=Vector(100,192),Vector(0,0)
local lineT=enemy(260,186) -- aligned right (miss=6 <= 19), d=160 <= 250, nearEnemy=160 >= 115
local _,mvLine,shLine,holdLine=update(s,{lineT})
assert(shLine==2 and holdLine and mvLine==0,'aligned tear lane jittered off-axis: mv='..tostring(mvLine))
print('PASS 0.27+ combat: target hysteresis, rock/wide-miss tear gating, firing-line deadband')
