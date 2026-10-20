# Contributing to BiliFix

Thanks for your interest! This is a small, focused mod - contributions are welcome
but keep the project's core philosophy in mind.

## The One Rule

**A fix mod must never break the game it fixes.** Every change is judged against this:
failures degrade silently (warnings at most), never escalate to load errors.

## Getting Started

```powershell
git clone https://github.com/szkele1145/BiliFix
cd BiliFix
./build.ps1        # compile + 131 regression tests + 3 behaviour probes + jar integrity check
```

Requirements: any JDK 21 (the build auto-detects `.tools\jdk21`, the MC runtime, or PATH).

> All three build scripts (`build.ps1`, `build-forge.ps1`, `build-fabric.ps1`) run the
> same suite. That is deliberate: when only `build.ps1` ran tests, the two 1.20.1
> variants had **zero** safety net - a broken `CrashSentinel` would ship straight
> into their jars. If you only build one variant, the others are still guarded.

## Project Layout

```
src/main/java/dev/polaris_fix/bilifix/
  BiliFixMod.java            # @Mod entry + loader-agnostic core init(Path, Path)
  FmlBridge.java             # reflection bridge to FML (never throws; null = fallback)
  CrashSentinel.java         # shutdown-hook diagnostic guardian
  EnvironmentDiagnostics.java# startup environment report
  config/BiliFixConfig.java  # bilifix.toml loader (zero-dependency TOML subset)
  mixin/JarToolMixin.java   # THE fix: hardens watermedia's VLC launch args
src/fabric/                 # Fabric-only sources (never seen by Forge/NeoForge builds)
src/main/resources/
  META-INF/neoforge.mods.toml  # FML metadata (also copied to mods.toml)
  bilifix.mixins.json          # mixin config (@Pseudo, defaultRequire=0; stays JAVA_21,
                               #   1.20.1 variants rewrite to JAVA_17 at packaging)
src/test/java/Regression.java # 137 assertions, mirrors production logic 1:1
src/test/java/ConcurrentRecordProbe.java  # links production classes: event cap under load
src/test/java/FmlBridgeProbe.java         # links production classes: FML reflection chain
src/test/java/ReadmeLogSampleProbe.java   # README log samples vs production strings
src/test/java/GpuDetectProbe.java         # links production classes: GPU detection really works
src/test/java/ArgumentRewriteProbe.java   # links production classes: the hardening logic itself
src/test/java/ForensicsSuppressionProbe.java  # links production classes: suppression must not leak across threads
src/test/java/ConfigParseProbe.java      # links production classes: a UTF-8 BOM must not drop the first setting
src/test/java/MixinTargetGuardProbe.java # links production classes: the silent-skip guard, vs real stubs
src/test/stubs/               # stub FML classes under the REAL package names
src/test/stubs/ci/            # minimal FML stub so CI can compile the production tree
build.ps1          # build + test + package + integrity gate (NeoForge 1.21.1)
build-forge.ps1    # Forge 1.20.1 variant (see docs/cross-loader-research.md)
build-fabric.ps1   # Fabric 1.20.1 variant (staging strip + entrypoint)
deploy.ps1         # local mods + GitHub asset sync
pending-modrinth.ps1  # auto-discovers and uploads versions missing from Modrinth
```

## The Test Layers

Not all tests are equal - know which layer you are looking at:

| Layer | File | Links production code? | What it proves |
| --- | --- | --- | --- |
| Mirror | `Regression.java` | **No** - it re-implements the logic | The *rules* hold. A mirrored copy cannot catch a bug in the production code itself |
| Behaviour | `ConcurrentRecordProbe`, `FmlBridgeProbe`, `ReadmeLogSampleProbe`, `GpuDetectProbe`, `ArgumentRewriteProbe`, `ForensicsSuppressionProbe`, `ConfigParseProbe`, `MixinTargetGuardProbe` | **Yes** | The production code actually behaves as intended |

