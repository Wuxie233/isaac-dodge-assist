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
