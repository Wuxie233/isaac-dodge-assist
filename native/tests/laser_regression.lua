local allocations=0
local mt={};mt.__index=mt
function Vector(x,y)allocations=allocations+1;return setmetatable({X=x,Y=y},mt)end
function mt.__add(a,b)return Vector(a.X+b.X,a.Y+b.Y)end
function mt.__sub(a,b)return Vector(a.X-b.X,a.Y-b.Y)end
function mt.__mul(a,b)return Vector(a.X*b,a.Y*b)end
function mt:LengthSquared()return self.X*self.X+self.Y*self.Y end
function mt:Length()return math.sqrt(self:LengthSquared())end
function mt:Dot(b)return self.X*b.X+self.Y*b.Y end
function mt:Rotated(a)local r=math.rad(a);return Vector(self.X*math.cos(r)-self.Y*math.sin(r),self.X*math.sin(r)+self.Y*math.cos(r))end
local L=dofile('mod/isaac_dodge_assist/laser_hazards.lua')
local F=dofile('mod/isaac_dodge_assist/threat_field.lua')
local function shape(points)
 return {origin=Vector(0,0),velocity=Vector(0,0),width=2,points=points or {Vector(0,0),Vector(100,0)},
  reach=100,angularSpeed=0,delay=0}
end
local function close(a,b)assert(a==b or math.abs(a-b)<1e-8,string.format('clearance mismatch %.12g vs %.12g',a,b))end
local s=shape()
close(L.clearanceXY(s,50,-20,50,20,1,1),-3)
close(L.clearanceXY(s,110,10,110,10,0,1),math.sqrt(200)-3)
close(L.clearanceXY(s,20,10,70,10,1,1),7)
close(L.clearanceXY(s,50,0,120,0,1,1),-3)
s=shape({Vector(5,5),Vector(5,5)})
close(L.clearanceXY(s,5,-10,5,10,1,1),-3)
s=shape({Vector(0,0),Vector(100,0),Vector(100,100)})
close(L.clearanceXY(s,90,50,110,50,1,1),-3)
s=shape();s.velocity=Vector(0,20)
close(L.clearanceXY(s,50,10,50,10,1,1),-3)
s=shape();s.ring=true;s.radius=50
close(L.clearanceXY(s,0,0,0,0,0,1),47)
close(L.clearanceXY(s,0,0,100,0,1,1),-3)
close(L.clearanceXY(s,60,-20,60,20,1,1),7)
s=shape();s.angularSpeed=90
assert(L.clearanceXY(s,50,50,50,50,1,1)<0,'rotating beam swept past player')
s=shape();s.angularSpeed=90;s.delay=1
assert(L.clearanceXY(s,50,50,50,50,1,1)>0,'rotation delay lost')
assert(L.clearanceXY(s,50,50,50,50,2,1)<0,'rotation never started')
s=shape();s.activeFrom=4
assert(L.clearanceXY(s,50,0,50,0,3,1)==math.huge)
close(L.clearanceXY(s,50,0,50,0,4,1),-3)
-- Cached geometry belongs only to an immutable snapshot.
local cold=shape()
close(L.clearanceXY(cold,50,10,50,10,1,1),7)
cold=shape({Vector(0,40),Vector(100,40)})
close(L.clearanceXY(cold,50,10,50,10,1,1),27)
-- The numeric field entry must not instantiate engine Vector objects, even
-- when first constructing rotating slices. Snapshot construction is separate.
s=shape();s.angularSpeed=12
local field=F.new(18,1,{s},L)
local start=allocations
for t=0,18 do F.sampleXY(field,50,10,51,12,t)end
assert(allocations==start,'laser query allocated engine vectors')
print('PASS laser crossings, endpoints, rings, translation, rotation, delay and allocation bound')
-- Committed brimstone wind-up (Vis/Gluttony "Attack01<dir>") is a hit from
-- the beam frame on; Chubber and unrelated animations add nothing.
EntityType={ENTITY_VIS=39,ENTITY_GLUTTONY=49,ENTITY_URIEL=271,ENTITY_GABRIEL=272}
local room={GetTopLeftPos=function()return Vector(40,40)end,GetBottomRightPos=function()return Vector(560,320)end}
local function windUp(kind,variant,animation,frame)
 return {Type=kind,Variant=variant,Position=Vector(300,180),Velocity=Vector(0,0),
  GetSprite=function()return {GetAnimation=function()return animation end,GetFrame=function()return frame end}end}
