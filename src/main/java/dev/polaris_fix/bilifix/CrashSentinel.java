package dev.polaris_fix.bilifix;

import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.lang.management.ManagementFactory;
import java.lang.management.RuntimeMXBean;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 崩溃诊断守护：在 JVM 退出时尽力留下一份诊断文件。
 *
 * <p>背景：BiliFix 修复的是原生层崩溃（D3D11VA 硬解把整个 JVM 打死，无 Java 堆栈）。
 * 这类崩溃发生后，启动器和崩溃分析器都拿不到 Java 层的线索。本守护在
 * shutdown hook 里把 BiliFix 的运行状态（加固参数、Mixin 应用次数、
 * 生命周期事件）写入 <code>bilifix-diagnostic.txt</code>：</p>
 * <ul>
 *   <li><b>正常退出</b>（用户关游戏）：文件记录"clean exit"，覆盖上次的崩溃快照</li>
 *   <li><b>异常退出</b>（崩溃后 hook 仍有机会运行的场景）：文件保留崩溃前状态，
 *       用户下次崩溃报告时附上即可加速定位</li>
 *   <li><b>硬性原生崩溃</b>（hook 完全没机会）：文件停留在上次会话内容——
 *       "文件时间戳早于崩溃时间"本身就是有价值的排查信息</li>
 * </ul>
 *
 * <p>设计约束：hook 里的代码必须极简且绝不能抛错（否则可能挂死退出流程）；
 * 所有状态收集在平时进行（O(1) 字段更新），hook 里只做一次顺序写。</p>
 */
public final class CrashSentinel {
    /** Mixin 参数加固的应用次数 */
    private static final AtomicLong HARDEN_COUNT = new AtomicLong();

    /** 生命周期事件（容量截断，防长会话内存增长） */
    private static final List<String> EVENTS = new CopyOnWriteArrayList<>();

    private static final int MAX_EVENTS = 64;

    private static volatile boolean registered = false;

    private CrashSentinel() {}

    /** 记录一次 Mixin 参数加固 */
    public static void recordHarden(int originalCount, int newCount) {
        HARDEN_COUNT.incrementAndGet();
        record("VLC args hardened: " + originalCount + " -> " + newCount + " items"
                + " (hw=" + BiliFixConfig.hwDecoderValue() + ")");
    }

    /** 记录生命周期事件（超过上限时丢弃最旧的） */
    public static void record(String event) {
        if (EVENTS.size() >= MAX_EVENTS) EVENTS.remove(0);
        EVENTS.add(Instant.now() + " | " + event);
    }

    /** 注册退出守护（幂等，由 BiliFixMod 构造时调用一次） */
    public static synchronized void register() {
        if (registered) return;
        registered = true;
        Runtime.getRuntime().addShutdownHook(new Thread(CrashSentinel::writeDiagnostic,
                "BiliFix-CrashSentinel"));
        record("sentinel registered");
    }

    /** 写诊断文件（hook 内执行：顺序、同步、无外部依赖、绝不抛错） */
    private static void writeDiagnostic() {
        try {
            Path dir = net.neoforged.fml.loading.FMLPaths.GAMEDIR.get();
            Path out = dir.resolve("bilifix-diagnostic.txt");
            StringBuilder sb = new StringBuilder(2048);
            sb.append("== BiliFix Diagnostic ==\n");
            try {
                RuntimeMXBean rt = ManagementFactory.getRuntimeMXBean();
                sb.append("jvm uptime: ").append(rt.getUptime() / 1000).append("s\n");
            } catch (Throwable ignored) {
                // ManagementFactory 在 hook 中不可用则跳过
            }
            sb.append("exit at: ").append(Instant.now()).append('\n');
            sb.append("harden count: ").append(HARDEN_COUNT.get()).append('\n');
            sb.append("strategy: hw=").append(BiliFixConfig.hwDecoderValue())
              .append(", vout=").append(BiliFixConfig.voutValue()).append('\n');
            sb.append("events (latest ").append(EVENTS.size()).append("):\n");
            for (String e : EVENTS) sb.append("  ").append(e).append('\n');
            sb.append("-- end --\n");
            Files.write(out, sb.toString().getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE);
        } catch (Throwable ignored) {
            // 守护绝不能影响退出流程
        }
    }
}
