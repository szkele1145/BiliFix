# 游戏内验证清单（用户醒来后按此执行）

> BiliFix v1.3.2 已部署在 `D:\PCL2\.minecraft\versions\航空学这一块\mods\`，
> 启动游戏即可开始验证。
> 
> **前置链路**：哔哩哔哩WaterMedia兼容模组（bilibili_media，Modrinth: bilibilimedia）
> + watermedia 2.1.x + waterframes —— 本模组修复的正是这条 B 站视频播放链。

## 一、启动验证（1 分钟）

1. 启动 PCL → 启动"航空学这一块"
2. 打开日志（PCL 的日志页或 `logs/latest.log`），确认以下三行存在：

   ```
   [BiliFix] v1.3.2 已加载：watermedia VLC 硬解崩溃修复（策略: hw=none, vout=gl,any）
   [BiliFix] ==== BiliFix 环境诊断 ====
   [BiliFix] watermedia: 已安装 ✓（BiliFix 正在守护）
   ```

   - [ ] 启动日志三行齐全
   - [ ] 无 BiliFix 相关报错

   **若"环境诊断"里 GPU 行显示你的真实显卡型号（如 NVIDIA/AMD/Intel）→ GPU 检测工作正常**

## 二、核心验证（播放之前必崩的视频）

3. 进入之前崩过的服务器/存档
4. **播放之前触发崩溃的 B 站视频**（就是那些 17:18 / 17:30 / 17:36 崩溃场景）
5. 播放期间确认另一行日志：

   ```
   [BiliFix] VLC 参数已加固: --avcodec-hw=none , --vout=gl,any (原 16 项 → 新 16 项)
   ```

   - [ ] 播放时出现"参数已加固"日志
   - [ ] 视频正常播放（画面 + 声音）
   - [ ] **播放 5 分钟以上游戏不退出**（之前 3 分钟内必崩）

## 三、回归确认

6. 切换几个不同视频再播（B 站普通视频 + 番剧/直播如有）
   - [ ] 不同类型视频均正常
7. 检查 `bilifix.toml` 已在 `.minecraft/config/` 生成
   - [ ] 配置文件存在且可读（含 hwDecoder / vout / verbose 三项注释齐全）

## 四、结果记录

- **全部通过** → 修复确认有效。告诉我一声，我把"实测有效"更新到项目描述里。
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
