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
- **没设的配置项被当成了"被归一化过"**——`strategyWasNormalized()` 决定要不要

- **修复的支点从未对照过真实的 watermedia**（新增证据层级）：整个修复只有一个

- **发布材料被改坏而没有任何构建发现**（新增证据层级）：CHANGELOG 里一个
  `### 修复` 标题被拆成了 `### 修` / 空行 / `复`——根因是插入内容时
  `String.Replace` 的**锚点跨越了换行**。这不会让任何构建失败：文件仍是
  合法 Markdown，只是那一节渲染成空标题加一个孤立段落。而发布说明是
  用户了解改动的唯一入口。
  - 新增 `DocStructureProbe`（6 断言）：断裂/空标题、标题附近的孤立单字、
    U+FFFD 替换符、`## Unreleased` 结构、空小节
  - 负向测试 `neg-docstruct.ps1`：把标题拆坏 → 探针 4 通过 / 2 失败
  Mixin 注入点（`JarTool#readArray`），但此前**所有**关于它的断言都基于
  **手写的假数据**——手写数据只能证明"改写逻辑对手写数据成立"，证明不了
  "对 watermedia 真的给的那份参数表成立"。而整个修复的价值全押在这份表上。
  - **实测真实 jar**（2026-10-21，`javap` + zip 读取，watermedia 2.1.36 与 2.1.37）：
    - 真实签名：`public static java.lang.String[] readArray(java.lang.String) throws IOException`
      —— 与 Mixin 目标**完全一致**（静态、返回 `String[]`、单 `String` 参数）
    - `PlayerAPI` 的字节码里是 `invokestatic JarTool.readArray` → `registerFactory`，
      **没有** `readArrayAndParse` —— 我们打的正是实际被调用的那个方法
    - `readArray` 只把参数当**资源名**读进 `Gson` 解析，改返回值是正确切入点
    - 真实 `videolan/arguments.json` 里确实有
      `"--vout", "direct3d11,glwin32,gl,any"` 与
      `"--avcodec-hw", "d3d11va,dxva2,any"` —— **这就是根因本身**
    - 真实 `videolan/arguments_linux.json` **根本没有** `--vout` / `--avcodec-hw`
      —— 这正是 mixin 里"没有就主动追加"分支存在的理由
  - 新增 `RealArgumentsProbe`（24 断言）：把**真实参数表**当装置，反射调用
    **生产的** `JarToolMixin`（不是手抄副本）跑改写
  - 负向测试 `neg-realargs.ps1`：破坏**生产改写**（让危险值原样留下）→
    探针 **17 通过 / 7 失败**
  - **证据分级**：本地有真实 jar → 24 条断言全跑；CI 无 jar → 19 条（5 条
    jar 级断言跳过），参数表级断言照跑
  - 顺带修掉一个真实缺陷：构建脚本用**中文路径字面量**定位 watermedia jar，
    而 `.ps1` 没有 BOM 时 WinPS 5.1 按 ANSI 读 → 路径乱码 → 静默跳过
    （`[SKIP] 真实 jar 检查`）。现在改为**按文件名递归查找**，不依赖非 ASCII 字面量
  打印 `配置归一化：…` 那一行，它在**三种最常见的情况**上给错了答案：
  - `hw=null, vout=null`（**全新用户，刚生成的默认配置**）→ 报警
  - `hw=null, vout=gl,any` → 报警
  - `hw=none, vout=null`（**只设了 hwDecoder 的用户**）→ 报警
  - 实际打印的都是 `配置归一化：hwDecoder 'none' → none, vout 'null' → original`
    ——**两个值都没变**，还把 `null` 原样显示出来
  - 根因：`null` 的语义是"未设置"，但 `effectiveStrategy()` 为显示把它映射成
    `"original"`，旧比较把 `null` 当成了"被改写的值"
  - **噪音警告是最坏的一种**：这行是在**崩溃排查时**读到的，它把注意力引向
    一个不存在的问题
  - 另：`keep → original` 别名用的是子串 `String.replace`，导致
    `vout = "keepkeep"` 被替换成 `"originaloriginal"`，而 `voutValue()`（switch
    整串匹配）原样保留 `keepkeep` —— 两边不一致，没改的值被报成"归一化过"
  - 修复：`null` 不算变化；别名按整串匹配；语义与显示只要有一处不同就说明
  - 新增 `NormalizedWarningProbe`（12 断言）+ 负向测试 `neg-normwarn.ps1`
    （还原旧写法 → 7 通过 / 5 失败）
  - `neg-startuplog.ps1` 的锚点是旧 return 语句，改写后**它自己先报
    `ANCHOR_NORMALIZED_NOT_FOUND` 拒绝运行**（而不是静默通过）——锚点已更新
