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
local function module(name)return dofile('mod/isaac_dodge_assist/'..name..'.lua')end
local Field,Planner,Motion,Laser,Kinematics=module('threat_field'),module('dodge_planner'),module('motion_prediction'),module('laser_hazards'),module('player_motion')
local dirs={Vector(0,0),Vector(-1,0),Vector(1,0),Vector(0,-1),Vector(0,1),Vector(-1,-1):Normalized(),Vector(1,-1):Normalized(),Vector(-1,1):Normalized(),Vector(1,1):Normalized()}
local function player(x,y,vx,vy)return {Position=Vector(x,y),Velocity=Vector(vx or 0,vy or 0),Size=5,MoveSpeed=1}end
local function context(p,steps,safe)
 local field=Field.new(steps,p.Size,{},Laser)
 return {player=p,steps=steps,field=field,sample=Field.sample,gridSafe=safe or function()return true end,room={},
  ticks=Kinematics.TICKS,models={Kinematics.models(Kinematics.new())}}
end
local function solve(ctx)return Planner.solve(ctx,dirs,function()return 0 end)end
local function best(scores,blocked)
 local k=1;local low=math.huge
 for i,s in ipairs(scores)do if (blocked & (1<<(i-1)))==0 and s<low then k,low=i,s end end
 return k
end
-- v0.8.5 wall-inertia regression remains valid through the module extraction.
local ctx=context(player(0,0,-1,0),8,function(_,_,p)return p.X>=0 end)
ctx.inside=false
local right,left=Planner.path(ctx,dirs[3],ctx.models[1]),Planner.path(ctx,dirs[2],ctx.models[1])
assert(not right.blocked and right.endpoint.X>0,'pre-input inertia rejected valid escape')
assert(left.blocked,'fully blocked movement must stay blocked')
print('PASS wall inertia and slide')
-- A high-speed character must not jump across a thin obstacle between samples.
ctx=context(player(0,0,40,0),8,function(_,_,p)return p.X<12 or p.X>24 end)
local tunnel=Planner.path(ctx,dirs[3],ctx.models[1])
assert(tunnel.endpoint.X<12,'terrain sweep tunneled through obstacle')
print('PASS swept terrain')
-- Current overlap: leaving the envelope decisively beats remaining inside it.
ctx=context(player(0,0),11,function(_,_,p)return p.Y>=0 end)
Field.add(ctx.field,nil,Vector(20,12),Vector(20,12),35)
local scores,blocked,danger,paths,inside=solve(ctx)
assert(inside and danger)
local chosen=best(scores,blocked)
assert(paths[chosen].fast.lastHit<ctx.steps and paths[chosen].slow.lastHit<ctx.steps,'did not choose sustained exit')
assert(scores[chosen]<scores[1],'idle beat escape')
print('PASS blood pool against wall: stable exit chosen, direction='..chosen)
-- Fixed comparative regression: v0.8.6 preferred LU, whose slow rollout still
-- touches a pool at tick 11. Down finishes all contact at tick 7.
ctx=context(player(0,0),11,function(_,_,p)return p.Y>=0 end)
for _,h in ipairs({{63,24,49},{52,76,24},{53,5,49},{-63,19,39}})do
 Field.add(ctx.field,nil,Vector(h[1],h[2]),Vector(h[1],h[2]),h[3])
end
scores,blocked,danger,paths=solve(ctx)
chosen=best(scores,blocked)
assert(chosen==5 and paths[chosen].slow.lastHit==7 and paths[6].slow.lastHit==11,
 'tail of route trapped player in adjacent pool')
