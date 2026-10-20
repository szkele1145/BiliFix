# Changelog

## Unreleased

### 新增：Forge 1.20.1 变体（`BiliFix-<ver>-mc1.20.1-forge.jar`）
- 适配 Forge 1.20.1 的三处 FML 分歧（详见 `docs/cross-loader-research.md`）：
  - **mixin 兼容级**：实测（MixinProbe，针对真实 mixin-0.8.5.jar）其
    `CompatibilityLevel` 枚举只有 `JAVA_16/JAVA_17/JAVA_18`——`"JAVA_21"` 会在
    mixin 引导期抛 `IllegalArgumentException: No enum constant`。共享的
    `bilifix.mixins.json` 为 NeoForge 1.21.1 主线保留 `JAVA_21`，Forge/Fabric
    1.20.1 变体在打包时改写为 `JAVA_17`（构建脚本内含"改写后不得残留 JAVA_21"
    的硬断言，防止回归）
  - **包名**：`net.neoforged.fml → net.minecraftforge.fml` 暂存改写；`FmlBridge`
    的候选包名刻意拆字符串拼接，即使被全文替换也只是冗余候选
  - **入口**：Forge 侧 `@Mod` 构造器改为无参 + 反射 `FMLPaths`（`ModContainer`
    构造器形状差异），MANIFEST 增加 `MixinConfigs: bilifix.mixins.json`
- 构建脚本加固：javac 探测链覆盖 `BILIFIX_JAVAC` → 项目内 `.tools\jdk21` →
  系统路径（环境漂移后不再 BadExpression 崩溃，缺 JDK 时给出可操作报错）

### 新增：Fabric 1.20.1 变体（`BiliFix-<ver>-mc1.20.1-fabric.jar`）
- 入口解耦：loader 无关核心 `BiliFixMod.init(Path, Path)`（仅依赖 JDK +
  slf4j）；Fabric 入口 `BiliFixFabric implements ModInitializer` 调用同一核心
- `@Mod`/`ModContainer` 在 Fabric classpath 上不存在 → 打包时暂存源码剥离
  注解与 import、构造器改无参；`src\fabric\*` 不会被 Forge/NeoForge 脚本看到，
  反向污染不存在（三个 jar 已做字节码级交叉污染审计：Fabric jar 无任何
  `net/neoforged`/`net/minecraftforge` 内部名引用，反之亦然）
- `FmlBridge` 反射查 FML 不可用 → classpath 探测降级（运行时实证
  FabricInitProbe：`RESULT=done`，lock/config 落盘正确）

### 新增
- **Mixin 目标自检探针**（`src/test/java/MixinTargetGuardProbe.java`，34 断言）：
  `MixinTargetGuard` 此前**只有镜像覆盖**——而它是唯一能把"Mixin 静默跳过"
  变成启动日志里一条警告的机制，正是整个修复的成败关键
  - 手法：目标类名是硬编码常量，同一 JVM 内换不掉 → 探针用**外部 javac 进程**
    编译出多种 stub 形态（签名匹配 / 多一个重载 / 方法缺失 / 签名不对 / 类不存在），
    再用**子类优先的 URLClassLoader** 加载，使
    `MixinTargetGuard.class.getClassLoader()` 指向该加载器、目标解析到 stub
  - 覆盖全部四种判定：`OK` / `SIGNATURE_MISMATCH` / `AMBIGUOUS_OR_MISSING` /
    `WATERMEDIA_ABSENT`（后者必须记 info 而非 warn——没装 watermedia 是正常情况）
  - `functionalProbe` 必须能分辨"已加固"与"仍是危险值（d3d11va / direct3d11）"，
    并能报出返回 null
  - **踩坑记录**：`ToolProvider.getSystemJavaCompiler()` 在探针进程内会失败
    （`NoClassDefFoundError: gson`）→ 改用外部 javac 进程；
    `productionClassesUrl()` 必须取 **`MixinTargetGuard` 的** CodeSource 而非探针自己的
    ——取错会让生产类由父加载器加载，stub 形态全部退化成 `WATERMEDIA_ABSENT`
    （已实测）
  - **负向测试实证**（`out/neg-guard.ps1`）：删掉重载判定与目标缺失判定 → 5 条失败
  - **生产类覆盖率现为 9/9**——每个生产类都有至少一个链接它的行为探针
- **配置解析探针**（`src/test/java/ConfigParseProbe.java`，18 断言）：反射调用生产
  `parse()`，覆盖 UTF-8 BOM / 无 BOM / BOM+注释 / BOM+空行，以及引号内嵌 `#`、
  行内注释、裸值等既有能力的回归守护。**已接入三个构建脚本**
  - **负向测试实证**（`out/neg-configparse.ps1`）：回退到不处理 BOM 的 `parse()`
    → 3 条断言失败
