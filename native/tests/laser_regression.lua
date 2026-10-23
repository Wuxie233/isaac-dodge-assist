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
-- Optional release comparison against a saved prior module. No production
-- dependency on the old source; deterministic fixtures remain above.
local baseline=os.getenv('IAD_LASER_BASELINE')
if baseline then
 local old=dofile(baseline)
 math.randomseed(920)
 local queries=0
 for i=1,400 do
  local points={}
  for j=1,math.random(2,20)do points[j]=Vector(math.random(-500,500),math.random(-500,500))end
  if i%7==0 then points[2]=points[1]end
  s=shape(points);s.reach=800
  s.origin=Vector(math.random(-600,600),math.random(-600,600))
  s.velocity=Vector(math.random(-15,15),math.random(-15,15))
  s.width=math.random(1,30);s.angularSpeed=math.random(-45,45);s.delay=math.random(0,8)+0.5
  s.ring=i%4==0;s.radius=math.random(1,200);s.activeFrom=i%5==0 and math.random(1,8) or nil
  for t=0,18 do
   local a=Vector(math.random(-700,700),math.random(-700,700))
   local b=a+Vector(math.random(-200,200),math.random(-200,200));local radius=math.random(1,20)
   -- Same snapshot, distinct cache lifetimes for the two implementations.
   s.sweeps=nil;local expected=old.clearance(s,a,b,t,radius);s.sweeps=nil
   close(L.clearanceXY(s,a.X,a.Y,b.X,b.Y,t,radius),expected)
   queries=queries+1
  end
 end
 print('PASS previous laser geometry differential: '..queries..' queries')
end