print('PASS four-pool comparative regression: down clears at tick 7; old LU hits through tick 11')
-- If every path remains inside a huge pool, still move toward its boundary.
ctx=context(player(10,0),8)
Field.add(ctx.field,nil,Vector(0,0),Vector(0,0),100)
scores,blocked,danger,paths=solve(ctx)
chosen=best(scores,blocked)
assert(chosen~=1 and paths[chosen].slow.depth<paths[1].slow.depth,'inside huge pool did not make escape progress')
print('PASS escape progress when no route clears within horizon')
-- Dense duplicate effects have exactly the same score as one physical area.
local before=scores[3]
for i=1,200 do Field.add(ctx.field,nil,Vector(0,0),Vector(0,0),100) end
local duplicateScores=solve(ctx)
assert(before==duplicateScores[3],'overlapping patches multiplied risk')
print('PASS duplicate-effect risk invariance')
-- Fast crossing threats use swept relative motion, including between endpoints.
local f=Field.new(2,1,{},Laser)
Field.add(f,1,Vector(-100,0),Vector(100,0),2)
assert(Field.sample(f,Vector(0,0),Vector(0,0),1)>0,'fast crossing missed')
assert(Field.sample(f,Vector(0,30),Vector(0,30),1)==0,'distant crossing false hit')
print('PASS fast crossing')
-- The broad-phase must retain *every* collision compared to brute force.
math.randomseed(901)
f=Field.new(3,7,{},Laser)
local data={}
for i=1,500 do
 local a=Vector(math.random(-1500,1500),math.random(-800,800));local b=a+Vector(math.random(-180,180),math.random(-180,180))
 local r=math.random(1,70);data[i]={a,b,r};Field.add(f,1,a,b,r)
end
for i=1,150 do
 local a=Vector(math.random(-500,500),math.random(-500,500));local b=a+Vector(math.random(-60,60),math.random(-60,60))
 local expected=0
 for _,h in ipairs(data)do
  local x,y=a-h[1],b-h[2];local d=y-x;local length=d:LengthSquared()
  local t=length>0 and math.max(0,math.min(1,-x:Dot(d)/length)) or 0
  expected=math.max(expected,h[3]+7-(x+d*t):Length())
 end
 local actual=Field.sample(f,a,b,1)
 assert(math.abs(expected-actual)<1e-7,'broad-phase omitted an intersecting threat')
end
assert(f.checks<500*150/4,'broad-phase did not reduce narrow checks')
print('PASS broad-phase vs 75000 brute checks: checks='..f.checks)
-- Braking must stop without an invented reversal, and cached forecasts agree.
local enemy={InitSeed=1,Position=Vector(0,0),Velocity=Vector(1,0)}
function enemy:ToNPC()return self end;function enemy:ToProjectile()return nil end
local motion=Motion.track({enemy},{[1]={velocity=Vector(3,0),speed=3}})
local p3=Motion.forecast(motion,enemy,3);local p10=Motion.forecast(motion,enemy,10)
assert(p3.X>=0 and p10.X==p3.X,'braking invented reverse motion')
assert(Motion.forecast(motion,enemy,2).X>=0,'forecast cache inconsistent')
print('PASS braking and motion cache')
ProjectileFlags={ANY_HEIGHT_ENTITY_HIT=1}
local bullet={Height=-60,FallingSpeed=100,FallingAccel=-0.1,HasProjectileFlags=function()return false end}
assert(Field.heightIntersects(bullet,1),'fell through entire collision band between samples')
bullet.Height=-100;bullet.FallingSpeed=0
assert(not Field.heightIntersects(bullet,1),'overhead projectile considered grounded')
bullet.Height=-49;bullet.FallingSpeed=1.68;bullet.FallingAccel=0
assert(Field.heightIntersects(bullet,1),'logged hit at height -49 treated as overhead')
print('PASS swept projectile height')
-- Delay sensitivity: the robust score must retain the slower response risk.
ctx=context(player(0,0),11)
for t=0,11 do Field.add(ctx.field,t,Vector(45-10*math.max(0,t-1),0),Vector(45-10*t,0),4)end
scores,blocked,danger,paths=solve(ctx)
for i,p in ipairs(paths)do
 assert(p.risk==math.max(p.fast.risk,p.slow.risk))
 if p.risk==0 then assert(scores[i]<=0,'safe manual route must pass through')else assert(scores[i]>0)end