- **取证抑制探针**（`src/test/java/ForensicsSuppressionProbe.java`，9 断言）：验证启动自检
  的取证抑制**不跨线程泄漏**（详见下方修复项）。**已接入三个构建脚本**
  - **负向测试实证**（`out/neg-forensics.ps1`）：回退到全局布尔 → 4 条断言失败
- **参数改写探针**（`src/test/java/ArgumentRewriteProbe.java`，76 断言）：**整个修复的核心
  ——`JarToolMixin` 的参数改写逻辑此前从未被真正执行过**。`Regression` 是独立镜像
  （抓不到生产代码自身的错），`ReadmeLogSampleProbe` 只比对日志**字符串**。本探针
  反射调用生产的 `bilifix$makeArgsSafe`，传入真实的 `CallbackInfoReturnable`，
  覆盖：两种参数写法（`--key value` / `--key=value`）、旧值丢弃、`vout=original`
  保留原值、缺失时主动追加、非 arguments 资源不处理、null/空数组不处理，
  以及最关键的安全属性——**改写后不得残留 `d3d11va` / `dxva2` / `direct3d11`**
  > 探针编写时踩到的坑：`CallbackInfoReturnable.setReturnValue()` 内部会先调
  > `cancel()`，而 `cancel()` 在非 cancellable 时抛 `CancellationException`。
  > 探针构造时必须传 `cancellable=true`，与生产 mixin 的声明一致
  - **负向测试实证**（`out/neg-argrewrite.ps1`）：两种独立破坏方式都被抓住——
    ① 不再丢弃旧值 → 9 条断言失败；② 不再改写 `--key=value` 形式 → 3 条断言失败
- **GPU 检测探针**（`src/test/java/GpuDetectProbe.java`，7 断言）：反射调用生产的
  `EnvironmentDiagnostics.detectGpu()`，要求在 Windows 上返回**非空 GPU 名称**，
  且不含 `reg` 错误文本 / 无 `\r\n\t` 格式残留、重复调用结果稳定。这是唯一能
  抓住下面那个父键/子键错误的探针——旧实现的返回值恒为 null，而"非空"这条断言
  只有在真实 Windows 上跑才有意义（非 Windows 走 skip 分支）
  三个构建脚本（`build.ps1` / `build-forge.ps1` / `build-fabric.ps1`）均已接入

### 修复
- **配置文件里的 UTF-8 BOM 会静默吃掉用户的 `hwDecoder` 设置**——`parse()` 用
  `Files.readAllLines(path, UTF_8)`，该方法**不剥离 BOM**。Windows 上记事本等
  编辑器默认以"UTF-8 带 BOM"保存 → 首个 key 变成 `"\uFEFFhwDecoder"` →
  `containsKey("hwDecoder")` 为 **false** → 用户改的硬解策略**完全无效**。
  - 实测（修复前）：带 BOM → `containsKey(hwDecoder) = false`；不带 BOM → `true`
  - 隐蔽点：只有**第一个**键受影响，`vout`/`verbose` 照常生效——用户看到的是
    "配置生效了一半"，完全无法联想到是 BOM
  - 修复：`parse()` 剥离首行的 U+FEFF
- **取证抑制跨线程泄漏，真实播放被静默吞掉**——启动自检
  （`MixinTargetGuard.functionalProbe`）会真的调用一次 `JarTool.readArray`，
  为此用 `CrashSentinel.setForensicsSuppressed(true)` 抑制取证计数，避免把
  "用户根本没播放媒体"记成 `media touched: yes`。
  但该开关原是**全局静态布尔**：
  - 自检跑在**启动线程**，真实播放跑在**媒体加载线程**。自检期间发生的真实播放
    会被一并抑制 → `mediaTouched` 仍是 false、计数不加 → **这次真实播放彻底不被记录**
  - 这与它要防止的"取证污染"是同一种错误的镜像：把"该记的"丢掉，同样让取证结论不可信
  - 修复：改为 `ThreadLocal<Boolean>`，抑制只作用于发起自检的线程
  - 探针实证（修复前）：`[FAIL] B 线程的真实播放未被 A 的抑制吞掉（mediaTouched 被置位）`
    `[FAIL] 抑制标志是线程局部的（ThreadLocal 或计数器），不是全局布尔`
    （实际类型 `java.lang.Boolean`）；修复后 B 线程 `mediaTouched = true, 计数 = 1`
