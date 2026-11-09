-- UI text (0.23): both languages carry every string with the same
-- placeholders, every Chinese string is renderable with the game's CJK font
-- (native/tests/data/cjk_font_chars.txt, from the installed font), the game
-- language picks the words (English when the Chinese font cannot load), and
-- the HUD words every sensor state and fades its toasts.
local function enum()
 return setmetatable({}, {__index=function(t,k)local n=(rawget(t,'_next') or 0)+1;t._next=n;rawset(t,k,n);return n end})
end
RoomType={ROOM_DEFAULT=1,ROOM_SHOP=2,ROOM_TREASURE=4,ROOM_BOSS=5}
function include(name)return dofile('mod/isaac_dodge_assist/'..name..'.lua')end
function Vector(x,y)return {X=x,Y=y}end
function Color(r,g,b,a)return {r,g,b,a}end
local texts={}
Isaac={RenderScaledText=function(s)texts[#texts+1]=s end,GetScreenWidth=function()return 480 end,
 WorldToScreen=function(v)return v end}
local UI=include('ui')
local Hud=include('hud');Hud.use(UI)

-- Same keys, same placeholders.
local function placeholders(s)local list={};for p in s:gmatch('%%[%d%.]*[sd%%]')do list[#list+1]=p end;return table.concat(list,',')end
for key,text in pairs(UI.STRINGS.en)do
 local zh=UI.STRINGS.zh[key]
 assert(zh,'no Chinese for '..key)
 assert(placeholders(zh)==placeholders(text),'placeholders differ for '..key..': '..text..' / '..zh)
end
for key in pairs(UI.STRINGS.zh)do assert(UI.STRINGS.en[key],'no English for '..key)end
for name in pairs(UI.ROOMS.en)do assert(UI.ROOMS.zh[name],'no Chinese room '..name)end

-- Every Chinese character exists in the game's CJK font.
local f=assert(io.open('native/tests/data/cjk_font_chars.txt','rb'),'font charset missing')
local charset={};for _,c in utf8.codes(f:read('a'))do charset[c]=true end;f:close()
local function renderable(s,where)
 for _,c in utf8.codes(s)do
  assert(c<128 or charset[c],string.format('%s: "%s" not in the CJK font (U+%04X)',where,utf8.char(c),c))
 end
end
for key,text in pairs(UI.STRINGS.zh)do renderable(text,key)end
for name,room in pairs(UI.ROOMS.zh)do for i=1,3 do renderable(room[i],name)end end
local okPills,pillNames=pcall(include,'pill_effects')
assert(okPills and pillNames[1].zh,'pill effects missing')
for id,pill in pairs(pillNames)do renderable(pill.zh,'pill '..id)end
local okCards,cardNames=pcall(include,'card_effects')
assert(okCards and cardNames[1].zh and cardNames[97].effect.zh,'card effects missing')
local cardCount=0
for id,card in pairs(cardNames)do
 cardCount=cardCount+1
 assert(card.en and card.effect.en and (card.class=='good' or card.class=='bad' or card.class=='neutral'),'card '..id)
 renderable(card.zh,'card '..id);renderable(card.effect.zh,'card effect '..id)
end
assert(cardCount==97,'card count '..cardCount)
local ok,names=pcall(include,'item_names')
if ok and type(names)=='table' and names.zh then
 for id,name in pairs(names.zh)do renderable(name,'item '..id)end
end
print('PASS ui strings: both languages complete, same placeholders, Chinese renderable with the game font')

-- The game language decides; Chinese falls back to English without its font.
Options={Language='zh'};assert(UI.lang()=='zh','zh not picked')
local fresh=include('ui');Options={Language='en'};assert(fresh.lang()=='en','en not picked')
Font=function()return {Load=function()end,IsLoaded=function()return false end}end;KColor=function()return {}end
fresh=include('ui');Options={Language='zh'};assert(fresh.lang()=='en','missing Chinese font did not fall back')
Font,KColor,Options=nil,nil,nil
-- Long names are cut to fit, character by character.
UI.setLang('zh')
local cut=UI.fit('硫磺火硫磺火硫磺火硫磺火',30)
assert(UI.width(cut)<=30 and cut:sub(-2)=='..' and utf8.len(cut),'fit: '..cut)
print('PASS ui language: Options.Language, English fallback without the Chinese font, UTF-8 fitting')

-- HUD: every sensor state is worded, in both languages; toasts fade.
local function hud(lang,view)
 UI.setLang(lang);texts={}
 Hud.render(Hud.new(),view,48,50)
 return table.concat(texts,'|')
end
for code in pairs(Hud.STATES)do
 for _,lang in ipairs({'en','zh'})do
  local line=hud(lang,{state=code,combatMode=0})
  assert(#line>0 and not line:find(code,1,true),'state '..code..' shown raw in '..lang)
 end
end
local score={grade='A',total=63,colour={1,1,1},qualities={[0]=0,0,1,2,1},unseen=1}
local zh=hud('zh',{state='THREAT / HELPER',combatMode=2,player=2,score=score})
assert(zh:find('躲避',1,true) and zh:find('自动战斗',1,true) and zh:find('P2',1,true) and zh:find('本层 A 63',1,true) and
 zh:find('Q4x1',1,true) and zh:find('未知 1',1,true),'chinese HUD: '..zh)
local en=hud('en',{state='MONITOR / HELPER',combatMode=1,score=score})
assert(en:find('Dodge',1,true) and en:find('Auto aim',1,true) and en:find('Floor A 63',1,true),'english HUD: '..en)
local state=Hud.new();Hud.toast(state,'hello')
local seen=0
for _=1,120 do texts={};Hud.render(state,{state='OFF',combatMode=0},48,50);if table.concat(texts,'|'):find('hello',1,true) then seen=seen+1 end end
assert(seen>=60 and seen<=95,'toast frames: '..seen)
UI.setLang(nil)
print('PASS hud: every sensor state worded in both languages, combat/co-op/score, toast fades')

-- Item stats and pills (0.24): the words for an item's stat changes, the
-- sum over items, the pill read (pure, skipped while a mod hooks it), the
-- tooltip over the nearest pedestal and the labels over pills.
local ItemView=include('item_view');ItemView.use(UI)
UI.setLang('zh')
local function joined(words)local t={};for _,w in ipairs(words)do t[#t+1]=w[1] end;return table.concat(t,' ')end
local reflection=joined(ItemView.words(ItemView.stats(5)))
assert(reflection:find('伤害+1.5',1,true) and reflection:find('射程x2',1,true) and reflection:find('幸运-1',1,true),'My Reflection: '..reflection)
local words=ItemView.words(ItemView.stats(5))
for _,w in ipairs(words)do if w[1]:find('幸运',1,true) then assert(w[2]==UI.BAD,'luck down not red') end end
local sum=ItemView.total({{id=1},{id=1},{id=4}})
assert(math.abs(sum.tears-1.4)<1e-9 and sum.dmgMult==1.5 and sum.dmg==0.5,'stat total')
assert(joined(ItemView.words(ItemView.stats(118))):find('硫磺火',1,true),'weapon flag')
UI.setLang('en')
assert(joined(ItemView.words(ItemView.stats(1)))=='Tears+0.7','english words: '..joined(ItemView.words(ItemView.stats(1))))
-- Pills: GetPillEffect with the bound player; horse flag; a hooked read is skipped.
local PillInfo=include('pill_info')
ModCallbacks={MC_GET_PILL_EFFECT=65}
local hooks={}
Isaac.GetCallbacks=function()return hooks end
local asked
local game={GetItemPool=function()return {GetPillEffect=function(_,color,player)asked=player;return (color & 0x7ff)+10 end}end}
local me={}
local e,horse=PillInfo.effect(game,3,me);assert(e==13 and not horse and asked==me,'pill read')
e,horse=PillInfo.effect(game,3|0x800,me);assert(e==13 and horse,'horse pill')
hooks={{}};assert(PillInfo.effect(game,3,me)==nil,'read while another mod hooks it')
hooks={}
-- Drawing: tooltip only near a pedestal; a label per pill, bad ones red.
Isaac.GetItemConfig=function()return {GetCollectible=function()return {Quality=4}end}end
texts={};ItemView.renderTooltip({{x=0,y=0,id=118}},Vector(200,0))
assert(#texts==0,'tooltip far away')
texts={};ItemView.renderTooltip({{x=0,y=0,id=118}},Vector(30,0))
assert(table.concat(texts,'|'):find('Brimstone',1,true),'tooltip: '..table.concat(texts,'|'))
-- Co-op boss room: the item the next pedestal will hold, under the stats.
texts={};ItemView.renderTooltip({{x=0,y=0,id=118,next=1}},Vector(30,0))
assert(table.concat(texts,'|'):find('Then: The Sad Onion  Q4',1,true),'next boss item: '..table.concat(texts,'|'))
-- With Tainted Isaac the next pedestal has two items; the list marks a
-- pedestal's other item with "or".
texts={};ItemView.renderTooltip({{x=0,y=0,id=118,next=1,nextOr=5}},Vector(30,0))
assert(table.concat(texts,'|'):find('Then: The Sad Onion or My Reflection',1,true),'next pair: '..table.concat(texts,'|'))
texts={};ItemView.renderPage({entries={{id=1,quality=1,roomType=4,factor=1},{id=5,quality=3,roomType=4,factor=1,altOf=1}}})
assert(table.concat(texts,'|'):find('or My Reflection',1,true),'or marker: '..table.concat(texts,'|'))
-- Chests and alt rocks (0.25.6): what they hold, in words.
local function said(c)local t={};for _,w in ipairs(ItemView.contentWords(c))do t[#t+1]=w[1] end;return table.concat(t,' ')end
assert(said({loot={coin=2,nickel=1,key=1},items={{id=118}},extras={{'trollBomb',1,true}}})=='Brimstone Q4 coins 7 keys 1 troll bomb','chest words')
assert(said({rock=true,loot={},items={},extras={},bad='spiders'})=='spiders' and said({loot={},items={},extras={}})=='empty','rock words')
-- Cards (0.25.5): every card shows its name; the nearest also its effect.
texts={};ItemView.renderCards({{x=0,y=0,id=1},{x=200,y=0,id=46}},Vector(10,0))
local cardText=table.concat(texts,'|')
assert(cardText:find('0 - The Fool',1,true) and cardText:find('Teleport to the start room',1,true) and
 cardText:find('Suicide King',1,true) and not cardText:find('Kills you',1,true),'cards: '..cardText)
texts={};ItemView.renderPills({{x=0,y=0,effect=1},{x=50,y=0,effect=0,horse=true}})
local labels=table.concat(texts,'|')
assert(labels:find('Bad Trip',1,true) and labels:find('Bad Gas (horse)',1,true),'pill labels: '..labels)
-- The F5 second page lists every item with its stats and the reachable total.
texts={};ItemView.renderPage({entries={{id=1,quality=1,roomType=4,factor=1},{id=5,quality=3,roomType=4,factor=0,need='redLocked'}}})
local page=table.concat(texts,'|')
assert(page:find('Take all reachable',1,true) and page:find('Tears+0.7',1,true) and page:find('out of reach',1,true),'page: '..page)
UI.setLang(nil)
print('PASS item view: stat words and colours, totals, pill read (pure, hook-aware), tooltip (with the next co-op boss item), card labels, pill labels, F5 stats page')

-- Pedestal notes (0.25.9): transformation progress per player, and the
-- Spindown Dice chain (ids below that are missing, hidden, locked or not
-- allowed are skipped; Car Battery turns two steps per use).
local ItemNotes=include('item_notes')
local configs={[1]={Tags=1<<5},[2]={Hidden=true},[3]={Tags=0,IsAvailable=function()return false end},
 [4]={Tags=0},[6]={Tags=1<<5|1<<10},[7]={Tags=0},[8]={Tags=0}}
Isaac.GetItemConfig=function()return {GetCollectible=function(_,id)local c=configs[id];if c then c.Quality=c.Quality or 2 end;return c end}end
local game={GetNumPlayers=function()return 3 end}
local function player(controller,counters,items)
 return {ControllerIndex=controller,GetPlayerFormCounter=function(_,f)return counters[f] or 0 end,
  HasPlayerForm=function(_,f)return (counters[f] or 0)>=3 end,HasCollectible=function(_,id)return items[id] or false end}
end
local list={player(0,{[0]=2},{}),player(0,{},{}),player(1,{[3]=3},{[723]=true})}
Isaac.GetPlayer=function(i)return list[i+1]end
local people=ItemNotes.players(game)
assert(#people==2 and people[2].number==3,'one entry per controller')
local notes=ItemNotes.notes(6,game,people)
assert(#notes.forms==2 and notes.forms[1].key=='guppy' and notes.forms[1].counts[1][2]==2 and notes.forms[2].counts[2][3]==true,'forms')
assert(table.concat(notes.spin.ids,',')=='4,1,0','spindown skips hidden and locked: '..table.concat(notes.spin.ids,','))
list[3]=player(1,{},{[723]=true,[356]=true})
people=ItemNotes.players(game)
local spin=ItemNotes.spindown(8,game,people)
assert(table.concat(spin.ids,',')=='6,1,0' and spin.carBattery,'car battery: '..table.concat(spin.ids,','))
assert(ItemNotes.spindown(668,game,people)==nil and ItemNotes.notes(7,game,{people[1]})==nil,'Dad\'s Note, nothing to say')
UI.setLang('en');texts={};ItemView.renderTooltip({{x=0,y=0,id=118,notes=notes}},Vector(30,0))
local tip=table.concat(texts,'|')
UI.setLang(nil)
assert(tip:find('Guppy|P1 2/3|P3 0/3',1,true) and tip:find('Seraphim|P1 0/3|P3 done',1,true) and tip:find('Spindown:|',1,true),'notes: '..tip)
print('PASS pedestal notes: transformation progress per player, Spindown chain (skips, Car Battery, Dad\'s Note)')

-- Sacrifice spikes (0.26.0): one line per coming sacrifice; a finished
-- room says so; Sanguine Bond's single "next" line.
UI.setLang('en')
texts={};ItemView.renderContainers({{x=0,y=0,rock=true,sacrifice={
 {n=3,loot={},items={},extras={},words={{'sac_angel15'}}},
 {n=4,lead='sac_chest',loot={coin=5,key=1},items={},extras={},words={}},
 {n=5,loot={},items={},extras={},words={{'sac_nothing'}}}}}},Vector(0,20))
local sac=table.concat(texts,'|')
assert(sac:find('#3:|angel chance +15%|#4:|chest|coins 5|keys 1|#5:|nothing',1,true),'sacrifice label: '..sac)
texts={};ItemView.renderContainers({{x=0,y=0,rock=true,done=true,sacrifice={}}},Vector(0,20))
assert(table.concat(texts,'|')=='sacrifices done','done: '..table.concat(texts,'|'))
texts={};ItemView.renderContainers({{x=0,y=0,rock=true,sacrifice={{loot={coin=6},items={},extras={},words={}}}}},Vector(0,20))
assert(table.concat(texts,'|')=='Next:|coins 6','sanguine: '..table.concat(texts,'|'))
UI.setLang(nil)
print('PASS sacrifice labels: next three sacrifices, finished room, Sanguine Bond')