- **NeoForge jar 里带着一个谁都不读的死文件**（新增证据层级）：`META-INF/mods.toml`
  和 `META-INF/neoforge.mods.toml` **内容完全相同**，两个都打进了 NeoForge jar。
  看着像"兼容两个 loader"，其实是 1.3.2 时期"一个 jar 也要在老 Forge 上加载"
  的遗留——那时项目只有一个 jar。三个变体分家后，这个文件彻底没人读了：
  - **实测**（2026-10-21，真实 `fancymodloader-4.0.45.jar`）：FML 的
    `ModFileParser` 常量池里**只有** `META-INF/neoforge.mods.toml` 一个字符串，
    **没有** `mods.toml`。NeoForge 21.1 根本不会读它
  - 危害不是"多占 1 KB"：用户解包 jar 会看到两个一模一样的元数据文件，
    不知道哪个生效——而"哪个文件真正决定模组能不能加载"正是排查这类问题
    时最先要确认的事
  - 修复：删掉源码里的 `META-INF/mods.toml`，打包脚本不再把它塞进 NeoForge jar
    （jar 从 19 条目降到 18 条目，30904 → 30265 字节）
  - **回归守卫**：`Regression` §9.8 的版本一致性断言改为"死文件必须不存在"
  - 新增 `JarMetadataProbe`（32 断言，**查的是打包好的 jar，不是源码**）：
    - 从 jar **自身内容**推断它是哪种 loader 的产物（看存在哪个元数据文件），
      **不靠参数顺序**——第一版靠顺序，build-forge 把 Forge jar 传到 NeoForge
      的位置上，4 条断言全红，而那个 jar 其实完全正常
    - 断言：恰好一种 loader 元数据（没有串台）、元数据声明的版本与 **jar 文件名**
      一致（不硬编码版本号，否则 `build/` 里残留的旧 jar 会被误判为坏）、
      mixin `compatibilityLevel`（NeoForge=JAVA_21，1.20.1 两端=JAVA_17）、
      `JarToolMixin` / `BiliFixMod` / `BiliFixFabric` 类在 jar 里
    - 接入**三个构建脚本**，位置在**打包之后**（查的就是产物），
      扫 `build/` 下所有 `BiliFix-*.jar`；一个都没找到时明确 SKIP 而不是
      "假装检查过了"
    - 负向测试 `neg-jarmeta.ps1`：① 往 NeoForge jar 里塞 `fabric.mod.json`
      ② 把 `compatibilityLevel` 改成 `JAVA_18` → 探针两次都失败（exit 1），
      **证明探针抓得住它声称覆盖的问题**
  - 证据分级：jar 级（本地构建后全跑）vs CI（不打包 → 明确 SKIP 并计入"跳过"）
- **一整份克隆下来的仓库根本跑不起来**（`1da2ff0`）：本地工作副本**掩盖**了三个
  互相独立的缺陷。方法是**本地模拟 GitHub runner**（clone → 配 JDK → 恢复缓存
  → 跑仿真），见 `src/test/sim-ci-runner.ps1`
  1. **步骤叫"Cache dependency jars"却根本没缓存**——它只是下载，每次跑都联网
     - 修复：真的加 `actions/cache`，且 `src/test/ci-faithful.ps1` **先**去
       `out/ci-libs`（缓存目录）找——否则恢复的缓存根本用不上
  2. **workflow 靠"只复制 `java.exe` + `javac.exe`"来满足测试脚本**——这**行不通**：
     JDK 21 是模块化的，`javac.exe` 需要 `lib/` 里的 `jdk.compiler` 模块，
     只有两个 exe 时每次编译都报 `Module jdk.compiler not found`
     - 修复：脚本自己解析 JDK（`.tools/jdk21` → `JAVA_HOME`，runner 上
       `actions/setup-java` 装的是**完整** JDK），那步复制整个删掉
  3. **20 个负向测试全都硬编码 `$d = 'C:\Users\<中文>\Desktop\BiliFix'`**
     - 在克隆里，那个路径要么不存在，要么**指向别人（开发者本机）的工作副本**
       ——脚本会从**错误的树**里拷源码，"测试"的根本不是正在提交的那个仓库
     - 而且 `.ps1` 无 BOM 时 WinPS 5.1 按 ANSI 读，路径直接乱码
     - 修复：仓库根一律**从脚本自身位置推导**（`$PSCommandPath` 上溯四层），
       JDK 走共享 helper `src/test/negative/jdk.ps1`
  - **证据**：`src/test/sim-ci-runner.ps1`（已入版本库）端到端复现 runner，
    结果 `RUNNER_SIM=ALL_GREEN`；它复现前**先失败**（编译不通过）
  - 顺带：三个构建脚本现在**显式带 UTF-8 BOM**（含中文，缺 BOM 会被按 ANSI 读）
