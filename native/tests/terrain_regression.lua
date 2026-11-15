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

local Terrain=dofile('mod/isaac_dodge_assist/terrain_snapshot.lua')
GridCollisionClass={COLLISION_NONE=0,COLLISION_WALL=1,COLLISION_SOLID=2,COLLISION_WALL_EXCEPT_PLAYER=3,COLLISION_PIT=4}
local directions={Vector(0,0),Vector(-1,0),Vector(1,0),Vector(0,-1),Vector(0,1),Vector(-1,-1):Normalized(),Vector(1,-1):Normalized(),Vector(-1,1):Normalized(),Vector(1,1):Normalized()}
local room={width=14,height=10,ox=-40,oy=0,cells={},calls=0,shape='rectangle'}
function room:GetGridWidth()return self.width end
function room:GetGridSize()return self.width*self.height end
function room:GetGridPosition(i)return Vector(self.ox+(i%self.width)*40,self.oy+math.floor(i/self.width)*40)end
function room:GetGridIndex(p)
 local x,y=math.floor((p.X-self.ox)/40+.5),math.floor((p.Y-self.oy)/40+.5)
 if x<0 or y<0 or x>=self.width or y>=self.height then return -1 end
 return x+y*self.width
end
function room:GetGridCollision(i)return self.cells[i] or 0 end
function room:IsPositionInRoom(p,r)
 self.calls=self.calls+1
 if p.X-r<self.ox-20 or p.Y-r<self.oy-20 or p.X+r>=self.ox+(self.width-.5)*40 or p.Y+r>=self.oy+(self.height-.5)*40 then return false end
 if self.shape=='L' then
  -- Missing lower right quadrant; exact distance to its closed corner/edges.
  local dx,dy=math.max(0,240-p.X),math.max(0,200-p.Y)
  if (p.X>=240 and p.Y>=200) or dx*dx+dy*dy<=r*r then return false end
 end
 return true
end
local function old(player,pos)
 for _,d in ipairs(directions)do
  local q=pos+d*math.max(2,player.Size-1)
  if not room:IsPositionInRoom(q,0)then return false end
  local index=room:GetGridIndex(q)
  local c=room:GetGridCollision(index)
  if c==1 or (not player.CanFly and c~=0 and c~=3) then return false end
  if c==2 and player.CanFly then
   local ge=room.GetGridEntity and room:GetGridEntity(index)
   if ge and GridEntityType and GridEntityType.GRID_LOCK and ge:GetType()==GridEntityType.GRID_LOCK then return false end
  end
 end
 return true
end
math.randomseed(917)
for i=0,room:GetGridSize()-1 do if i%7==0 then room.cells[i]=i%5 end end
local checked=0
for _,shape in ipairs({'rectangle','L'})do
 room.shape=shape
 for _,size in ipairs({2,5,12,30,55})do for _,fly in ipairs({false,true})do
  local p={Size=size,CanFly=fly};local cache=Terrain.new(room,p,directions)
  for i=1,1200 do
   local pos=Vector(math.random(-60,499)+.25,math.random(-20,379)+.125)
   assert(Terrain.safe(cache,pos.X,pos.Y)==old(p,pos),'footprint cache disagrees with original at '..pos.X..','..pos.Y)
   checked=checked+1
  end
  -- Exact grid edges and footprint offsets must agree as well.
  for _,x in ipairs({-20,20,60,100,220,240,260})do for _,y in ipairs({20,60,180,200,220})do
   assert(Terrain.safe(cache,x,y)==old(p,Vector(x,y)),'grid edge differs')
  end end
 end end
end
room.shape='rectangle';room.cells={}
local p={Size=5,CanFly=false};local at=room:GetGridIndex(Vector(100,100))
local first=Terrain.new(room,p,directions);assert(Terrain.safe(first,100,100))
room.cells[at]=2;local second=Terrain.new(room,p,directions);assert(not Terrain.safe(second,100,100),'new obstacle stale')
room.cells[at]=0;local third=Terrain.new(room,p,directions);assert(Terrain.safe(third,100,100),'destroyed obstacle stale')
room.cells[at]=4;p.CanFly=true;assert(Terrain.safe(Terrain.new(room,p,directions),100,100),'flight over pit failed')
p.CanFly=false;assert(not Terrain.safe(Terrain.new(room,p,directions),100,100),'lost flight cached incorrectly')
do
 GridEntityType=GridEntityType or {GRID_LOCK=11}
 local rockRoom={
  GetTopLeftPos=function()return Vector(60,140)end,
  GetBottomRightPos=function()return Vector(580,420)end,
  GetGridWidth=function()return 15 end,
  GetGridSize=function()return 135 end,
  GetGridPosition=function(_,i)return Vector((i%15)*40+40,math.floor(i/15)*40+120)end,
  GetGridIndex=function(_,v)return math.floor((v.Y-100)/40)*15+math.floor((v.X-20)/40)end,
  GetGridCollision=function(_,i)
   local cx,cy=i%15,math.floor(i/15)
   if cx<=0 or cx>=14 or cy<=0 or cy>=8 then return GridCollisionClass.COLLISION_WALL end
   if i==65 or i==67 then return GridCollisionClass.COLLISION_SOLID end
   return GridCollisionClass.COLLISION_NONE
  end,
  GetGridEntity=function(_,i)
   if i==67 then return {GetType=function()return GridEntityType.GRID_LOCK end} end
   return nil
  end,
  IsPositionInRoom=function(_,v,m)m=m or 0;return v.X>=60+m and v.X<=580-m and v.Y>=140+m and v.Y<=420-m end,
 }
 -- index 65 = col 5 row 4 => center (240, 280); index 67 = col 7 row 4 => center (320, 280).
 local pf={Position=Vector(200,280),Size=10,CanFly=true}
 local tf=Terrain.new(rockRoom,pf,directions)
 assert(Terrain.safe(tf,240,280),'flying player must cross COLLISION_SOLID rock')
 assert(not Terrain.safe(tf,320,280),'flying player must be blocked by GRID_LOCK Key Block')
 pf.CanFly=false
 local tw=Terrain.new(rockRoom,pf,directions)
 assert(not Terrain.safe(tw,240,280),'walking player must be blocked by COLLISION_SOLID rock')

 -- Beast room sky: beyond normal grid/room bounds (gridIndex=-1, col=0) must remain traversable when opts.beast=true.
 local beastRoom={
  GetTopLeftPos=function()return Vector(60,140)end,
  GetBottomRightPos=function()return Vector(580,420)end,
  GetGridWidth=function()return 15 end,
  GetGridSize=function()return 135 end,
  GetGridPosition=function(_,i)return Vector((i%15)*40+40,math.floor(i/15)*40+120)end,
  GetGridIndex=function()return -1 end,
  GetGridCollision=function()return GridCollisionClass.COLLISION_NONE end,
  GetGridEntity=function()return nil end,
  IsPositionInRoom=function()return false end,
 }
 pf.CanFly=true
 local tb=Terrain.new(beastRoom,pf,directions,{beast=true})
 assert(Terrain.safe(tb,566,464),'Beast sky must be traversable when opts.beast=true')
 assert(not Terrain.safe(tb,566,492),'Beast deep void below screen floor must remain blocked')
end
print('PASS terrain cache vs original: '..checked..' random footprints, exact grid edges, L rooms, flight, SOLID/GRID_LOCK, Beast sky')
