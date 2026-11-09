# Isaac Dodge Assist · 以撒紧急躲避

<img src="assets/banner.svg" alt="Isaac Dodge Assist 以撒紧急躲避 项目横幅" width="100%">

An emergency dodge assist for The Binding of Isaac: Repentance+ on Windows: it takes over local keyboard movement only when your path is about to enter danger and a safer direction exists, with optional auto-aim and auto-combat modes.

当前版本：Lua 传感器 0.25.9，原生输入程序 NativeHost 0.4.6。旧 SendInput 辅助已不再使用。

## 它做什么

- **紧急躲避**：人工移动路径即将进入危险范围且存在更安全方向时，接管本机键盘移动；危险解除后交还控制。安全的手动方向会立即归还控制。
- **只改输入**：只调整移动（战斗模式下另含射击），不取消伤害、不改血量或无敌时间；原生程序不覆盖网络设备，不写角色位置或速度。封死走位的局面仍可能受伤。
- **战斗辅助（可选，F10）**：
  - AIM：按住任意射击键时，原生程序把方向换成瞄准方向；不按不射。
  - AUTO：房间有敌人且你不碰方向键时，原生程序接管走位和射击。躲避优先；按方向键就是手动走（仍有躲避），按射击键就是手动射（自动瞄准）。硫磺火等激光按瞬间到达瞄准（不算眼泪飞行和惯性），按光束宽度和长度判断是否打得到。硫磺火蓄满后按收益放：四个方向里挑这一发能造成最多伤害的方向（每个敌人按剩余血量封顶，能穿多个就穿多个），有敌人马上要走进光束线时最多再等 15 帧；站位也优先选一条线能扫到多个敌人的位置，并避开会顺带打死近处自爆怪的方向。Azazel 这类短光束：蓄力时退到 130 外的同一条线上等，按剩余蓄力时间往回靠，蓄满时正好到出手点；光束放出后跟着目标横移，让光束一直压在它身上；被打中会让蓄力作废，所以从零重新计。AUTO 走位不碰道具台和商店商品（联机时不抢队友的），献祭房的地刺对飞行角色也不踩（手动走上去不拦）。
