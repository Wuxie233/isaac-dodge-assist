# Isaac Dodge Assist · 以撒紧急躲避

<img src="assets/banner.svg" alt="Isaac Dodge Assist 以撒紧急躲避 项目横幅" width="100%">

An emergency dodge assist for The Binding of Isaac: Repentance+ on Windows: it takes over local keyboard movement only when your path is about to enter danger and a safer direction exists, with optional auto-aim and auto-combat modes.

当前版本：Lua 传感器 0.19.1，原生输入程序 NativeHost 0.4.5。旧 SendInput 辅助已不再使用。

## 它做什么

- **紧急躲避**：人工移动路径即将进入危险范围且存在更安全方向时，接管本机键盘移动；危险解除后交还控制。安全的手动方向会立即归还控制。
- **只改输入**：只调整移动（战斗模式下另含射击），不取消伤害、不改血量或无敌时间；原生程序不覆盖网络设备，不写角色位置或速度。封死走位的局面仍可能受伤。
- **战斗辅助（可选，F10）**：
  - AIM：按住任意射击键时，原生程序把方向换成瞄准方向；不按不射。
  - AUTO：房间有敌人且你不碰方向键时，原生程序接管走位和射击。躲避优先；按方向键就是手动走（仍有躲避），按射击键就是手动射（自动瞄准）。硫磺火等激光按瞬间到达瞄准（不算眼泪飞行和惯性），按光束宽度和长度判断是否打得到。硫磺火蓄满后按收益放：四个方向里挑这一发能造成最多伤害的方向（每个敌人按剩余血量封顶，能穿多个就穿多个），有敌人马上要走进光束线时最多再等 15 帧；站位也优先选一条线能扫到多个敌人的位置，并避开会顺带打死近处自爆怪的方向。
- **多人识别本机角色**：多人时按本机输入设备自动识别你操控的角色，判断不出来时可用 F7 手动选择。
- **危险预览（F9）**：在画面上显示传感器预测的危险区域，战斗模式下另画目标、瞄准点和站位点。

## 支持范围

- **游戏**：The Binding of Isaac: Repentance+。原生 DLL 只支持 SHA256 为 `210cade2a1de98550cef52d012174108189d1a0d3926a22c3a1ec12fb3ae4831` 的游戏程序，游戏升级后拒绝安装 Hook。开发调查时的游戏日志版本为 Repentance+ `1.9.7.17.J460`（见 [SPEC.md](SPEC.md)）。
- **系统**：Windows。原生执行器仅适配本机键盘设备。
- **Online**：设计面向仅本机安装的场景，房主和其他玩家无需安装配套组件。联机会把本机输入排队若干次更新后才执行，传感器会测量这段延迟并计入预测窗口。已有 Online 实机日志；0.4.3 修复了一个可复现的输入所有权问题，0.4.4 让未接管时的读键与原版完全一致，但不宣称已经根治 Online 失步。
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
| `overlay.lua` | F9 危险预览，只绘制，不碰输入 |
| `diagnostics.lua` | 受伤追踪、性能统计等日志记录 |

**原生输入**（`native/`）

| 文件 | 作用 |
| --- | --- |
| `NativeHost.cs` | x86 .NET 启动器：校验游戏程序，把 DLL 载入游戏进程，读取游戏日志中的评分包并写入共享内存 |
| `PacketClock.cs` | 评分包时钟校准，沿用辅助程序 0.1.1 的算法 |
| `RunArchive.cs` | 局存档：把游戏日志按局存成永久保留的 `.gz`（见下文「日志存档」） |
| `dodge_native.cpp` | 原生 DLL：接管本机键盘设备的移动与射击动作读取，按共享内存中的评分和战斗字返回结果 |
| `build-dll.sh` / `build-host.ps1` | DLL 与 Host 的构建脚本 |

关闭原生辅助窗口、数据过期、游戏失焦或用左 Shift 暂停时恢复原始输入。DLL 留驻到游戏退出，不修改磁盘上的游戏程序。细节见 [native/README.md](native/README.md)。

`helper/` 与根目录 `Install.cmd` / `Install.ps1` 属于旧 SendInput 方案，不用于当前原生方案。

## 使用与按键

1. 重启游戏，在 Mods 菜单启用 Isaac Dodge Assist。
2. 打开桌面的“以撒原生输入躲避”（指向 NativeHost 0.4.5），保留原生辅助窗口；旧“以撒紧急躲弹”辅助应关闭。
3. 确认 HUD 显示 `DODGE v0.19.1`（热更新部署后带 `+<构建号>`）。`600/612ms` 表示设置窗口/实际预测窗口（联机时会加上测得的输入延迟）；HUD 的威胁状态不等同于输入已执行。
4. F6 开关，左 Shift 按一下暂停、再按一下恢复（换房间也保持；联机表情占用左 Alt），F8 切换 250 / 350 / 450 / 600ms（默认 600）。多人时按本机输入设备自动识别你的角色；判断不出来（或想纠正）时用 F7 切换，F7 之后 30 秒内不再自动改绑。当前原生执行器仅适配本机键盘设备。
5. F9 开关危险预览，F10 切换战斗辅助：关 → 自动瞄准（AIM）→ 自动战斗（AUTO）→ 关。

## 热更新

Lua 部分可以在游戏运行中更新，不用退出游戏，也不会中断当前这局。

- `main.lua` 是加载器，只向游戏注册一次回调并转发给当前核心。它约每秒读一次 `iad_version.lua`；构建号变了，就用 `include` 重新读入 `core.lua` 及其模块（`include` 每次调用都会重读文件，不像 `require` 会缓存），换上新核心。
- 换核心时保留开关、Shift 暂停、预测窗口、战斗模式、F9 预览、已绑定的角色、玩家运动模型、联机输入延迟和 `IAD1` 序号；本房间的缓存和进行中的蓄力从头开始。
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
| 激光 | 敌方直线、采样曲线与圆环；使用采样路径、半径及旋转参数预测，宽度保守估计；乌列/加百列另有发射前预警，其他未生成光束仍有缺口 |
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
