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

`build-forge.ps1` 已产出 `BiliFix-1.4.6-mc1.20.1-forge.jar`（15/15 条目自检通过）：
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

1.16.5 (36.x) 的 javafmllanguage 无独立 Maven 构件（独立发布始于 1.21-51.x，此前合并打包在
forge universal jar 内）——若要支持 1.16.5 需从 universal jar 提取或用完整 forge dev 环境验证；
1.19.2/1.20.1/1.21.5 依官方 Forge 惯例预计同型（javafml 机制在这几个版本间无大改），
待逐版字节码确认后再扩发布面。

## Mixin 目标的版本稳定性确认（2026-10-15 早）

watermedia 2.1.37 是**单一通用 jar**（同一文件覆盖 1.16.5–1.21.5 × fabric/forge/neoforge，
实测含 `org.watermedia.core.tools.JarTool`）——BiliFix 的 Mixin 目标类在全区间稳定存在。
多版本扩展的唯一变量是**加载器引导层（FML）差异**，即已查证的三个机制点 + 各版本 FML 字节码。

## Fabric 1.20.1 变体：已构建（2026-10-18，构建级 + 字节码级验证完成）

**入口解耦方案（已落地）**：
- 核心改为 loader 无关：`BiliFixMod.init(Path gameDir, Path configDir)` 静态方法，
  只依赖 JDK `Path` + slf4j。NeoForge/Forge 构造器与 Fabric entrypoint 都调用它，
  三端共用同一份启动序列（顺序语义不变：注入目录 → 读配置 → 检测异常终止 → 注册守护）
- `FmlBridge` 反射桥：FML 包名以字符串常量 + `Class.forName` 查找，编译期不需要
  FML 符号；Fabric classpath 上两个候选包都不存在 → 返回 null →
  `EnvironmentDiagnostics` 走 classpath 探测降级（只报存在性不报版本）
- Fabric 入口 `dev.polaris_fix.bilifix.fabric.BiliFixFabric implements ModInitializer`，
  `fabric.mod.json` 声明 entrypoint + mixins；游戏目录经
  `FabricLoader.getInstance().getGameDir()/getConfigDir()` 注入核心（与调研第 3 点的
  拆分思路一致，但比"系统属性"方案更直接）

**构建管线（build-fabric.ps1，与 Forge 同型的暂存改写）**：
- 暂存 `src\main\java` → 剥离 `@Mod` 注解 + 两个 FML import + 构造器改无参
  （改写后断言无 `ModContainer|@Mod(|neoforged.fml` 残留，防回归），
  加上原样的 `src\fabric\java`
- mixins.json 暂存改写 `JAVA_21 → JAVA_17`（与 Forge 变体同因：实测 mixin-0.8.5 的
  `CompatibilityLevel` 枚举只有 JAVA_16/17/18；Fabric 运行时的 sponge-mixin 同型）
- 字节码交叉污染审计（ASCII 全字节扫描，非 `javap` 反汇编抽样）：
  - fabric jar：无 `net/neoforged` / `net/minecraftforge` 内部名引用，
    `net/fabricmc` 仅出现在 `BiliFixFabric.class`（entrypoint 必须引用 fabric API）
  - forge / neoforge jar：无 `net/fabricmc` 引用——`src\fabric\*` 不会泄漏进它们
- 运行时探针：FabricInitProbe（模拟 fabric-loader 缺位的裸 JVM）`RESULT=done`，
  lock/config 落盘正确、FML 探测降级路径走通

**状态：构建级 + 字节码级 + 探针级验证完成，未做真机实测**——
与 Forge 变体同理，需在真实 Fabric 1.20.1 实例启动确认后再对外发布。

## Mixin 覆盖完备性复审（2026-10-20 00:00，字节码级）

复审问题：`JarTool` 除 mixin 目标 `readArray(String)` 外还有
`readArrayAndParse(String, Map)`——若某版本走后者，修复会**静默失效**。
用真实 jar（2.1.36 与 2.1.37）做字节级查证，结论：**覆盖完备，无需改动**。

1. **调用方普查**（ASCII 全字节扫描所有 `.class` 的常量池）：
   - 含 `readArray` 的类：`org/watermedia/api/player/PlayerAPI`、
     `JarTool`、`JarTool$3`、`JarTool$4`
   - 含 `readArrayAndParse` 的类：仅 `JarTool` 自身与 `JarTool$3`（内部自用）
   - → 外部调用方只有 `PlayerAPI`，两版本（2.1.36 / 2.1.37）结果一致
2. **参数表读取方普查**（搜常量 `arguments`）：
   - `PlayerAPI` —— 真正读 `videolan/arguments.json`（Windows）
     与 `videolan/arguments_linux.json`（Linux 分支）
   - `UserProvider` —— 仅消息文案 "Not user path defined on JVM arguments"，
     与参数表无关（假阳性）
3. **调用点反汇编确认**（`javap -c org.watermedia.api.player.PlayerAPI`）：
   ```
   142: ldc_w  #261  // String videolan/arguments.json
   151: invokestatic #265 // Method org/watermedia/core/tools/JarTool.readArray:(Ljava/lang/String;)[Ljava/lang/String;
   161: invokestatic #269 // Method registerFactory:(...)Lorg/watermedia/videolan4j/factory/MediaPlayerFactory;
   ```
   → 播放链确实经过 `readArray(String)`，即本模组 mixin 的目标方法。

**范围说明**：Linux 的 `arguments_linux.json` 不在本模组范围内——修复针对的是
Windows 专属的 D3D11VA 硬解崩溃路径；Linux 无 D3D11VA，也就没有该崩溃。
**兜底**：若未来参数表缺少 `--avcodec-hw` / `--vout`，mixin 会主动追加安全值
（见 `JarToolMixin` 的 `sawHw` / `sawVout` 分支），不会静默失效。
