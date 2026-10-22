package dev.polaris_fix.bilifix.config;

import dev.polaris_fix.bilifix.BiliFixMod;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * BiliFix 极简配置系统（零依赖，不引 Cloth Config/YACL）。
 *
 * 配置文件：.minecraft/config/bilifix.toml
 * 语法为极简 TOML 子集：key = "value" / key = true|false / # 注释
 *
 * 项：
 *   hwDecoder = "none"|"auto"|"any"|"d3d11va"|"dxva2"|"disable"   解码策略
 *   vout      = "gl,any"|"direct3d11,glwin32,gl,any"|"original"    视频输出策略
 *   verbose   = true|false                                        打印替换详情
 */
public final class BiliFixConfig {

    // ---------- 默认值：单一真源 ----------
    // 为什么必须提出来（v1.4.8 审查发现）："none" / "gl,any" / false 这三个
    // 默认值此前**散落在四个地方**——静态字段初始值、load() 的异常重置、
    // writeDefault() 写进用户文件的内容、hwDecoderValue() 未知值回退。
    // 任何一处漏改，用户拿到的配置与实际生效的策略就不一致，而日志显示的
    // 是"已加载配置"，不会提示任何异常——又一条静默失效路径。
    // 改默认值只能改这里。
    /** 默认硬解策略：软件解码（最稳，修复崩溃） */
    public static final String DEFAULT_HW_DECODER = "none";
    /** 默认视频输出策略：OpenGL（安全） */
    public static final String DEFAULT_VOUT = "gl,any";
    /** 默认是否打印完整参数对比 */
    public static final boolean DEFAULT_VERBOSE = false;

    /**
     * 软解（默认，最稳定，修复崩溃）。
     *
     * <p><b>必须 volatile</b>：load() 在主线程（mod 构造）里写，而
     * {@code JarToolMixin} 经 {@code PlayerAPI.start() → readArray} 可能在
     * watermedia 的工作线程上读。JLS §17.4.5：两条线程间没有 happens-before
     * 边，写方的值对读方**不保证可见**——媒体线程可能永远读到类初始化时的
     * 旧默认值，用户的自定义配置静默失效。默认值恰好也是安全值（崩溃不会
     * 回来），但 {@code hwDecoder = "any"} 之类的高危自定义可能读不到。
     * 引用写入本身原子，volatile 只补可见性，零运行时成本。</p>
     */
    public static volatile String hwDecoder = DEFAULT_HW_DECODER;
    /** 视频输出：默认去掉 direct3d11 偏好（volatile 理由同 {@link #hwDecoder}） */
    public static volatile String vout = DEFAULT_VOUT;
    /** 是否在日志打印完整参数对比（volatile 理由同 {@link #hwDecoder}） */
    public static volatile boolean verbose = DEFAULT_VERBOSE;

    /**
     * 外部注入的配置目录（Fabric 侧用）。为 null 时回退到 FML 的 CONFIGDIR，
     * 使同一份配置代码在 NeoForge/Forge 与 Fabric 上共用。
     */
    private static volatile Path injectedConfigDir;

    private BiliFixConfig() {}

    /**
     * 注入配置目录（Fabric entrypoint 调用，传 {@code FabricLoader.getInstance().getConfigDir()}）。
     *
     * <p>与 {@code CrashSentinel.setGameDir} 同一思路：Fabric 没有 FML，
     * 直接引用 {@code FMLPaths} 会在运行时抛 {@code NoClassDefFoundError}；
     * 注入后该引用不会被解析（{@code getstatic} 是惰性解析）。</p>
     */
    public static void setConfigDir(Path configDir) {
        injectedConfigDir = configDir;
    }

    public static Path configPath() {
        Path configDir = injectedConfigDir;
        // FML 侧走反射桥：Fabric 的 classpath 上没有 net.neoforged.fml，直接引用会编译失败
        if (configDir == null) configDir = dev.polaris_fix.bilifix.FmlBridge.fmlDir("CONFIGDIR");
        // 最后兜底：注入与 FML 都不可用时退回工作目录，绝不因取不到路径而中断启动
        if (configDir == null) configDir = Path.of("config");
        return configDir.resolve("bilifix.toml");
    }

