# 当前安装版本的原生输入链路

二进制 SHA256：210cade2a1de98550cef52d012174108189d1a0d3926a22c3a1ec12fb3ae4831。下列为首选映像基址 0x400000 下的 VA，运行时使用 RVA 加真实模块基址。

## 已观察到的静态事实

- RTTI 将 InputDeviceKeyboard@Input@KAGE 定位到虚表 0xba1678。槽 +0x30 是 IsActionPressed（0xa1e8d0），+0x38 是 GetActionValue（0xa1ea20）。后者是 thiscall float(action)，通过 x87 返回。
- NetInputDevice@IsaacRepentancePlus 使用另一个虚表 0xb78030；本实现不改它。
- 网络输入收集函数在 0x901d56 取得底层本机设备，0x901e11 调用输入帧打包函数 0x900ca0。
- 0x900ca0 在 0x900d69 读取设备槽 +0x30，在 0x900d8c、0x900dd9 读取槽 +0x38。动作 1 减 0 为横向，3 减 2 为纵向，再量化到输入帧。
- 玩家移动包装函数 0x779360 经 0x9562d0 获取移动值；没有把这个仿真阶段函数作为 Hook 点。

据此选择只替换键盘设备的两个虚表槽，让替代值在本机输入打包前产生。此处具有进入原有同步链路的静态依据；实际 Online 是否一致仍待运行验证。

原始反汇编保存在 <work>/isaac-native-input/input-snapshot.asm、<work>/isaac-native-input/keyboard-action.asm、<work>/isaac-native-input/net-device.asm。公开 REPENTOGON 的完整函数签名未匹配此版本，故没有直接套用其偏移。
