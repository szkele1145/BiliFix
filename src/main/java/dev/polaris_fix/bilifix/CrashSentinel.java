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
 * 崩溃诊断守护：把 BiliFix 的运行状态落盘，并为"无声崩溃"留下证据。
 *
 * <p>背景：BiliFix 修复的是原生层崩溃（D3D11VA 硬解把整个 JVM 打死，无 Java 堆栈）。
 * 这类崩溃发生后，启动器和崩溃分析器都拿不到 Java 层的线索。</p>
 *
 * <p><b>关键约束</b>：原生崩溃（native abort）<b>不会执行 JVM shutdown hook</b>。
 * 因此单独依赖"退出时写文件"无法区分"上次干净退出"与"上次被原生层打死"。
 * 本类用两个文件构成可客观判定的证据链：</p>
 * <ul>
 *   <li>{@code bilifix-session.lock} —— 会话进行中标记。启动时留下，
 *       <b>干净退出时删除</b>。</li>
 *   <li>{@code bilifix-diagnostic.txt} —— 退出快照。hook 里写入本次运行状态
 *       （加固次数、策略、生命周期事件）。</li>
 * </ul>
 *
 * <p>两者组合出的判定：</p>
 * <ul>
 *   <li><b>上次干净退出</b>：本次启动时没有残留 lock → 正常，不必打扰用户</li>
 *   <li><b>上次硬性原生崩溃</b>：本次启动时发现残留 lock（说明上次没走到 hook）
 *       → 明确告诉用户"上次会话异常终止，未执行退出流程"，并给出排查建议。
 *       这是本模组针对的故障类型的直接指纹。</li>
 * </ul>
 *
 * <p>设计约束：hook 里的代码必须极简且绝不能抛错（否则可能挂死退出流程）；
 * 所有状态收集在平时进行（O(1) 字段更新），hook 里只做一次顺序写。</p>
 */
public final class CrashSentinel {
    /** 会话进行中标记的文件名（存在 = 上次没有干净退出） */
    public static final String SESSION_FILE = "bilifix-session.lock";

    /** 退出快照文件名 */
    public static final String DIAGNOSTIC_FILE = "bilifix-diagnostic.txt";

    /** Mixin 参数加固的应用次数 */
    private static final AtomicLong HARDEN_COUNT = new AtomicLong();

    /** 本次会话是否真的执行过参数加固（= 用户确实播放过媒体） */
    private static volatile boolean mediaTouched = false;

    /** 生命周期事件（容量截断，防长会话内存增长） */
    private static final List<String> EVENTS = new CopyOnWriteArrayList<>();

    private static final int MAX_EVENTS = 64;

    private static volatile boolean registered = false;

    /** 上次会话探测只做一次：重复构造时第二次会看到本次刚写的 lock，误报为崩溃 */
    private static volatile boolean probed = false;

    private CrashSentinel() {}

    /** 记录一次 Mixin 参数加固（fullArgs 非空时附带完整参数序列） */
    public static void recordHarden(int originalCount, int newCount, String fullArgs) {
        HARDEN_COUNT.incrementAndGet();
        mediaTouched = true;
        String event = "VLC args hardened: " + originalCount + " -> " + newCount + " items"
                + " (hw=" + BiliFixConfig.hwDecoderValue() + ")";
        if (fullArgs != null) event += " | " + fullArgs;
        record(event);
    }

    /** 本次会话是否执行过参数加固（即是否播放过媒体） */
    public static boolean mediaTouched() {
        return mediaTouched;
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
        Runtime.getRuntime().addShutdownHook(new Thread(CrashSentinel::onShutdown,
                "BiliFix-CrashSentinel"));
        record("sentinel registered");
    }

