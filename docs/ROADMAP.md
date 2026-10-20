# Roadmap

Status legend: ✅ done · 🔄 in progress · ⏳ planned (needs something) · 💡 idea

## Core fix

- ✅ Harden watermedia 2.1.x VLC launch args (D3D11VA → software decoding)
- ✅ Configurable strategy (`bilifix.toml`: hwDecoder / vout / verbose)
- ✅ Verified in-game: full load, 18 args hardened, clean exit
  (evidence from **v1.3.2** — 14 min — and **v1.4.4** — 51 min, both clean;
  **v1.4.7 has never been launched**, so its new forensic path is unverified)

## Diagnostics

- ✅ Startup environment report (JVM / OS / GPU / memory)
- ✅ Companion-chain version reporting (watermedia / bilibili_media / waterframes)
- ✅ CrashSentinel: three-file evidence chain - `bilifix-session.lock` (leftover
  lock = a native-layer abort, since hooks never ran), `bilifix-diagnostic.txt`
  (exit snapshot), `bilifix-crash.txt` (verdict, survives later clean exits)
- ✅ verbose mode captures the full hardened arg sequence
- ⏳ **v1.4.7 runtime verification** - the jar was deployed 2026-10-16 07:30 but
  has never been launched; the forensic additions (`bilifix-session.lock`,
  `bilifix-crash.txt`, the `media touched` field) are an untested code path
- ⏳ **Video playback stress test** - the original crash trigger, awaiting an
  in-game session (the last unverified mile: everything up to and including the
  VLC arg delivery is log-verified, but no session has ever been shown to
  actually play media — v1.4.4's 51-minute session predates the `media touched`
  field and cannot prove playback)

## Loader matrix

- ✅ NeoForge 1.21.1 (primary, released: v1.4.7; v1.4.8 built & static-verified)
- 🔄 Forge 1.20.1 - built & static-verified (`BiliFix-1.4.8-mc1.20.1-forge.jar`),
  awaiting a runtime test (three FML divergences adapted incl. the mixin
  `CompatibilityLevel` JAVA_21→JAVA_17 staging rewrite, proven against the real
  mixin-0.8.5.jar; see docs/cross-loader-research.md)
- 🔄 Fabric 1.20.1 - entrypoint decoupling **done** (loader-agnostic
  `BiliFixMod.init(Path, Path)` + `BiliFixFabric implements ModInitializer`);
  built & static-verified (`BiliFix-1.4.8-mc1.20.1-fabric.jar`), bytecode audit
  shows zero cross-loader contamination, awaiting a runtime test
- 💡 Forge 1.18.2 / 1.19.2 / 1.21.5 - FMLModContainer bytecode-verified
  identical in 1.18.2 and 1.20.1; the watermedia 2.1.x jar is universal across
  the whole range, so the fix logic needs zero changes - only per-version FML
  boot-layer verification

## Infrastructure

- ✅ One-command build (131 tests + jar integrity gate)
- ✅ **All three build scripts run the full suite** - Regression (131) plus five
  behaviour probes that link the production classes: `ConcurrentRecordProbe`
  (event cap under 32-thread load), `FmlBridgeProbe` (FML reflection chain
  against stub classes under the real package names), `ReadmeLogSampleProbe`
  (README log samples vs the production format strings), `GpuDetectProbe`
  (the GPU model really reaches the diagnostic report) and
  `ArgumentRewriteProbe` (the hardening logic itself, which until now was
  never executed by any test). Previously only `build.ps1` tested, leaving the
  two 1.20.1 variants unguarded
- ✅ Every behaviour probe has a **negative test** proving it can fail:
  concurrency (event list exceeds the cap), FML bridge (missing `get()`),
  README (version drift), GPU (reverted to the class-key query), argument
  rewrite (old value kept / `=` form unrewritten)
- ✅ One-command deploy (mods + GitHub asset, with retry)
- ✅ One-command Modrinth sync (auto-discovers missing versions)
- ✅ Self-contained toolchain (project JDK 21, survives MC runtime trims)
- ⏳ CI workflow (written, all 5 dep URLs verified) - needs a PAT with the
  `workflow` scope to push `.github/workflows/`
- ⏳ Modrinth review (processing - official guidance: 2-4 weeks is normal)
- ✅ **Release creation in `deploy.ps1`** - now auto-creates the tag + Release
  from CHANGELOG when `v<version>` is missing, then refreshes/upload the jar
  asset. Verified end-to-end on 2026-10-16: asset URL
  https://github.com/szkele1145/BiliFix/releases/download/v1.4.7/BiliFix-1.4.7-mc1.21.1-neoforge.jar

## Ideas (unscheduled)

- 💡 In-game `/bilifix` status command (blocked on obfuscated client jar
  tooling - needs a proper ModDevGradle setup, was attempted and rolled back)
- 💡 CrashSentinel upload hint: print the diagnostic file path in the log on exit
