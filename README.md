# BiliFix

**Fixes the silent JVM crash (exit code -1) caused by watermedia/libVLC D3D11VA hardware decoding when playing Bilibili videos in Minecraft modpacks.**

[![Modrinth](https://img.shields.io/badge/Modrinth-available-brightgreen)](https://modrinth.com/mod/bilifix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Releases](https://img.shields.io/badge/GitHub-Releases-blue)](https://github.com/szkele1145/BiliFix/releases)

**English** | [简体中文](README.zh-CN.md)

Fixes the silent JVM crash that kills the game (exit code **-1**, no Java stack trace) when playing Bilibili videos in modpacks using **bilibili_media** + **watermedia** + **waterframes**.

## The Problem

Modpacks combining **bilibili_media** (Bilibili URL resolver) + **watermedia** (embedded libVLC) + **waterframes** (video screens) suffer a silent death:

- The game process just **vanishes** — PCL reports `Minecraft exited, return code: -1`
- The log tail shows normal chat or VLC output, **no Java exception at all**
- Crash analyzers find nothing

## Root Cause

watermedia hardcodes these VLC launch args in `videolan/arguments.json`:

```
--vout direct3d11,glwin32,gl,any
--avcodec-hw d3d11va,dxva2,any
```

This forces **D3D11VA/DXVA2 hardware decoding**. The decoder thread copies hardware surfaces back to the Java heap via vlcj callbacks; on some GPU drivers/multithreaded scenarios this **crashes natively and kills the entire JVM** — leaving no Java-level trace.

## How It Works

BiliFix uses a Mixin to intercept watermedia's argument loading entry point (`JarTool.readArray`), replacing the dangerous args at runtime:

| Original | Replaced with (default) |
|---|---|
| `--avcodec-hw d3d11va,dxva2,any` | `--avcodec-hw none` (software decoding) |
| `--vout direct3d11,glwin32,gl,any` | `--vout gl,any` |

- No jar patching — pure runtime injection, same mechanism bilibili_media itself uses to hook watermedia
- Cost: video falls back to software decoding; slight CPU increase, negligible for 1080p

## Configuration

`.minecraft/config/bilifix.toml` (auto-generated on first launch):

```toml
# Hardware decoding strategy (this is the crash source):
#   none    = software decoding, most stable (default, fixes the crash)
#   any     = VLC auto-pick hardware decoding (may re-crash)
#   d3d11va = force D3D11VA (high risk)
#   dxva2   = force DXVA2 (high risk)
hwDecoder = "none"

# Video output module (vout):
#   gl,any    = OpenGL output (default, safe)
#   original  = keep watermedia's original args
vout = "gl,any"

# Print full argument replacement details to the log
verbose = false
```

Changes take effect after restarting the game.

## Install

1. Drop `BiliFix-x.x.x.jar` into your `mods` folder
2. Requires NeoForge 21.1 (MC 1.21.1); watermedia 2.1.x (optional dependency — BiliFix silently idles without it)

## Compatibility

| Component | Version |
|---|---|
| Minecraft | 1.21.1 |
| NeoForge | 21.1.x |
| watermedia | **2.1.x** (tested 2.1.36) |
| bilibili_media | 2.3 |

Also applies to any mod playing videos through watermedia 2.1 (netmusic, waterframes, etc.), not just Bilibili.

> **About watermedia 3.0**: it is a complete rewrite (embedded libVLC replaced by an ffmpeg/WaterTx engine).
> The D3D11VA crash path this mod fixes no longer exists there — **BiliFix is neither needed nor effective for 3.0+**.
> This mod targets watermedia 2.1.x only.

## Verifying It Works

After launching, the log should contain:

```
[BiliFix] v1.3.0 已加载：watermedia VLC 硬解崩溃修复（策略: hw=none, vout=gl,any）
[BiliFix] VLC 参数已加固: --avcodec-hw=none , --vout=gl,any (原 16 项 → 新 16 项)
```

Then play the video that previously crashed the game — it should no longer exit.

## Building From Source

```powershell
./build.ps1   # compile + run 37 regression tests + package
```

Requires a local JDK 21 (the Minecraft runtime JDK works) and the game libraries on disk.

## License

[MIT](LICENSE)