    /**
     * 上次会话是否异常终止（原生崩溃指纹）。
     *
     * <p>必须在 {@link #register()} <b>之前</b>调用：register() 会留下本次会话的
     * lock，之后就无法区分残留的是上次的还是本次的。</p>
     *
     * @param gameDir 游戏目录
     * @return 上次异常终止的诊断文本；上次干净退出（或无法判定）时返回 null
     */
    public static String detectUncleanShutdown(Path gameDir) {
        if (gameDir == null) return null;
        if (probed) return null;   // 幂等：只判定一次，避免重复构造误报
        probed = true;
        try {
            Path session = gameDir.resolve(SESSION_FILE);
            if (!Files.exists(session)) return null;
            long ageSec = -1;
            try {
                ageSec = Math.max(0, (System.currentTimeMillis()
                        - Files.getLastModifiedTime(session).toMillis()) / 1000L);
            } catch (Throwable ignored) {
                // 时间不可读不影响判定，只是少一条信息
            }
            record("unclean previous session detected (lock age " + ageSec + "s)");
            return "上次游戏会话异常终止（未执行 JVM 退出流程）。\n"
                 + "session lock: " + session + " (存在 " + ageSec + " 秒)\n"
                 + "这种退出方式（无 Java 堆栈 / 退出码 -1）与原生层崩溃一致。\n"
                 + "若你刚播过 B 站视频，请把这份文件和 PCL 的错误报告一起反馈。\n"
                 + "排查建议：确认 bilifix.toml 的 vout = \"gl,any\"、hwDecoder = \"none\"，"
                 + "然后把 vout 改为 \"original\" 对比是否复现。\n";
        } catch (Throwable ignored) {
            // 取证失败绝不影响游戏启动
            return null;
        }
    }

    /** 标记本次会话进行中（启动时调用）。失败不影响游戏。 */
    public static void markSessionStart(Path gameDir) {
        if (gameDir == null) return;
        try {
            String content = "pid=" + ProcessHandle.current().pid()
                    + "\nversion=" + BiliFixMod.VERSION
                    + "\nstarted=" + Instant.now()
                    + "\nstrategy: hw=" + BiliFixConfig.hwDecoderValue()
                    + ", vout=" + BiliFixConfig.voutValue() + "\n";
            Files.write(gameDir.resolve(SESSION_FILE),
                    content.getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE);
        } catch (Throwable ignored) {
            // 标记失败只会让"上次异常终止"的判定失效，不影响游戏运行
        }
    }

    /** 退出流程：写快照 + 清除会话标记（必须最先清除标记，见下） */
    private static void onShutdown() {
        Path gameDir;
        try {
            gameDir = gameDirectory();
        } catch (Throwable ignored) {
            gameDir = null;
        }
        // 先删标记：只要走到了这里（哪怕是崩溃后的正常退出流程），就说明
        // JVM 有机会执行 hook，不算"原生层直接打死"。若写快照时再崩，
        // 标记已清除会漏报一次——但漏报比误报安全（误报会让用户白排查）。
        try {
            if (gameDir != null) Files.deleteIfExists(gameDir.resolve(SESSION_FILE));
        } catch (Throwable ignored) {
            // 删不掉则下次启动会报一次"上次异常终止"——保守方向，可接受
        }
        writeDiagnostic(gameDir);
    }

    /** 写诊断文件（hook 内执行：顺序、同步、无外部依赖、绝不抛错） */
    private static void writeDiagnostic(Path gameDir) {
        if (gameDir == null) return;
        try {
            Path out = gameDir.resolve(DIAGNOSTIC_FILE);
            StringBuilder sb = new StringBuilder(2048);
            sb.append("== BiliFix Diagnostic ==\n");
            try {
                RuntimeMXBean rt = ManagementFactory.getRuntimeMXBean();
                sb.append("jvm uptime: ").append(rt.getUptime() / 1000).append("s\n");
            } catch (Throwable ignored) {
                // ManagementFactory 在 hook 中不可用则跳过
            }
            sb.append("exit at: ").append(Instant.now()).append('\n');
            sb.append("version: ").append(BiliFixMod.VERSION).append('\n');
            sb.append("harden count: ").append(HARDEN_COUNT.get()).append('\n');
            sb.append("media touched: ").append(mediaTouched ? "yes" : "no").append('\n');
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

    /** 游戏目录（NeoForge 与 Forge 的 API 同名，仅包名不同） */
    private static Path gameDirectory() {
        return net.neoforged.fml.loading.FMLPaths.GAMEDIR.get();
    }
}
