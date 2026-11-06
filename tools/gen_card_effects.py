#!/usr/bin/env python3
"""Generate mod/isaac_dodge_assist/card_effects.lua: every card, rune and soul stone with its
name (from the game) and a one-line effect (written here).

    python3 tools/gen_card_effects.py <dir with pocketitems.xml and stringtable.sta> mod/isaac_dodge_assist/card_effects.lua

Names come from the installed game's pocketitems.xml (<card>/<rune> id and "#KEY" name) and
stringtable.sta (category PocketItems; en = language id 0, zh = id 13), like gen_item_names.py.
The game's own card description is a flavour line ("Where journey begins"), so the effect
lines below are written for this mod, short enough for a label over the card, after the
Repentance+ behaviour (the wiki's Cards and Runes page, 2026-11-06). class: good, bad or
neutral (a choice, or good and bad at once), coloured like pill labels.
"""
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from gen_item_names import load_stringtable, lua_str, EN, ZH  # noqa: E402

EFFECTS = {
    1: ('neutral', 'Teleport to the start room', '传送回本层起始房'),
    2: ('good', 'Homing tears, range up (room)', '本房间追踪眼泪、射程提升'),
    3: ('good', "Mom's foot stomps the strongest enemy", '妈妈的脚踩血最多的敌人'),
    4: ('good', 'DMG +1.5, speed +0.3 (room)', '本房间伤害+1.5 速度+0.3'),
    5: ('neutral', 'Teleport to the boss room', '传送到 Boss 房'),
    6: ('good', '2 soul hearts', '生成2个魂心'),
    7: ('good', '2 red hearts', '生成2个红心'),
    8: ('good', 'Invincible ramming for 6 s', '无敌冲撞6秒（不能射击）'),
    9: ('good', 'A heart, key, bomb and coin', '心、钥匙、炸弹、硬币各一个'),
    10: ('neutral', 'Teleport to the shop', '传送到商店'),
    11: ('neutral', 'Spawns a slot or fortune machine', '生成老虎机或算命机'),
    12: ('good', 'Bigger, DMG and speed up, +1 heart (room)', '本房间变大、伤害速度提升、+1心'),
    13: ('good', 'Flight (room)', '本房间飞行'),
    14: ('good', '40 damage to every enemy', '对全屏敌人造成40伤害'),
    15: ('neutral', 'Spawns a blood donation machine', '生成献血机'),
    16: ('good', 'DMG +2 (room)', '本房间伤害+2'),
    17: ('neutral', '6 troll bombs around the room', '房间里随机6颗自爆炸弹'),
    18: ('neutral', 'Teleport to the treasure room (planetarium first)', '传送到宝箱房（有星象房则去星象房）'),
    19: ('neutral', 'Teleport to the secret room', '传送到隐藏房'),
    20: ('good', 'Full heal, 100 damage to all, map', '回满血、全屏100伤害、显示地图'),
    21: ('neutral', 'Spawns a beggar', '生成一个乞丐'),
    22: ('good', 'Reveals the floor map', '显示本层地图'),
    23: ('good', 'Doubles bombs', '炸弹翻倍'),
    24: ('good', 'Doubles coins', '硬币翻倍'),
    25: ('good', 'Doubles keys', '钥匙翻倍'),
    26: ('good', 'Doubles red hearts', '红心翻倍'),
    27: ('neutral', 'Pickups and enemies into bombs', '拾取物和小怪全变炸弹'),
    28: ('neutral', 'Pickups and enemies into coins', '拾取物和小怪全变硬币'),
    29: ('neutral', 'Pickups and enemies into keys', '拾取物和小怪全变钥匙'),
    30: ('neutral', 'Pickups and enemies into hearts', '拾取物和小怪全变红心'),
    31: ('good', 'Teleport to the devil or angel room', '传送到恶魔/天使房'),
    32: ('neutral', 'Destroys the rocks in the room', '摧毁房间里的石头'),
    33: ('good', 'Duplicates pickups and chests', '复制房间里的拾取物和箱子'),
    34: ('neutral', 'Trapdoor to the next floor', '开一个通往下一层的活板门'),
    35: ('good', 'Removes curses, +1 soul heart', '清除诅咒、+1魂心'),
    36: ('good', 'Reveals the map and secret rooms', '显示地图（含隐藏房）'),
    37: ('neutral', 'Rerolls the items in the room (D6)', '重随房间里的道具（D6）'),
    38: ('good', '3 locusts for the room', '本房间3只蝗虫'),
    39: ('good', 'Shield for 20 s', '20秒护盾'),
    40: ('neutral', 'A random rune effect', '随机一种符文效果'),
    41: ('neutral', '40 damage to all; eats items for stats', '全屏40伤害；吞掉地上道具换属性'),
    42: ('good', 'Throw: kills what it hits, bosses too', '扔出，碰到的敌人直接秒杀（含Boss）'),
    43: ('good', 'Everything in the room is free', '本房间商品免费'),
    44: ('neutral', 'Shows a hint', '显示一条提示'),
    45: ('neutral', 'Fills the room with poop', '满屋子屎'),
    46: ('bad', 'Kills you, drops lots of loot', '你直接死亡，掉一堆东西'),
    47: ('good', "Opens every door (Dad's Key)", '打开房间所有门'),
    48: ('good', 'Uses your active item', '使用一次你的主动道具'),
    49: ('neutral', 'Rerolls items and pickups (D6 + D20)', '重随房间道具和拾取物'),
    50: ('good', "Mom's hands grab two enemies", '妈妈的手抓走两个敌人'),
    51: ('good', 'Blocks the next hit', '挡下一次伤害'),
    52: ('good', 'Huge, DMG +7, crushes rocks (room)', '本房间巨大化、伤害+7、压碎石头'),
    53: ('good', '3 random cards', '生成3张随机卡牌'),
    54: ('neutral', 'Slows time, speed up, shot speed down (room)', '本房间时间变慢、移速提升、弹速下降'),
    55: ('neutral', 'A weaker random rune effect', '较弱的随机符文效果'),
    56: ('bad', 'Drops all your hearts and pickups', '掉落身上所有心和拾取物，只剩半心'),
    57: ('good', 'Repels enemies and shots for 1 min', '1分钟内推开敌人和子弹'),
    58: ('bad', "Mom's foot stomps at you for 1 min", "1分钟内妈妈的脚追着你踩"),
    59: ('good', '+2 hearts, tears up for 1 min', '1分钟内+2心之容器、射速提升'),
    60: ('good', 'An extra boss fight with a reward', '传送去打一个额外 Boss（有奖励）'),
    61: ('good', '2 bone hearts', '生成2个骨心'),
    62: ('neutral', 'An item, but a broken heart', '生成一个道具，但获得一颗碎心'),
    63: ('good', 'Invincible statue, 4x fire rate, 10 s', '变成无敌石像、4倍射速，10秒'),
    64: ('good', '2-4 golden chests', '生成2-4个金箱'),
    65: ('neutral', 'Sells everything in the room for coins', '把房间里的道具和拾取物换成硬币'),
    66: ('neutral', 'A random dice room effect', '随机触发一种骰子房效果'),
    67: ('good', 'Weakens all enemies (room)', '本房间敌人虚弱（受伤翻倍）'),
    68: ('neutral', 'Keeper for 30 s: triple shot, coins on kill', '30秒变店主：三连发、杀敌掉钱'),
    69: ('good', 'Friendly bones from the enemies killed', '杀死的敌人变成友方骷髅'),
    70: ('bad', 'Eats 5 random pills', '强制吃5颗随机胶囊'),
    71: ('good', 'The Bible: flight and a Seraphim for 30 s', '圣经效果：飞行和天使跟班30秒'),
    72: ('good', 'Rock clusters, often tinted rocks', '生成几堆石头，常有有色石头'),
    73: ('neutral', 'Loses your oldest item, 2 new items', '失去最早的道具，生成2个新道具'),
    74: ('good', 'Teleport to the ultra secret room', '传送到究极隐藏房'),
    75: ('neutral', 'DMG +1.5 for the floor, but darkness', '本层伤害+1.5，但有黑暗诅咒'),
    76: ('good', 'Spawns a restock machine', '生成补货机'),
    77: ('good', 'Trapdoor to a crawl space', '开一个通往暗道的活板门'),
    78: ('good', 'Opens a red room once', '开一次红门'),
    79: ('good', '1-20 red hearts', '生成1-20个红心'),
    80: ('neutral', 'Repeats your last pill, card or active', '重复上一次用的胶囊/卡牌/主动'),
    81: ('good', 'Items cycle with a second choice', '房间里的道具多一个可选'),
    82: ('good', 'Enemies drop half hearts (room)', '本房间敌人死亡掉半心'),
    83: ('good', 'Opens every door and red rooms', '打开所有门并开出红门'),
    84: ('good', 'Invincible dash for 3 s, DMG up', '3秒无敌穿过敌人、伤害提升'),
    85: ('good', 'Poison farts and 7 butt bombs', '毒屁和7颗屎屁炸弹'),
    86: ('good', '14 dead birds attack', '14只死鸟攻击敌人'),
    87: ('good', 'Berserk for 10 s: melee, DMG +3', '狂暴10秒：近战、伤害+3'),
    88: ('good', 'Mega Blast for 7.5 s', '超大硫磺火7.5秒'),
    89: ('good', 'Extra life while held', '拿着时多一条命'),
    90: ('neutral', 'Rerolls everything from random pools', '用随机道具池重随房间里所有东西'),
    91: ('neutral', 'Become the Lost for the room', '本房间变成游魂'),
    92: ('good', 'A permanent random familiar', '永久获得一个随机跟班'),
    93: ('good', '1-25 coins', '生成1-25个硬币'),
    94: ('good', '15 locusts', '召唤15只蝗虫'),
    95: ('good', 'The Forgotten fights with you (room)', '本房间遗骸随你一起战斗'),
    96: ('good', '6 item wisps', '生成6个魂火'),
    97: ('good', 'Esau joins you for the floor', '本层以扫和你一起行动'),
}


