-- Hot reload through the real loader (main.lua) and core (core.lua): a new
-- build swaps in place and keeps settings, the bound player and the IAD1
-- sequence; a build that fails to load is skipped; a build that errors at
-- run time rolls back to the previous one.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','EffectVariant','EntityCollisionClass','GridCollisionClass','GridEntityType','EntityFlag','PlayerType','ModCallbacks','Keyboard','BombVariant','ProjectileFlags','ButtonAction'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
local callbacks,logs={}, {}
function RegisterMod()return {AddCallback=function(_,kind,fn)callbacks[kind]=fn end}end
local build,coreOverride='A',nil
function include(name)
 if name=='iad_version' then return build and {build=build} or 'iad_version.lua: no such file' end
 if name=='core' and coreOverride then return coreOverride() end
 return dofile('mod/isaac_dodge_assist/'..name..'.lua')
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
function p.GetMovementInput()return Vector(0,0)end
local pressed=nil
Input={IsButtonPressed=function()return false end,IsButtonTriggered=function(k)return k==pressed end,
 GetActionValue=function()return 0 end}
local labels={}
function Game()return {GetNumPlayers=function()return 1 end,GetRoom=function()return room end,IsPaused=function()return false end}end
Isaac={GetTime=function()return os.clock()*1000 end,GetPlayer=function()return p end,
 GetRoomEntities=function()return {} end,DebugString=function(s)logs[#logs+1]=s end,
 RenderText=function(text)labels[#labels+1]=text end,WorldToScreen=function(v)return v end}
local loader=dofile('mod/isaac_dodge_assist/main.lua')
local function tick()callbacks[ModCallbacks.MC_POST_UPDATE]()end
local function render()callbacks[ModCallbacks.MC_POST_RENDER]()end
local function press(key)pressed=key;render();pressed=nil end
local function lastPacket()
 for i=#logs,1,-1 do
  if logs[i]:sub(1,5)=='IAD1|' then
   local f={};for part in logs[i]:gmatch('[^|]+')do f[#f+1]=part end
   return f
  end
 end
end
local function logged(text)
 for _,line in ipairs(logs)do if line:find(text,1,true)then return true end end
 return false
end
callbacks[ModCallbacks.MC_POST_GAME_STARTED]()
for _=1,6 do tick()end
assert(loader.build()=='A' and logged('IAD: sensor 0.16.0 build A loaded'),'cold start')
press(Keyboard.KEY_F8)   -- 450 -> 600
press(Keyboard.KEY_F10)  -- OFF -> AIM
press(Keyboard.KEY_LEFT_SHIFT) -- pause
tick()
local before=lastPacket()
assert(before[6]=='600' and before[4]=='0','settings before reload: '..table.concat(before,'|'))
local seq=tonumber(before[2])

-- A new build is picked up by the render poll (every 60 renders).
build='B'
for _=1,60 do render()end
assert(loader.build()=='B' and logged('IAD LOADER: reloaded A -> B'),'reload not applied')
assert(logged('IAD: sensor 0.16.0 build B reloaded'),'new core did not announce itself')
tick()
local after=lastPacket()
assert(tonumber(after[2])>seq,'IAD1 sequence went backwards across reload')
assert(after[6]=='600' and after[4]=='0','settings lost across reload: '..table.concat(after,'|'))
assert(labels[#labels]:find('+B',1,true) or labels[#labels-1]:find('+B',1,true),'HUD does not show the build')
press(Keyboard.KEY_LEFT_SHIFT);tick()  -- resume
press(Keyboard.KEY_F10)                 -- AIM -> AUTO: combat mode survived
assert(logs[#logs]=='IAD COMBAT: AUTO','combat mode lost across reload: '..logs[#logs])
press(Keyboard.KEY_F10)                 -- back to OFF
print('PASS hot reload: build swap, settings, pause, combat mode and IAD1 sequence carried over')

-- A build whose core does not load (syntax error: include returns text).
build='C';coreOverride=function()return 'core.lua:12: unexpected symbol near )' end
for _=1,60 do render()end
assert(loader.build()=='B' and logged("IAD LOADER: build C did not load, keeping B"),'broken build replaced the running one')
tick();assert(lastPacket()[4]=='1','sensor stopped after a failed load')
for _=1,120 do render()end
local attempts=0
for _,line in ipairs(logs)do if line:find('build C did not load',1,true)then attempts=attempts+1 end end
assert(attempts==1,'failed build retried: '..attempts)
print('PASS hot reload: a build that fails to load is skipped once and the old core keeps running')

-- A build that loads but errors at run time rolls back within probation.
build='D'
local real=dofile('mod/isaac_dodge_assist/core.lua')
coreOverride=function()
 return function(mod,saved,id)
  local api=real({AddCallback=function(self,kind,fn,param)
   if kind==ModCallbacks.MC_POST_UPDATE then fn=function()error('boom in update')end end
   mod:AddCallback(kind,fn,param)
  end},saved,id)
  return api
 end
end
for _=1,60 do render()end
assert(loader.build()=='D','runtime-broken build not loaded')
local seqD=tonumber(lastPacket()[2])
tick()
assert(loader.build()=='B' and logged('IAD LOADER: build D failed, back to B'),'no rollback after a runtime error')
assert(logged('IAD LOADER: core error: '),'runtime error not logged')
tick()
assert(tonumber(lastPacket()[2])>seqD and lastPacket()[4]=='1','rolled-back core did not continue the sequence')
for _=1,120 do render()end
assert(loader.build()=='B','rolled-back build was loaded again')
print('PASS hot reload: runtime error rolls back to the previous build with an increasing IAD1 sequence')
