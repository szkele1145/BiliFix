# 事故复盘：v1.3.2 的两次游戏启动失败（2026-10-14）

> 一个"修复崩溃的 mod"自己导致游戏无法启动——完整记录根因、教训与防御措施。

## 事故一：jar 结构损坏（"invalid entry size"）

**现象**：游戏在 EARLYDISPLAY 阶段直接失败：
```
Failed to initialize the mod loading system
invalid entry size (expected 0 but got 154 bytes)
```

**根因**：为追求"可复现构建"，用 .NET ZipArchive Update 模式把 jar 内
META-INF 条目时间戳改写为 `1980-01-01 00:00:00 UTC`——这恰好是 zip/DOS
时间戳格式的 epoch 边界，写入后产生非法 central directory，整个 jar 损坏。

**为什么没拦住**：当时用 `jar tf` 验证通过——但那是宽松校验；FML 的
严格读取路径直接失败。**验证工具与消费方不一致 = 验证无效**。

**防御**（commit `4406b85` + `17bd171`）：
- 删除时间戳后处理（正确性 > 可复现性）
- build.ps1 固化"消费方级自检"：逐条目完整读取 + size 声明比对

## 事故二：mods.toml 结构错误（"Missing ModLoader"）

**现象**：游戏走到 mod 加载但拒绝 BiliFix：
```
InvalidModFileException: Missing ModLoader in file (BiliFix-1.3.2.jar)
```

**根因**：`neoforge.mods.toml` 用了扁平 key（`modID="..."` 顶层），
而 NeoForge 21.1 要求标准 FML 结构：
`modLoader="javafml"` + `loaderVersion` + `[[mods]]` 块 + `[[mixins]]` 声明 +
`[[dependencies.<modid>]]`。

**为什么没拦住**：从未与"真实能跑的 mod"做过结构对比；也没有在无游戏
环境下对 FML 识别规则做功课。**第一次给目标平台发版前没有做过一次端到端
加载验证**。

**防御**（commit `afa1f29`）：
- 对照整合包内正常 mod（bilibili_media）重写完整 FML 结构
- 双 toml（mods.toml + neoforge.mods.toml）对齐主流做法
- 建立 FML 链路预检清单（12 项结构断言 + 字段级 diff + 三引号配对）

## 元教训

1. **发布任何面向运行时的产物，必须用消费方的严格路径验证**，不是工具的宽松路径。
2. **与生态内已验证的同类产物做逐字段对比**，比自己凭记忆写格式可靠得多。
3. **在拿不到目标运行时环境时，"模仿正常样本 + 全量静态断言"是最低成本的安全网**。
4. 连续两次事故都源于"在非核心目标上过度工程"（可复现构建）与"核心目标上想当然"
   （toml 结构）——精力应该花在加载链路上。

## 时间线

- 昨晚~今晨：v1.3.2 构建（含 zip 损坏引入）→ 发布双平台
- 11:42 用户启动游戏 → 事故一爆发
- ~12:45 定位 zip 损坏根因 → 修复 + 自检 + 三方重新发布
- 13:26 用户再启动 → 事故二爆发（toml 结构）
- ~13:50 定位 toml 根因 → 对照样本重写 + FML 预检清单 + 三方重新发布
- 待用户下次启动：动态验证（预期 `[BiliFix] v1.3.2 已加载` 日志出现）