    /** 加载配置：不存在则生成默认文件 */
    public static synchronized void load() {
        Path path = configPath();
        try {
            if (Files.notExists(path)) {
                writeDefault(path);
                BiliFixMod.LOGGER.info("[BiliFix] 已生成默认配置: {}", path);
            } else {
                Map<String, String> kv = parse(path);
                if (kv.containsKey("hwDecoder")) hwDecoder = kv.get("hwDecoder");
                if (kv.containsKey("vout"))      vout      = kv.get("vout");
                if (kv.containsKey("verbose"))  verbose   = parseBoolean(kv.get("verbose"));
                // 重复键必须可见（v1.4.8 审查发现）：同一个键写两次时后者生效，
                // 但用户改不动配置时无从判断是哪一行在起作用。重复键静默覆盖
                // 与"未知键被静默忽略"是同族缺陷。
                for (String dup : DUPLICATE_KEYS) {
                    BiliFixMod.LOGGER.warn("[BiliFix] 配置里的键 '{}' 重复出现了多次，"
                            + "只有最后一个生效——请删掉多余的行", dup);
                }
                DUPLICATE_KEYS.clear();
                // 未识别的 key 警告：写错的配置必须可见，否则就是又一条静默失效路径
                // （与 UTF-8 BOM 同族——用户写了配置、文件也"加载成功"、但设置没生效，
                // 且日志里没有任何指向原因的线索）。
                for (String k : kv.keySet()) {
                    if (k.equals("hwDecoder") || k.equals("vout") || k.equals("verbose")) continue;
                    // 忽略大小写后能对上已知键 → 多半是大小写写错，给出可直接照做的提示
                    String lower = k.toLowerCase();
                    if (lower.equals("hwdecoder") || lower.equals("vout") || lower.equals("verbose")) {
                        String correct = lower.equals("hwdecoder") ? "hwDecoder"
                                       : lower.equals("vout") ? "vout" : "verbose";
                        BiliFixMod.LOGGER.warn("[BiliFix] 配置键 '{}' 拼写不对（键名区分大小写），"
                                + "应为 '{}'——本次该设置未生效", k, correct);
                    } else {
                        BiliFixMod.LOGGER.warn("[BiliFix] 配置里有未识别的键 '{}'"
                                + "（已知键: hwDecoder / vout / verbose，区分大小写），该设置被忽略", k);
                    }
                }
                // 触发一次校验，让无效值在启动时就发出警告
                hwDecoderValue();
                voutValue();
                verboseValue();
                BiliFixMod.LOGGER.info("[BiliFix] 已加载配置: {}", path);
            }
        } catch (Exception e) {
            // 显式重置为安全默认：日志说"使用默认值"就必须真的重置——
            // 静态字段保留的是上次值（首次加载恰好等于默认，但未来 reload 时会残留用户旧值）。
            // 重置到 DEFAULT_* 常量，不另写一份字面量（v1.4.8：默认值提为单一真源）。
            hwDecoder = DEFAULT_HW_DECODER;
            vout = DEFAULT_VOUT;
            verbose = DEFAULT_VERBOSE;
            BiliFixMod.LOGGER.warn("[BiliFix] 配置加载失败，已重置为默认值（软解）: {}", e.toString());
        }
    }

    /**
     * 解析布尔配置值：只有 {@code true} / {@code false}（忽略大小写）合法。
     *
     * <p><b>为什么要单独一个方法</b>（v1.4.8 审查发现）：旧实现是
     * {@code verbose = "true".equalsIgnoreCase(v)}——除了 true/false 之外的
     * 任何值（{@code "yes"}、{@code "1"}、{@code "on"}、拼错的 {@code "ture"}）
     * 都<b>静默</b>变成 false。而 {@code hwDecoder} 的未知值会警告、
     * {@code vout} 的空值也会警告——三个字段行为不一致，正是
     * {@link #voutValue()} 注释里说的"两个字段行为不一致，早晚会有人踩到"。
     * 用户写 {@code verbose = "yes"} 后看到的是"配置加载成功"，
     * 详细日志没开，却没有任何线索指向原因。</p>
     *
     * <p>非法值一律回退 {@code false}（不打开详细日志 = 安全默认，
     * 少刷屏）并给出警告。</p>
     */
    static boolean parseBoolean(String raw) {
        if (raw == null) return DEFAULT_VERBOSE;
        String v = raw.trim();
        if (v.equalsIgnoreCase("true")) return true;
        if (v.equalsIgnoreCase("false")) return false;
        BiliFixMod.LOGGER.warn("[BiliFix] verbose 配置值 '{}' 不是合法的布尔值"
                + "（只接受 true / false），已回退到 {}", raw, DEFAULT_VERBOSE);
        return DEFAULT_VERBOSE;
    }

