# 游戏内验证清单（用户醒来后按此执行）

> **当前待验证：v1.4.8**（2026-10-18 15:30 部署）：
> - NeoForge 侧：`D:\PCL2\.minecraft\versions\航空学这一块\mods\BiliFix-1.4.8-mc1.21.1-neoforge.jar`
>   （旧 1.4.4 已删；watermedia 2.1.36 + bilibili_media 2.3 在位，完整验证场）
> - Fabric 侧：`D:\PCL2\.minecraft\versions\璃湾省 1.20.1 城建版\mods\BiliFix-1.4.8-mc1.20.1-fabric.jar`
>   （该实例无 watermedia → 验证静默待机不搞挂游戏）
>
> **前置链路**：哔哩哔哩WaterMedia兼容模组（bilibili_media，Modrinth: bilibilimedia）
> + watermedia 2.1.x + waterframes —— 本模组修复的正是这条 B 站视频播放链。

## 一、启动验证（1 分钟）⏳ 待做（v1.4.8，NeoForge 侧）

> **证据现状（勿混淆版本）**：已完成的启动验证跑的是 **v1.3.2**（10-14 16:39→16:54，
> 14 分 36 秒）与 **v1.4.4**（10-15 19:53→20:44，51 分钟）——两次都干净退出、无崩溃。
> **v1.4.7/v1.4.8 从未启动过**。v1.4.7 的会话取证（`bilifix-session.lock` /
> `bilifix-crash.txt` / `media touched` 字段）与 v1.4.8 的 Fabric 入口 +
> 反射桥降级均为**全新代码路径，零运行时验证**，必须重跑本节。

1. 启动 PCL → 启动"航空学这一块"
2. 打开日志（PCL 的日志页或 `logs/latest.log`），确认以下三行存在：

   ```
   [BiliFix] v1.4.8 已加载：watermedia VLC 硬解崩溃修复（策略: hw=none, vout=gl,any）
   [BiliFix] ==== BiliFix 环境诊断 ====
   [BiliFix] watermedia: 已安装 ✓（BiliFix 正在守护）
   ```

   > 上面是**行格式**示例（版本号随 jar 变化，以你实际部署的为准）。

   - [ ] 启动日志三行齐全，且版本号为 **1.4.8**
   - [ ] 启动后 `mods` 同级目录出现 `bilifix-session.lock`（本次会话的存活标记）
   - [ ] 关闭游戏后 `bilifix-session.lock` 消失，且**未**生成 `bilifix-crash.txt`
     （生成即代表误判上次为崩溃——这正是 v1.4.7 起要验证的新逻辑）

   **若"环境诊断"里 GPU 行显示你的真实显卡型号（如 NVIDIA/AMD/Intel）→ GPU 检测工作正常**

   ### v1.4.8 新增：两条自检日志（必须出现）

   ```
   [BiliFix] Mixin 注入目标自检通过: org.watermedia.core.tools.JarTool.readArray(String) 唯一匹配
   [BiliFix] 功能自检通过: --avcodec-hw=none , --vout=gl,any —— 注入已生效（端到端验证）
   ```

   - [ ] 出现「Mixin 注入目标自检通过」行
   - [ ] 出现「**功能自检通过**」行 —— 这行是**端到端**证据：它真的调用了一次
     `JarTool.readArray`，并确认返回的 `--avcodec-hw` **和** `--vout` 都已是安全值
   - [ ] 若出现任何 `⚠` 开头的 BiliFix 警告行 → **判定不通过**（说明注入未生效，
     崩溃会回来）

   > 功能自检为何是决定性的：`bilifix.mixins.json` 是 `required:false`，
   > mixin 框架会把注入失败降级为 debug 日志（正常日志级别看不见）→
   > "模组装着、修复没生效"这种最难察觉的失效，过去没有任何提示。
   > 功能自检是唯一能证明注入真的生效的手段。
   > 参考基线（`out/mixin-e2e/probe-mixin-e2e.ps1` A 线实证）：裸 JVM 无 mixin
   > 时真实 2.1.36 的参数表是 `--avcodec-hw d3d11va,dxva2,any` +
   > `--vout direct3d11,glwin32,gl,any`（18 项）——游戏内应看不到这组值。

## 二、核心验证（播放之前必崩的视频）

