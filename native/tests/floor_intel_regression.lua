-- Floor intel (0.21): floor map cells and dimensions, layout loot of
-- unvisited rooms, seen items, reward rocks and the floor score, through a
-- stub of the read-only level API.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
for _,name in ipairs({'EntityType','GridCollisionClass'})do _G[name]=enum()end
GridCollisionClass.COLLISION_NONE=0
EntityType.ENTITY_PICKUP=5
RoomType={ROOM_DEFAULT=1,ROOM_SHOP=2,ROOM_TREASURE=4,ROOM_BOSS=5,ROOM_SECRET=7,ROOM_SUPERSECRET=8,ROOM_SACRIFICE=13,
 ROOM_PLANETARIUM=24,ROOM_ULTRASECRET=29}
PickupVariant={PICKUP_HEART=10,PICKUP_COIN=20,PICKUP_KEY=30,PICKUP_BOMB=40,PICKUP_CHEST=50,PICKUP_PILL=70,PICKUP_COLLECTIBLE=100,
 PICKUP_TAROTCARD=300}
CoinSubType={COIN_PENNY=1,COIN_NICKEL=2,COIN_DIME=3}
HeartSubType={HEART_FULL=1,HEART_SOUL=3}
GridEntityType={GRID_ROCK=2,GRID_ROCKT=4,GRID_ROCK_ALT=6,GRID_ROCK_SS=22,GRID_ROCK_ALT2=26,GRID_ROCK_GOLD=27}
function include(name)return dofile('mod/isaac_dodge_assist/'..name..'.lua')end
local FloorMap=include('floor_map')
local FloorIntel=include('floor_intel')
local FloorScore=include('floor_score')

-- Shapes: cells relative to SafeGridIndex; LTL's safe cell is its top-right.
local function same(cells,expected)
 if #cells~=#expected then return false end
 for i,c in ipairs(cells)do if c[1]~=expected[i][1] or c[2]~=expected[i][2] then return false end end
 return true
end
assert(same(FloorMap.cells(6*13+6,1),{{6,6}}),'1x1')
assert(same(FloorMap.cells(2*13+5,8),{{5,2},{6,2},{5,3},{6,3}}),'2x2')
assert(same(FloorMap.cells(3*13+7,9),{{7,3},{6,4},{7,4}}),'LTL anchors on the top-right cell')
assert(same(FloorMap.cells(3*13+7,12),{{7,3},{8,3},{7,4}}),'LBR')