- **多人识别本机角色**：多人时按本机输入设备自动识别你操控的角色，判断不出来时可用 F7 手动选择。
- **危险预览（F9）**：在画面上显示传感器预测的危险区域，战斗模式下另画目标、瞄准点和站位点。
- **楼层情报（按住 Tab）**：全部只读，不改任何游戏数据，联机可用。
  - **楼层地图**：按住 Tab（游戏的地图键）时显示，松开就关；显示本层全部房间，包括还没揭示的隐藏房、超级隐藏房和究极隐藏房，每种特殊房间各有颜色和字母。房间左上角的绿点表示里面见过道具，右上角的黄点表示还有没炸的奖励石头。右侧"各房间收益"按房间列出打完能拿到什么：道具（`~` 为预测）、还不知道的道具数、掉落（硬币、钥匙、胶囊、箱子、奖励石头等），以及进去需要什么（钥匙、炸弹、红钥匙）。没进过的房间排在前面、按收益从高到低；进过的变暗排在后面。装好后第一次重启游戏起，面板画在游戏 HUD 和游戏自己的大地图之上（模组带一个什么都不画的着色器，借它的回调绘制）。
  - **楼层评分**：HUD 第二行常驻 `本层 <等级> <分数>`（英文界面为 `Floor`），后面跟本层高品质道具的数量和还不知道的道具数。分数由三部分组成：道具（见过的按品质 0～4 计分，商店的打五折、恶魔交易打六折，没进过的宝箱房道具台和 Boss 奖励按约 1～2 级品质估算）、掉落（进过的房间按地上实有的计，没进过的按房间布局计）、稀有房间（星象房、图书馆、骰子房等）。地图右侧列出每件道具，以及恶魔房概率、星象房概率、Boss Rush 和 Hush 的剩余时间。
  - **能不能拿到**：评分只按你现在拿得到的算。
    - 究极隐藏房：没解锁任何红门道具（红钥匙、碎钥匙、该隐魂石、逆位月亮）就不计分，标"进不去"；解锁了但没带在身上，只按一部分计。
    - 隐藏房：没炸弹时标"需炸弹"。
    - 第二层起的宝箱房、商店、星象房、图书馆、宝库、骰子房：没钥匙时标"需钥匙"。
    - 商店商品：钱不够时标"钱不够"。
    - 拿不到的道具变灰、排在最后。
  - **面板收益（F5）**：按 F5 打开、再按关闭，列出本层每件道具捡起后的属性变化（伤害、射速、射程、弹速、移速、幸运、心，以及飞行、穿透、硫磺火这类效果），顶部汇总"能拿的全拿"之后面板会怎么变。只在特定情况下生效的写"条件触发"，不给数字。再按一次 F5 关闭。
  - **道具台提示**：走到道具台旁边时，台子上方显示名字、品质和属性变化。联机打完 Boss 后，第一件道具的提示多一行"拿走后出：…"，即下一位玩家会拿到的道具（变成幽灵的队友不算人数）。
    - **变身进度**：道具算哪种变身（嗝屁猫、别西卜、蘑菇头、撒拉弗、鲍勃、嗑药、好的妈妈？、连体、利维坦、拉了、书虫、蜘蛛宝宝），就列出每个人现在几件，例如"嗝屁猫 P1 2/3 P2 0/3"；再拿一件就变身的标绿，已变身的写"已变身"。方便决定谁拿。
    - **计数二十面骰**：有人拿着时，列出连用 1～3 次后台子上会变成什么（跳过没解锁、隐藏和本模式不允许的道具；带车载电池时一次跳两格；爸爸的字条不受影响）。
  - **箱子、袋子、罐子里有什么**：地上没开的箱子（普通、金、红、石、刺、永恒等）和袋子，头顶直接标出打开后会出的东西（道具名和品质、硬币总额、钥匙、炸弹、心、胶囊、卡牌、饰品……），离你最近的那个显示全部；罐子、蘑菇、骷髅、息肉这类可破坏的石头，标出打碎后掉什么，放出蜘蛛、毒气之类的标红，什么都不掉的不标。没进过的房间里，布局固定放的箱子也会算出内容，计入"各房间收益"。原理见 [native/research/chest-contents.md](native/research/chest-contents.md)：内容由箱子自己的掉落随机数决定（打开前不变），罐子由它的生成种子决定，都只读不改。日志核对：打开过的箱子和袋子 373/376 完全一致，箱子里的道具 66/66，罐子 9/9。
  - **便便、火堆、店主、奖励按钮、乞丐和机器**：地上的便便（含金便便）、火堆、店主头顶直接标出打掉后会掉什么，什么都不掉的不标；奖励按钮标出踩下去会给什么（伏击标红）；乞丐和各种机器标出"第几次出什么"（按你现在身上的东西算，12 次内不出就写出来）。没进的房间里布局固定放的这些东西也提前算好，计入"各房间收益"。原理见 [native/research/room-feature-drops.md](native/research/room-feature-drops.md)。日志核对：便便 38/38、火堆 14/14、奖励按钮 1/1、有出货的乞丐和机器 10/10。
  - **卡牌效果**：地上和商店里的卡牌、符文、魂石都标出名字（塔罗牌在地上看起来都一样），离得最近的那张再显示效果，好的绿色、坏的红色。名字取自游戏，效果说明按 Repentance+ 的实际效果写成一行。
  - **胶囊效果**：地上和商店里每颗胶囊的头顶直接标出吃下去的实际效果（含 PHD、False PHD 等转换）。好效果绿色，坏效果红色，中性白色；大号胶囊标"（大）"。用的是游戏自己吃胶囊时调用的同一个读取，已反编译确认只读不写。
  - **奖励石头**：当前房间里没炸的有色石头、超级有色石头、愚人金石头、骷髅/罐子类石头，按种类用彩色菱形框出来。
  - **道具预知**：没进过的宝箱房、隐藏房、星象房、究极隐藏房、诅咒房、图书馆、恶魔房、黑市的道具台和 Boss 奖励，进门前就显示具体道具，评分按真实品质计。联机时 Boss 房按两件预测（第二人那件，三人以上的后续道具不预测）。每章最后的 Boss（It Lives、Hush、Satan、以撒、The Lamb、Mega Satan、Delirium 等）不掉道具，不再预测；虚空层的 Boss 第一件来自随机道具池，不预测。队里有里以撒时，每个道具台的第二个选项也会列出（前面带"或"），评分按两者中较好的算。地图上用青点标出，列表里带 `~`。原理是用纯 Lua 复刻游戏的道具池（`item_emulator.lua`），并跟着游戏每一次取道具同步，从不调用游戏的道具池函数。日志回放 126 次取道具对上 124 次（宝箱房 36/36）。细节见 [native/research/item-emulation.md](native/research/item-emulation.md)。
  - 预知有几种情况会关掉或降级，评分面板最后一行会写明 `forecast exact`、`approx` 或 `off (原因)`：
    - **关掉**：贪婪模式、挑战，以及有人拿着混沌或 TMTRAINER。
    - **降级为近似**：继续游戏，或者在一局中途才加载模组。
    - **不预测**：普通商店的货架、骑士类 Boss 的固定掉落、三四人联机时 Boss 的第三、四件。

