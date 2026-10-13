# BiliFix

**修复整合包播放 B 站视频时游戏无声崩溃（退出码 -1、无任何 Java 崩溃堆栈）的问题。**

[![Modrinth](https://img.shields.io/badge/Modrinth-available-brightgreen)](https://modrinth.com/mod/bilifix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Releases](https://img.shields.io/badge/GitHub-Releases-blue)](https://github.com/szkele1145/BiliFix/releases)

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
- 与 bilibili_media 自己注入 watermedia 的机制（`NetworkAPIMixin`）完全同路数，兼容性有保障
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

## 安装

1. 下载 `BiliFix-x.x.x.jar` 放进 `mods` 目录
2. 需要 NeoForge 21.1（MC 1.21.1）；watermedia 2.1+（可选依赖，没有它本模组不做事）

## 兼容性

| 组件 | 版本 |
|---|---|
| Minecraft | 1.21.1 |
| NeoForge | 21.1.x |
| watermedia | **2.1.x**（实测 2.1.36） |
| bilibili_media | 2.3 |

理论上同样适用于所有用 watermedia 2.1 播放视频的场景（netmusic、waterframes 等），不限 B 站。

> **关于 watermedia 3.0**：3.0 是完全重构的架构（弃用内嵌 libVLC，改用 ffmpeg/WaterTx 媒体引擎），
> 不存在本模组修复的 D3D11VA 崩溃路径，**无需也无效**。本模组只针对 watermedia 2.1.x。

## 验证修复是否生效

启动游戏后日志中应出现：

```
[BiliFix] v1.3.1 已加载：watermedia VLC 硬解崩溃修复（策略: hw=none, vout=gl,any）
[BiliFix] ==== BiliFix 环境诊断 ====
[BiliFix] watermedia: 已安装 ✓（BiliFix 正在守护）
[BiliFix] VLC 参数已加固: --avcodec-hw=none , --vout=gl,any (原 16 项 → 新 16 项)
```

然后播放之前必崩的视频，游戏不再退出。

## 从源码构建

```powershell
./build.ps1   # 编译 + 37 项回归测试 + 打包
```

需要本地 JDK 21（Minecraft 运行时自带即可）和磁盘上的游戏库文件。

## 许可

[MIT](LICENSE)

## 致谢

- 问题诊断基于社区大量"返回值 -1"崩溃报告
- watermedia / videolan4j / libVLC 的开发者们