def main(src, out):
    cats, langs = load_stringtable(src + '/stringtable.sta')
    strings = cats['PocketItems']
    root = ET.parse(src + '/pocketitems.xml').getroot()
    names = {}
    for tag in ('card', 'rune'):
        for e in root.iter(tag):
            i = int(e.get('id'))
            if i == 0:
                continue
            key = e.get('name', '')
            row = strings.get(key[1:]) if key.startswith('#') else None
            en = row[langs[EN]] if row else key
            zh = row[langs[ZH]] if row and row[langs[ZH]] else en
            names[i] = (en.strip(), zh.strip())
    missing = sorted(set(names) ^ set(EFFECTS))
    assert not missing, f'cards without an effect line or not in the game: {missing}'
    lines = ['-- Generated by tools/gen_card_effects.py (names from the installed game\'s pocketitems.xml and',
             '-- stringtable.sta; effect lines written for this mod). Do not edit by hand.',
             '-- [id] = {en, zh, effect = {en, zh}, class = good|bad|neutral}',
             'return {']
    for i in sorted(names):
        cls, een, ezh = EFFECTS[i]
        en, zh = names[i]
        lines.append(f'    [{i}] = {{en = {lua_str(en)}, zh = {lua_str(zh)}, effect = {{en = {lua_str(een)}, '
                     f'zh = {lua_str(ezh)}}}, class = "{cls}"}},')
    lines.append('}')
    open(out, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print(f'{len(names)} cards -> {out}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