- **负向测试会改真实仓库，而没有任何机制发现它改了**（`2b85858`）：
  负向测试**故意破坏生产代码**，且是在**真实工作树**上跑的（不是副本）——
  所以任何一条脚本把临时目录解析错了，就能删掉或改写仓库里的文件
  - **实证**：`src/test/negative/run-all-negative-tests.ps1` **本身**从工作树里
    消失了。git 里完好无损（`git checkout` 即可恢复），但它是在**CI 仿真跑到
    复制阶段**时才暴露的：`Copy-Item: Cannot find path ... run-all-negative-
    tests.ps1`。这是**第二次**发生同样的事（v1.4.8 开发期间已被误删过一次）
  - **上次的修复不够**：给每个 `neg-*.ps1` 的 `$tmp` 加了"必须在 `%TEMP%` 下"
    的守卫，但那个守卫只能保护**自己**要删的那个目录——它**看不见别的脚本
    删了东西**
  - 修复：守卫上移到**聚合层**。`run-all-negative-tests.ps1` 在跑之前给工作树
    做快照（每个跟踪文件的路径 + SHA256，加上未跟踪文件），跑完再比一次
    - 跑完工作树有任何变化 → **判 FAIL**（不管那条脚本自己的断言过没过），
      并逐条打印"消失/变更前"和"新增/变更后"
    - **守卫能失败已被证明**：临时造了两条会篡改/删除跟踪文件的负向测试，
      两者都被抓住（EXIT=1，删掉的文件和变动的哈希都打印出来了）
  - 附带教训：**`git reset --hard` 会连未提交的改动一起抹掉**。验证守卫时用它
    清理临时文件，结果把刚写好的守卫和另一处改动**同时清没了**——同一个
    "误删仓库文件"的问题，这次是我自己造成的。清理临时改动应该用精确的
    `git checkout -- <path>` 或 `git stash`
  - `src/test/ci-faithful.ps1` 同步加固两处：
    - JDK 解析回退到 `JAVA_HOME`（CI runner 没有 git-ignored 的 `.tools/jdk21`）
    - `git ls-files` 返回空 → **硬错误**。空树会跑零个测试，
      而那看起来和"全绿"一模一样
- **旧 jar 残留在 build/ 里，而检查它的探针会把它当当前产物**（`83265ce`）：
  三个相互关联的缺陷，源于一个真实的场景——`build/forge/` 里躺着
  `BiliFix-1.4.7-mc1.20.1-forge.jar`（**几周**没人清理）：
  1. **housekeeping 只清了 build/ 的根目录**。它只存在于 `build.ps1` 里，
     `build/forge/` 和 `build/fabric/` **从来没人清过**。而 jar 元数据探针
     扫的是 `build/` **递归**——残留的旧 jar 会被当成当前产物来检查
     - 修复：三个构建脚本都清理**全部**输出目录，但**只删版本不同**的 jar
       ——构建一个变体不该毁掉另两个变体的当前产物
     - 位置：必须在**探针之前**。第一版放在脚本末尾，探针早就跑完了
  2. **`Regression.pickJar` 取"修改时间最新"的 jar**。有残留时那就不是刚
     构建出来的产物——检查一个不是当前代码产物的 jar，什么也证明不了
     - 修复：只接受**当前版本**的 jar（`BiliFix-<version>-...`）
  3. **`Regression` 读 jar 条目前不判空**。条目缺失恰恰是那段检查要检测的
     失败情形，它却把**整个回归套件**打死
     - 实证：把 forge jar 改名成 `BiliFix-1.4.8-mc1.20.1-fabric.jar` 放进
       `build/fabric/`，旧代码直接抛
       `NullPointerException: ze at JarFile.getInputStream`；修复后
       **报 4 条 FAIL、exit 1、不崩**
     - 修复：读条目前判空，缺失记 FAIL 并继续
  - 新增断言（`Regression` 137 → **140** 条）：pickJar 只返回当前版本的 jar、
    读条目不抛异常
