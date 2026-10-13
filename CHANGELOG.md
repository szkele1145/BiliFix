# Changelog

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
