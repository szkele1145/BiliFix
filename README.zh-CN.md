# BiliFix

**修复整合包播放 B 站视频时游戏无声崩溃（退出码 -1、无任何 Java 崩溃堆栈）的问题。**

[![Modrinth Downloads](https://img.shields.io/modrinth/dt/BiliFix)](https://modrinth.com/mod/BiliFix)
[![Modrinth](https://img.shields.io/modrinth/project/BiliFix?color=green)](https://modrinth.com/mod/BiliFix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Releases](https://img.shields.io/github/release/szkele1145/BiliFix)](https://github.com/szkele1145/BiliFix/releases)
[![Version](https://img.shields.io/badge/version-1.4.7-blue)](CHANGELOG.md)

[English](README.md) | **简体中文**

## 问题是什么？

用 **bilibili_media**（B 站视频解析）+ **watermedia**（内嵌 libVLC）+ **waterframes**（播放屏幕）的整合包/服务器，看视频一段时间后游戏会**直接消失**：

- PCL 显示 `Minecraft 已退出，返回值：-1`
- 日志结尾只有正常的聊天记录或 VLC 输出，**没有任何 Java 异常**
- 崩溃分析器显示"未找到可能的原因"

## 根因

watermedia 创建 VLC 实例时写死了（`videolan/arguments.json`）：

```
--vout direct3d11,glwin32,gl,any
--avcodec-hw d3d11va,dxva2,any
```

强制 D3D11VA/DXVA2 硬解码。解码线程把硬解表面经 vlcj 回调拷贝到 Java 堆时，在部分显卡驱动/多线程场景下**原生层直接崩溃，杀死整个 JVM**——所以没有任何 Java 层的痕迹。

## 修复方式

BiliFix 用 Mixin 拦截 watermedia 读取 VLC 参数的入口（`JarTool.readArray`），运行时替换为安全参数：

| 原参数 | 替换为（默认） |
|---|---|
| `--avcodec-hw d3d11va,dxva2,any` | `--avcodec-hw none`（纯软解） |
| `--vout direct3d11,glwin32,gl,any` | `--vout gl,any` |

- 不修改 watermedia 的 jar 文件，纯运行时注入
- 与 bilibili_media 自己注入 watermedia 的机制完全同路数，兼容性有保障
- 代价只是视频改软解、CPU 占用略增，1080p 无压力

## 配置

`.minecraft/config/bilifix.toml`（首次启动自动生成）：

```toml
# 硬解码策略（崩溃根源就在这）：
#   none    = 软件解码，最稳定（默认，修复崩溃）
#   any     = VLC 自动选择硬解（可能复现崩溃）
#   d3d11va = 强制 D3D11VA（高风险）
#   dxva2   = 强制 DXVA2（高风险）
hwDecoder = "none"

# 视频输出模块（vout）：
#   gl,any    = OpenGL 输出（默认，安全）
#   original  = 保留 watermedia 原始参数
vout = "gl,any"

# 日志中打印完整参数替换详情
verbose = false
```

修改后重启游戏生效。

## 崩溃诊断守护（v1.4.0+）

游戏退出时，BiliFix 会把运行状态写入游戏目录的 `bilifix-diagnostic.txt`
（加固次数、策略、生命周期事件；`verbose = true` 时含完整 VLC 参数序列）。
如果无声崩溃复发，这个文件是 Java 侧留下的最后证据——把它附在崩溃报告里。

启动日志的诊断区还会报出前置链路的精确版本（watermedia / bilibili_media / waterframes）。

## 安装

1. 下载对应加载器的 jar 放进 `mods` 目录：

   | 加载器 / 游戏版本 | 文件名 |
   |---|---|
   | NeoForge 1.21.1 | `BiliFix-x.x.x-mc1.21.1-neoforge.jar` |
   | Forge 1.20.1 | `BiliFix-x.x.x-mc1.20.1-forge.jar` |
   | Fabric 1.20.1 | `BiliFix-x.x.x-mc1.20.1-fabric.jar` |

2. 需要上表对应的加载器；watermedia 2.1+（可选依赖，没有它本模组不做事）
3. **前置建议**：[哔哩哔哩WaterMedia兼容模组（BiliBiliMedia）](https://modrinth.com/mod/bilibili_media)——本模组修复的主要场景就是它的 B 站视频播放链路

## 兼容性

| 组件 | 版本 |
|---|---|
| Minecraft | 1.21.1（NeoForge）/ 1.20.1（Forge、Fabric） |
| 加载器 | NeoForge 21.1.x / Forge 47.x / Fabric Loader 0.14.21+ |
| watermedia | **2.1.x**（真机验证：2.1.36 · 签名探针验证：2.1.37） |
| bilibili_media | 2.3 |

理论上同样适用于所有用 watermedia 2.1 播放视频的场景（netmusic、waterframes 等），不限 B 站。

> **关于 watermedia 3.0**：3.0 是完全重构的架构（弃用内嵌 libVLC，改用 ffmpeg/WaterTx 媒体引擎），不存在本模组修复的 D3D11VA 崩溃路径，**无需也无效**。本模组只针对 watermedia 2.1.x。

## 验证修复是否生效

启动游戏后日志中应出现：

```
[BiliFix] v1.4.8 已加载：watermedia VLC 硬解崩溃修复（策略: hw=none, vout=gl,any）
[BiliFix] ==== BiliFix 环境诊断 ====
[BiliFix] watermedia: 已安装 ✓（BiliFix 正在守护）
[BiliFix] Mixin 注入目标自检通过: org.watermedia.core.tools.JarTool.readArray(String) 唯一匹配
[BiliFix] 功能自检通过: --avcodec-hw=none , --vout=gl,any —— 注入已生效（端到端验证）
[BiliFix] VLC 参数已加固: --avcodec-hw=none , --vout=gl,any (原 18 项 → 新 18 项)
```

> 括号里的参数数量由 watermedia 决定，会随其版本变化（2.1.36/2.1.37 实测均为 18 项，
> `javap` 已确认两版 `JarTool.readArray(String)` 签名一致）；
> 关键是两个加固项已替换、且总项数不变（没有丢参数）。

### 怎么看懂这几行

| 日志行 | 含义 | 缺失说明什么 |
| --- | --- | --- |
| `Mixin 注入目标自检通过` | 找到了唯一匹配的注入点 | 出现 `⚠ 功能自检无法判定` 或 `功能自检失败` 则注入未生效，**修复也就没生效** |
| `功能自检通过: --avcodec-hw=... , --vout=...` | **端到端验证**：真的调用了一次 `readArray` 并确认两个参数已被改写 | 这行是最终判据——它证明的是行为，不是"代码看起来在" |
| `VLC 参数已加固` | 实际播放媒体时触发了改写 | 没这行说明你还没播放过视频（**这很正常**，不是故障） |

> **v1.4.8 起**，`功能自检通过` 那一行由启动时的自检产生（不是播放视频才有），
> 所以**不播放视频也能确认修复是否生效**。它通过 `CrashSentinel` 的取证抑制开关
> 发起自检，不会污染"是否真的播放过媒体"这一取证字段。

然后播放之前必崩的视频，游戏不再退出。

> **早期 1.3.2 下载者注意**：曾短暂发布过两个有缺陷的 1.3.2 构建（zip 元数据损坏 / mods.toml 结构错误——游戏启动时报 *"invalid entry size"* 或 *"Missing ModLoader"*)。已在数小时内全部替换；如遇到任一报错，请**重新下载 1.3.2**。完整复盘见 [docs/postmortem-1.3.2.md](docs/postmortem-1.3.2.md)。

## 从源码构建

```powershell
./build.ps1            # 编译 + 131 项回归测试 + 打包（NeoForge 1.21.1）
./build-forge.ps1      # Forge 1.20.1 变体
./build-fabric.ps1     # Fabric 1.20.1 变体
```

脚本自动探测 JDK 21（Minecraft 运行时即可）与游戏库目录。可用环境变量覆盖：BILIFIX_JAVAC、BILIFIX_LIBS，或参数 -WatermediaJar。

## 部署

```powershell
./deploy.ps1 -Variant neoforge   # 部署进 1.21.1 NeoForge 实例
./deploy.ps1 -Variant fabric     # 部署进 1.20.1 Fabric 实例
./deploy.ps1 -Variant forge      # 需 BILIFIX_INSTANCE=<目录>（暂无 Forge 测试床）
./deploy.ps1 -Variant fabric -SkipRemote   # 只部署本地 mods 目录
```

把 `build/` 里对应的 jar 部署到实例 `mods/` 目录（先清除旧 BiliFix jar）；
不加 `-SkipRemote` 时还会**增量**同步 GitHub Release 资产（按变体各自处理，
不会触碰其他变体的资产）。

## 文档索引

- [CHANGELOG.md](CHANGELOG.md) — 每个版本的变更
- [CONTRIBUTING.md](CONTRIBUTING.md) — 项目结构与改动清单
- [docs/ROADMAP.md](docs/ROADMAP.md) — 各条工作线状态
- [docs/verification-checklist.md](docs/verification-checklist.md) — 修复的验证方法
- [docs/cross-loader-research.md](docs/cross-loader-research.md) — 加载器适配矩阵
- [docs/postmortem-1.3.2.md](docs/postmortem-1.3.2.md) — 两次启动失败事故复盘

## 许可

[MIT](LICENSE)

## 致谢

- 问题诊断基于社区大量"返回值 -1"崩溃报告
- watermedia / videolan4j / liaVLC 的开发者们
