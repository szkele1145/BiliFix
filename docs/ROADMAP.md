# Roadmap

Status legend: ✅ done · 🔄 in progress · ⏳ planned (needs something) · 💡 idea

## Core fix

- ✅ Harden watermedia 2.1.x VLC launch args (D3D11VA → software decoding)
- ✅ Configurable strategy (`bilifix.toml`: hwDecoder / vout / verbose)
- ✅ Verified in-game: full load, 18 args hardened, 15+ min stable, clean exit

## Diagnostics

- ✅ Startup environment report (JVM / OS / GPU / memory)
- ✅ Companion-chain version reporting (watermedia / bilibili_media / waterframes)
- ✅ CrashSentinel: three-file evidence chain - `bilifix-session.lock` (leftover
  lock = a native-layer abort, since hooks never ran), `bilifix-diagnostic.txt`
  (exit snapshot), `bilifix-crash.txt` (verdict, survives later clean exits)
- ✅ verbose mode captures the full hardened arg sequence
- ⏳ **Video playback stress test** - the original crash trigger, awaiting an
  in-game session (the last unverified mile: everything up to and including the
  VLC arg delivery is log-verified)

## Loader matrix

- ✅ NeoForge 1.21.1 (primary, released: v1.4.7)
- 🔄 Forge 1.20.1 - built & static-verified, awaiting a runtime test
  (three FML divergences adapted, see docs/cross-loader-research.md)
- ⏳ Fabric - needs entrypoint decoupling from FML (config loader +
  ModContainer), medium effort
- 💡 Forge 1.18.2 / 1.19.2 / 1.21.5 - FMLModContainer bytecode-verified
  identical in 1.18.2 and 1.20.1; the watermedia 2.1.x jar is universal across
  the whole range, so the fix logic needs zero changes - only per-version FML
  boot-layer verification

## Infrastructure

- ✅ One-command build (66 tests + jar integrity gate)
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
- 💡 Automatic GitHub release creation from deploy.ps1 (currently two steps) -
  promoted to a tracked item under Infrastructure above
- 💡 CrashSentinel upload hint: print the diagnostic file path in the log on exit