- **文档里的数字过期了**（`ff06cdc`）：README 与 README.zh-CN 写
  "131 regression tests + 3 behaviour probes"，实际是 **137 条回归断言 +
  20 个行为探针**（由 `Regression.class` 实跑得出：137/0/0）
  - 顺带把 watermedia 2.1.37 的证据描述从"签名探针验证"升级为
    "真实 jar 验证"——参数表是**从真实 jar 里读出来的**，不只是签名一致
- **Fabric 侧的入口路径零自动化覆盖**——Fabric 是**唯一有独立入口**的加载器
  （`ModInitializer.onInitialize()` → 显式注入 `getGameDir()/getConfigDir()`），
  而共享核心 `init()` 里的顺序是**有语义的**：先注入目录，再读配置。顺序写反，
  配置文件就落到别处——**静默**：模组照常工作，只是用户的配置永远不生效，
  且不报任何错
  - 旧的 `FabricInitProbe` 只存在于 `build/`（被 git 忽略）、**只打印不断言**，
    任何回归都不会让构建失败；它输出的 "unclean-shutdown fingerprint path
    exercised" 其实是**假的**——`CrashSentinel.probed` 只判定一次，同进程内
    init 两次**不会**触发判定，那条路径从未被走过
  - 修复：探针进版本库、变成断言式（13 断言）、接入三个构建脚本 + CI
  - 崩溃指纹场景改用**独立目录 + 预先写好的 lock** 模拟"上次进程被杀"，
    并把该场景**放在第一次 init 之前**（`probed` 一旦置位就不再判定）
  - 负向测试 `src/test/negative/neg-fabricinit.ps1`：把 `init()` 改成"先 load
    配置再注入目录" → 10 通过 / 3 失败
- **回归镜像与生产悄悄分歧了**——`Regression.java` 是**独立镜像**（自己重写一遍
  生产逻辑，不引用生产类），好处是双方同时错才漏；代价是**生产行为有意改变时，
  镜像必须手工同步**。忘了同步，镜像会给出与生产**相反**的结论——比没有镜像
  更糟（有人依据它去改生产，会把正确的修复改回去），而且**没有任何东西报警**，
  因为镜像测试和自己一致、全绿
  - 实测到三处分歧：`hwDecoder = "  ANY  "`（镜像漏 trim → `none`，生产 → `any`）、
    `vout = ""`、`vout = "   "`（镜像返回空串，生产已回退 `gl,any`）
  - 修复：镜像同步到生产行为
  - 新增 `MirrorParityProbe`（8 断言）：**反射加载 Regression 里真实的镜像实现**
    逐个输入比对——把"镜像与生产分歧"变成可检测的失败，并打印分歧明细
  - 关键教训：探针**不能把镜像代码复制一份**到自己文件里。第一版就是这么写的，
    结果破坏 Regression 时行为比对两条仍然 PASS，只有源码断言发现得了——
    **安全网必须真的连在网上**
  - 负向测试 `src/test/negative/neg-mirrorparity.ps1`（坏代码上 6 通过 / 2 失败，
    且打印出 3 处分歧明细）
- **vout 配置为空时会把空模块名交给 libVLC**——用户把 `vout =` 清空（或写成
  `vout = ""`）时，`voutValue()` 原样返回**空串**，mixin 于是写出
  `--vout ""`——一个**空的视频输出模块名**。这比崩溃更隐蔽：不崩，只是没有
  画面，用户会以为是 watermedia 或别的 mod 的问题。而 `hwDecoderValue()` 对
  同样的空值早就回退到安全默认并警告了——**两个字段行为不一致**
  - 修复：空串与纯空白一律回退到 `DEFAULT_VOUT` 并给出警告
  - `null` 的语义不变（"未设置 / 保留原值"，即 `original` 的别名）——那是
    合法语义，不该回退
  - 探针 `ArgumentRewriteProbe` 补 4 条断言（此前第 9 组"空配置"**只查了
    hw、漏了 vout**，于是这个缺陷在探针里毫无痕迹）
  - 负向测试 `src/test/negative/neg-voutempty.ps1`（坏代码上 76 通过 / 4 失败）
