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
PickupVariant={PICKUP_HEART=10,PICKUP_COIN=20,PICKUP_KEY=30,PICKUP_BOMB=40,PICKUP_CHEST=50,PICKUP_PILL=70,PICKUP_COLLECTIBLE=100}
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
assert(score.summary:find('?x2',1,true),'unseen count: '..score.summary)
for _,r in ipairs(floorMap.rooms)do if r.type==RoomType.ROOM_TREASURE then r.visited=true end end
score=FloorScore.evaluate(floorMap.rooms,{[1]={{id=182,quality=4,name='Sacred Heart'}}},{})
assert(math.abs(score.items-(FloorScore.ITEM[4]+FloorScore.UNSEEN_ITEM))<1e-9,'seen item value')
assert(score.lines[2][1]:find('Q4 Sacred Heart',1,true),'item line: '..score.lines[2][1])
-- Shop items and deals are worth less than free ones.
score=FloorScore.evaluate({{index=9,type=RoomType.ROOM_SHOP,visited=true,label='$',cells={}}},
 {[9]={{id=1,quality=2,price=15},{id=2,quality=2,devil=true}}},{})
assert(math.abs(score.items-FloorScore.ITEM[2]*(FloorScore.SHOP+FloorScore.DEVIL))<1e-9,'priced items')
assert(FloorIntel.readableName('#THE_SAD_ONION_NAME')=='The Sad Onion' and FloorIntel.readableName('Modded')=='Modded','names')
print('PASS floor score: unseen pedestals, layout loot, seen qualities, shop and deal prices, item names')

-- Through FloorIntel.update: the current room's items and loot are kept,
-- reward rocks are listed while unbroken.
local grids={[16]={t=4,state=1},[17]={t=27,state=1},[18]={t=2,state=1},[19]={t=4,state=2}}
local room={GetGridSize=function()return 135 end,
 GetGridEntity=function(_,i)local g=grids[i];if not g then return nil end
  return {Position={X=i*40,Y=100},State=g.state,GetType=function()return g.t end}end,
 GetGridCollision=function(_,i)return grids[i] and 1 or 0 end}
local function pickup(variant,subtype,price)
 local e={Type=5,Variant=variant,SubType=subtype,Price=price or 0}
 function e:ToPickup()return self end
 return e
end
Isaac={GetItemConfig=function()return {GetCollectible=function(_,id)return {Quality=3,Name='#MOMS_KNIFE_NAME'}end}end}
local game={GetLevel=function()return level end,GetRoom=function()return {GetDevilRoomChance=function()return 0.34 end}end,TimeCounter=30*65}
local state=FloorIntel.new()
current=rooms[2]; rooms[2].VisitedCount=1
local found=FloorIntel.update(state,game,room,function()return {pickup(100,114),pickup(20,2),pickup(10,3),pickup(30,1,5)}end,1)
assert(#found==2,'reward rocks: '..#found)
assert(state.items[1] and state.items[1][1].id==114 and state.items[1][1].name=="Moms Knife",'seen item')
assert(state.loot[1].nickel==1 and state.loot[1].soul==1 and state.loot[1].key==nil and state.loot[1].tinted==1 and state.loot[1].goldrock==1,'room loot')
local last=state.score.lines[#state.score.lines][1]
assert(last:find('deal 34%',1,true) and last:find('planetarium 25%',1,true) and last:find('rush 18:55',1,true),last)
-- The item stays counted after it is taken; a new floor forgets it.
FloorIntel.update(state,game,room,function()return {}end,40)
assert(state.items[1][1].id==114,'taken item forgotten')
FloorIntel.newLevel(state)
assert(next(state.items)==nil and state.map==nil,'new floor kept old intel')
print('PASS floor intel: room items kept once seen, priced pickups excluded from loot, reward rocks, readouts')

-- Map view: every room cell is drawn, labels and score lines are printed.
local MapView=include('map_view')
local rects,texts=0,{}
function Vector(x,y)return {X=x,Y=y}end
function Color(r,g,b,a)return {r,g,b,a}end
function Sprite()return {Load=function()end,Play=function()end,Render=function()rects=rects+1 end}end
Isaac.GetScreenWidth=function()return 480 end
Isaac.GetScreenHeight=function()return 270 end
Isaac.RenderScaledText=function(s,x,y)assert(x==x and y==y);texts[#texts+1]=s end
FloorIntel.update(state,game,room,function()return {pickup(100,114)}end,100)
floorMap=state.map
MapView.render(floorMap,FloorIntel.extras(state),state.score)
local cells=0;for _,r in ipairs(floorMap.rooms)do cells=cells+#r.cells end
assert(rects>=cells+1,'map cells not drawn: '..rects..' for '..cells)
local joined=table.concat(texts,'|')
assert(joined:find('|S|',1,true) and joined:find('FLOOR ',1,true),'labels/score missing: '..joined)
texts={};MapView.scoreLine(state.score,48,64)
assert(#texts==1 and texts[1]:find('^FLOOR '),'score line')
print('PASS map view: cells, labels, score panel and HUD line')
-- Descriptors that never compare equal: the dimension filter gives up
-- rather than hiding every room.
local savedHash=GetPtrHash
GetPtrHash=function(x)return math.random() end
assert(#FloorMap.scan(level).rooms==6,'map emptied when no descriptor matched')
GetPtrHash=savedHash
print('PASS floor map: dimension filter falls back to every room')