3. 进入之前崩过的服务器/存档
4. **播放之前触发崩溃的 B 站视频**（就是那些 17:18 / 17:30 / 17:36 崩溃场景）
5. 播放期间确认另一行日志：

   ```
   [BiliFix] VLC 参数已加固: --avcodec-hw=none , --vout=gl,any (原 18 项 → 新 18 项)
   ```
   （该行在**启动时**即出现——watermedia 在 mod 加载阶段就创建 VLC 实例，
   不必等播放；16:40:24 的 v1.3.2 日志已证实）

   - [ ] 本次启动出现"参数已加固"日志，且 `hw=none`

   > **已确立的端到端证据（v1.3.2 会话，16:40:25）**：watermedia 日志打印的
   > VLC 实际参数序列为 `--vout, gl,any` + `--avcodec-hw, none`
   > ——替换项已真实送达 libVLC，其余参数原样保留（18 项不增不减）。
   > **注意**：该证据来自 v1.3.2；v1.4.4 会话同样打印了 18→18 的加固日志。
   > v1.4.8 的 Mixin 注入逻辑未改动，但仍应在本次会话中重新确认一次。
   - [ ] 视频正常播放（画面 + 声音）
   - [ ] **播放 5 分钟以上游戏不退出**（之前 3 分钟内必崩）
   - [ ] 退出后诊断文件出现 `media touched` 字段且为"是"（v1.4.7 新增，用于
     区分"真播放过"与"只是开着游戏"——v1.4.4 的 51 分钟会话就没有该字段，
     因此无法证明当时播放过媒体）

## 三、回归确认

6. 切换几个不同视频再播（B 站普通视频 + 番剧/直播如有）
   - [ ] 不同类型视频均正常
7. 检查 `bilifix.toml` 已在 `.minecraft/config/` 生成
   - [ ] 配置文件存在且可读（含 hwDecoder / vout / verbose 三项注释齐全）

## 三-B、Fabric 侧验证（⏳ 待做，v1.4.8 新增）

8. 启动 PCL → 启动"璃湾省 1.20.1 城建版"（Fabric 1.20.1，63 个 fabric mod，
   无 watermedia）
9. 预期行为——**BiliFix 静默待机，游戏完全正常**：
   - [ ] 日志有 `[BiliFix] v1.4.8 已加载：...` 一行（入口 BiliFixFabric →
     BiliFixMod.init 走通，FabricLoader 目录注入成功）
   - [ ] 日志有环境诊断块，但 watermedia 行报"未安装"（classpath 探测降级，
     不报错不搞挂游戏）
   - [ ] **无** "VLC 参数已加固"行（无注入目标，`required:false` 静默跳过）
   - [ ] 游戏正常进主菜单/世界，正常退出；`bilifix-session.lock` 出现后消失，
     无 `bilifix-crash.txt`
10. 这一半验证通过 = Fabric 入口 + 反射桥降级 + 静默待机三件事全部成立。
    之后 Forge 变体（无真机场，暂缓）与 NeoForge 侧任一通过，即可晋级 CHANGELOG。

## 四、结果记录

- **全部通过** → 修复确认有效。告诉我一声，我晋级 CHANGELOG `## Unreleased` →
  `## 1.4.8` 并走 publish.ps1 发布。
- **出现新崩溃** → 把新的错误报告 zip 发我（PCL 自动生成那个），我继续排查。
- **视频画面异常但游戏不崩** → 把 `config/bilifix.toml` 里的 `vout` 改成 `original` 再试，然后告诉我现象。

## 已知背景

- 之前的三次崩溃（17:18 / 17:30 / 17:36）退出码全是 -1，无 Java 堆栈 → 原生层死亡
- 根因：watermedia 强制 D3D11VA 硬解，解码线程拷贝硬解表面回 Java 堆时崩溃
- BiliFix 把 VLC 改为软件解码（`--avcodec-hw none`），代价是视频解码吃一点 CPU，1080p 无压力

## Modrinth 审核预期（2026-10-14 查证官方文档）

当前提交审核约 7 小时无结果属**完全正常**：官方说明正常 24–48 小时，
因审核员培训期平均 **2–4 周甚至更长**。审核期间上传新版本不影响队列位置，
催促只会更慢。无需任何操作，等即可。
