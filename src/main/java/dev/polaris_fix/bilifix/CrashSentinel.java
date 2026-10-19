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
 *   <li>{@code bilifix-crash.txt} —— 异常终止<b>结论</b>。只在发现上次残留 lock 时
 *       写入，干净退出不覆盖，所以用户晚几天回来查看也还有线索。</li>
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
    /**
     * 崩溃结论文件名（只在发现上次异常终止时写入，干净退出<b>不覆盖</b>）。
     *
     * <p>为什么单独一个文件：用户的实际行为往往是"崩溃 → 重启 → 再做点别的 →
     * 正常退出 → 这时才想起来看日志"。若把结论只塞进退出快照
     * （{@link #DIAGNOSTIC_FILE}），本次正常退出会把唯一的结论覆盖掉，线索
     * 就此永久丢失。单独落盘后，结论会一直保留到下一次异常终止为止。</p>
     */
    public static final String CRASH_FILE = "bilifix-crash.txt";

    /** Mixin 参数加固的应用次数 */
    private static final AtomicLong HARDEN_COUNT = new AtomicLong();

    /** 本次会话是否真的执行过参数加固（= 用户确实播放过媒体） */
    private static volatile boolean mediaTouched = false;

    /**
     * 取证抑制开关：为 true 时 {@link #recordHarden} 不置 {@code mediaTouched}、
     * 不递增 {@code HARDEN_COUNT}、也不写事件。
     *
     * <p><b>为什么需要</b>（v1.4.8 功能自检引入的取证污染）：启动自检会真的调用
     * 一次 {@code JarTool.readArray}，这会触发 mixin → {@code recordHarden} →
     * {@code mediaTouched = true}。于是用户<b>根本没播放过媒体</b>，诊断文件却写
     * {@code media touched: yes}——直接摧毁 v1.4.7 建立的核心取证语义
     * （"media touched 用于区分『真播放过媒体』与『只是开着游戏』"）。
     * 崩溃排查时这个字段一旦撒谎，结论就不可信了。</p>
     */
    private static volatile boolean suppressForensics = false;

    /**
     * 设置取证抑制（自检类调用必须成对使用 try/finally 复位）。
     *
     * @param suppress true = 抑制取证计数与 mediaTouched
     */
    public static void setForensicsSuppressed(boolean suppress) {
        suppressForensics = suppress;
    }

    /** 生命周期事件（容量截断，防长会话内存增长） */
    private static final List<String> EVENTS = new CopyOnWriteArrayList<>();

    private static final int MAX_EVENTS = 64;

    private static volatile boolean registered = false;

    /** 上次会话探测只做一次：重复构造时第二次会看到本次刚写的 lock，误报为崩溃 */
    private static volatile boolean probed = false;

    /**
     * 外部注入的游戏目录（Fabric 侧用）。为 null 时走 FMLPaths 兜底，
     * 使同一份 CrashSentinel 在 NeoForge/Forge（FMLPaths 可用）与
     * Fabric（FML 不可用，由 entrypoint 注入）上都能正确工作。
     */
    private static volatile Path injectedGameDir;

    private CrashSentinel() {}

    /**
     * 注入游戏目录（Fabric entrypoint 调用）。
     *
     * <p>为什么需要注入：Fabric 上没有 FML，{@code FMLPaths} 不可用。让 Fabric
     * 侧把 {@code FabricLoader.getInstance().getGameDir()} 传进来，同一份
     * CrashSentinel 就能在三种 loader 上共用，无需维护第二份实现。
     * 本方法只依赖 JDK 的 {@link Path}，所以在纯 JVM 测试里也能调用。</p>
     */
    public static void setGameDir(Path gameDir) {
        injectedGameDir = gameDir;
    }

    /** 记录一次 Mixin 参数加固（fullArgs 非空时附带完整参数序列） */
    public static void recordHarden(int originalCount, int newCount, String fullArgs) {
        if (suppressForensics) return;   // 自检调用：不污染取证数据（见 suppressForensics javadoc）
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

    /**
     * 记录生命周期事件（超过上限时丢弃最旧的）。
     *
     * <p>{@code synchronized} 是为了让容量上限成为<b>硬保证</b>：目标集合虽然是
     * 线程安全的 {@link CopyOnWriteArrayList}，但"判满 → 丢最旧 → 追加"是一组
     * check-then-act，单独看每一步都安全、合起来不是。{@link #recordHarden} 经
     * Mixin 在媒体加载线程上被调用，并发进入是可能的。事件记录是低频路径
     * （仅生命周期节点），加锁没有性能顾虑。</p>
     */
    public static synchronized void record(String event) {
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
            String report = "上次游戏会话异常终止（未执行 JVM 退出流程）。\n"
                 + "session lock: " + session + " (存在 " + ageSec + " 秒)\n"
                 + "这种退出方式（无 Java 堆栈 / 退出码 -1）与原生层崩溃一致。\n"
                 + "若你刚播过 B 站视频，请把这份文件和 PCL 的错误报告一起反馈。\n"
                 + "排查建议：确认 bilifix.toml 的 vout = \"gl,any\"、hwDecoder = \"none\"，"
                 + "然后把 vout 改为 \"original\" 对比是否复现。\n";
            writeCrashReport(gameDir, ageSec, report);
            return report;
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
            sb.append("events (").append(EVENTS.size()).append(" recorded):\n");
            for (String e : EVENTS) sb.append("  ").append(e).append('\n');
            sb.append("-- end --\n");
            Files.write(out, sb.toString().getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE);
        } catch (Throwable ignored) {
            // 守护绝不能影响退出流程
        }
    }

    /**
     * 解析游戏目录：优先用 {@link #setGameDir(Path)} 注入的值（Fabric 侧），
     * 否则通过 {@link FmlBridge} 反射读取 FML 的 {@code FMLPaths.GAMEDIR}
     * （NeoForge / Forge 的包名不同，反射可同时兼容，且 Fabric 编译期无需这些类）。
     *
     * <p>Fabric 运行时（无注入且无 FML）返回 null；所有调用方均已做 null 判定
     * （{@code onShutdown} 的 delete 分支、{@code writeDiagnostic}、
     * {@code writeCrashReport} 的 early-return），不会 NPE。</p>
     */
    private static Path gameDirectory() {
        Path injected = injectedGameDir;
        if (injected != null) return injected;
        return FmlBridge.fmlDir("GAMEDIR");
    }

    /**
     * 把"上次异常终止"的结论写入 {@link #CRASH_FILE}。
     *
     * <p>与退出快照的区别：这个文件只在判定到异常终止时写，正常退出不动它，
     * 所以用户晚几天回来查看也仍能看到结论。失败不影响游戏。</p>
     */
    private static void writeCrashReport(Path gameDir, long ageSec, String report) {
        if (gameDir == null) return;
        try {
            StringBuilder sb = new StringBuilder(report.length() + 256);
            sb.append("== BiliFix 异常终止报告 ==\n");
            sb.append("detected at: ").append(Instant.now()).append('\n');
            sb.append("version: ").append(BiliFixMod.VERSION).append('\n');
            sb.append("lock age: ").append(ageSec).append("s\n");
            sb.append('\n').append(report);
            sb.append("-- end --\n");
            Files.write(gameDir.resolve(CRASH_FILE),
                    sb.toString().getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE);
        } catch (Throwable ignored) {
            // 写不出报告不影响游戏，也不影响日志里的同一条结论
        }
    }
}