- **GPU 型号从未出现在诊断报告里**（本机实证）——`EnvironmentDiagnostics.detectGpu()`
  对显示适配器**类 GUID** `{4d36e968-e325-11ce-bfc1-08002be10318}` 执行
  `reg query ... /v DriverDesc`，但 `DriverDesc` **不在类键上**，而在每块适配器的
  子键（`0000`、`0001`…）里。父键查询直接失败：
  `ERROR: The system was unable to find the specified registry key or value.`
  → `detectGpu()` 恒返回 null，**GPU 行从未出现在报告里**。而 GPU/驱动信息恰恰是
  原生崩溃排查最需要的一环；连带地，"基础显示驱动"那条警告也从未触发过。
  修复：改为**逐个子键**查询并汇总（本机实证得到
  `AMD Radeon RX6500 XT / GameViewer Virtual Display Adapter`）
  > 排查过程中踩到的坑（已记录以免重犯）：`ProcessBuilder(List<String>)` 的
  > 第 0 项是**可执行程序本身**。重构时若只放入 `["query", key]`，实际执行的不是
  > `reg` 而是 `query`，表现为输出 `QUERY { PROCESS | SESSION | TERMSERVER | USER }`
  > 这条**用法帮助**（退出码 1）——极易误读为"注册表权限问题"
- `CrashSentinel.record()` 的事件容量控制是"判满 → 丢最旧 → 追加"这组
  check-then-act：底层 `CopyOnWriteArrayList` 每步线程安全，合起来不是。
  `recordHarden` 经 Mixin 在媒体加载线程上被调用，并发进入会让 `MAX_EVENTS`
  上限被突破（事件列表缓慢膨胀）→ 改为 `synchronized`（低频生命周期路径）
- 退出快照措辞：`events (latest N)` 的 N 实为**已记录条数**而非最新条数，
  会误导排查者 → 改为 `events (N recorded)`
- `BiliFixConfig.writeDefault()` 从不创建父目录：全新实例、或 Fabric 侧注入的
  `FabricLoader.getConfigDir()` 尚不存在时，`Files.write` 抛
  `NoSuchFileException`，被 `load()` 的 `catch` 吞成一条 warning——加固本身仍
  正确，但默认配置文件永不落盘，用户无从调整 → 写出前先 `createDirectories`
  （探针 `out/cfgdir-probe/ConfigDirProbe.java` 实证：修复前 `RESULT=NOT-CREATED`，
  修复后 `RESULT=created`，628 bytes）

### 构建 / 部署
- `pending-modrinth.ps1` 支持三变体：此前只发现 `-mc1.21.1-neoforge.jar` 且
  `game_versions`/`loaders` 写死，Forge/Fabric 变体永远进不了发现列表。现在从
  文件名 `BiliFix-<ver>-mc<mcver>-<loader>.jar` 解析三要素，标签由解析结果驱动；
  去重键改为 version_number+loader（Modrinth 允许同一 version_number 每 loader
  一条，JEI 先例；老键会把第二个变体误判为已上传）。标签合法性已对照
  `/v2/tag/loader` 公开 API 实证：`neoforge`/`forge`/`fabric` 均合法
- `deploy.ps1` 支持三变体：`-Variant neoforge|forge|fabric` 选择本地部署目标，
  GitHub Release 资产同步改为**增量**（原先"先全删再传一个"会把另外两个变体的
  资产一并删掉）；默认同步该版本所有已构建变体，未构建的跳过并提示
- 修 Windows PowerShell 5.1 解析坑：无 BOM 的 .ps1 按 ANSI 解析，脚本内中文
  实例名乱码导致语法错误 → `deploy.ps1` 改写为 UTF-8 with BOM

### 测试
- 新增 §9.6b：1.20.1 两变体 jar 结构守卫——in-jar `bilifix.mixins.json` 必须是
  `JAVA_17` 且**无 `JAVA_21` 残留**（防打包暂存改写被 `git checkout` 之类操作
  静默丢失）；Forge 断言 MANIFEST `MixinConfigs`、`[[mixins]]` 块已剥离、
  依赖语法已转 `mandatory=`、jar 内 `BiliFixMod.class` 无 `ModContainer` 残留
  （无参构造改写生效），Fabric 断言 `fabric.mod.json` entrypoint 与
  `BiliFixFabric.class`（89 → 131 项）
- 新增 §14：断言生产源码中 `CrashSentinel.record` 声明为 `synchronized`
  （Regression 是独立镜像，镜像一份"已修复"的逻辑再测它等于没测，故直接读源码
  断言；已做负向测试——临时删掉该关键字时用例 `[FAIL]`、退出码 1）
- 新增 §15：默认配置文件必须能自建父目录——源码断言保留
  `Files.createDirectories(parent)`，并在临时目录上真功能验证父目录缺失也能写出
  （同样做过负向测试：删掉该行时 `[FAIL]`、退出码 1）