- **配置默认值有四个真源**——`none` / `gl,any` / `false` 此前散落在**四处**：
  静态字段初值、`load()` 异常重置、`writeDefault()` **写进用户文件**的内容、
  `hwDecoderValue()` 未知值回退。任何一处漂移就会出现：用户拿到的配置文件
  写着一套策略，实际生效的是另一套，而加载日志说的是"已加载配置"——
  **没有任何异常提示**。典型的静默失效路径
  - 修复：提为三个 `DEFAULT_*` 常量（`BiliFixConfig`），四处全部引用
  - 探针 `src/test/java/ConfigDefaultProbe.java`（14 断言，**行为级**：
    真的生成配置文件、真的加载、真的回退，不只比对源码文本）
  - 负向测试 `src/test/negative/neg-cfgdefault.ps1`（默认值漂移 →
    12 通过 / 2 失败）
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖
  "ModList 不存在"时的降级；而成功路径（找到 ModList → 调
  `getModFileById` → 调 `versionString`）**零覆盖**。这条路径坏了，
  `EnvironmentDiagnostics` 会把**已安装的 watermedia 报成"未安装"**——
  诊断输出直接撒谎，用户照着日志排查会走错方向
  - 真实 FML 形状已用 `javap` 实证：Forge 1.20.1 与 NeoForge 1.21.1 的
    `ModList` 都是**具体类**，`getModFileById` 声明在类上、对未安装的 mod
    返回 `null`（字节码就是 `fileById.get(id)` + checkcast，**不抛异常**）；
    `FMLPaths` 两端都是 **enum**，`GAMEDIR` 是枚举常量，路径要靠实例方法
    `get()` 取——`FmlBridge.fmlDir` 的三步链路**与真实 FML 一致**
  - 新增探针 `src/test/java/FmlModVersionProbe.java`（9 断言）+
    独立桩目录 `src/test/stubs-fmlmodlist/`（ModList / IModFileInfo /
    IModInfo / IModFile / IConfigurable）
  - 新增负向测试 `src/test/negative/neg-fmlmodver.ps1`（把版本查询替换成
    返回 modId → 探针 6 通过 / 3 失败）
  - **探针发现并修正了一个错误的既有断言**：`FmlBridgeProbe` 原先断言
    "ModList 不存在时 modVersion 返回 null"——加了 ModList 桩后该环境在
    classpath 上**不再存在**，断言必然失败。改为断言"mod 未安装时返回
    null"（真实 FML 语义），把"ModList 完全不存在"留给独立的
    `FmlBridgeProbe` classpath 保留
  - **实测澄清（推翻了一开始的判断）**：`Class.getMethod()` 会搜索类、
    父类**以及实现的接口**上的 public 方法——即使实现类是**包私有**的，
    `getMethod("versionString")` 依然能命中。所以 `FmlBridge.call()` 的
    类查找路径就够用，其 `getInterfaces()` 接口回退是**冗余保险**，
    不是本场景的必需路径。探针把这条实测事实钉成断言
- **参数数组里的 null 元素会让加固逻辑抛 NPE**——`JarToolMixin` 的改写循环里  `switch (arg)` 对 null 元素抛
  `NullPointerException: Cannot invoke "String.hashCode()"`；
  `isValue(...)` 里的 `s.startsWith("-")` 同样会对 null 抛
  `NullPointerException: Cannot invoke "String.startsWith(String)"`
  - 实测（修复前）：参数数组含一个 null 元素 → 改写方法直接抛 NPE
  - **为什么重要**：本 mixin 是"绝对安全的加固点"，一个 NPE 从这里冒进
    watermedia 的 `PlayerAPI.start()` 会让**媒体播放直接失败**——
    加固点反而成了故障源。真实的 `videolan/arguments.json` 经 Gson 解析
    不会有 null 元素，但 `JarTool.readArray` 是**通用**方法，watermedia
    将来用它读别的 JSON，其值完全可以含 null
  - 修复：null 元素**丢弃**（它不可能是有效的 VLC 参数；若它落在某个选项的
    值位置，保留它会让该选项读到 null 值）；`isValue(null)` 返回 false
    而不是抛异常
  - 探针 `src/test/java/NullElementProbe.java`（15 断言）；
    负向测试 `src/test/negative/neg-nullelem.ps1`（还原两处防御后
    1 通过 / 14 失败，两条不同的 NPE 路径证明两处防御各自独立必要）
