-- Closed-loop dodge simulation: real main.lua sensor + a Lua port of the
-- native rank() + a world that follows the kinematics measured in game logs
-- (player 60Hz, 2 ticks per sensing update, retention 0.885, terminal
-- 4.0*MoveSpeed per tick; NPCs and projectiles move once per update).
-- Usage (from the project root):
--   lua5.3 native/tests/closed_loop_sim.lua <modDir|none> <latencyTicks> <seed> <scenario> [updates]
-- Prints one line: hits, takeovers and timing. Not a substitute for the game.
local modDir, latency, seed, scenario, updates = arg[1], tonumber(arg[2]), tonumber(arg[3]), arg[4], tonumber(arg[5] or 2400)
math.randomseed(seed)
local mt={};mt.__index=mt
function Vector(x,y) return setmetatable({X=x,Y=y},mt) end
function mt.__add(a,b)return Vector(a.X+b.X,a.Y+b.Y)end
function mt.__sub(a,b)return Vector(a.X-b.X,a.Y-b.Y)end
function mt.__mul(a,b)return Vector(a.X*b,a.Y*b)end
function mt.__tostring(a)return string.format("%.2f %.2f",a.X,a.Y)end
function mt:LengthSquared()return self.X*self.X+self.Y*self.Y end
function mt:Length()return math.sqrt(self:LengthSquared()) end
function mt:Dot(b)return self.X*b.X+self.Y*b.Y end
function mt:Resized(n)local l=self:Length();return l>0 and self*(n/l) or Vector(0,0)end
function mt:Normalized()return self:Resized(1)end
function mt:Distance(b)return (self-b):Length()end
function mt:Rotated(a)local r=math.rad(a);return Vector(self.X*math.cos(r)-self.Y*math.sin(r),self.X*math.sin(r)+self.Y*math.cos(r))end
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags','NpcState','TearFlags'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
-- Standard 1x1 room: 15x9 grid with a wall ring; interior x 40..560, y 40..320.
local W,H,LEFT,RIGHT,TOP,BOTTOM=15,9,40,560,40,320
local room={}
function room:GetGridWidth()return W end
function room:GetGridSize()return W*H end
function room:GetGridEntity()return nil end
function room:GetGridCollision(i)
 local x,y=i%W,i//W
 return (x==0 or y==0 or x==W-1 or y==H-1) and GridCollisionClass.COLLISION_WALL or 0
end
function room:GetGridIndex(p)
 local x,y=math.floor(p.X/40),math.floor(p.Y/40)
 if x<0 or y<0 or x>=W or y>=H then return -1 end
 return x+y*W