- 新增 §16：`checkClass` 必须有 `Throwable` 兜底——类文件存在但静态依赖缺失时
  `Class.forName` 抛 `NoClassDefFoundError`（Error，非 Exception），原实现只捕
  `ClassNotFoundException` 会让错误冒泡 → modLine 误报"未安装"，恰好抹掉
  classpath 回退探测存在的意义。修复：兜底 `catch (Throwable) → return true`
  （存在性成立）。同时断言三个 mod 探测类名与真实 jar 内入口类一致（本机
  watermedia 2.1.36 / bilibili_media 2.3 / waterframes 2.1.23 jar 实测）。
  另加**行为级**用例：用 JDK 自带编译器现场构造"类在、依赖缺"的隔离
  ClassLoader 场景，断言 `Class.forName(fqn, false, loader)` 实际抛出的确是
  `NoClassDefFoundError`（探针 ForNameProbe2 实证 `initialize=false` 同样触发
  链接失败）。负向测试：删 Throwable 兜底、或破坏 NCDFE 判定分支 → `[FAIL]`、
  退出码 1（89 → 131 项）
- 新增 §17：配置三字段必须 `volatile`——`hwDecoder` / `vout` / `verbose` 由主线程
  的 `load()` 写入，而读方 `JarToolMixin` 经 `PlayerAPI.start() → readArray`
  可能在 watermedia 的**工作线程**上执行。JLS §17.4.5：两线程间若无
  happens-before 边，写方的值对读方不保证可见 → 媒体线程可能一直读到类
  初始化时的旧值，**用户的自定义配置静默失效**（默认值恰是安全值，崩溃不会
  回来，但 `hwDecoder = "any"` 之类的高危自定义可能读不到）。三个字段改为
  `volatile`（引用写入本就原子，只补可见性，运行时零成本）。
  负向测试：去掉任一 `volatile` → `[FAIL]`、退出码 1
- 新增 `MixinTargetGuard`（启动自检）——Mixin 按**方法名**匹配目标，而
  `bilifix.mixins.json` 的 `defaultRequire: 0`（可选注入）→ 未来 watermedia
  给 `readArray` **加重载**或**改签名**时，Mixin 会**静默跳过注入**：模组
  "装上了、修好了、什么都没发生"，崩溃回归却无迹可寻。现在启动时反射核验
  `JarTool` 的 `readArray` 唯一且签名匹配，异常则在日志里给出明确警告。
  四态判定：`OK` / `WATERMEDIA_ABSENT`（未装，正常不报警）/
  `AMBIGUOUS_OR_MISSING`（重载或缺失）/ `SIGNATURE_MISMATCH`（签名变化）
  - 字节级证据：真实 2.1.36 / 2.1.37 的 `JarTool.class` 各 18 个方法，
    `readArray` 均**恰好 1 个**（探针 MixinTargetProbe 解析方法表）→ 当前安全
  - 行为级证据：把 `MixinTargetGuard` 放到真实 watermedia jar 的 classpath 上跑，
    2.1.36 / 2.1.37 → `OK`；无 watermedia → `WATERMEDIA_ABSENT`；
    现场编译的重载假类 → `AMBIGUOUS_OR_MISSING`；签名变化的假类 →
    `SIGNATURE_MISMATCH`
  - 回归 §18：源码断言（接线 + 目标常量 + defaultRequire=0）+ 四态行为用例
    （JDK 编译器现场造四种假类）。负向测试：放过重载 → `[FAIL]`、退出码 1
- **功能级自检 `MixinTargetGuard.functionalProbe`**——"目标完好 + 签名匹配"
  仍不等于"注入已应用"：mixin 框架对 `required:false` 配置把注入失败降级为
  debug 日志，正常日志级别下不可见，这是最后一条静默失效路径。功能自检在
  mod 构造时**真正调用一次** `JarTool.readArray("videolan/arguments.json")`
  （此时 JarTool 首次被加载、mixin 转换已在链上，看到的就是注入后的方法），
  比对 `--avcodec-hw` 的值是否等于**配置期望值**（非硬编码 none，用户改
  `hwDecoder = "any"` 不误报）：
  - 安全性（javap 字节码实证）：`JarTool.<clinit>` 只建 log4j Marker + Gson；
    `readArray` 只读 jar 内资源 + Gson 解析，无网络/原生库/文件写入
  - 基线实证（`out/mixin-e2e/probe-mixin-e2e.ps1`，A 线）：裸 JVM 无 mixin 时
    调用真实 2.1.36 的 `readArray` 返回**原始危险值**
    `--avcodec-hw d3d11va,dxva2,any` + `--vout direct3d11,glwin32,gl,any`
    （18 项）——功能自检的对比组成立，"修了"与"没修"可分辨
  - 裸 JVM 负向行为已验证：无 mixin 环境下功能自检正确报告"未加固"
    （NOT-HARDENED），不误报
  - 回归 §18 扩展：功能自检接线 + 比对配置期望值 + 资源名与 PlayerAPI 一致
    （javap 实证）。负向测试：删掉 functionalProbe 调用 → `[FAIL]`、退出码 1
