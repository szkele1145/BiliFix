# Changelog

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