- **负向测试从未进入版本库**——全部 11 个 `out/neg-*.ps1` 一直在
  gitignore 的 `out/` 里：探针"能失败"的证据只存在于一台机器上，
  clone 仓库的人无法复现，CI 也不跑
  - 修复：移入 `src/test/negative/`（受版本控制），新增总控
    `run-all-negative-tests.ps1`（11 个全部跑，任一失败即构建失败），
    接入三个构建脚本、`out/ci-faithful.ps1` 与 `.github/workflows/ci.yml`
  - 顺带修了两个负向测试自身的缺陷：`neg-concurrency.ps1` 与
    `neg-fmlbridge.ps1` 没有显式 `exit 0`——"探针失败 = 负向测试成功"
    但脚本把探针的失败码当成了**自己**的退出码（总控会把它们误判为
    失败）；`neg-fmlbridge.ps1` 的 stub 扫描没排除 slf4j stub
    （javac 报"找不到 org.slf4j"，与其他脚本同坑）
  - 踩坑记录：`edit` 工具会剥掉 `.ps1` 的 UTF-8 BOM → WinPS 5.1 按
    ANSI 读中文路径变乱码（`涓€鍙瘉`）→ 所有含中文路径的脚本编辑后
    必须重新加 BOM
- **写错的配置键被静默忽略**——`parse()` 会把配置里的**所有**键放进 map，
  而 `load()` 只读 `hwDecoder` / `vout` / `verbose` 三个，其余**无声丢弃**：
  日志只打印一句"已加载配置"，用户以为自己改的配置生效了
  - 实测（修复前）：配置写 `hwdecoder = "any"`（`d` 小写，最常见的笔误）→
    加载"成功"、日志无任何提示、实际解码器仍是 `none`（软解）。
    用户设了硬解，得到软解，且毫无线索
  - 与 UTF-8 BOM 是**同族缺陷**：用户改了配置、文件也"加载成功"、
    设置没生效、日志不指向任何原因
  - 修复：`load()` 对未识别的键发警告，并区分最常见原因（大小写写错）
    与真正的未知键：
    `[BiliFix] 配置键 'hwdecoder' 拼写不对（键名区分大小写），应为 'hwDecoder'——本次该设置未生效`
  - 探针 `src/test/java/UnknownConfigKeyProbe.java`（10 断言）；
    负向测试 `out/neg-unknownkey.ps1`（还原后 3 通过 / 7 失败）
- **取证文件里的 `vout=null` 会让用户以为配置坏了**——`writeDiagnostic`（写
  `bilifix-diagnostic.txt`）与 `markSessionStart`（写 `bilifix-session.lock`）
  直接写 `voutValue()` 的返回值。用户显式配置 `vout = "original"`（或 `keep`）时，
  它返回 `null`——含义是"**保留 watermedia 的原值**"，但文件里就成了 `vout=null`，
  读起来像"配置丢了/坏了"，而实际配置完全正确
  - 实测（修复前）：`vout=original` / `keep` / `ORIGINAL` 三种写法都写成
    `strategy: hw=none, vout=null`
  - **为什么重要**：诊断文件是原生崩溃后 Java 侧**唯一**留下的东西，用户会照它排查
  - 修复：新增 `strategyVout()`，null 映射为用户能读懂的 `original`
  - 探针 `src/test/java/ForensicsVoutProbe.java`（12 断言）；
    负向测试 `out/neg-forensicsvout.ps1`（还原后 2 通过 / 10 失败）