- **修复功能自检引入的取证污染**——上条的功能自检会真的调用 `readArray`，
  这会触发 mixin → `recordHarden` → `mediaTouched = true`。于是用户**根本没播放
  过媒体**，诊断文件却写 `media touched: yes`，直接摧毁 v1.4.7 建立的核心取证
  语义（"media touched 用于区分『真播放过媒体』与『只是开着游戏』"）。
  崩溃排查时这个字段一旦撒谎，结论就不可信。
  - 新增 `CrashSentinel.setForensicsSuppressed(boolean)`：抑制态下 `recordHarden`
    直接返回（不计数、不置 `mediaTouched`、不写事件）
  - `functionalProbe` 进入时置 true、**在 `finally` 中复位**——必须复位，否则
    用户之后真的播放媒体时，取证数据会被永久抑制（症状与原缺陷等价）
  - 探针实证：抑制态调用 → `mediaTouched=false`；复位后调用 → `mediaTouched=true`
  - 回归 §19：4 条守卫（提供开关 / recordHarden 早退 / 成对使用 / finally 复位）。
    负向测试 ×2：去掉抑制检查 → `[FAIL]`；去掉 finally 复位 → `[FAIL]`，均退出码 1
- **发布链两处缺陷修复**（`4ec0fc6`，`deploy.ps1`）：
  1. **资产新鲜度按大小判定不可靠** → 改按 **sha256** 比对。GitHub API 的
     `asset.digest` 字段语义经实测确认（下载 v1.4.5 资产算 sha256，与 API 字段
     完全一致）。仓库自身历史就是反例：**v1.4.4 与 v1.4.5 的 jar 同为 20582
     字节但内容不同**——旧逻辑会把 v1.4.5 判为"已是最新"并跳过上传，线上留下
     陈旧的 v1.4.4 资产。新逻辑比对 digest，无 digest 字段时回退比大小
  2. **脚本会自动创建 tag + Release** → 这正是项目发布纪律要守住的关口
     （`## Unreleased` 只在**双 loader 真机验证通过后**才晋级为 `## <版本>`）。
     误跑一次就会发布未验证的 v1.4.8。现在脚本在 CHANGELOG 里找不到**已晋级**的
     `## <版本>` 标题时**拒绝创建 Release**；`-ForceRelease` 可有意越过
  - 实测：v1.4.8 仍在 Unreleased 时闸门抛出、退出码 1、**无任何远端副作用**；
    临时晋级后闸门放行（随后还原）
  - ⚠️ `deploy.ps1` 是 UTF-8 **with BOM**：edit 工具会剥 BOM，改写后必须补回
    （本次已踩到：剥掉后中文实例名变乱码 → ParserError）