end
function room:GetGridPosition(i)return Vector((i%W)*40+20,(i//W)*40+20)end
function room:IsPositionInRoom(p,r)r=r or 0;return p.X-r>=LEFT and p.X+r<=RIGHT and p.Y-r>=TOP and p.Y+r<=BOTTOM end
function room:GetTopLeftPos()return Vector(LEFT,TOP)end
function room:GetBottomRightPos()return Vector(RIGHT,BOTTOM)end
local applied=Vector(0,0)
local p={Type=EntityType.ENTITY_PLAYER,Variant=0,SubType=0,Position=Vector(300,180),Velocity=Vector(0,0),
 Size=10,MoveSpeed=1,InitSeed=9,CanFly=false,ControllerIndex=0}
function p:GetPlayerType()return -1 end
function p:GetSubPlayer()return nil end
function p:IsSubPlayer()return false end
function p:IsDead()return false end
function p:IsCoopGhost()return false end
function p:AreControlsEnabled()return true end
function p:ToPlayer()return self end
function p:GetMovementInput()return applied end
local scene,callbacks,packet={}, {}, nil
function RegisterMod()return {AddCallback=function(_,kind,fn)callbacks[kind]=fn end}end
-- Optional tuning experiments: SIM_FAST_DELAY / SIM_SLOW_DELAY override the
-- response models' latency (ticks); SIM_F8 presses F8 that many times.
function include(name)
 local m=dofile(modDir..'/'..name..'.lua')
 if name=='player_motion' and (os.getenv('SIM_FAST_DELAY') or os.getenv('SIM_SLOW_DELAY')) then
  local models=m.models
  m.models=function(state)
   local a,b=models(state)
   a.delay=tonumber(os.getenv('SIM_FAST_DELAY') or a.delay);b.delay=tonumber(os.getenv('SIM_SLOW_DELAY') or b.delay)
   return a,b
  end
 end
 return m
end
function Game()return {GetNumPlayers=function()return 1 end,GetRoom=function()return room end,IsPaused=function()return false end}end
-- GetActionValue goes through the hooked device: the input entering the
-- online queue now (SIM_NO_POLL=1 hides it, like a build without the API).
ButtonAction={ACTION_LEFT=0,ACTION_RIGHT=1,ACTION_UP=2,ACTION_DOWN=3}
local polledInput=Vector(0,0)
Input={IsButtonPressed=function()return false end,IsButtonTriggered=function()return false end}
if not os.getenv('SIM_NO_POLL') then
 Input.GetActionValue=function(action)
  local v=polledInput
  if action==0 then return v.X<0 and -v.X or 0 elseif action==1 then return v.X>0 and v.X or 0
  elseif action==2 then return v.Y<0 and -v.Y or 0 else return v.Y>0 and v.Y or 0 end
 end
end
Isaac={GetTime=function()return os.clock()*1000 end,GetPlayer=function()return p end,
 GetRoomEntities=function()return scene end,RenderText=function()end,WorldToScreen=function(v)return v end,
 DebugString=function(s)
  if os.getenv('SIM_DEBUG') and s:find('^IAD KIN') then print(s) end
  local body=s:match('^IAD1|(.*)$')
  if body then
   local f={};for part in body:gmatch('[^|]+')do f[#f+1]=part end
   local r={};for n in f[6]:gmatch('[^,]+')do r[#r+1]=tonumber(n)end
   packet={active=f[3]=='1',risk=r,blocked=tonumber(f[7])}
  end
 end}
local assist=modDir~='none'
if assist then dofile(modDir..'/main.lua') else
 callbacks[ModCallbacks.MC_POST_UPDATE]=function()end;callbacks[ModCallbacks.MC_POST_GAME_STARTED]=function()end
end
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for _=1,tonumber(os.getenv('SIM_F8') or 0) do
 Input.IsButtonTriggered=function(key)return key==Keyboard.KEY_F8 end
 if callbacks[ModCallbacks.MC_POST_RENDER] then callbacks[ModCallbacks.MC_POST_RENDER]() end
 Input.IsButtonTriggered=function()return false end
end
-- Native rank(), ported from dodge_native.cpp (indices 1-based here).
local dx,dy={0,-1,1,0,0,-1,1,-1,1},{0,0,0,-1,1,-1,-1,1,1}
local function rank(risk,blocked,manual,x,y,previous)
 local best=manual
 if risk[manual]>0 then
  local score=risk[manual]
  for i=1,9 do
   if (blocked & (1<<(i-1)))==0 then
    local value=risk[i]+3*(math.abs(dx[i]-x)+math.abs(dy[i]-y))
    if value<score then score,best=value,i end
   end
  end
 end
 if best==manual or risk[best]>=risk[manual] then return nil end
 if previous and (blocked & (1<<(previous-1)))==0 and risk[previous]<risk[manual] and
  math.floor(risk[previous]/1048576)==math.floor(risk[best]/1048576) and risk[previous]<=risk[best]+65536 then return previous end
 return best
end
local dirs={}
for i=1,9 do dirs[i]=Vector(dx[i],dy[i]);if i>5 then dirs[i]=dirs[i]:Normalized()end end
-- World.
local seedCounter=100
local function base(kind)
 seedCounter=seedCounter+1
 local e={Type=kind,Variant=0,SubType=0,InitSeed=seedCounter,SpawnerType=-1,Position=Vector(0,0),Velocity=Vector(0,0),
  Size=13,Scale=1,SpriteScale=Vector(1,1),SizeMulti=Vector(1,1),CollisionDamage=1,
  EntityCollisionClass=EntityCollisionClass.ENTCOLL_ALL,SpriteOffset=Vector(0,0),FrameCount=0}
 for _,k in ipairs({'ToNPC','ToProjectile','ToBomb','ToLaser','ToEffect','ToTear'})do e[k]=function()return nil end end
 function e:IsDead()return false end;function e:HasEntityFlags()return false end
 function e:IsActiveEnemy()return false end;function e:IsBoss()return false end
 function e:GetSprite()return {GetAnimation=function()return 'Walk' end,GetFrame=function()return 0 end}end
 return e
end
local function npc(x,y,size,ai)
 local e=base(EntityType.ENTITY_NPC);e.Position=Vector(x,y);e.Size=size;e.ai=ai;e.timer=math.random(10,40)
 function e:ToNPC()return self end;function e:IsActiveEnemy()return true end
 return e
end
local function bullet(from,velocity)
 local e=base(EntityType.ENTITY_PROJECTILE);e.Position=from;e.Velocity=velocity;e.Size=5
 e.Height=-23;e.FallingSpeed=0;e.FallingAccel=-0.1
 function e:ToProjectile()return self end;function e:HasProjectileFlags()return false end
 return e
end
local npcs,bullets={},{}
local function edgePoint()
 local side=math.random(4)
 if side==1 then return LEFT+20,math.random(TOP+20,BOTTOM-20) elseif side==2 then return RIGHT-20,math.random(TOP+20,BOTTOM-20)
 elseif side==3 then return math.random(LEFT+20,RIGHT-20),TOP+20 else return math.random(LEFT+20,RIGHT-20),BOTTOM-20 end
end
local turrets,chasers,spread,period,shot,flies=0,0,1,36,9,0
if scenario=='turrets' then turrets=3
elseif scenario=='chasers' then chasers=2;turrets=1
elseif scenario=='spread' then turrets=2;spread=3;period=40
elseif scenario=='dense' then turrets=4;period=24;shot=8
elseif scenario=='flies' then flies=6 end
for _=1,turrets do local x,y=edgePoint();npcs[#npcs+1]=npc(x,y,13,'turret')end
for _=1,chasers do local x,y=edgePoint();npcs[#npcs+1]=npc(x,y,13,'chaser')end
for _=1,flies do local x,y=edgePoint();npcs[#npcs+1]=npc(x,y,9,'fly')end
-- Player physics and the human: wanders, re-choosing a direction every 0.5-1.5 s.
local F,K=0.885,4.0
local manual,manualLeft=1,0
local hits,overrides,ticks,invulnerable=0,0,0,0
local pending={}
-- Online play queues every local input (manual and native override) for a
-- fixed number of 60Hz ticks before it moves the player (SIM_INPUT_DELAY).
local inputDelay=tonumber(os.getenv('SIM_INPUT_DELAY') or 0)
local inputQueue={}
local current,previousChoice,previousAt=nil,nil,-1000
-- Damage classification from the packets actually used before each hit.
local packets,classes={},{late=0,trapped=0,chose_safe=0,ignored_safe=0}
local function classify()
 local first,safeSeen,choseSafe=nil,false,false
 for back=#packets,math.max(1,#packets-12),-1 do
  local q=packets[back]
  if not q or not q.active or q.manualRisk<=0 then break end
  first=back
  if q.bestRisk<=0 then safeSeen=true end
  if q.appliedRisk and q.appliedRisk<=0 then choseSafe=true end
 end
 local lead=first and (#packets-first+1) or 0
 local kind=lead<=2 and 'late' or (not safeSeen and 'trapped') or (choseSafe and 'chose_safe') or 'ignored_safe'
 classes[kind]=classes[kind]+1
end
local function collide()
 if invulnerable>0 then return end
 for i=#bullets,1,-1 do
  if bullets[i].Position:Distance(p.Position)<bullets[i].Size+p.Size then
   hits=hits+1;invulnerable=60;table.remove(bullets,i);classify();return
  end
 end
 for _,e in ipairs(npcs) do
  if e.Position:Distance(p.Position)<e.Size+p.Size then
   hits=hits+1;invulnerable=60;p.Velocity=(p.Position-e.Position):Resized(6);classify();return
  end
 end
end
local function tick()
 ticks=ticks+1
 while pending[1] and pending[1].at<=ticks do current=table.remove(pending,1) end
 local choice
 if current and current.active then
  local previous=(previousChoice and ticks-previousAt<=7) and previousChoice or nil
  choice=rank(current.risk,current.blocked,manual,dx[manual],dy[manual],previous)
  previousChoice,previousAt=choice,ticks
 end
 local chosen=dirs[choice or manual]
 polledInput=chosen
 inputQueue[#inputQueue+1]=chosen
 local direction=#inputQueue>inputDelay and table.remove(inputQueue,1) or dirs[1]
 if choice then overrides=overrides+1 end
 if ticks%2==0 then
  local q={active=current and current.active}
  if q.active then
   local best=math.huge
   for i=1,9 do if (current.blocked & (1<<(i-1)))==0 then best=math.min(best,current.risk[i]) end end
   q.manualRisk,q.bestRisk,q.appliedRisk=current.risk[manual],best,current.risk[choice or manual]
  end
  packets[#packets+1]=q
 end
 applied=direction
 local target=direction*(K*p.MoveSpeed)
 local v=p.Velocity*F+target*(1-F)
 local x,y=p.Position.X+v.X,p.Position.Y+v.Y
 if x-p.Size<LEFT then x,v=LEFT+p.Size,Vector(0,v.Y) elseif x+p.Size>RIGHT then x,v=RIGHT-p.Size,Vector(0,v.Y) end
 if y-p.Size<TOP then y,v=TOP+p.Size,Vector(v.X,0) elseif y+p.Size>BOTTOM then y,v=BOTTOM-p.Size,Vector(v.X,0) end
 p.Position,p.Velocity=Vector(x,y),v
 if invulnerable>0 then invulnerable=invulnerable-1 end
 collide()
end
local function worldUpdate()
 for i=#bullets,1,-1 do
  local b=bullets[i];b.Position=b.Position+b.Velocity;b.FrameCount=b.FrameCount+1
  if not room:IsPositionInRoom(b.Position,0) then table.remove(bullets,i) end
 end
 for _,e in ipairs(npcs) do
  if e.ai=='turret' then
   e.timer=e.timer-1
   if e.timer<=0 then
    e.timer=period+math.random(-6,6)
    local aim=(p.Position-e.Position):Normalized()
    for s=1,spread do
     local angle=(s-(spread+1)/2)*20+math.random(-4,4)
     bullets[#bullets+1]=bullet(e.Position+aim*15,aim:Rotated(angle)*shot)
    end
   end
  elseif e.ai=='fly' then
   -- Attack-fly-like: slow pursuit with a random wobble that changes often.
   if math.random()<0.15 then e.wobble=Vector(math.random()*2-1,math.random()*2-1):Resized(2.2) end
   local toward=(p.Position-e.Position):Resized(2.4)+(e.wobble or Vector(0,0))
   e.Velocity=e.Velocity*0.7+toward*0.3
   e.Position=e.Position+e.Velocity
  else
   local toward=(p.Position-e.Position):Resized(3.6)
   e.Velocity=e.Velocity*0.8+toward*0.2
   e.Position=e.Position+e.Velocity
  end
 end
 scene={}
 for _,e in ipairs(npcs)do scene[#scene+1]=e end
 for _,b in ipairs(bullets)do scene[#scene+1]=b end
end
local started=os.clock()
for update=1,updates do
 manualLeft=manualLeft-1
 if manualLeft<=0 then manual=math.random()<0.2 and 1 or math.random(2,9);manualLeft=math.random(15,45)end
 tick();tick()
 collide()
 worldUpdate()
 collide()
 packet=nil
 callbacks[ModCallbacks.MC_POST_UPDATE]()
 -- The packet affects ticks after `latency` further ticks.
 if packet then pending[#pending+1]={at=ticks+latency+1,active=packet.active,risk=packet.risk,blocked=packet.blocked} end
end
if assist and callbacks[ModCallbacks.MC_PRE_GAME_EXIT] then callbacks[ModCallbacks.MC_PRE_GAME_EXIT]() end
print(string.format("mod=%s latency=%d seed=%d scenario=%s updates=%d hits=%d per_min=%.2f override_ticks=%.1f%% ms/update=%.2f",
 modDir,latency,seed,scenario,updates,hits,hits*1800/updates,overrides*100/ticks,(os.clock()-started)*1000/updates)..
 string.format(" late=%d trapped=%d chose_safe=%d ignored_safe=%d",classes.late,classes.trapped,classes.chose_safe,classes.ignored_safe))