## 支持范围

- **游戏**：The Binding of Isaac: Repentance+。原生 DLL 只支持 SHA256 为 `210cade2a1de98550cef52d012174108189d1a0d3926a22c3a1ec12fb3ae4831` 的游戏程序，游戏升级后拒绝安装 Hook。开发调查时的游戏日志版本为 Repentance+ `1.9.7.17.J460`（见 [SPEC.md](SPEC.md)）。
- **系统**：Windows。原生执行器仅适配本机键盘设备。
- **Online**：设计面向仅本机安装的场景，房主和其他玩家无需安装配套组件。联机会把本机输入排队若干次更新后才执行，传感器会测量这段延迟并计入预测窗口。已有 Online 实机日志；0.4.3 修复了一个可复现的输入所有权问题，0.4.4 让未接管时的读键与原版完全一致，但不宣称已经根治 Online 失步。
- **镜像世界**（下水道/矿井 II 的镜子另一边）：游戏把左右键反过来，躲避和自动战斗输出时也左右对调（0.25.9 起；之前在镜像世界里左右是反的）。
- **Deathmatch**（联机通关后的玩家对战房）：对手的眼泪、激光、刀和他跟班的攻击当成危险来躲，你自己的不躲；平时联机队友的攻击照旧不算危险。自动战斗不会去打对手。
- **尚未做到或尚未验证**：
  - 目标是覆盖全部怪物攻击，目前不能声称已经达到，缺口见 [COVERAGE.md](COVERAGE.md) 和下文“当前检测”。
  - 雅各与以扫、遗骸/魂等多实体角色仍显示不支持。
  - 多数算法改动的证据来自 Linux 上的 Lua 模拟和闭环模拟，模拟不能代替实机验收，也不能换算为实机 FPS。

## 工作方式

```
Lua 传感器（游戏内模组） -> 威胁与危险建模 -> 九方向规划评分 -> 游戏日志 IAD1/IAD2 行
  -> NativeHost 读取日志并写入共享内存 -> 原生 DLL 在本机键盘设备的动作读取上返回所选方向
```

**Lua 传感器**（`mod/isaac_dodge_assist/`）