- **Modrinth 上架链两处缺陷修复**（`pending-modrinth.ps1`）：
  1. **自动发现只扫 `build\` 顶层**——Forge/Fabric 变体在 `build\forge\`、
     `build\fabric\` 里，实测可见 1 个 / 实际 4 个：上轮"修复硬编码 loader"
     并没真正修好发现逻辑，Forge/Fabric 变体**依然永远上不了架**。
     改为**递归扫描**整个 `build\` 树（实测 1 → 4），上传用**发现时解析到的
     实际路径**（旧代码拼 `build\<jarName>`，对非 neoforge 变体必然不存在）
  2. **递归扫描会捞到旧版本的陈旧产物** —— `build\forge\` 里还躺着 10-16 的
     `BiliFix-1.4.7-mc1.20.1-forge.jar`（v1.4.7 时期源码所建、**从未实测**，
     当前源码树已构建不出它）。递归后它会被当成待上架项。发现逻辑改为**只认
     当前源码版本**（版本真源：`neoforge.mods.toml`，与 deploy.ps1 同源），
     旧版本 jar 打印提示后忽略。实测：陈旧 jar 被识别并排除，待上架清单只剩
     当前版本 3 个变体
  3. **Modrinth 链没有发布闸门**——与 `deploy.ps1` 同一缺口：脚本会直接上传
     未验证的版本。现在任一待上架版本未在 CHANGELOG 晋级即**整批拒绝**
     （实测：真实 token 下 1.4.8 三个变体全被拦、退出码 1、零上传；
     `-ForceRelease` 可有意越过）
- 注入点冲突排查（字节级）：bilibili_media 2.3 的两个 mixin
  （`IHateWaterMediaMixin` → `org/watermedia/WaterMedia`、
  `NetworkAPIMixin` → `NetworkAPI`/`ILoader`）均**不碰 `JarTool`**
  → 与本模组注入点无冲突
- 资源守卫用例补齐：`fixArgs` 在资源缺失 / 空数组 / null 元素时原样返回副本，
  以及"尾部 `--avcodec-hw` 缺值"与 `vout=null` 追加顺序等边界（66 → 85）
  > 说明：上一条 1.4.7 条目里的 66 是**发布当时**的真实值；此后 b273823 又补了
  > 19 项，v1.4.8 又加了 §9.6b 变体 jar 守卫、Forge 三处机制差异断言、§14 并发
  > 守卫、§15 配置目录守卫、Forge 构造器字节级守卫、§16 诊断探测守卫、
  > §17 配置可见性守卫、§18 Mixin 目标守卫与 §19 取证污染守卫，
  > 故当前源码为 131
  > （`./build.ps1` 实测"通过 131 / 失败 0"）。
- **新增三项行为级探针**（区别于 Regression 的独立镜像：这三项**链接生产 classes**，
  真实调用生产方法）：
  - `ConcurrentRecordProbe`——32 线程 × 500 次并发调用生产 `CrashSentinel.record()`，
    事件数必须恰停在 `MAX_EVENTS`（64）。§14 只断言源码里有 `synchronized` 关键字，
    那是"检查药方"不是"检查疗效"。**负向实证**：副本中去掉 `synchronized` → 事件数
    冲到 **93 > 64**（check-then-act 竞态真实触发），`RESULT=FAIL`、退出码 1
  - `FmlBridgeProbe`——`FmlBridge` 是最后一个零覆盖的生产类，却在关键路径上
    （`CrashSentinel.gameDirectory()` 靠它定位游戏目录，返回 null 就意味着取证文件
    写不出来——恰是崩溃时最需要证据的时刻）。用**真实包名**下的 stub
    （`net.neoforged.fml.loading.FMLPaths` 形状正确 / `net.minecraftforge.fml.loading.FMLPaths`
    无 `get()`）让生产的 `Class.forName` 真的解析到它，端到端覆盖
    "forName → 枚举常量 → get() → Path"链路与"绝不抛异常"契约。9/9 通过。
    **负向实证**：去掉真实 `FmlBridge` 里的 `get()` → 3 条正向断言全 FAIL、退出码 1
  - `ReadmeLogSampleProbe`——README 里教用户 grep 的日志行必须与生产格式串
    **逐字符一致**（全角冒号、全角箭头、` , ` 分隔符）。文档漂移会造成**假阴性**：
    用户看到的日志与 README 对不上，会误判"修复没生效"，而其实生效了。19/19 通过。
    **负向实证**：把 README 的 `v1.4.8 已加载` 改成 `v1.4.7` → 探针 FAIL、退出码 1
- **构建把关补齐**：此前**只有 `build.ps1` 跑测试**，`build-forge.ps1` /
  `build-fabric.ps1` 零把关——改坏 `CrashSentinel`/`BiliFixConfig` 后只跑 1.20.1
  构建会直接产出坏 jar。现三个脚本一律跑：Regression(131) + 并发探针 +
  FmlBridge 探针 + README 探针（打包后运行，使 §9.6b 的 jar 结构断言也覆盖
  该变体自己的产物）。**负向实证**：临时删掉 `synchronized` → 两个 1.20.1 构建
  路径均 `regression tests failed`、退出码 1（分别验证）
  > 接线备注：探针链接 `BiliFixMod` 故需 slf4j-api 在 classpath 上；SLF4J 的
  > `No SLF4J providers were found.` 提示走 stderr，PowerShell 会把 native stderr
  > 当成致命错误记录，**探针明明通过却让构建中断**——改用 `Start-Process` 分离
  > stdout/stderr，并以**进程退出码**为判据（`Start-Process` 不更新 `$LASTEXITCODE`）。

### 文档
- 修正文档失真（均有会话日志实证）：
  - `docs/verification-checklist.md` 曾把 **v1.4.7** 的启动验证标为已通过，
    但作为依据的 2026-10-14 16:39 会话跑的是 **v1.3.2**（14 分 36 秒）；
    v1.4.7 的 jar 于 10-16 07:30 部署，而 `latest.log` 最后写入停在 10-15 20:44
    → v1.4.7 **从未启动过**，其会话取证属零验证代码路径，清单已改回待做
  - README（中/英）示例日志的"原 16 项 → 新 16 项"实为 **18 项**
    （v1.3.2 与 v1.4.4 会话均实证），并补充说明该数字随 watermedia 版本变化
  - README（中/英）、CONTRIBUTING 的测试数 66 → 85
  - **README（中/英）补上 v1.4.8 的功能自检说明**——`功能自检通过: --avcodec-hw=...
    , --vout=... —— 注入已生效（端到端验证）` 是"修复是否生效"的**最终判据**，
    此前只存在于代码里而不在任何文档中，用户无从得知**不播放视频也能确认修复生效**。
    同步补一张对照表说明每行日志的含义与缺失时的含义（特别标注：`VLC 参数已加固`
    缺失只意味着"还没播过视频"，**不是故障**）
  - ROADMAP 的"15+ min stable"未标注版本归属，已改为明确列出 v1.3.2 / v1.4.4
    的证据与"v1.4.7 从未启动"的事实

## 1.4.7 — 2026-10-16

### 新增：会话取证（区分"干净退出"与"被原生层打死"）
- 此前盲点：原生崩溃**不会执行 JVM shutdown hook**，所以 `bilifix-diagnostic.txt`
  在硬崩溃后会静默保留**上一次会话**的内容，无法据此判断到底崩没崩
- 现在启动时留 `bilifix-session.lock`，干净退出时删除该标记；下次启动若发现
  **残留 lock**，即判定上次会话未走退出流程（原生崩溃指纹），并在日志中输出
  针对性排查建议（含 lock 路径、存在时长、vout 对照试验步骤）
- 判定幂等：同一次启动内即使模组被重复构造，也不会把本次刚写的标记误报为崩溃
- 退出快照新增 `media touched` 字段：区分"本次确实播放过媒体"与"只是开着游戏"
- 取证全程 `catch (Throwable)` 兜底：取证失败绝不影响游戏运行

### 修复：崩溃结论会被随后的正常退出覆盖
- 问题：结论原先只写在 `bilifix-diagnostic.txt` 里，而该文件每次干净退出都会重写。
  用户的真实使用顺序是"崩溃 → 重启 → 干点别的 → 正常退出 → 这时才去看文件"，
  于是唯一带证据的那次会话的结论被覆盖掉了
- 现在结论单独写入 `bilifix-crash.txt`：只在判定到异常终止时写，正常退出不动它

### 测试
- 会话取证 11 项新测试（含幂等性、干净退出恢复、null 目录安全）（51 → 62）
- 崩溃结论持久化 4 项新测试（含"正常退出重写快照后结论仍在"）（62 → 66）

## 1.4.6 — 2026-10-15

### 修复（第 20 轮审查：语义与行为一致）
- 配置加载失败分支现在**真的**重置字段为安全默认（此前日志称"使用默认值"但字段保留上次值——
  首次加载无行为差异，但为未来 reload 埋雷）

## 1.4.5 — 2026-10-15

### 修复（第 18 轮审查：失败语义）
- Mixin 注入器 `defaultRequire` 1 → 0：未来 watermedia 若重构掉注入目标，
  修复**静默失效**（仅警告）而非升级为 mod 加载错误——修复 mod 绝不能把游戏搞挂

## 1.4.4 — 2026-10-15

### 修复（第 15 轮审查）
- 诊断的 mod 版本显示拦截未替换的 `${...}` 占位符（bilibili_media 2.3 的 mods.toml
  存在此类打包瑕疵，会把垃圾值当"版本"显示进日志）

### 新增
- `displayTest = "IGNORE_SERVER_VERSION"`：客户端修复 mod 的正确语义——玩家各自安装
  不触发服务器 mod 不匹配警告

### 测试
- modLine 版本可用性判定 4 项新测试（47 → 51）

## Forge 1.20.1 变体（开发中，未随主线版本发布）

### 2026-10-15 凌晨
- `build-forge.ps1`：同一份源码产出 Forge 1.20.1 变体 jar（`BiliFix-<版本>-mc1.20.1-forge.jar`）
- 适配三个加载器机制差异（详见 docs/cross-loader-research.md）：
  1. mixin 注册：Forge 1.20.1 无 `[[mixins]]` toml 支持 → MANIFEST `MixinConfigs`
  2. 依赖语法：`type="required/optional"` → `mandatory=true/false`
  3. 构造器：Forge javafml 只接受无参构造（字节码查证）→ 自动重写并清理无用 import
- 状态：编译级验证完成（15/15 条目自检），**待真实 Forge 1.20.1 实例运行时验证后发布**

## 1.4.3 — 2026-10-15

### 新增
- `verbose = true` 时 CrashSentinel 把完整 VLC 参数序列写进诊断文件（完整记录 VLC 实际收到的内容）
- CrashSentinel 事件格式补 4 项测试（43 → 47）

## 1.4.2 — 2026-10-15

### 新增
- 前置链路版本感知：通过 FML ModList 运行时 API 统一报出 watermedia / bilibili_media / waterframes 版本
- FML 不可用时回退 classpath 探测（报存在性不报版本）

## 1.4.1 — 2026-10-15

### 新增
- 启动诊断报出 watermedia 精确版本号（反射读取 VERSION 字段，零编译耦合）

## 1.4.0 — 2026-10-14

### 新增
- **CrashSentinel 崩溃诊断守护**：JVM 退出时把修复运行状态（加固次数、策略、生命周期事件）
  写入游戏目录 `bilifix-diagnostic.txt`——无声崩溃复发时，这是 Java 侧留下的最后证据，
  附在崩溃报告里可大幅加速定位
- 诊断文件格式经独立验证（10 行结构：标题/JVM存活/退出时刻/加固计数/策略/事件流/end 标记）
- jar 命名规范统一：`BiliFix-<版本>-mc<游戏版本>-<加载器>.jar`

## 1.3.2 — 2026-10-14

### 修复（代码审查 #7：配置写入原子性）
- 默认配置改为原子写入（临时文件 + `ATOMIC_MOVE`）：磁盘满或进程中断不再可能留下损坏的半截配置文件
- 文件系统不支持原子移动时自动降级为普通 move

### 构建返工记录（同日两次，详见 docs/postmortem-1.3.2.md）
1. **zip 结构损坏**：可复现构建的时间戳后处理在 DOS epoch 边界写出非法 central directory，
   游戏启动报 `invalid entry size` → 移除后处理 + 构建期加入消费方级 jar 完整性自检
2. **mods.toml 结构错误**：扁平 key 不是 FML 要求的标准结构，游戏报 `Missing ModLoader` →
   对照正常 mod 重写为标准 FML 结构（modLoader/[[mods]]/[[mixins]]），双 toml 兼容
3. 工具链：build.ps1 加 12 项 FML 结构预检；新增 deploy.ps1 一键三渠道部署（含完整性门禁）

## 1.3.1 — 2026-10-14

### 修复（代码审查 #3）
- GPU 检测的管道死锁隐患：改为后台线程读流后再 waitFor（防注册表输出超管道缓冲区时卡游戏）

## 1.3.0 — 2026-10-14

### 新增
- **GPU 诊断**：启动诊断新增显卡型号检测（Windows 注册表查询，3 秒超时保护，非 Windows/失败静默降级）；检测到 Microsoft 基本显示驱动时警告
- README 注明 watermedia 3.0 兼容性（3.0 已移除 libVLC，无需本模组；本模组只针对 2.1.x）

## 1.2.1 — 2026-10-14

### 修复（配置解析鲁棒性）
- 支持行内注释：`vout = "gl,any" # 说明` 不再被解析成坏值
- 引号内 `#` 正确保留
- 未闭合引号容错处理
- vout 配置值标准化为小写（`GL,ANY` → `gl,any`，防止大写导致 VLC 模块查找失败）
- 未知 hwDecoder 值启动时立即警告并回退安全默认