This distinction matters. `Regression`'s §14 asserts the source contains the keyword
`synchronized` - that checks the prescription, not the effect. The behaviour probes
link the real classes and exercise them:

- `ConcurrentRecordProbe` - 32 threads hammer the real `CrashSentinel.record()`;
  the event list must stay at exactly `MAX_EVENTS`.
- `FmlBridgeProbe` - stub FML classes under the *real* package names answer the
  production `Class.forName`, so the "forName -> enum constant -> get() -> Path"
  chain runs end to end, plus the "never throws" contract.
- `ReadmeLogSampleProbe` - the log lines the READMEs tell users to grep for must
  match the production format strings character for character. A drifted doc
  otherwise produces a false negative: the user sees a log that does not match
  the README and concludes the fix did not apply, when it did.
- `GpuDetectProbe` - calls the real `EnvironmentDiagnostics.detectGpu()` and
  requires a non-blank GPU name on Windows. The class key `{4d36e968-...}` has
  no `DriverDesc` of its own - it lives in the per-adapter subkeys - so the
  class-key query fails and the GPU line never reaches the report.
- `ForensicsSuppressionProbe` - the startup self-check suppresses the forensic
  counters so it does not fake a "media touched" signal. That suppression must
  be thread-local: a global flag also swallows a real playback happening on the
  media thread, losing the evidence the diagnostic file exists to provide.
- `ConfigParseProbe` - calls the real `BiliFixConfig.parse()`. A UTF-8 BOM must
  not drop the first setting: Windows editors save with a BOM by default and
  `Files.readAllLines` does not strip it, so `hwDecoder` would be silently
  ignored while `vout` and `verbose` kept working - the config looks "half
  applied" and nothing points at the BOM.
- `MixinTargetGuardProbe` - the guard that turns a silent mixin skip into a
  visible warning, checked against real stub classes. The target class name is
  a hard-coded constant, so the probe compiles several stub shapes with an
  external `javac` process and loads each through a child-first
  `URLClassLoader`; then it calls the real `evaluate()`, `check(Logger)` and
  `functionalProbe(Logger)`. All four `Status` values are covered, including
  `WATERMEDIA_ABSENT` - which must log info, not warn, because watermedia
  simply being absent is normal.
- `ArgumentRewriteProbe` - calls the real `JarToolMixin` rewriting method with
  a real `CallbackInfoReturnable`. This is the core of the fix, and until this
  probe existed **nothing ever executed it**: the mirror cannot catch a bug in
  the production code, and the README probe only compares log strings. It
  asserts the dangerous parameters (`d3d11va`, `dxva2`, `direct3d11`) are gone
  afterwards, for both `--key value` and `--key=value` spellings.

Every behaviour probe has a **negative test**: break the production code (or the
README) and the probe must fail. A test that cannot fail is not a test.

## Making Changes

1. **Run the build script for your variant first** - it must be green before and
   after your change.
2. If you touch arg-replacement or config-parsing logic, **mirror the change in
   `Regression.java`** and add a test for it (that file duplicates production logic
   by design - keep them in sync; see the header note about test blind spots).
3. If the change is in `CrashSentinel`, `FmlBridge` or anything that logs a line
   the READMEs quote, consider whether a behaviour probe or the README probe
   should cover it.
4. If you touch packaging or the mods.toml, run the **FML precheck list** described
   in `docs/postmortem-1.3.2.md` - the two launch-failure incidents both came from
   that layer, which tests do not cover.
5. Verify the jar with a **strict full-entry read** (the build does this; never
   bypass it).

## Submitting

- Open an issue first for anything non-trivial.
- PRs: one logical change, commit message explains the "why" (not just the "what").
- Note in the PR whether `build.ps1` and (if relevant) `build-forge.ps1` are green.

## Release Notes

Versions are synced across GitHub Releases, Modrinth and the local mods folder via
`deploy.ps1` + `pending-modrinth.ps1`. The jar naming convention is
`BiliFix-<version>-mc<mcversion>-<loader>.jar` - keep it.
