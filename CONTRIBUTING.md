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
./build.ps1        # compile + 85 regression tests + jar integrity check
```

Requirements: any JDK 21 (the build auto-detects `.tools\jdk21`, the MC runtime, or PATH).

## Project Layout

```
src/main/java/dev/polaris_fix/bilifix/
  BiliFixMod.java            # @Mod entry
  CrashSentinel.java         # shutdown-hook diagnostic guardian
  EnvironmentDiagnostics.java# startup environment report
  config/BiliFixConfig.java  # bilifix.toml loader (zero-dependency TOML subset)
  mixin/JarToolMixin.java   # THE fix: hardens watermedia's VLC launch args
src/main/resources/
  META-INF/neoforge.mods.toml  # FML metadata (also copied to mods.toml)
  bilifix.mixins.json          # mixin config (@Pseudo, defaultRequire=0)
src/test/java/Regression.java # 85 assertions, mirrors production logic 1:1
build.ps1          # build + test + package + integrity gate
build-forge.ps1    # Forge 1.20.1 variant (same sources, see docs/cross-loader-research.md)
deploy.ps1         # local mods + GitHub asset sync
pending-modrinth.ps1  # auto-discovers and uploads versions missing from Modrinth
```

## Making Changes

1. **Run `./build.ps1` first** - it must be green before and after your change.
2. If you touch arg-replacement or config-parsing logic, **mirror the change in
   `Regression.java`** and add a test for it (that file duplicates production logic
   by design - keep them in sync; see the header note about test blind spots).
3. If you touch packaging or the mods.toml, run the **FML precheck list** described
   in `docs/postmortem-1.3.2.md` - the two launch-failure incidents both came from
   that layer, which tests do not cover.
4. Verify the jar with a **strict full-entry read** (the build does this; never
   bypass it).

## Submitting

- Open an issue first for anything non-trivial.
- PRs: one logical change, commit message explains the "why" (not just the "what").
- Note in the PR whether `build.ps1` and (if relevant) `build-forge.ps1` are green.

## Release Notes

Versions are synced across GitHub Releases, Modrinth and the local mods folder via
`deploy.ps1` + `pending-modrinth.ps1`. The jar naming convention is
`BiliFix-<version>-mc<mcversion>-<loader>.jar` - keep it.
