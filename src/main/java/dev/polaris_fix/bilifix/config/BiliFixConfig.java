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
    /** 软解（默认，最稳定，修复崩溃） */
    public static String hwDecoder = "none";
    /** 视频输出：默认去掉 direct3d11 偏好 */
    public static String vout = "gl,any";
    /** 是否在日志打印完整参数对比 */
    public static boolean verbose = false;

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
                if (kv.containsKey("verbose"))  verbose   = "true".equalsIgnoreCase(kv.get("verbose"));
                // 触发一次校验，让无效值在启动时就发出警告
                hwDecoderValue();
                voutValue();
                BiliFixMod.LOGGER.info("[BiliFix] 已加载配置: {}", path);
            }
        } catch (Exception e) {
            // 显式重置为安全默认：日志说"使用默认值"就必须真的重置——
            // 静态字段保留的是上次值（首次加载恰好等于默认，但未来 reload 时会残留用户旧值）
            hwDecoder = "none";
            vout = "gl,any";
            verbose = false;
            BiliFixMod.LOGGER.warn("[BiliFix] 配置加载失败，已重置为默认值（软解）: {}", e.toString());
        }
    }

    /** hwDecoder 的最终 VLC 参数值："disable" 与 "none" 等价；未知值回退 none 并警告 */
    public static String hwDecoderValue() {
        if (hwDecoder == null) return "none";
        return switch (hwDecoder.toLowerCase().trim()) {
            case "disable", "none", "off" -> "none";
            case "auto", "any" -> "any";
            case "d3d11va" -> "d3d11va";
            case "dxva2" -> "dxva2";
            default -> {
                BiliFixMod.LOGGER.warn("[BiliFix] 未知的 hwDecoder 配置值 '{}'，回退到安全默认 none", hwDecoder);
                yield "none";
            }
        };
    }

    /** vout 的最终 VLC 参数值："original" 表示保留 watermedia 原始值；其他值标准化为小写 */
    public static String voutValue() {
        if (vout == null) return null;
        String v = vout.toLowerCase().trim();
        return switch (v) {
            case "original", "keep" -> null; // null → 不替换
            default -> v;
        };
    }

    // ---------- 内部：解析与生成 ----------

    static Map<String, String> parse(Path path) throws IOException {
        Map<String, String> kv = new LinkedHashMap<>();
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            String s = line.trim();
            if (s.isEmpty() || s.startsWith("#")) continue;
            int eq = s.indexOf('=');
            if (eq <= 0) continue;
            String k = s.substring(0, eq).trim();
            String v = stripValue(s.substring(eq + 1).trim());
            kv.put(k, v);
        }
        return kv;
    }

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
        List<String> lines = new ArrayList<>();
        lines.add("# BiliFix 配置 —— watermedia/libVLC 崩溃修复");
        lines.add("# 修改后需重启游戏生效。");
        lines.add("");
        lines.add("# 硬解码策略（崩溃根源就在这）：");
        lines.add("#   none    = 软件解码，最稳定（默认，修复崩溃）");
        lines.add("#   any     = VLC 自动选择硬解（可能复现崩溃）");
        lines.add("#   d3d11va = 强制 D3D11VA（高风险）");
        lines.add("#   dxva2   = 强制 DXVA2（高风险）");
        lines.add("hwDecoder = \"none\"");
        lines.add("");
        lines.add("# 视频输出模块（vout）：");
        lines.add("#   gl,any    = OpenGL 输出（默认，安全）");
        lines.add("#   original  = 保留 watermedia 原始参数（direct3d11,glwin32,gl,any）");
        lines.add("vout = \"gl,any\"");
        lines.add("");
        lines.add("# 日志中打印完整参数替换详情");
        lines.add("verbose = false");
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