    /**
     * verbose 的最终生效值。
     *
     * <p>与 {@link #hwDecoderValue()} / {@link #voutValue()} 对称：无效值在这里
     * 被识别并警告，而不是在解析时静默吞掉。{@code load()} 会调用一次，
     * 让问题在启动时就可见。</p>
     */
    public static boolean verboseValue() {
        return verbose;
    }

    /** hwDecoder 的最终 VLC 参数值："disable" 与 "none" 等价；未知值回退 none 并警告 */
    public static String hwDecoderValue() {
        if (hwDecoder == null) return DEFAULT_HW_DECODER;
        return switch (hwDecoder.toLowerCase().trim()) {
            case "disable", "none", "off" -> "none";
            case "auto", "any" -> "any";
            case "d3d11va" -> "d3d11va";
            case "dxva2" -> "dxva2";
            default -> {
                BiliFixMod.LOGGER.warn("[BiliFix] 未知的 hwDecoder 配置值 '{}'，回退到安全默认 none", hwDecoder);
                yield DEFAULT_HW_DECODER;
            }
        };
    }

    /**
     * vout 的最终 VLC 参数值："original" 表示保留 watermedia 原始值；其他值标准化为小写。
     *
     * <p><b>空值必须回退到安全默认</b>（v1.4.8 修复）：{@code vout = ""}（用户把值
     * 清空了）此前原样返回空串，mixin 会写出 {@code --vout ""}——一个<b>空的视频输出
     * 模块名</b>交给 libVLC。这比崩溃更隐蔽：不崩，只是没有画面，用户会以为是
     * watermedia 或别的 mod 的问题。而 {@link #hwDecoderValue()} 对同样的空值早就
     * 回退到安全默认并警告了——两个字段行为不一致，早晚会有人踩到。
     * 现在空串与纯空白一律回退 {@link #DEFAULT_VOUT} 并给出警告。</p>
     *
     * <p>注意与 {@code null} 的区别：{@code null} 表示"未设置 / 保留原值"
     * （{@code original} 的别名），空串表示"用户设置了但内容为空"——后者是
     * 配置错误，回退；前者是合法语义，保留。</p>
     */
    public static String voutValue() {
        if (vout == null) return null;
        String v = vout.toLowerCase().trim();
        return switch (v) {
            case "original", "keep" -> null; // null → 不替换
            default -> {
                if (v.isEmpty()) {
                    BiliFixMod.LOGGER.warn("[BiliFix] vout 配置为空，已回退到安全默认 {}", DEFAULT_VOUT);
                    yield DEFAULT_VOUT;
                }
                yield v;
            }
        };
    }

    // ---------- 内部：解析与生成 ----------