| 文件 | 作用 |
| --- | --- |
| `main.lua` | 热更新加载器：只向游戏注册一次回调并转发给当前核心；`iad_version.lua` 变化时换上新核心（见下文「热更新」） |
| `core.lua` | 传感器核心：组织每次更新的感知、规划与输出 `IAD1` 评分包 |
| `npc_hazards.lua` | 妈妈伸手、炸弹引信与连锁推动、自爆怪死亡爆炸等需要按动画/时序预测的攻击 |
| `motion_prediction.lua` | 敌人与弹体的逐次更新运动快照 |
| `player_motion.lua` | 玩家运动模型，并在游戏中持续校准 |
| `input_queue.lua` | 测量联机输入排队延迟，规划时先按队列中的输入推进角色 |
| `threat_field.lua` | 按时间索引的扫掠圆危险场，供所有移动候选共享 |
| `area_index.lua` | 血池等范围区域的空间索引 |
| `laser_hazards.lua` | 激光几何（直线、曲线、圆环、旋转扫掠） |
| `tnt_hazards.lua` | TNT 引爆预测 |
| `terrain_snapshot.lua` | 每次更新的地形缓存 |
| `dodge_planner.lua` | 对停止和八个方向做轨迹评分 |
| `escape_space.lua` | 风险相同时比较出口与连通空间 |
| `player_binding.lua` | 多人时识别本机操控的角色 |
| `combat.lua` | AIM / AUTO 战斗辅助，输出 `IAD2` 战斗字 |
| `overlay.lua` | F9 危险预览，只绘制，不碰输入；奖励石头的菱形框 |
| `floor_map.lua` | 读本层全部房间（含未揭示的隐藏房）和未进房间的布局 |
| `floor_intel.lua` | 楼层情报：见过的道具、各房间掉落、奖励石头、楼层读数 |
| `floor_score.lua` | 楼层评分 |
| `room_rewards.lua` | 当前房间里没炸的奖励石头 |
| `map_view.lua` | 楼层面板（按住 Tab）：地图、本层图例、评分构成、各房间收益、读数 |
| `hud.lua` | 常驻 HUD（状态行、评分行）、按键提示、联机时的角色标签 |
| `ui.lua` | 界面语言（随游戏语言切换中英文）、字体、文字与矩形绘制 |
| `item_names.lua` | 道具的官方中英文名（由 `tools/gen_item_names.py` 从游戏文件生成） |
| `item_view.lua` | F5"道具与面板收益"页、道具台提示、卡牌和胶囊效果标签 |
| `item_notes.lua` | 道具台提示里按玩家算的变身进度和计数二十面骰结果（只读 ItemConfig 和玩家计数） |
| `chest_forecast.lua` | 箱子、袋子、罐子类石头打开/打碎前的内容（逆向自游戏，纯 Lua） |
| `drop_forecast.lua` | 便便、火堆、店主、奖励按钮打掉/踩下前的掉落，乞丐和机器第几次出什么（逆向自游戏，纯 Lua） |
| `room_features.lua` | 房间里的乞丐、机器、店主、火堆、便便、奖励按钮（布局和当前房间） |
| `card_effects.lua` | 卡牌/符文/魂石的名字和一行效果（`tools/gen_card_effects.py` 生成） |
| `content/shaders.xml` | 不画任何东西的着色器，只为在 HUD 之上绘制面板 |
| `item_stats.lua` | 每件道具的属性变化（由 `tools/gen_item_stats.py` 生成） |
| `pill_effects.lua` / `pill_info.lua` | 胶囊效果的中英文名与好坏分类（`tools/gen_pill_effects.py`）；读取地上胶囊的实际效果 |
| `item_emulator.lua` / `item_pool_data.lua` | 游戏道具池的纯 Lua 复刻及其数据（数据由 `tools/gen_item_pool_data.py` 从游戏文件生成，游戏更新后要重新生成） |
| `item_forecast.lua` | 用复刻的道具池预知未进房间的道具，跟着游戏的每次取道具同步 |
| `diagnostics.lua` | 受伤追踪、性能统计等日志记录 |

**原生输入**（`native/`）

| 文件 | 作用 |
| --- | --- |
| `NativeHost.cs` | x86 .NET 启动器：校验游戏程序，把 DLL 载入游戏进程，读取游戏日志中的评分包并写入共享内存 |
| `PacketClock.cs` | 评分包时钟校准，沿用辅助程序 0.1.1 的算法 |
| `RunArchive.cs` | 局存档：把游戏日志按局存成永久保留的 `.gz`（见下文「日志存档」） |
| `dodge_native.cpp` | 原生 DLL：接管本机键盘设备的移动与射击动作读取，按共享内存中的评分和战斗字返回结果 |
| `build-dll.sh` / `build-host.ps1` | DLL 与 Host 的构建脚本 |

