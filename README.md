# BiliFix

**Fixes the silent JVM crash (exit code -1) caused by watermedia/libVLC D3D11VA hardware decoding when playing Bilibili videos in Minecraft modpacks.**

[![Modrinth Downloads](https://img.shields.io/modrinth/dt/BiliFix)](https://modrinth.com/mod/BiliFix)
[![Modrinth](https://img.shields.io/modrinth/project/BiliFix?color=green)](https://modrinth.com/mod/BiliFix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Releases](https://img.shields.io/github/release/szkele1145/BiliFix)](https://github.com/szkele1145/BiliFix/releases)
[![Version](https://img.shields.io/badge/version-1.4.7-blue)](CHANGELOG.md)

**English** | [简体中文](README.zh-CN.md)

Fixes the silent JVM crash that kills the game (exit code **-1**, no Java stack trace) when playing Bilibili videos in modpacks using **bilibili_media** + **watermedia** + **waterframes**.

## The Problem

Modpacks containing **bilibili_media** (Bilibili URL resolver) + **watermedia** (embedded libVLC) + **waterframes** (video screens) suffer a silent death:

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

## Crash Diagnostic Guardian (v1.4.0+)

On game exit, BiliFix writes its runtime state to `bilifix-diagnostic.txt` in the
game directory (hardening count, strategy, lifecycle events; the full hardened VLC
arg sequence too when `verbose = true`). If the silent crash ever recurs, this file
is the last Java-side evidence — attach it to your crash report.

The startup diagnostics also report the exact companion-chain versions
(watermedia / bilibili_media / waterframes).

## Install

1. Download the jar for your loader into your `mods` folder:

   | Loader / game version | File |
   |---|---|
   | NeoForge 1.21.1 | `BiliFix-x.x.x-mc1.21.1-neoforge.jar` |
   | Forge 1.20.1 | `BiliFix-x.x.x-mc1.20.1-forge.jar` |
   | Fabric 1.20.1 | `BiliFix-x.x.x-mc1.20.1-fabric.jar` |

2. Requires the matching loader from the table; watermedia 2.1.x (optional dependency — BiliFix silently idles without it)
3. **Recommended companion**: [BiliBiliMedia](https://modrinth.com/mod/bilibili_media) — the Bilibili playback chain this mod primarily fixes

## Compatibility

| Component | Version |
|---|---|
| Minecraft | 1.21.1 (NeoForge) / 1.20.1 (Forge, Fabric) |
| Loaders | NeoForge 21.1.x / Forge 47.x / Fabric Loader 0.14.21+ |
| watermedia | **2.1.x** (tested 2.1.36) |
| bilibili_media | 2.3 |

Also applies to any mod playing videos through watermedia 2.1 (netmusic, waterframes, etc.), not just Bilibili.

> **About watermedia 3.0**: it is a complete rewrite (embedded libVLC replaced by an ffmpeg/WaterTx engine).
> The D3D11VA crash path this mod fixes no longer exists there — **BiliFix is neither needed nor effective for 3.0+**.
> This mod targets watermedia 2.1.x only.

## Verifying It Works

After launching, the log should contain:

```
[BiliFix] v1.4.8 已加载：watermedia VLC 硬解崩溃修复（策略: hw=none, vout=gl,any）
[BiliFix] VLC 参数已加固: --avcodec-hw=none , --vout=gl,any (原 18 项 → 新 18 项)
```

> The argument counts in parentheses come from watermedia and vary by its version
> (18 with 2.1.36). What matters is that both hardening entries were replaced and
> the total count is unchanged — no argument was dropped.

Then play the video that previously crashed the game — it should no longer exit.

> **Note for early 1.3.2 downloads**: two defective 1.3.2 builds were briefly
> published (corrupted zip metadata / wrong mods.toml structure — the game failed
> at startup with *"invalid entry size"* or *"Missing ModLoader"*). Both were
> replaced within hours; if you hit either error, **re-download 1.3.2**.
> See [docs/postmortem-1.3.2.md](docs/postmortem-1.3.2.md) for the full story.

## Building From Source

```powershell
./build.ps1           # compile + run 99 regression tests + package (NeoForge 1.21.1)
./build-forge.ps1     # Forge 1.20.1 variant
./build-fabric.ps1    # Fabric 1.20.1 variant
```

The script auto-detects the JDK 21 (Minecraft runtime works) and the game
libraries folder. Overrides: `BILIFIX_JAVAC=<javac path>`, `BILIFIX_LIBS=<libraries dir>`,
`-WatermediaJar <path>`.

## Documentation

- [CHANGELOG.md](CHANGELOG.md) - every release and what changed
- [CONTRIBUTING.md](CONTRIBUTING.md) - project layout and the change checklist
- [docs/ROADMAP.md](docs/ROADMAP.md) - status of every workstream
- [docs/verification-checklist.md](docs/verification-checklist.md) - how the fix is verified
- [docs/cross-loader-research.md](docs/cross-loader-research.md) - the loader matrix
- [docs/postmortem-1.3.2.md](docs/postmortem-1.3.2.md) - the two startup-failure incidents

## License

[MIT](LICENSE)