-- A level: start room, a treasure room, an unvisited secret room with three
-- pills and a weighted coin/key spawn, a boss room, a room of another
-- dimension at the same index, and a super secret room with a tinted rock
-- placed by its layout.
local function spawn(entries)
 local sum=0;for _,e in ipairs(entries)do sum=sum+e[4] end
 return {SumWeights=sum,EntryCount=#entries,PickEntry=function(_,r)
  local acc=0
  for _,e in ipairs(entries)do
   acc=acc+e[4]/sum
   if r<acc-1e-9 then return {Type=e[1],Variant=e[2],Subtype=e[3],Weight=e[4]} end
  end
  local e=entries[#entries];return {Type=e[1],Variant=e[2],Subtype=e[3],Weight=e[4]}
 end}
end
local function spawns(list)return {Size=#list,Get=function(_,i)return list[i+1] end}end
local function desc(index,safe,shape,kind,visited,list)
 return {ListIndex=index,SafeGridIndex=safe,GridIndex=safe,VisitedCount=visited and 1 or 0,Clear=visited,
  SpawnSeed=1000+index,AwardSeed=2000+index,Flags=0,
  Data={Type=kind,Variant=index,Subtype=0,Shape=shape,Spawns=spawns(list or {})}}
end
local rooms={
 desc(0,6*13+6,1,RoomType.ROOM_DEFAULT,true),
 desc(1,6*13+7,1,RoomType.ROOM_TREASURE,false,{spawn({{5,100,0,1}})}),
 desc(2,5*13+6,1,RoomType.ROOM_SECRET,false,{spawn({{5,70,0,1}}),spawn({{5,70,0,1}}),spawn({{5,70,0,1}}),
  spawn({{5,20,1,1},{5,30,1,1}}),spawn({{10,0,0,1}})}),
 desc(3,6*13+5,9,RoomType.ROOM_BOSS,false),
 desc(4,5*13+6,1,RoomType.ROOM_DEFAULT,false),
 desc(5,7*13+8,1,RoomType.ROOM_SUPERSECRET,false,{spawn({{1003,0,0,1}}),spawn({{1000,0,0,1}})}),
}
local byIndex={}
for _,d in ipairs(rooms)do if d.ListIndex~=4 then byIndex[d.SafeGridIndex]=d end end
local current=rooms[1]
function GetPtrHash(x)return x and (x.ListIndex or -1)+1000 or 0 end
local level={GetRooms=function()return {Size=#rooms,Get=function(_,i)return rooms[i+1] end}end,
 GetRoomByIdx=function(_,i)return byIndex[i] or {} end,GetCurrentRoomDesc=function()return current end,
 GetPlanetariumChance=function()return 0.25 end}
local floorMap=FloorMap.scan(level,function(i,d)return FloorMap.layout(d,FloorIntel.lootKind)end)
assert(#floorMap.rooms==5,'other-dimension room not filtered: '..#floorMap.rooms)
assert(floorMap.current==0,'current room')
local secret
for _,r in ipairs(floorMap.rooms)do if r.type==RoomType.ROOM_SECRET then secret=r end end
assert(secret.label=='S' and secret.layout,'secret room not labelled or layout missing')
assert(math.abs(secret.layout.loot.pill-3)<1e-9 and math.abs(secret.layout.loot.coin-0.5)<1e-9 and
 math.abs(secret.layout.loot.key-0.5)<1e-9,'weighted layout loot')
for _,r in ipairs(floorMap.rooms)do
 if r.type==RoomType.ROOM_TREASURE then assert(r.layout.pedestals==1,'treasure pedestal') end
 if r.type==RoomType.ROOM_SUPERSECRET then assert(r.layout.loot.tinted==1,'layout tinted rock') end
 if r.type==RoomType.ROOM_DEFAULT then assert(r.layout==nil,'visited room keeps a layout') end
end
print('PASS floor map: shapes (LTL anchor), dimension filter, labels, weighted layout loot')

-- Score: unseen treasure + boss items, the secret room's pills and loot,
-- the layout tinted rock; then the treasure room seen with a quality 4.
local score=FloorScore.evaluate(floorMap.rooms,{},{})
local expected=2*FloorScore.UNSEEN_ITEM
local lootPoints=3*FloorScore.LOOT.pill+0.5*FloorScore.LOOT.coin+0.5*FloorScore.LOOT.key+FloorScore.LOOT.tinted
assert(math.abs(score.items-expected)<1e-9 and math.abs(score.loot-lootPoints)<1e-9,'score parts: '..score.items..' '..score.loot)
assert(score.unseen==2,'unseen count: '..score.unseen)
for _,r in ipairs(floorMap.rooms)do if r.type==RoomType.ROOM_TREASURE then r.visited=true end end
score=FloorScore.evaluate(floorMap.rooms,{[1]={{id=182,quality=4,name='Sacred Heart'}}},{})
assert(math.abs(score.items-(FloorScore.ITEM[4]+FloorScore.UNSEEN_ITEM))<1e-9,'seen item value')
assert(score.entries[1].id==182 and score.entries[1].quality==4 and score.entries[1].roomType==RoomType.ROOM_TREASURE,'item entry')
-- Shop items and deals are worth less than free ones.
score=FloorScore.evaluate({{index=9,type=RoomType.ROOM_SHOP,visited=true,label='$',cells={}}},
 {[9]={{id=1,quality=2,price=15},{id=2,quality=2,devil=true}}},{})
assert(math.abs(score.items-FloorScore.ITEM[2]*(FloorScore.SHOP+FloorScore.DEVIL))<1e-9,'priced items')
assert(FloorIntel.readableName('#THE_SAD_ONION_NAME')=='The Sad Onion' and FloorIntel.readableName('Modded')=='Modded','names')
-- 0.25.5 room list: what each resource room gives, rooms not entered first.
local listed=FloorScore.evaluate({{index=1,type=RoomType.ROOM_TREASURE,visited=true,cells={}},
 {index=2,type=RoomType.ROOM_SECRET,visited=false,cells={},layout={pedestals=0,shop=0,loot={pill=3}}},
 {index=3,type=RoomType.ROOM_DEFAULT,visited=false,cells={},layout={pedestals=0,shop=0,loot={coin=2}}},
 {index=4,type=RoomType.ROOM_DEFAULT,visited=false,cells={},layout={pedestals=0,shop=0,loot={chest=1}}}},
 {[1]={{id=182,quality=4}}},{})
local order={};for _,r in ipairs(listed.roomList)do order[#order+1]=r.index end
assert(table.concat(order,',')=='2,4,1','room list order: '..table.concat(order,','))
assert(listed.roomList[1].loot.pill==3 and listed.roomList[3].items[1].id==182,'room list content')
print('PASS floor score: unseen pedestals, layout loot, seen qualities, shop and deal prices, item names')

-- 0.24 access: what it takes to get into a room not entered yet.
local A=FloorScore.access
local none={keys=0,bombs=0,coins=0,stage=2,redHeld=false,redUnlocked=false}
local need,f=A('ROOM_ULTRASECRET',false,none);assert(need=='redLocked' and f==0,'locked red tools: '..tostring(need))
need,f=A('ROOM_ULTRASECRET',false,{keys=0,bombs=0,coins=0,stage=2,redUnlocked=true});assert(need=='red' and f>0 and f<1,'red unlocked, not held')
need,f=A('ROOM_ULTRASECRET',false,{keys=0,bombs=0,coins=0,stage=2,redHeld=true,redUnlocked=true});assert(need==nil and f==1,'red key held')
need,f=A('ROOM_SECRET',false,none);assert(need=='bomb' and f<1,'secret without bombs')
need,f=A('ROOM_TREASURE',false,{keys=0,bombs=0,coins=0,stage=1});assert(need==nil and f==1,'basement 1 treasure is open')
need,f=A('ROOM_TREASURE',false,none);assert(need=='key' and f<1,'locked treasure without keys')
need,f=A('ROOM_TREASURE',false,{keys=1,bombs=0,coins=0,stage=3});assert(need==nil and f==1,'key in hand')
need,f=A('ROOM_ULTRASECRET',true,none);assert(need==nil and f==1,'a visited room needs nothing')
-- Through evaluate: an unreachable ultra secret item counts nothing and
-- sorts last; a shop item we cannot pay for counts less.
local us={index=1,type=RoomType.ROOM_ULTRASECRET,visited=false,layout={pedestals=1,shop=0,loot={}},cells={}}
local shop={index=2,type=RoomType.ROOM_SHOP,visited=true,cells={}}
local poor={keys=0,bombs=0,coins=5,stage=2,redHeld=false,redUnlocked=false}
local scored=FloorScore.evaluate({us,shop},{[2]={{id=3,quality=3,price=15}}},{},{[1]={{id=182,quality=4,kind='pedestal',predicted=true}}},poor)
assert(scored.entries[1].id==3 and scored.entries[1].need=='coins' and scored.entries[2].need=='redLocked' and scored.entries[2].factor==0,'access entries')
assert(math.abs(scored.items-FloorScore.ITEM[3]*FloorScore.SHOP_SHORT)<1e-9,'unreachable item counted: '..scored.items)
print('PASS floor score access: red-door tools, bombs, keys from floor 2, coins, unreachable items last')

-- Through FloorIntel.update: the current room's items and loot are kept,
-- reward rocks are listed while unbroken.
local grids={[16]={t=4,state=1},[17]={t=27,state=1},[18]={t=2,state=1},[19]={t=4,state=2}}
local room={GetGridSize=function()return 135 end,
 GetGridEntity=function(_,i)local g=grids[i];if not g then return nil end
  return {Position={X=i*40,Y=100},State=g.state,GetType=function()return g.t end}end,
 GetGridCollision=function(_,i)return grids[i] and 1 or 0 end}
local function pickup(variant,subtype,price)
 local e={Type=5,Variant=variant,SubType=subtype,Price=price or 0,Position={X=200,Y=200}}
 function e:ToPickup()return self end
 return e
end
-- Run 4RRYH7RK (2026-11-04): its 223 locked items, owned items per player.
local cases=dofile('native/tests/data/item_emulator_cases.lua')
local locked={};for _,id in ipairs(cases[1].unavailable)do locked[id]=true end
local owned,trinkets,logs={},{},{}
local held={keys=0,bombs=0,coins=0,cards={0,0}}
local player={GetCollectibleNum=function(_,id)return owned[id] or 0 end,HasCollectible=function(_,id)return (owned[id] or 0)>0 end,
 HasTrinket=function(_,id)return trinkets[id]==true end,GetNumKeys=function()return held.keys end,GetNumBombs=function()return held.bombs end,
 GetNumCoins=function()return held.coins end,HasGoldenKey=function()return false end,HasGoldenBomb=function()return false end,
 GetCard=function(_,slot)return held.cards[slot+1] end}
Isaac={GetItemConfig=function()return {GetCollectible=function(_,id)
  return {Quality=id==114 and 3 or 1,Name=id==114 and '#MOMS_KNIFE_NAME' or '#ITEM_'..id,IsAvailable=function()return not locked[id] end}end}end,
 GetPlayer=function()return player end,GetChallenge=function()return 0 end,DebugString=function(s)logs[#logs+1]=s end}
local function startSeed(str)return dofile('mod/isaac_dodge_assist/item_emulator.lua').seedFromString(str)end
local game={GetLevel=function()return level end,GetRoom=function()return {GetDevilRoomChance=function()return 0.34 end}end,TimeCounter=30*65,
 GetSeeds=function()return {GetStartSeed=function()return startSeed('4RRYH7RK')end}end,IsGreedMode=function()return false end,
 GetNumPlayers=function()return 1 end}
local state=FloorIntel.new()
current=rooms[2]; rooms[2].VisitedCount=1
local found=FloorIntel.update(state,game,room,function()return {pickup(100,114),pickup(20,2),pickup(10,3),pickup(30,1,5)}end,1)
assert(#found==2,'reward rocks: '..#found)
assert(state.items[1] and state.items[1][1].id==114 and state.items[1][1].name=="Moms Knife",'seen item')
assert(state.loot[1].nickel==1 and state.loot[1].soul==1 and state.loot[1].key==nil and state.loot[1].tinted==1 and state.loot[1].goldrock==1,'room loot')
local r=state.readouts
assert(r.deal==34 and r.planetarium==25 and r.seconds==65,'readouts')
-- The item stays counted after it is taken; a new floor forgets it.
FloorIntel.update(state,game,room,function()return {}end,40)
assert(state.items[1][1].id==114,'taken item forgotten')
FloorIntel.newLevel(state)
assert(next(state.items)==nil and state.map==nil,'new floor kept old intel')
-- Cards and pills are labelled in shops too (0.25.5), but priced ones are
-- not loot.
FloorIntel.newRoom(state,game)
FloorIntel.update(state,game,room,function()return {pickup(300,1,5),pickup(300,46),pickup(70,3,5)}end,60)
assert(#state.cards==2 and state.cards[1].id==1 and state.cards[2].id==46 and #state.pills==1,'shop cards and pills not labelled')
assert(state.loot[1].card==1 and state.loot[1].pill==nil,'priced card or pill counted as loot')
print('PASS floor intel: room items kept once seen, priced pickups excluded from loot, reward rocks, readouts')

-- Map view, in both languages: every room cell is drawn, kind labels, the
-- legend and the score panel are worded in the game's language.
local MapView=include('map_view')
local UI=include('ui')
MapView.use(UI)
local rects,texts=0,{}
function Vector(x,y)return {X=x,Y=y}end
function Color(r,g,b,a)return {r,g,b,a}end
function Sprite()return {Load=function()end,Play=function()end,Render=function()rects=rects+1 end}end
Isaac.GetScreenWidth=function()return 480 end
Isaac.GetScreenHeight=function()return 270 end
Isaac.RenderScaledText=function(s,x,y)assert(x==x and y==y);texts[#texts+1]=s end
FloorIntel.update(state,game,room,function()return {pickup(100,114)}end,100)
floorMap=state.map
local function panel(lang)
 UI.setLang(lang);texts,rects={},0
 MapView.render(floorMap,FloorIntel.extras(state),state.score,state.readouts)
 return '|'..table.concat(texts,'|')..'|'
end
local en=panel('en')
local cells=0;for _,r in ipairs(floorMap.rooms)do cells=cells+#r.cells end
assert(rects>=cells+1,'map cells not drawn: '..rects..' for '..cells)
assert(en:find('|S|',1,true) and en:find('|Score ',1,true) and en:find('|Secret|',1,true) and en:find('Devil/Angel 34%',1,true),'english panel: '..en)
local zh=panel('zh')
assert(zh:find('|隐|',1,true) and zh:find('|评分 ',1,true) and zh:find('|隐藏房|',1,true) and zh:find('恶魔/天使 34%',1,true) and
 not zh:find('Score',1,true),'chinese panel: '..zh)
UI.setLang(nil)
print('PASS map view: cells, kind labels, legend and score panel in English and Chinese')
-- Descriptors that never compare equal: the dimension filter gives up
-- rather than hiding every room.
local savedHash=GetPtrHash
GetPtrHash=function(x)return math.random() end
assert(#FloorMap.scan(level).rooms==6,'map emptied when no descriptor matched')
GetPtrHash=savedHash
print('PASS floor map: dimension filter falls back to every room')

-- Item forecast: the logged treasure room 4.13 of run 4RRYH7RK (SpawnSeed
-- 206474361, its pedestal at layout spawn 6) held Angry Fly (511); unvisited,
-- the floor score names it. A fixed layout item is taken as is; an ordinary
-- shop's slots are not forecast; Chaos turns the forecast off.
local function slotSpawns(n,variant,subtype)
 local list={}
 for i=1,n do list[i]=spawn({{1000,0,0,1}}) end
 list[n+1]=spawn({{5,variant,subtype,1}})
 return list
end
rooms={desc(0,6*13+6,1,RoomType.ROOM_DEFAULT,true),desc(1,6*13+7,1,RoomType.ROOM_TREASURE,false,slotSpawns(6,100,0)),
 desc(2,5*13+6,1,RoomType.ROOM_SHOP,false,slotSpawns(1,150,0)),desc(3,7*13+6,1,RoomType.ROOM_SECRET,false,slotSpawns(2,100,12))}
rooms[2].SpawnSeed,rooms[2].AwardSeed,rooms[2].Flags=206474361,1,0
rooms[3].SpawnSeed,rooms[4].SpawnSeed=5,7
byIndex={};for _,d in ipairs(rooms)do byIndex[d.SafeGridIndex]=d end
current=rooms[1]
state=FloorIntel.startRun(FloorIntel.new(),game,false)
assert(state.forecast and state.forecast.exact,'fresh run forecast not exact')
FloorIntel.update(state,game,room,function()return {}end,1)
local treasure=state.predicted[1]
assert(treasure and #treasure==1 and treasure[1].id==511 and treasure[1].kind=='pedestal','treasure forecast: '..tostring(treasure and treasure[1] and treasure[1].id))
assert(state.predicted[2]==nil,'ordinary shop slots forecast')
assert(state.predicted[3] and state.predicted[3][1].id==12,'fixed layout item')
local named=false
for _,e in ipairs(state.score.entries)do if e.id==511 and e.predicted and e.roomType==RoomType.ROOM_TREASURE then named=true end end
assert(named and state.readouts.forecast=='exact','forecast not in the score')
-- Floor 2 with no key: the forecast treasure item needs one; with a key it does not.
level.GetStage=function()return 2 end
state.scanAt=-100;FloorIntel.update(state,game,room,function()return {}end,3)
local function entryOf(id)for _,e in ipairs(state.score.entries)do if e.id==id then return e end end end
assert(entryOf(511).need=='key','treasure needs a key on floor 2')
held.keys=1;state.scanAt=-100;FloorIntel.update(state,game,room,function()return {}end,4)
assert(entryOf(511).need==nil,'key held, still marked')
held.keys=0;level.GetStage=nil
-- An owned item leaves the pools: the forecast moves on to another item.
owned[511]=1;FloorIntel.newRoom(state,game);FloorIntel.update(state,game,room,function()return {}end,2)
assert(state.predicted[1][1].id~=511,'owned item still forecast')
owned[511]=nil
-- The game's own picks keep the copy in step (and redo the forecast).
local version=state.forecast.version
FloorIntel.picked(state,state.predicted[1][1].id,0,true)
assert(state.forecast.version==version+1,'pick not recorded')
FloorIntel.picked(state,33,0,false)
assert(state.forecast.version==version+1,'a pick without decrease changed the pools')
-- Chaos: off, and said so.
owned[402]=1;FloorIntel.update(state,game,room,function()return {}end,40)
assert(next(state.predicted)==nil and state.readouts.forecast=='off' and state.readouts.forecastWhy=='chaos','chaos forecast')
owned[402]=nil
-- A continued run is approximate; a core loaded mid-run starts one too.
state=FloorIntel.startRun(state,game,true)
assert(not state.forecast.exact,'continued run claimed exact')
state=FloorIntel.new();FloorIntel.update(state,game,room,function()return {}end,1)
assert(state.forecast and not state.forecast.exact,'mid-run start')
for _,line in ipairs(logs)do assert(not line:find('forecast',1,true),line)end
print('PASS item forecast: logged treasure room named before entry, fixed items, owned and picked items, Chaos off, approximate continues')

-- 0.25 co-op boss rooms. Online run TTA8C7DH (2026-11-05), the Haunt's room
-- 5.5011 (AwardSeed 1150171659): two people, two boss items, Squeezy (196)
-- and, once it was taken, Supper (707). Not entered yet, both are forecast
-- (alone, only the first); cleared, the first pedestal (InitSeed X35^3 of
-- the AwardSeed) names the second exactly, on its tooltip and in the score.
local Emu=include('item_emulator')
local people={setmetatable({ControllerIndex=1},{__index=player}),setmetatable({ControllerIndex=2},{__index=player})}
local onePlayer=Isaac.GetPlayer
Isaac.GetPlayer=function(i)return people[i+1] end
local coop=setmetatable({GetSeeds=function()return {GetStartSeed=function()return startSeed('TTA8C7DH')end}end,
 GetNumPlayers=function()return 2 end},{__index=game})
for _,id in ipairs({36,152,147,343})do owned[id]=1 end
rooms={desc(0,6*13+6,1,RoomType.ROOM_DEFAULT,true),desc(1,6*13+7,1,RoomType.ROOM_BOSS,false)}
rooms[2].AwardSeed=1150171659
byIndex={};for _,d in ipairs(rooms)do byIndex[d.SafeGridIndex]=d end
current=rooms[1]
state=FloorIntel.startRun(FloorIntel.new(),coop,false)
FloorIntel.update(state,coop,room,function()return {}end,1)
local boss=state.predicted[1]
assert(boss and #boss==2 and boss[1].id==196 and boss[2].id==707 and boss[2].kind=='boss','co-op boss forecast: '..
 tostring(boss and boss[1] and boss[1].id)..' '..tostring(boss and boss[2] and boss[2].id))
local solo=setmetatable({GetNumPlayers=function()return 1 end},{__index=coop})
local alone=FloorIntel.startRun(FloorIntel.new(),solo,false)
FloorIntel.update(alone,solo,room,function()return {}end,1)
assert(#alone.predicted[1]==1 and alone.predicted[1][1].id==196,'solo boss forecast')
-- Entering logs what was promised for the room.
current=rooms[2];rooms[2].VisitedCount=1
logs={}
FloorIntel.newRoom(state,coop)
assert(logs[1]=='IAD FORECAST: room=1 exact=true items=196:boss,707:boss','forecast log: '..tostring(logs[1]))
-- A new floor enters its first room before newLevel: a room of the new
-- floor at the same list index is not the one the old forecast was for.
logs={}
local otherFloor=desc(1,6*13+7,1,RoomType.ROOM_DEFAULT,true);otherFloor.SpawnSeed=4242
current=otherFloor;FloorIntel.newRoom(state,coop);current=rooms[2]
assert(#logs==0,'old floor forecast logged on a new floor: '..tostring(logs[1]))
-- The kill: the game picks Squeezy for the first pedestal.
FloorIntel.picked(state,196,2,true)
local first=pickup(100,196);first.InitSeed=Emu.bossItemInitSeed(1150171659,0)
FloorIntel.update(state,coop,room,function()return {first}end,2)
assert(state.pedestals[1].next==707,'next boss item on the pedestal: '..tostring(state.pedestals[1].next))
local promised=false
for _,e in ipairs(state.score.entries)do if e.id==707 and e.predicted then promised=true end end
assert(promised,'next boss item not in the score')
-- Taken: Supper is on the floor, seen, and nothing more is promised.
local second=pickup(100,707);second.InitSeed=12345
state.scanAt=-100;FloorIntel.update(state,coop,room,function()return {pickup(100,0),second}end,3)
assert(state.bossNext==nil and #state.items[1]==2 and not state.items[1][2].predicted,'second boss item seen')
print('PASS co-op boss items: logged Haunt room forecast for two (one alone), entry log, next item on the first pedestal and in the score')
-- Hot reload (0.25.0 in game): the new core's own copy of item_forecast had
-- no pool data, so the next room failed ("upvalue 'data'") and the forecast
-- stayed off for the run. Adopted, it goes on; an error left by the old
-- core's code is tried again.
local Reloaded=include('floor_intel')
state.forecastError='old core'
state=Reloaded.adopt(state)
rooms[2].VisitedCount=0;current=rooms[1]
Reloaded.newRoom(state,coop)
state.scanAt=-100;Reloaded.update(state,coop,room,function()return {}end,4)
assert(not state.forecastError and state.readouts.forecast=='exact','forecast after reload: '..tostring(state.forecastError))
Isaac.GetPlayer=onePlayer
for _,id in ipairs({36,152,147,343})do owned[id]=nil end
print('PASS forecast across a hot reload: pool data in the new core, an old error retried')

-- 0.25.3: the game crashed (2026-11-05 23:25, entering the Deathmatch room)
-- inside GetCollectibleNum(43): item 43 is commented out of items.xml, has
-- no config, and the pool data listed it. Neither the data nor the owned
-- item scan may name an id the game has no config for.
local data=include('item_pool_data')
assert(data.items[43]==nil and data.items[61]==nil,'retired items 43/61 in the pool data')
local configured=Isaac.GetItemConfig
local retired={[43]=true,[61]=true,[9999]=true}
data.items[9999]={t=1,a=-1,q=1}
Isaac.GetItemConfig=function()
 local base=configured()
 return setmetatable({GetCollectible=function(self,id)if retired[id] then return nil end return base.GetCollectible(self,id)end},{__index=base})
end
local asked={}
local strict=setmetatable({GetCollectibleNum=function(_,id)
 if retired[id] then error('GetCollectibleNum('..id..') on an id without config') end
 asked[#asked+1]=id;return 0 end},{__index=player})
local unchecked=Isaac.GetPlayer
Isaac.GetPlayer=function()return strict end
local FreshIntel=include('floor_intel')
local _include=include
include=function(name)if name=='item_pool_data' then return data end return _include(name)end
local guarded=FreshIntel.startRun(FreshIntel.new(),game,false)
include=_include
assert(guarded.forecast and not guarded.forecastError and #asked>700,'owned scan: '..tostring(guarded.forecastError)..' '..#asked)
FreshIntel.newRoom(guarded,game)
assert(not guarded.forecastError,'owned scan on a new room: '..tostring(guarded.forecastError))
data.items[9999]=nil
Isaac.GetPlayer,Isaac.GetItemConfig=unchecked,configured
print('PASS owned items: no retired id in the pool data, ids without a config never asked about')

-- 0.25.4 (2026-11-06 Online run 84C0BJH9, Azazel + Tainted Isaac, to
-- Delirium): a chapter's last boss drops nothing (It Lives, Hush, Satan,
-- The Lamb, Delirium...), except in The Void, where only Delirium keeps it
-- so; and with Tainted Isaac every pedestal's second item (X38 of its
-- InitSeed, same pool) is forecast as the other choice of that pedestal.
Isaac.GetPlayer=function(i)return people[i+1] end
local function bossRoom(subtype)
 local d=desc(1,6*13+7,1,RoomType.ROOM_BOSS,false);d.AwardSeed=1150171659;d.Data.Subtype=subtype;return d
end
local function forecastFor(subtype,stage)
 rooms={desc(0,6*13+6,1,RoomType.ROOM_DEFAULT,true),bossRoom(subtype)}
 byIndex={};for _,d in ipairs(rooms)do byIndex[d.SafeGridIndex]=d end
 current=rooms[1];level.GetStage=function()return stage end
 local s=FloorIntel.startRun(FloorIntel.new(),coop,false)
 FloorIntel.update(s,coop,room,function()return {}end,1)
 return s
end
local itLives=forecastFor(25,8)
assert(itLives.predicted[1]==nil and itLives.score.unseen==0,'It Lives forecast an item: unseen '..itLives.score.unseen)
local voidSatan=forecastFor(24,12)
assert(voidSatan.predicted[1] and #voidSatan.predicted[1]==1 and voidSatan.score.unseen==1,
 'Void boss: only the second person item is known')
local delirium=forecastFor(70,12)
assert(delirium.predicted[1]==nil and delirium.score.unseen==0,'Delirium forecast an item')
local mom=forecastFor(6,6)
assert(#mom.predicted[1]==2,'an ordinary boss lost its items')
-- Tainted Isaac: the logged treasure room 4.13 of run 4RRYH7RK (Angry Fly,
-- 511) gets its second item right under it, and counts once.
local cycling=setmetatable({GetPlayerType=function()return 21 end},{__index=people[2]})
Isaac.GetPlayer=function(i)return i==0 and people[1] or cycling end
rooms={desc(0,6*13+6,1,RoomType.ROOM_DEFAULT,true),desc(1,6*13+7,1,RoomType.ROOM_TREASURE,false,slotSpawns(6,100,0))}
rooms[2].SpawnSeed,rooms[2].AwardSeed=206474361,1
byIndex={};for _,d in ipairs(rooms)do byIndex[d.SafeGridIndex]=d end
current=rooms[1];level.GetStage=nil
local solo4R=setmetatable({GetSeeds=function()return {GetStartSeed=function()return startSeed('4RRYH7RK')end}end},{__index=coop})
local t=FloorIntel.startRun(FloorIntel.new(),solo4R,false)
FloorIntel.update(t,solo4R,room,function()return {}end,1)
local pair=t.predicted[1]
assert(pair and #pair==2 and pair[1].id==511 and pair[2].altOf==511 and pair[2].id~=511,'Tainted Isaac pair: '..
 tostring(pair and pair[2] and pair[2].id))
local counted=0;for q=0,4 do counted=counted+(t.score.qualities[q] or 0) end
assert(counted==1 and t.score.entries[1].altOf==nil and t.score.entries[2].altOf==511,'a pedestal counted twice')
-- In the room: the pedestal shows one item, then the other; the second is
-- the same choice.
local cycle=pickup(100,511);cycle.InitSeed=Emu.layoutInitSeed(206474361,6)
current=rooms[2];rooms[2].VisitedCount=1;FloorIntel.newRoom(t,solo4R)
FloorIntel.update(t,solo4R,room,function()return {cycle}end,2)
cycle.SubType=pair[2].id;t.scanAt=-100
FloorIntel.update(t,solo4R,room,function()return {cycle}end,3)
assert(#t.items[1]==2 and t.items[1][2].altOf==511,'cycled item not the same choice')
counted=0;for q=0,4 do counted=counted+(t.score.qualities[q] or 0) end
assert(counted==1,'cycling pedestal counted twice: '..counted)
Isaac.GetPlayer=onePlayer;level.GetStage=nil
print('PASS boss rewards and cycling pedestals: none after a chapter boss (Void exception), Tainted Isaac pairs forecast, seen and counted once')

-- 0.25.6 chests: an unopened golden chest of run GJSHZSRA (drop RNG seed
-- 1749904949, opened to a penny, a nickel and a penny) is labelled with
-- what it holds and counts as that loot, not as "a chest"; a chest the
-- layout of a room not entered yet always places shows what it will hold.
local CF=include('chest_forecast')
local ctxPlayer=setmetatable({Variant=0,GetPlayerType=function()return 14 end,GetTrinketMultiplier=function()return 0 end},{__index=player})
Isaac.GetPlayer=function()return ctxPlayer end
level.GetCurrentRoomIndex=function()return 70 end
level.GetStartingRoomIndex=function()return 84 end
game.Difficulty=1
local roomTypeNow=RoomType.ROOM_DEFAULT
room.GetType=function()return roomTypeNow end
room.GetBackdropType=function()return 1 end
room.GetDevilRoomChance=function()return 0.34 end
local gameRoom=game.GetRoom;game.GetRoom=function()return room end
rooms={desc(0,6*13+6,1,RoomType.ROOM_DEFAULT,true),desc(1,6*13+7,1,RoomType.ROOM_SECRET,false,{spawn({{5,50,0,1}})})}
rooms[2].SpawnSeed=123456789
byIndex={};for _,d in ipairs(rooms)do byIndex[d.SafeGridIndex]=d end
current=rooms[1];level.GetStage=function()return 1 end
local c=FloorIntel.startRun(FloorIntel.new(),game,false)
local chest=pickup(60,1);chest.InitSeed=1749904949
function chest:GetDropRNG()return {GetSeed=function()return 1749904949 end}end
FloorIntel.update(c,game,room,function()return {chest}end,1)
local held=c.containers[1]
assert(held and held.loot.coin==2 and held.loot.nickel==1 and #held.items==0,'golden chest contents')
assert(c.loot[0].coin==2 and c.loot[0].nickel==1 and c.loot[0].gold==nil,'chest counted as a chest, not its contents')
-- The secret room's layout chest: the room list shows what it holds.
local ctxNow=CF.readContext(game,nil,function()return false end)
local init=include('item_emulator').layoutInitSeed(123456789,0)
local v,sub=CF.resolve(50,init,ctxNow);if v~=69 and sub==0 then sub=1 end
local expect=CF.predict(v,sub,init,ctxNow,init)
local secretRoom
for _,r in ipairs(c.score.roomList)do if r.type==RoomType.ROOM_SECRET then secretRoom=r end end
assert(secretRoom and secretRoom.loot.chest==nil and c.contentLoot[1],'layout chest not opened in the forecast')
local expected=0;for _,g in ipairs(expect.groups)do if g.type==5 then expected=expected+g.count end end
local got=0;for _,n in pairs(c.contentLoot[1])do got=got+n end
assert(math.abs(got-expected)<1e-9,'layout chest contents: '..got..' vs '..expected)
-- Labels: what the chest holds, in words.
local ItemView2=include('item_view');ItemView2.use(UI)
UI.setLang('en');local words={}
for _,w in ipairs(ItemView2.contentWords(held))do words[#words+1]=w[1] end
assert(table.concat(words,' ')=='coins 7','chest words: '..table.concat(words,' '))
UI.setLang(nil)
Isaac.GetPlayer=onePlayer;level.GetStage=nil;room.GetType=nil;game.GetRoom=gameRoom
print('PASS chests: a logged golden chest labelled and counted as its coins, a layout chest of a room not entered forecast')
