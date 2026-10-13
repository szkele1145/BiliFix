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

    private BiliFixConfig() {}

    public static Path configPath() {
        Path configDir = net.neoforged.fml.loading.FMLPaths.CONFIGDIR.get();
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
            BiliFixMod.LOGGER.warn("[BiliFix] 配置加载失败，使用默认值（软解）: {}", e.toString());
        }
    }

    /** hwDecoder 的最终 VLC 参数值："disable" 与 "none" 等价；未知值回退 none 并警告 */
    public static String hwDecoderValue() {
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