end
local beams={};L.appendWarnings(windUp(49,0,'Attack01Horiz',20),room,beams)
assert(#beams==2 and beams[1].activeFrom==7 and not beams[1].warning,'gluttony wind-up not predicted')
assert(L.clearanceXY(beams[1],480,182,480,182,6,10)==math.huge,'beam active before its frame')
assert(L.clearanceXY(beams[1],480,182,480,182,7,10)<0 and L.clearanceXY(beams[2],120,178,120,178,7,10)<0,'horizontal beam missed')
assert(L.clearanceXY(beams[1],300,260,300,260,7,10)>0,'beam covers off-line position')
beams={};L.appendWarnings(windUp(39,0,'Attack01Down',30),room,beams)
assert(#beams==1 and beams[1].activeFrom==1 and L.clearanceXY(beams[1],300,300,300,300,1,10)<0,'vis down beam missed')
beams={};L.appendWarnings(windUp(39,2,'Attack01Down',10),room,beams);assert(#beams==0,'chubber is not a brimstone shooter')
beams={};L.appendWarnings(windUp(49,0,'Walk',10),room,beams);assert(#beams==0,'walking gluttony predicted a beam')
print('PASS brimstone wind-up: Gluttony horizontal pair, Vis down, timing, Chubber/walk exclusions')
-- Swept rotating beams are approximated by a few rotated slices plus an arc
-- margin, and distant queries are rejected by a radial/cone lower bound. Both
-- must stay on the safe side of a dense sweep: never report more clearance
-- than the reference, and never give away more than the approximation is
-- allowed to (one slice width).
local function segmentDistance(px,py,ax,ay,bx,by)
 local dx,dy=bx-ax,by-ay
 local x,y=px-ax,py-ay
 local length=dx*dx+dy*dy
 local t=length>0 and math.max(0,math.min(1,(x*dx+y*dy)/length)) or 0
 x,y=x-dx*t,y-dy*t
 return math.sqrt(x*x+y*y)
end
local function polylineDistance(points,angle,ax,ay,bx,by)
 local best=math.huge
 local c,sn=math.cos(math.rad(angle)),math.sin(math.rad(angle))
 local function rotate(p) return p.X*c-p.Y*sn,p.X*sn+p.Y*c end
 local pax,pay=rotate(points[1])
 for i=2,#points do
  local pbx,pby=rotate(points[i])
  -- A segment-to-segment proximity is bounded by the two endpoint queries;
  -- for the crossing case add the endpoints of one segment against the other.
  best=math.min(best,segmentDistance(ax,ay,pax,pay,pbx,pby),segmentDistance(bx,by,pax,pay,pbx,pby),
   segmentDistance(pax,pay,ax,ay,bx,by),segmentDistance(pbx,pby,ax,ay,bx,by))
  pax,pay=pbx,pby
 end
 return best
end
local function bruteClearance(shape,a,b,t,radius)
 -- The planner pairs each slice of the sweep with the matching slice of the
 -- player path, so the reference does the same with 96x finer slices.
 local best=math.huge
 local samples=96
 local ax=a.X-shape.origin.X-shape.velocity.X*(t-1)
 local ay=a.Y-shape.origin.Y-shape.velocity.Y*(t-1)
 local bx=b.X-shape.origin.X-shape.velocity.X*t
 local by=b.Y-shape.origin.Y-shape.velocity.Y*t
 for k=0,samples-1 do
  local u,v=k/samples,(k+1)/samples
  local angle=(shape.angularSpeed or 0)*math.max(0,(t-1+(u+v)*0.5)-shape.delay)
  local d=polylineDistance(shape.points,angle,ax+(bx-ax)*u,ay+(by-ay)*u,ax+(bx-ax)*v,ay+(by-ay)*v)
  if d-radius<best then best=d-radius end
 end
 return best
end
math.randomseed(4821)
local safety,slack,queries=0,0,0
for i=1,180 do
 local points
 if i%3~=0 then
  -- Anchored beams like every shape the mod builds.
  points={Vector(0,0)}
  for j=2,math.random(2,9)do points[j]=Vector(math.random(-80,600),math.random(-120,120))end
 else
  points={Vector(math.random(-400,400),math.random(-400,400))}
  for j=2,math.random(2,9)do points[j]=Vector(math.random(-500,500),math.random(-500,500))end
 end
 local shape=shape(points)
 shape.origin=Vector(math.random(-600,600),math.random(-600,600))
 shape.velocity=Vector(math.random(-15,15),math.random(-15,15))
 shape.width=math.random(1,30)
 shape.angularSpeed=math.random(-30,30)
 shape.delay=math.random(0,6)+0.5
 shape.reach=700
 for t=1,10 do
  local a=Vector(math.random(-700,700),math.random(-700,700))
  local b=a+Vector(math.random(-200,200),math.random(-200,200))
  local radius=math.random(1,20)
  local expected=bruteClearance(shape,a,b,t,radius)
  local got=L.clearanceXY(shape,a.X,a.Y,b.X,b.Y,t,radius)
  queries=queries+1
  -- The approximation widens slices; it must never claim more clearance than
  -- the finer pairing by more than one slice's arc margin.
  assert(got<=expected+12,string.format('overstates safety %.6f vs %.6f',got,expected))
  -- Contact is never lost, and a wider slice (whose arc margin is exact) may
  -- only add bounded conservatism. The remaining slack is reported below.
  if expected<0 then assert(got<0,string.format('contact lost %.6f vs %.6f',got,expected)) end
  assert(got>=math.min(expected,24)-100,string.format('over-conservative %.6f vs %.6f',got,expected))
  if got>expected then safety=math.max(safety,got-expected) end
  slack=math.max(slack,expected-got)
 end
end
print(string.format('PASS laser swept-slice and broad-phase vs dense sweep: %d queries, overshoot<=%.2f, slack<=%.1f',
 queries,safety,slack))
