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

### 构建 / 部署
- `deploy.ps1` 支持三变体：`-Variant neoforge|forge|fabric` 选择本地部署目标，
  GitHub Release 资产同步改为**增量**（原先"先全删再传一个"会把另外两个变体的
  资产一并删掉）；默认同步该版本所有已构建变体，未构建的跳过并提示
- 修 Windows PowerShell 5.1 解析坑：无 BOM 的 .ps1 按 ANSI 解析，脚本内中文
  实例名乱码导致语法错误 → `deploy.ps1` 改写为 UTF-8 with BOM

### 测试
- 新增 §9.6b：1.20.1 两变体 jar 结构守卫——in-jar `bilifix.mixins.json` 必须是
  `JAVA_17` 且**无 `JAVA_21` 残留**（防打包暂存改写被 `git checkout` 之类操作
  静默丢失）；Forge 断言 MANIFEST `MixinConfigs`，Fabric 断言
  `fabric.mod.json` entrypoint 与 `BiliFixFabric.class`（89 → 99 项）
- 资源守卫用例补齐：`fixArgs` 在资源缺失 / 空数组 / null 元素时原样返回副本，
  以及"尾部 `--avcodec-hw` 缺值"与 `vout=null` 追加顺序等边界（66 → 85）
  > 说明：上一条 1.4.7 条目里的 66 是**发布当时**的真实值；此后 b273823 又补了
  > 19 项，v1.4.8 再加 10 项，故当前源码为 99（`./build.ps1` 实测"通过 99 / 失败 0"）。

### 文档
- 修正文档失真（均有会话日志实证）：
  - `docs/verification-checklist.md` 曾把 **v1.4.7** 的启动验证标为已通过，
    但作为依据的 2026-10-14 16:39 会话跑的是 **v1.3.2**（14 分 36 秒）；
    v1.4.7 的 jar 于 10-16 07:30 部署，而 `latest.log` 最后写入停在 10-15 20:44
    → v1.4.7 **从未启动过**，其会话取证属零验证代码路径，清单已改回待做
  - README（中/英）示例日志的"原 16 项 → 新 16 项"实为 **18 项**
    （v1.3.2 与 v1.4.4 会话均实证），并补充说明该数字随 watermedia 版本变化
  - README（中/英）、CONTRIBUTING 的测试数 66 → 85
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