关闭原生辅助窗口、数据过期、游戏失焦或按 ` 暂停时恢复原始输入。DLL 留驻到游戏退出，不修改磁盘上的游戏程序。细节见 [native/README.md](native/README.md)。

`helper/` 与根目录 `Install.cmd` / `Install.ps1` 属于旧 SendInput 方案，不用于当前原生方案。

## 使用与按键

1. 重启游戏，在 Mods 菜单启用 Isaac Dodge Assist。
2. 打开桌面的“以撒原生输入躲避”（指向 NativeHost 0.4.5），保留原生辅助窗口；旧“以撒紧急躲弹”辅助应关闭。
3. 进游戏时屏幕上方会提示“躲避助手 v0.25.9 已加载”（热更新后提示“已更新到 v…+<构建号>”）。
   - 左上角 HUD 有两行。第一行是状态：色点绿色表示正常监视，橙色表示正在判断危险，灰色表示暂停或关闭；后面跟战斗辅助模式，联机时还会显示你绑定的是 P 几。第二行是本层评分。
   - HUD 的危险状态不等于输入已经被接管。
   - 界面语言跟随游戏语言，游戏设为中文就显示中文（用游戏自带的中文字体），其他语言显示英文。
   - 按键都会在屏幕上方弹出一行提示，例如“预测窗口：450 毫秒”。
4. F6 开关，` 键（Esc 下面）按一下暂停、再按一下恢复（换房间也保持；联机表情占用左 Alt），F8 切换预测窗口 250 / 350 / 450 / 600 毫秒（默认 450）。多人时按本机输入设备自动识别你的角色；判断不出来（或想纠正）时用 F7 切换，F7 之后 30 秒内不再自动改绑。当前原生执行器仅适配本机键盘设备。
5. F9 开关危险预览，F10 切换战斗辅助：关 → 自动瞄准（AIM）→ 自动战斗（AUTO）→ 关。按住 Tab 看楼层面板，F5 开关"道具与面板收益"页。

## 热更新

Lua 部分可以在游戏运行中更新，不用退出游戏，也不会中断当前这局。