end
assert(best(scores,blocked)~=1,'incoming projectile did not cause evacuation')
print('PASS robust latency and safe/manual score contract')
-- Current laser occupancy is instantaneous, not a negative-time sweep.
local shape={origin=Vector(0,0),velocity=Vector(4,0),width=2,points={Vector(0,0),Vector(100,0)},reach=100,angularSpeed=0,delay=0}
assert(Laser.clearance(shape,Vector(20,0),Vector(20,0),0,1)<0)
assert(Laser.clearance(shape,Vector(20,10),Vector(20,10),0,1)>0)
shape.activeFrom=4
assert(Laser.clearance(shape,Vector(20,0),Vector(20,0),0,1)==math.huge)
print('PASS present and delayed laser geometry')
-- Full dense room timing includes building indices; no forced garbage collection.
local start=os.clock();local queries,checks,records=0,0,0
for round=1,12 do
 ctx=context(player(0,0),11)
 for i=1,600 do local a=Vector((i%30)*35-500,math.floor(i/30)*35-350);Field.add(ctx.field,nil,a,a,13)end
 solve(ctx)
 queries=queries+ctx.field.queries;checks=checks+ctx.field.checks;records=records+ctx.field.records
end
print(string.format('BENCH 600 static patches: %.2f ms/update; records/update=%d checks/update=%.0f queries/update=%.0f (Linux Lua simulation)',(os.clock()-start)*1000/12,records/12,checks/12,queries/12))
-- Re-plan while the simulated character actually moves with slower controls.
-- This catches repeatedly postponing an escape despite favorable one-shot scores.
local sim=player(0,0);local queue={dirs[1],dirs[1]};local finalClear=0
for tick=1,45 do
 local c=context(sim,11,function(_,_,pos)return pos.Y>=0 end)
 for _,h in ipairs({{63,24,49},{52,76,24},{53,5,49},{-63,19,39}})do
  Field.add(c.field,nil,Vector(h[1],h[2]),Vector(h[1],h[2]),h[3])
 end
 local s,b=solve(c);local choice=s[1]<=0 and 1 or best(s,b)
 queue[#queue+1]=dirs[choice];local input=table.remove(queue,1)
 sim.Velocity=sim.Velocity*0.75+input*(6*sim.MoveSpeed*0.25)
 sim.Position=sim.Position+sim.Velocity
 if sim.Position.Y<0 then sim.Position=Vector(sim.Position.X,0);sim.Velocity=Vector(sim.Velocity.X,0)end
 local occupied=Field.sample(c.field,sim.Position,sim.Position,0)>0
 finalClear=occupied and 0 or finalClear+1
end
assert(finalClear>=15,'replanning never completed a stable escape')
print('PASS closed-loop delayed-control escape: final clear ticks='..finalClear)
-- Online input queue: the lag that explains applied-input changes is
-- learned, and queued inputs move the player before any candidate.
local Queue=module('input_queue')
local q=Queue.new();local seq={}
math.randomseed(77)
for f=1,400 do seq[f]=dirs[(f//9)%2==0 and 2 or 3+(f//18)%2] end
for f=1,400 do Queue.observe(q,f,seq[f],f>4 and seq[f-4] or dirs[1]) end
assert(q.delay==4,'online input delay not learned: '..Queue.summary(q))
local queued=Queue.pending(q);assert(#queued==4 and queued[4]==seq[400] and queued[1]==seq[397],'pending inputs misaligned')
ctx=context(player(0,0),11)
ctx.pending={dirs[2],dirs[2],dirs[2],dirs[2]};ctx.input=dirs[2]
local committed=Planner.path(ctx,dirs[3],ctx.models[1])
ctx.pending=nil;ctx.input=nil
local free=Planner.path(ctx,dirs[3],ctx.models[1])
assert(committed.endpoint.X<free.endpoint.X-30,'queued left inputs did not delay the right turn')
q=Queue.new();for f=1,200 do Queue.observe(q,f,seq[f],seq[f]) end
assert(q.delay==0 and #Queue.pending(q)==0,'offline play gained a queue')
print('PASS online input queue: lag 4 learned, pending order, committed motion, offline zero')
dofile('native/tests/main_integration.lua')