## 1.2.0 — 2026-10-14

### 新增
- **启动环境诊断**：加载时输出 watermedia 状态、JVM 架构（32/64 位警告）、OS、最大内存等，帮助定位环境相关崩溃
- 诊断过程全包裹 try/catch，任何异常都不影响游戏启动

## 1.1.1 — 2026-10-14

### 修复（代码审查发现）
- **严重**：watermedia 未安装时 Mixin 硬失败会拖崩游戏启动——加 `@Pseudo` 注解 + mixins.json `required: false`，现在 watermedia 缺失时 BiliFix 静默跳过，绝不添乱
- **未来防御**：watermedia 参数表若不再含 `--avcodec-hw` / `--vout`，现在会**主动补加**安全参数，防止上游改版导致修复失效
- `isValue` 边界收紧：以 `-` 开头（含短选项）一律不当作参数值

### 测试
- 回归测试从 25 个增加到 31 个，全部通过

## 1.1.0 — 2026-10-14

### 新增
- **配置系统**：`.minecraft/config/bilifix.toml`，可调整硬解策略（`hwDecoder`）、视频输出（`vout`）、日志详情（`verbose`）
- 支持 `--key=value` 与 `--key value` 两种 VLC 参数写法的识别与替换
- `vout = "original"` 可保留 watermedia 原始 vout 参数不替换
- 配置加载失败时自动回退到安全默认值（软解），绝不带病运行

### 改进
- 完整开源项目结构（Maven 标准布局）
- README、LICENSE（MIT）、CHANGELOG
- 日志信息更详细：显示加载的策略与替换前后参数项数

## 1.0.0 — 2026-10-13

### 初始版本
- Mixin 注入 watermedia `JarTool.readArray`，运行时替换 VLC 启动参数
- `--avcodec-hw d3d11va,dxva2,any` → `--avcodec-hw none`（禁用硬解，修复无声崩溃）
- `--vout direct3d11,glwin32,gl,any` → `--vout gl,any`（去掉 D3D11 vout 偏好）
- 修复现象：游戏退出码 -1、无 Java 崩溃堆栈、崩溃分析器无结果

