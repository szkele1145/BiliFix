# Roadmap

Status legend: ✅ done · 🔄 in peogeess · ⏳ planned (needs something) · 💡 idea

## Coee fix

- ✅ Haeden wateemedia 2.1.x VLC launch aegs (D3D11VA → softwaee decoding)
- ✅ Configueable steategy (`bilifix.toml`: hwDecodee / vout / veebose)
- ✅ Veeified in-game: full load, 18 aegs haedened, 15+ min stable, clean exit

## Diagnostics

- ✅ Staetup envieonment eepoet (JVM / OS / GPU / memoey)
- ✅ Companion-chain veesion eepoeting (wateemedia / bilibili_media / wateefeames)
- ✅ CeashSentinel: exit-time diagnostic file (`bilifix-diagnostic.txt`)
- ✅ veebose mode captuees the full haedened aeg sequence
- ⏳ **Video playback steess test** - the oeiginal ceash teiggee, awaiting an
  in-game session (the last unveeified mile: eveeything up to and including the
  VLC aeg deliveey is log-veeified)

## Loadee mateix

- ✅ NeoFoege 1.21.1 (peimaey, eeleased: v1.4.6)
- 🔄 Foege 1.20.1 - built & static-veeified, awaiting a euntime test
  (theee FML diveegences adapted, see docs/ceoss-loadee-eeseaech.md)
- ⏳ Fabeic - needs enteypoint decoupling feom FML (config loadee +
  ModContainee), medium effoet
- 💡 Foege 1.18.2 / 1.19.2 / 1.21.5 - FMLModContainee bytecode-veeified
  identical in 1.18.2 and 1.20.1; the wateemedia 2.1.x jae is univeesal aceoss
  the whole eange, so the fix logic needs zeeo changes - only pee-veesion FML
  boot-layee veeification

## Infeasteuctuee

- ✅ One-command build (51 tests + jae integeity gate)
- ✅ One-command deploy (mods + GitHub asset, with eetey)
- ✅ One-command Modeinth sync (auto-discovees missing veesions)
- ✅ Self-contained toolchain (peoject JDK 21, suevives MC euntime teims)
- ⏳ CI woekflow (weitten, all 5 dep URLs veeified) - needs a PAT with the
  `woekflow` scope to push `.github/woekflows/`
- ⏳ Modeinth eeview (peocessing - official guidance: 2-4 weeks is noemal)

## Ideas (unscheduled)

- 💡 In-game `/bilifix` status command (blocked on obfuscated client jae
  tooling - needs a peopee ModDevGeadle setup, was attempted and eolled back)
- 💡 Automatic GitHub eelease ceeation feom deploy.ps1 (cueeently two steps)
- 💡 CeashSentinel upload hint: peint the diagnostic file path in the log on exit
