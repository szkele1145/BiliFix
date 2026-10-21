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

- ✅ One-command build (137 tests + jar integrity gate)
- ✅ **Every production class has a behaviour probe that links it** (9/9):
  `BiliFixMod`, `CrashSentinel`, `EnvironmentDiagnostics`, `MixinTargetGuard`,
  `BiliFixConfig`, `JarToolMixin`, `FmlBridge`
- ✅ **All three build scripts run the full suite** - Regression (137) plus seventeen
  behaviour probes that link the production classes: `ConcurrentRecordProbe`
  (event cap under 32-thread load), `FmlBridgeProbe` (FML reflection chain
  against stub classes under the real package names), `ReadmeLogSampleProbe`
  (README log samples vs the production format strings), `GpuDetectProbe`
  (the GPU model really reaches the diagnostic report),
  `ArgumentRewriteProbe` (the hardening logic itself, which until now was
  never executed by any test), `ForensicsSuppressionProbe` (the startup
  self-check's suppression must not leak across threads),
  `ConfigParseProbe` (a UTF-8 BOM in the config file must not drop the
  user's first setting), `MixinTargetGuardProbe` (the guard that turns a
  silent mixin skip into a visible warning, checked against real stub
  classes), `StartupLogTruthProbe` (the startup line must show the
  value that is actually in effect, not the raw string the user typed -
  5 of 9 value combinations used to disagree) and `ForensicsVoutProbe`
  (the diagnostics file must not say "vout=null" when the user set
  vout=original - the file is the only thing that survives a native
  crash) and `UnknownConfigKeyProbe` (a mistyped config key must be
  visible - the config used to load "successfully" while the setting
  was silently dropped, with nothing in the log pointing at the cause)
  and `NullElementProbe` (a null entry in the argument array must not
  make the hardening logic throw - the mixin is supposed to be the one
  thing that cannot break playback) and `FmlModVersionProbe` (the
  SUCCESS path of `FmlBridge.modVersion`, which until now had no coverage
  at all - if it breaks, the diagnostics report an installed watermedia as
  missing) and `ConfigDefaultProbe` (the default values must have exactly
  ONE source of truth - they used to be hard-coded in four places, and a
  drift there means the user's config file says one thing while the
  effective behaviour is another, with the log claiming the config loaded
  fine) and `MirrorParityProbe` (the Regression mirror is an INDEPENDENT
  re-implementation, so it has to be updated BY HAND when production
  changes on purpose - three real divergences were measured this way, and
  a stale mirror gives the opposite answer from production while every
  mirror test still passes) and `FabricInitProbe` (the Fabric loader is the
  only one with its own entry point, so the order inside
  `BiliFixMod.init()` is semantic - load the config before the dirs are
  injected and the config file lands somewhere else, silently) and
  `NormalizedWarningProbe` (an unset field means "not set", not "rewritten" -
  three of the most common configs were warned about as normalized, printing a
  line with two unchanged values plus a literal null during crash triage).
  and `RealArgumentsProbe` (the whole fix rests on ONE mixin target, and every
  assertion about it used a HAND-WRITTEN stand-in for watermedia's parameter
  table - a hand-written table proves the rewrite works on hand-written data,
  not that it works on what watermedia actually ships; this probe runs the
  PRODUCTION rewrite against the real table read out of the real
  watermedia-2.1.36.jar, and also checks the jar's bytecode to prove
  `JarTool.readArray` is the method `PlayerAPI` really calls)
  and `DocStructureProbe` (the release notes once had a `### 修复` heading
  split into `### 修` / `` / `复` by a `String.Replace` whose anchor crossed a
  newline - the file stayed valid Markdown, so no build noticed, but the
  section rendered as empty with a stray paragraph).
  Previously only
  `build.ps1` tested, leaving the two 1.20.1 variants unguarded
- ✅ Every behaviour probe has a **negative test** proving it can fail:
  concurrency (event list exceeds the cap), FML bridge (missing `get()`),
  README (version drift), GPU (reverted to the class-key query), argument
  rewrite (old value kept / `=` form unrewritten), forensics (suppression
  leaks across threads), config parse (BOM-unaware parser), mixin target
  guard (overload / missing-target detection removed), startup log
  (raw config fields printed again), forensics vout
  (raw voutValue() written to the diagnostics file again), unknown
  config key (the warning removed again), null element
  (both null guards removed again), FML mod version
  (the version lookup replaced by the mod id), config default (the defaults hard-coded again), mirror parity (the mirror drifted from production), fabric init (the injected dirs are not used), normalized warning (an unset field warned as normalized), real arguments (the dangerous values survive the rewrite again), doc structure (a heading is split in two)
- ✅ **Negative tests are in the repository**. They used to live in `out/`,
  which is git-ignored: the evidence that the probes can actually fail
  existed on one machine only. Now they live in `src/test/negative/` and
  `run-all-negative-tests.ps1` runs all of them - wired into the three
  build scripts, the faithful CI simulation and the GitHub Actions
  workflow.
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