    static Map<String, String> parse(Path path) throws IOException {
        Map<String, String> kv = new LinkedHashMap<>();
        boolean first = true;
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            String s = line.trim();
            // UTF-8 BOM（U+FEFF）剥离：Windows 上记事本等编辑器默认以 UTF-8+BOM
            // 保存，而 Files.readAllLines 不会去掉它 → 首个 key 变成
            // "\uFEFFhwDecoder"，containsKey("hwDecoder") 为 false，用户的配置
            // **被静默忽略**（且只有第一个键受影响，vout/verbose 照常生效，
            // 更难察觉）。实测：带 BOM → containsKey=false，不带 → true。
            if (first) {
                first = false;
                if (!s.isEmpty() && s.charAt(0) == '\uFEFF') s = s.substring(1).trim();
            }
            if (s.isEmpty() || s.startsWith("#")) continue;
            int eq = s.indexOf('=');
            if (eq <= 0) continue;
            String k = s.substring(0, eq).trim();
            String v = stripValue(s.substring(eq + 1).trim());
            // 重复键检测（v1.4.8）：同一个键出现多次时后者生效（与 TOML 一致），
            // 但静默覆盖会让用户改不动配置时无从判断是哪一行在起作用。
            // 记下来，由 load() 统一警告。
            if (kv.containsKey(k) && !DUPLICATE_KEYS.contains(k)) {
                DUPLICATE_KEYS.add(k);
            }
            kv.put(k, v);
        }
        return kv;
    }

    /**
     * 最近一次 parse() 发现的重复键。
     *
     * <p>用 {@link List} 而不是直接返回给调用方：{@code parse()} 的返回类型
     * 是 {@code Map<String,String>}，塞不进重复信息又不破坏既有签名
     * （{@code ConfigParseProbe} 等探针直接调用它）。</p>
     */
    private static final List<String> DUPLICATE_KEYS = new ArrayList<>();

    /**
     * 提取配置值：支持引号内嵌 '#'、引号后行内注释两种 TOML 常见写法。
     * <ul>
     *   <li>"gl,any" → gl,any（引号包裹，可含 #）</li>
     *   <li>"gl,any" # 说明 → gl,any（引号后跟注释）</li>
     *   <li>true → true（裸值，# 后为注释）</li>
     * </ul>
     */
    static String stripValue(String raw) {
        if (raw.isEmpty()) return raw;
        if (raw.charAt(0) == '"') {
            int end = raw.indexOf('"', 1);
            if (end > 0) return raw.substring(1, end);
            return raw.substring(1); // 未闭合引号：取剩余全部
        }
        int hash = raw.indexOf('#');
        if (hash >= 0) return raw.substring(0, hash).trim();
        return raw;
    }

    static void writeDefault(Path path) throws IOException {
        // 父目录可能尚不存在：全新实例，或 Fabric 侧由 entrypoint 注入的
        // FabricLoader.getConfigDir()。缺目录时 Files.write 抛 NoSuchFileException，
        // 该异常会被 load() 的 catch 吞成一条 warning —— 修复行为本身仍正确（字段
        // 已重置为安全默认），但默认配置文件永远不会落盘，用户也就无从调整。
        // 探针实证：目录缺失时配置创建失败，目录存在时成功（ConfigDirProbe）。
        Path parent = path.getParent();
        if (parent != null) Files.createDirectories(parent);
        List<String> lines = new ArrayList<>();
        lines.add("# BiliFix 配置 —— watermedia/libVLC 崩溃修复");
        lines.add("# 修改后需重启游戏生效。");
        lines.add("");
        lines.add("# 硬解码策略（崩溃根源就在这）：");
        lines.add("#   none    = 软件解码，最稳定（默认，修复崩溃）");
        lines.add("#   any     = VLC 自动选择硬解（可能复现崩溃）");
        lines.add("#   d3d11va = 强制 D3D11VA（高风险）");
        lines.add("#   dxva2   = 强制 DXVA2（高风险）");
        lines.add("hwDecoder = \"" + DEFAULT_HW_DECODER + "\"");
        lines.add("");
        lines.add("# 视频输出模块（vout）：");
        lines.add("#   gl,any    = OpenGL 输出（默认，安全）");
        lines.add("#   original  = 保留 watermedia 原始参数（direct3d11,glwin32,gl,any）");
        lines.add("vout = \"" + DEFAULT_VOUT + "\"");
        lines.add("");
        lines.add("# 日志中打印完整参数替换详情");
        lines.add("verbose = " + DEFAULT_VERBOSE);
        // 原子写：先写临时文件再 ATOMIC_MOVE，磁盘满/中断不会留下半个配置文件
        Path tmp = path.resolveSibling(path.getFileName() + ".tmp");
        Files.write(tmp, lines, StandardCharsets.UTF_8);
        try {
            Files.move(tmp, path, java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        } catch (java.nio.file.AtomicMoveNotSupportedException e) {
            Files.move(tmp, path, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
    }
}
