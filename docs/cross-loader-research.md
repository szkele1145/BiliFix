# 跨加载器支持调研（2026-10-14 凌晨，待与项目所有者确认）

## 背景
watermedia 2.1.x（libVLC 时代）支持：MC 1.16.5 / 1.18.2 / 1.19.2 / 1.20.1 / 1.21.1 / 1.21.5 × fabric / forge / neoforge。
BiliFix 的修复机制（Mixin 注入 watermedia 自己的 JarTool 类）不依赖 MC 版本，
理论上可覆盖全部 6 个 MC 版本。

## 现状
当前只发布 NeoForge 1.21.1 变体（本机整合包的环境）。

## 扩展所需工作（估算）
1. **Forge 变体**：mods.toml（而非 neoforge.mods.toml）+ MANIFEST MixinConfigs（已有）→ 低成本，机制相同
2. **Fabric 变体**：fabric.mod.json（声明 mixins + entrypoint）→ 中成本，加载入口要适配
3. **多 MC 版本**：mod 里没有引用任何 MC 类（纯 Mixin + FMLPaths/ModContainer）→
   - FMLPaths/ModContainer 是 NeoForge/FML 的类 → **Fabric 上不可用，需要条件加载配置**
   - 需要拆分：配置加载改为不依赖 FMLPaths（用系统属性或 FabricLoader.getInstance().getConfigDir()）

## 风险
- 每个加载器 × 版本组合都需要真实验证（无法只靠编译保证）
- 用户当前实际场景只有 NeoForge 1.21.1

## 建议
先等 NeoForge 1.21.1 在真实游戏里验证修复有效，再考虑扩展。
若社区有 Fabric/Forge 需求（issue 反馈），按上面清单逐个适配。

## 补充验证（2026-10-14 上午）

**Forge 变体已确认极低成本**：代码差异仅 3 处 import 包名替换
（`net.neoforged.fml.ModContainer` / `net.neoforged.fml.common.Mod` /
`net.neoforged.fml.loading.FMLPaths` → `net.minecraftforge.*` 等价物），
核心逻辑（Mixin、配置、诊断）零改动。若用户或社区提出需求，
当天即可产出 Forge 变体（mods.toml + 换包名编译）。

## Forge 1.20.1 变体：已构建（2026-10-15 凌晨）

`build-forge.ps1` 已产出 `BiliFix-1.4.3-mc1.20.1-forge.jar`（15/15 条目自检通过）：
- 同源码，3 处 import 替换（net.neoforged.fml -> net.minecraftforge.fml）+ Forge 版 mods.toml
- Forge FML 依赖按需自动下载（fmlcore/javafmllanguage/fmlloader/forgespi，URL 实测有效）
- **状态：编译级验证完成，未做运行时实测**——v1.3.2 的教训（编译通过≠游戏能加载），
  需在真实 Forge 1.20.1 实例启动确认后再对外发布。
  （本机的 shwetro-1201 开发环境正好是 Forge 1.20.1，可作实测场）
## Forge 1.20.1 实测前的机制差异全记录（2026-10-15 凌晨，字节码/官方文档级查证）

除 3 处 import 替换外，还发现并适配了三个会导致加载失败的机制差异：

1. **mixin 注册渠道**：Forge 1.20.1 FML 不认 mods.toml 的 `[[mixins]]` 块（NeoForge 专属）
   → Forge 变体剥离该块，改用 MANIFEST `MixinConfigs`（两个加载器机制正好相反）
   来源：docs.minecraftforge.net/en/1.20.1/gettingstarted/modfiles（完整字段表中无 mixins）
2. **依赖字段语法**：Forge 用 `mandatory=true/false`，NeoForge 用 `type="required"/"optional"`
   → 构建时正则转换
3. **mod 构造器签名**：Forge 1.20.1 FMLModContainer 以空参数数组调 getDeclaredConstructor
   （字节码证据），只接受无参构造器；NeoForge 注入 ModContainer
   → 构建时把 BiliFixMod(ModContainer) 重写为 BiliFixMod() 并删除无用 import

"编译通过 ≠ 运行正确"的三个活例。每个差异都靠官方文档或字节码级查证发现，
而非等真实实例崩溃。
## 版本矩阵调研（2026-10-15 早）

字节码对比 Forge 1.18.2 (40.2.21) 与 1.20.1 (47.3.0) 的 FMLModContainer：
**完全一致**（iconst_0 + anewarray，空参数数组调 getDeclaredConstructor）——
无参构造器要求覆盖 1.18.2 → 1.20.1 整个区间，build-forge.ps1 的构造器重写通用。

1.16.5 (36.x) 的 javafmllanguage 未能对上 Maven 版本号（待查正确坐标）；
1.19.2/1.20.1/1.21.5 依官方 Forge 惯例预计同型（javafml 机制在这几个版本间无大改），
待逐版字节码确认后再扩发布面。