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