- **启动行显示的值与实际生效的值不一致**——`BiliFixMod.init()` 打印的是配置里的
  **原始字符串**，而真正写进 VLC 参数的是**归一化后**的值
  （`hwDecoderValue()` / `voutValue()`）。两者在多处不同：
  `disable`/`off` → `none`、`auto`/`AUTO`/`any` → `any`、未知值（如 `gpu`）→ `none`、
  `vout=original`/`keep` → 保留原值、`vout` 的大小写与空白被标准化。
  **实测 9 个取值组合里 5 个显示值与生效值不符。**
  - **为什么重要**：启动行是崩溃排查时读的第一行。用户写 `hwDecoder="gpu"` 时
    日志说 `hw=gpu` 而实际已回退到 `none`（软解）——会以为硬解还开着、追错方向；
    `hwDecoder="AUTO"` 更危险：日志说 `hw=AUTO` 而实际是 `any`，
    即 VLC 自动选硬解——**正是引发崩溃的那一档**
  - 现在启动行显示**生效值**，且归一化发生时额外说明一行：
    `[BiliFix] 配置归一化：hwDecoder 'gpu' → none, vout 'ORIGINAL' → original`
  - `effectiveStrategy()` / `strategyWasNormalized()` 成为日志与探针的**单一真相源**，
    两者不会再漂移
  - 探针 `src/test/java/StartupLogTruthProbe.java`（23 断言）遍历 13 个配置组合；
    负向测试 `out/neg-startuplog.ps1` 证明其有效（还原后 10 通过 / 4 失败）
  - **踩坑记录**：探针的源码级断言必须**接收源码文件路径作为参数**——
    否则它读的是工作副本而非被测的那份代码，断言会对坏掉的代码**假 PASS**；
    且断言必须只看 `effectiveStrategy()` 方法体（`strategyWasNormalized()`
    里同样调用 `hwDecoderValue()`，搜全文会掩盖破坏）
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

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖：崩溃结论会被随后的正常退出覆盖
- 问题：结论原先只写在 `bilifix-diagnostic.txt` 里，而该文件每次干净退出都会重写。
  用户的真实使用顺序是"崩溃 → 重启 → 干点别的 → 正常退出 → 这时才去看文件"，
  于是唯一带证据的那次会话的结论被覆盖掉了
- 现在结论单独写入 `bilifix-crash.txt`：只在判定到异常终止时写，正常退出不动它

### 测试
- 会话取证 11 项新测试（含幂等性、干净退出恢复、null 目录安全）（51 → 62）
- 崩溃结论持久化 4 项新测试（含"正常退出重写快照后结论仍在"）（62 → 66）

## 1.4.6 — 2026-10-15

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（第 20 轮审查：语义与行为一致）
- 配置加载失败分支现在**真的**重置字段为安全默认（此前日志称"使用默认值"但字段保留上次值——
  首次加载无行为差异，但为未来 reload 埋雷）

## 1.4.5 — 2026-10-15

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（第 18 轮审查：失败语义）
- Mixin 注入器 `defaultRequire` 1 → 0：未来 watermedia 若重构掉注入目标，
  修复**静默失效**（仅警告）而非升级为 mod 加载错误——修复 mod 绝不能把游戏搞挂

## 1.4.4 — 2026-10-15

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（第 15 轮审查）
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

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（代码审查 #7：配置写入原子性）
- 默认配置改为原子写入（临时文件 + `ATOMIC_MOVE`）：磁盘满或进程中断不再可能留下损坏的半截配置文件
- 文件系统不支持原子移动时自动降级为普通 move

### 构建返工记录（同日两次，详见 docs/postmortem-1.3.2.md）
1. **zip 结构损坏**：可复现构建的时间戳后处理在 DOS epoch 边界写出非法 central directory，
   游戏启动报 `invalid entry size` → 移除后处理 + 构建期加入消费方级 jar 完整性自检
2. **mods.toml 结构错误**：扁平 key 不是 FML 要求的标准结构，游戏报 `Missing ModLoader` →
   对照正常 mod 重写为标准 FML 结构（modLoader/[[mods]]/[[mixins]]），双 toml 兼容
3. 工具链：build.ps1 加 12 项 FML 结构预检；新增 deploy.ps1 一键三渠道部署（含完整性门禁）

## 1.3.1 — 2026-10-14

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（代码审查 #3）
- GPU 检测的管道死锁隐患：改为后台线程读流后再 waitFor（防注册表输出超管道缓冲区时卡游戏）

## 1.3.0 — 2026-10-14

### 新增
- **GPU 诊断**：启动诊断新增显卡型号检测（Windows 注册表查询，3 秒超时保护，非 Windows/失败静默降级）；检测到 Microsoft 基本显示驱动时警告
- README 注明 watermedia 3.0 兼容性（3.0 已移除 libVLC，无需本模组；本模组只针对 2.1.x）

## 1.2.1 — 2026-10-14

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（配置解析鲁棒性）
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

### 修复
- **`FmlBridge.modVersion` 的成功路径从未被测过**——`FmlBridgeProbe` 只覆盖（代码审查发现）
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