- `main.lua` 是加载器，只向游戏注册一次回调并转发给当前核心。它约每秒读一次 `iad_version.lua`；构建号变了，就用 `include` 重新读入 `core.lua` 及其模块（`include` 每次调用都会重读文件，不像 `require` 会缓存），换上新核心。
- 换核心时保留开关、` 暂停、预测窗口、战斗模式、F9 预览、已绑定的角色、玩家运动模型、联机输入延迟和 `IAD1` 序号；本房间的缓存和进行中的蓄力从头开始。
- 新核心读入失败（语法错误、文件缺失）时继续用旧核心，日志写 `IAD LOADER: build ... did not load`，同一构建不再重试。新核心换上后约 10 秒内出错，就退回旧核心并写 `IAD LOADER: build ... failed, back to ...`。
- 部署用 `python3 tools/deploy_mod.py --remote '<Windows 上的模组目录>'`（需要 windows-bridge）：只推送哈希不同的文件，推完逐个核对，最后才写 `iad_version.lua` 触发游戏内换核心。`--dry-run` 只列出差异。
- `main.lua` 本身变化、原生 DLL 或 NativeHost 变化仍需要重启游戏或 Host；脚本会提示加载器变了。

## 日志存档

游戏每次启动都会清空重写 `log.txt`。NativeHost 0.4.5 起把每一行原样存档，一局一个文件，永久保留：

- 位置：`%LOCALAPPDATA%\IsaacDodgeAssist\Logs\runs\<开局时间>_<种子>.log.gz`；主菜单、加载等局外的行存在 `launches\<启动时间>.log.gz`；`runs\index.tsv` 记录每局的种子、开始时间、状态和结束原因。
- 局的边界来自传感器写的 `IAD RUN begin|pause|end`：保存退出只算暂停，继续游戏接着写同一个文件；死亡（没有复活）、通关或不保存退出才算结束。
- Host 晚于游戏打开时从头补存；同一次游戏启动中重开 Host 不会重复存。只有开着 Host 时才存档。
- Linux 侧运行 `python3 tools/pull_logs.py` 把新存档拉到 `/wuxie/data/isaac-dodge/logs/`；`tools/deploy_mod.py` 发布后会顺便拉一次。正在进行的那一段（`.part`）要等暂停或结束后才拉得到。

## 安装与卸载

仅支持 Windows，且只认 SHA256 为 `210cade2a1de98550cef52d012174108189d1a0d3926a22c3a1ec12fb3ae4831` 的游戏程序；游戏升级后原生部分拒绝安装 Hook。

1. 把 `mod/isaac_dodge_assist` 复制到游戏目录的 `mods` 下。
2. 构建原生部分：Linux 运行 `bash native/build-dll.sh` 生成 DLL；Windows 把 `NativeHost.cs`、`PacketClock.cs`、`build-host.ps1` 放在同一目录执行构建脚本，再把 DLL 放在生成的 EXE 旁。细节见 [native/README.md](native/README.md)。
3. 启动游戏，在 Mods 菜单启用 Isaac Dodge Assist，再打开 NativeHost，之后按上面的「使用与按键」操作。

原生 DLL 随游戏退出结束，不修改磁盘上的游戏程序。只需停用时，在 Mods 菜单禁用本模组并关闭原生辅助即可。根目录 `Install.cmd` / `Install.ps1` 是旧 SendInput 方案的安装器，不用于当前原生方案；`Uninstall.ps1` 按安装记录删除传感器和旧辅助文件。

## 测试

在项目根目录运行。Lua 测试需要系统 `liblua5.3.so.0`，闭环模拟需要 PATH 中有 `lua5.3`。

**Lua 回归**（加载实际模组源码，不需要游戏）

```bash
python3 native/tests/planner_regression.py
```

不带参数时依次运行：全部模组 Lua 语法检查、`planner_regression.lua`（其中包含 `main_integration.lua`）、`laser_regression.lua`、`diagnostics_regression.lua`、`combat_regression.lua`、`player_binding_regression.lua`，以及带 `PERF_ASSERT=1` 的 `performance_regression.lua` 性能护栏。`path_regression.py` 是转发到同一组回归的兼容入口。局存档（C#）单独运行 `bash native/tests/run_archive_regression.sh`（需要 dotnet 8 SDK 和 gzip）。

传入单个文件时只运行语法检查和该文件，例如：

```bash
python3 native/tests/planner_regression.py native/tests/terrain_regression.lua
PERF_ASSERT=1 python3 native/tests/planner_regression.py native/tests/performance_regression.lua
```

**闭环模拟**

`closed_loop_sim.lua` 用实际 `main.lua`、原生 `rank()` 的 Lua 移植和按实测参数运行的房间做闭环模拟，输出受伤、接管和耗时：

```bash
lua5.3 native/tests/closed_loop_sim.lua <modDir|none> <latencyTicks> <seed> <scenario> [updates]
```

`closed_loop_matrix.py` 按模组版本 × 0～3 帧延迟 × 场景 × 种子汇总每模拟分钟受伤次数：

```bash
python3 native/tests/closed_loop_matrix.py <label>=<modDir|none> ... [--updates N] [--seeds N]
python3 native/tests/closed_loop_matrix.py new=mod/isaac_dodge_assist
```

场景有 `turrets`、`chasers`、`spread`、`dense`、`flies`，默认运行前四种，用 `SIM_SCENARIOS` 指定。其他环境变量：`SIM_INPUT_DELAY`（联机输入排队帧数）、`SIM_F8`（按 F8 的次数）、`SIM_COMBAT=auto`（自动战斗，额外输出每分钟击杀）。模拟敌人只有直线子弹和追击，不能代替实机验收。

**原生部分**

- DLL：Linux 运行 `bash native/build-dll.sh` 构建；交叉编译 `native/tests/abi_and_ranking.cpp` 后在 Windows 运行（覆盖评分、战斗决策、原始输入快照、3ms 重用边界与调用 ABI）。
- Host 配对：Windows 在 `native` 目录用 `csc /target:exe /main:HostProtocolRegression /out:HostProtocolRegression.exe PacketClock.cs tests\host_protocol_regression.cs`，再运行生成的 EXE（覆盖 `IAD2` 一次性消费、错序、重置、畸形与重复）。

## 检查与证据范围

0.4 已完成 Lua 语法检查，以及空场、通用空中 NPC、范围伤害、直线激光、圆环和友方来源过滤的直接几何演练。0.5 另对熄灭/燃烧篝火过滤、加速接近、逃生排序、远端碰墙进行了集中模拟检查。该检查使用模拟数据，不等于游戏内避让验收。Windows 辅助未改动，沿用已完成的编译及日志协议检查。此前实机日志出现过原生接管状态，本次新增伤害类别尚未进行实机验收。

API 依据：[激光路径与圆环](https://wofsauge.github.io/IsaacDocs/rep/EntityLaser.html)、[特效属性](https://wofsauge.github.io/IsaacDocs/rep/EntityEffect.html)、[特效类别](https://wofsauge.github.io/IsaacDocs/rep/enums/EffectVariant.html)、[炸弹](https://wofsauge.github.io/IsaacDocs/rep/EntityBomb.html)。

## 当前检测

| 伤害类型 | 实现与限制 |
| --- | --- |
| 敌方弹幕 | 逐帧位置与速度外推；弯曲、追踪、分裂和突然加速仍是近似预测 |
| 怪物身体、冲撞、跳跃 | 当前可碰撞并造成伤害的敌对 NPC 进入接触预测；跳落单列预警，未读取每种攻击的精确落地帧 |
| 激光 | 敌方直线、采样曲线与圆环；使用采样路径、半径及旋转参数预测，宽度保守估计；乌列/加百列、Vis/Double Vis/暴食、Rage Creep、Monstro II、Dark One、The Haunt（无皮阶段）、Satan、Mega Satan、Krampus、Eye（瞄准你）、Red Ghost 和硫磺漩涡另有发射前预警，其他未生成光束仍有缺口 |
| 地面及范围攻击 | 敌方血池/毒池类、火焰、冲击波、落点目标、脚踩/手抓/火箭等常见特效族，以及公开接触伤害的其他特效；按危险圈估计，可能提前或额外避让；飞行忽略已识别的地面池 |
| 爆炸 | 有爆炸伤害的炸弹从出现就避让，包含自己放的炸弹；引信读 `Pulse` 动画，爆炸前后一帧按必中；滚动的炸弹按实测摩擦（每帧速度 ×0.95，Super Troll 不减速）外推落点；先爆的炸弹会把范围内后爆的炸弹以约 14 的初速推开，被推的炸弹沿推开方向覆盖它在剩余引信内能滑到的距离，按爆炸先后连锁计算（最多 8 颗）；爆炸余烟不再加入危险圈；TNT 和爆炸岩石单独预警 |
| 自爆怪 | 普通/溺水/污染 Boom Fly、Mulliboom、Kamikaze/Holy Leech、Black Maw、Ticking Spider、Poison Mind、Black Bony、Fly Bomb：预测到玩家方眼泪或激光会打死它时，从死亡前后几帧起把它周围（中心距约 85）当必中；只是血量很低时为预警。AUTO 不在它死时离自己不到 110 的情况下开致命一发，会追人的自爆怪保持 150 以上、周围始终有预警圈，并优先在远处打掉 |

目标是覆盖全部怪物攻击，目前不能声称已经达到。特殊脚本伤害、尚未生成且没有公开预警的攻击、未识别的专用特效，以及 TNT 的精确爆炸时机仍有缺口；自爆怪由跟班、刀或炸弹打死、炸弹推力的真实大小目前都只是保守估计，`IAD BURST`/`IAD BOMB` 测量日志用于校准。这里只调整移动，不取消伤害、不改血量或无敌时间；封死走位的局面仍可能受伤。伤害回调会向游戏日志记录 `IAD HIT` 的来源类型与状态，供定位漏判；其他模组取消的伤害也可能触发此记录，因此它不等同于实际扣血统计。

检测会排除可追溯到玩家、跟班或友方实体的激光与特效。玩家炸弹仍按可能伤到自己处理。方向评分同时检查墙壁、障碍物、坑与尖刺；移动速度、攻击范围和碰撞模型均为近似值。雅各与以扫、遗骸/魂等多实体角色仍显示不支持。

## 文档

- [CHANGELOG.md](CHANGELOG.md)：各版本变更记录
- [SPEC.md](SPEC.md)：最初的设计草案
- [COVERAGE.md](COVERAGE.md)：攻击覆盖记录与已知缺口
- [native/README.md](native/README.md)：原生输入程序的构建、支持版本、退出行为与版本记录

## 许可

MIT，见 [LICENSE](LICENSE)。自动瞄准的提前量与弹道通畅规则沿用 [isaac-jev](https://github.com/chongchong59699/isaac-jev)（MIT）。
