import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** BiliFix v1.1.0 回归测试：配置解析 + 参数替换（与 JarToolMixin/BiliFixConfig 相同逻辑） */
public class Regression {
    static int passed = 0, failed = 0;

    public static void main(String[] args) throws Exception {
        // ============ 1. 配置解析 ============
        Path cfg = Files.createTempFile("bilifix", ".toml");
        Files.write(cfg, List.of(
            "# 注释行",
            "hwDecoder = \"d3d11va\"",
            "vout = \"original\"",
            "verbose = true",
            "  # 缩进注释",
            "bad-line-no-equals"
        ), StandardCharsets.UTF_8);
        Map<String,String> kv = parse(cfg);
        check("解析: hwDecoder", "d3d11va".equals(kv.get("hwDecoder")));
        check("解析: vout", "original".equals(kv.get("vout")));
        check("解析: verbose", "true".equals(kv.get("verbose")));
        check("解析: 忽略注释/坏行", kv.size() == 3);

        // ============ 2. 策略映射 ============
        check("策略: none->none", "none".equals(hwValue("none")));
        check("策略: disable->none", "none".equals(hwValue("disable")));
        check("策略: off->none", "none".equals(hwValue("off")));
        check("策略: auto->any", "any".equals(hwValue("auto")));
        check("策略: any->any", "any".equals(hwValue("any")));
        check("策略: 乱码->none(安全回退)", "none".equals(hwValue("garbage!!!")));
        check("策略: NULL->none(安全回退)", "none".equals(hwValue(null)));

        // ============ 3. 参数替换（"--key value" 形式，原始 arguments.json） ============
        String[] original = {
            "--no-quiet", "--cr-average=5000", "--swscale-mode=0",
            "--network-synchronisation", "--network-caching=1000",
            "--live-caching=1000", "--file-caching=1000",
            "--aout", "directsound,waveout,mmdevice",
            "--vout", "direct3d11,glwin32,gl,any",
            "--avcodec-skip-idct=4", "--avcodec-fast",
            "--avcodec-hw", "d3d11va,dxva2,any",
            "--no-metadata-network-access", "--no-file-logging", "--http-reconnect"
        };
        List<String> r1 = fixArgs(original, "none", "gl,any");
        check("替换: --avcodec-hw none 相邻", idx(r1,"--avcodec-hw") >= 0 && "none".equals(r1.get(idx(r1,"--avcodec-hw")+1)));
        check("替换: --vout gl,any 相邻", idx(r1,"--vout") >= 0 && "gl,any".equals(r1.get(idx(r1,"--vout")+1)));
        check("替换: 无 d3d11va 残留", !r1.toString().contains("d3d11va"));
        check("替换: 无 direct3d11 残留", !r1.toString().contains("direct3d11"));
        check("替换: aout 保留", r1.contains("directsound,waveout,mmdevice"));
        check("替换: 缓存参数保留", r1.contains("--network-caching=1000") && r1.contains("--http-reconnect"));
        check("替换: 总项数不变", r1.size() == original.length);

        // ============ 4. 参数替换（"--key=value" 等号形式） ============
        String[] eqForm = {"--no-quiet", "--avcodec-hw=d3d11va,dxva2,any", "--vout=direct3d11,glwin32,gl,any", "--http-reconnect"};
        List<String> r2 = fixArgs(eqForm, "none", "gl,any");
        check("等号: --avcodec-hw=none", r2.contains("--avcodec-hw=none"));
        check("等号: --vout=gl,any", r2.contains("--vout=gl,any"));
        check("等号: 其他保留", r2.contains("--no-quiet") && r2.contains("--http-reconnect"));

        // ============ 5. vout=original 不替换 vout ============
        List<String> r3 = fixArgs(original, "none", null);
        check("original: vout 保留原值", r3.contains("direct3d11,glwin32,gl,any"));
        check("original: hw 仍然替换", idx(r3,"--avcodec-hw") >= 0 && "none".equals(r3.get(idx(r3,"--avcodec-hw")+1)));

        // ============ 6. 混合形式与边界 ============
        String[] mixed = {"--avcodec-hw", "d3d11va", "--vout=direct3d11"};
        List<String> r4 = fixArgs(mixed, "dxva2", "gl,any");
        check("混合: 空格形式 hw", r4.contains("--avcodec-hw") && r4.get(r4.indexOf("--avcodec-hw")+1).equals("dxva2"));
        check("混合: 等号形式 vout", r4.contains("--vout=gl,any"));

        // ============ 7. v1.1.1 防御：参数表缺失时主动补加 ============
        String[] noHw = {"--no-quiet", "--http-reconnect"};
        List<String> r5 = fixArgs(noHw, "none", "gl,any");
        check("防御: 补加 --avcodec-hw none", idx(r5,"--avcodec-hw") >= 0 && "none".equals(r5.get(idx(r5,"--avcodec-hw")+1)));
        check("防御: 补加 --vout gl,any", idx(r5,"--vout") >= 0 && "gl,any".equals(r5.get(idx(r5,"--vout")+1)));
        check("防御: 原参数保留", r5.contains("--no-quiet") && r5.contains("--http-reconnect"));

        // vout=original 且参数表无 vout 时不补加
        List<String> r6 = fixArgs(noHw, "none", null);
        check("防御: vout=original 时不补加 vout", !r6.contains("--vout"));
        check("防御: hw 仍然补加", idx(r6,"--avcodec-hw") >= 0 && "none".equals(r6.get(idx(r6,"--avcodec-hw")+1)));

        // ============ 8. 短选项值边界（isValue 含 - 排除） ============
        String[] shortOpt = {"--avcodec-hw", "-something"};
        List<String> r7 = fixArgs(shortOpt, "none", null);
        check("边界: 以-开头不算值", r7.contains("-something")); // -something 被当作下一个参数保留

        // ============ 9. 配置值解析边界（v1.2.1 stripValue） ============
        check("配置: 引号内含#", "a#b".equals(stripValue("\"a#b\"")));
        check("配置: 引号后行内注释", "gl,any".equals(stripValue("\"gl,any\" # Open GL")));
        check("配置: 裸值#注释", "true".equals(stripValue("true # on")));
        check("配置: 裸值无注释", "false".equals(stripValue("false")));
        check("配置: 未闭合引号", "abc".equals(stripValue("\"abc")));
        check("配置: 空值", "".equals(stripValue("")));

        // ============ 10. 端到端：写默认文件→重读→改值→再读 ============
        Path cfgDir = Files.createTempDirectory("bilifix-e2e");
        Path cfg2 = cfgDir.resolve("bilifix.toml");
        // 模拟 writeDefault 生成
        List<String> def = List.of(
            "# BiliFix 配置",
            "hwDecoder = \"none\"",
            "vout = \"gl,any\"",
            "verbose = false"
        );
        Files.write(cfg2, def, StandardCharsets.UTF_8);
        Map<String,String> kv1 = parse(cfg2);
        check("端到端: 默认值", "none".equals(kv1.get("hwDecoder")) && "gl,any".equals(kv1.get("vout")) && "false".equals(kv1.get("verbose")));
        // 用户手动编辑（带行内注释的典型场景）
        Files.write(cfg2, List.of(
            "hwDecoder = \"d3d11va\" # try hw",
            "vout = \"original\"",
            "verbose = true"
        ), StandardCharsets.UTF_8);
        Map<String,String> kv2 = parse(cfg2);
        check("端到端: 行内注释值", "d3d11va".equals(kv2.get("hwDecoder")));
        check("端到端: original 保留", "original".equals(kv2.get("vout")));
        check("端到端: verbose=true", "true".equals(kv2.get("verbose")));
        // hwDecoderValue/voutValue 对新值的映射
        check("端到端: d3d11va 策略映射", "d3d11va".equals(hwValue(kv2.get("hwDecoder"))));
        check("端到端: vout original 映射 null", (Object) null == voutMap(kv2.get("vout")));
        // 清理
        Files.deleteIfExists(cfg2);

        // ============ 11. CrashSentinel 逻辑同构测试（v1.4.3） ============
        // recordHarden 的事件格式（含/不含 fullArgs）
        String ev1 = sentinelEvent(18, 18, null);
        String ev2 = sentinelEvent(16, 16, "--avcodec-hw none --vout gl,any");
        check("Sentinel: 基本事件", ev1.contains("VLC args hardened: 18 -> 18 items") && ev1.contains("hw=none"));
        check("Sentinel: fullArgs 附加", ev2.contains(" | --avcodec-hw none --vout gl,any"));
        check("Sentinel: 无 fullArgs 时无竖线", !ev1.contains(" | "));
        // 事件环（容量截断）
        check("Sentinel: ev2 独立于 ev1", !ev2.equals(ev1));

        // ============ 12. modLine 版本可用性判定（v1.4.4） ============
        check("modLine: 正常版本可用", verUsable("2.1.36"));
        check("modLine: null 不可用", !verUsable(null));
        check("modLine: 空 不可用", !verUsable(""));
        check("modLine: ${version} 占位符不可用", !verUsable("${version}"));

        // ============ 13. 会话取证：上次异常终止判定（v1.4.7） ============
        // 核心：原生崩溃不执行 shutdown hook，故用"残留 lock"作为硬崩溃指纹。
        Path game = Files.createTempDirectory("bilifix-session");
        Path lock = game.resolve(SESSION_FILE);
        Path snap = game.resolve(DIAGNOSTIC_FILE);

        // (a) 无 lock = 上次干净退出，不打扰用户
        probed = false;
        check("会话: 无 lock 判定为干净", detectUnclean(game) == null);

        // (b) 幂等：同一次启动内重复构造不得把本次刚写的 lock 误判为崩溃
        Files.write(lock, List.of("pid=1234", "version=1.4.7"), StandardCharsets.UTF_8);
        check("会话: 幂等（重复探测不误报）", detectUnclean(game) == null);

        // (c) 模拟下一次启动：残留 lock 存在 → 判定为异常终止
        probed = false;
        String diag = detectUnclean(game);
        check("会话: 残留 lock 判定为异常终止", diag != null);
        check("会话: 诊断含原生崩溃线索", diag != null && diag.contains("原生层崩溃"));
        check("会话: 诊断含排查建议", diag != null && diag.contains("vout"));
        check("会话: 诊断含 lock 路径", diag != null && diag.contains("bilifix-session.lock"));

        // (d) 干净退出流程：写快照 + 清除 lock（顺序：先删 lock 再写快照）
        Files.write(snap, List.of("harden count: 3", "media touched: yes"), StandardCharsets.UTF_8);
        Files.deleteIfExists(lock);
        check("会话: 干净退出后 lock 清除", !Files.exists(lock));
        check("会话: 退出快照保留", Files.exists(snap));
        check("会话: 快照含 media touched",
                Files.readString(snap, StandardCharsets.UTF_8).contains("media touched: yes"));

        // (e) lock 清除后再次启动应判定为干净
        probed = false;
        check("会话: 清除后恢复干净判定", detectUnclean(game) == null);

        // (f) null 目录不得抛异常
        probed = false;
        check("会话: null 目录安全", detectUnclean(null) == null);

        Files.deleteIfExists(snap);
        Files.deleteIfExists(game);

        System.out.println();
        System.out.println("通过 " + passed + " / 失败 " + failed);
        if (failed > 0) System.exit(1);
    }

    // ===== 与 CrashSentinel.recordHarden 相同的事件构造逻辑 =====
    static String sentinelEvent(int originalCount, int newCount, String fullArgs) {
        String event = "VLC args hardened: " + originalCount + " -> " + newCount + " items"
                + " (hw=none)";
        if (fullArgs != null) event += " | " + fullArgs;
        return event;
    }

    // ===== 与 modLine 相同的版本可用性判定 =====
    static boolean verUsable(String ver) {
        return ver != null && !ver.isBlank() && !ver.contains("${");
    }

    // ===== 与 CrashSentinel 相同的会话取证逻辑（v1.4.7） =====
    static final String SESSION_FILE = "bilifix-session.lock";
    static final String DIAGNOSTIC_FILE = "bilifix-diagnostic.txt";
    static boolean probed = false;

    /** 与 CrashSentinel.detectUncleanShutdown 同构：残留 lock = 上次未走退出流程 */
    static String detectUnclean(Path gameDir) {
        if (gameDir == null) return null;
        if (probed) return null;   // 幂等：只判定一次
        probed = true;
        try {
            Path session = gameDir.resolve(SESSION_FILE);
            if (!Files.exists(session)) return null;
            long ageSec = -1;
            try {
                ageSec = Math.max(0, (System.currentTimeMillis()
                        - Files.getLastModifiedTime(session).toMillis()) / 1000L);
            } catch (Throwable ignored) { }
            return "上次游戏会话异常终止（未执行 JVM 退出流程）。\n"
                 + "session lock: " + session + " (存在 " + ageSec + " 秒)\n"
                 + "这种退出方式（无 Java 堆栈 / 退出码 -1）与原生层崩溃一致。\n"
                 + "若你刚播过 B 站视频，请把这份文件和 PCL 的错误报告一起反馈。\n"
                 + "排查建议：确认 bilifix.toml 的 vout = \"gl,any\"、hwDecoder = \"none\"，"
                 + "然后把 vout 改为 \"original\" 对比是否复现。\n";
        } catch (Throwable ignored) {
            return null;
        }
    }

    // ===== 与 JarToolMixin.bilifix$makeArgsSafe 完全一致的逻辑 =====
    static List<String> fixArgs(String[] original, String hw, String vout) {
        List<String> fixed = new ArrayList<>(original.length + 4);
        boolean sawHw = false, sawVout = false;
        for (int i = 0; i < original.length; i++) {
            String arg = original[i];
            switch (arg) {
                case "--avcodec-hw" -> {
                    sawHw = true;
                    fixed.add("--avcodec-hw"); fixed.add(hw);
                    if (i + 1 < original.length && isValue(original[i + 1])) i++;
                }
                case "--vout" -> {
                    sawVout = true;
                    if (vout != null) {
                        fixed.add("--vout"); fixed.add(vout);
                        if (i + 1 < original.length && isValue(original[i + 1])) i++;
                    } else if (i + 1 < original.length && isValue(original[i + 1])) {
                        fixed.add("--vout"); fixed.add(original[i + 1]); i++;
                    } else fixed.add("--vout");
                }
                default -> {
                    if (arg.startsWith("--avcodec-hw=")) { sawHw = true; fixed.add("--avcodec-hw=" + hw); }
                    else if (arg.startsWith("--vout=")) {
                        sawVout = true;
                        if (vout != null) fixed.add("--vout=" + vout);
                        else fixed.add(arg);
                    } else fixed.add(arg);
                }
            }
        }
        if (!sawHw) { fixed.add("--avcodec-hw"); fixed.add(hw); }
        if (vout != null && !sawVout) { fixed.add("--vout"); fixed.add(vout); }
        return fixed;
    }
    static boolean isValue(String s) { return !s.startsWith("-"); }
    static int idx(List<String> l, String k) { return l.indexOf(k); }

    // ===== 与 BiliFixConfig 相同的辅助（v1.2.1+：走 stripValue，与生产代码同步） =====
    static Map<String,String> parse(Path path) throws Exception {
        Map<String,String> kv = new LinkedHashMap<>();
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
    static String hwValue(String s) {
        if (s == null) return "none";
        return switch (s.toLowerCase()) {
            case "disable", "none", "off" -> "none";
            case "auto", "any" -> "any";
            case "d3d11va" -> "d3d11va";
            case "dxva2" -> "dxva2";
            default -> "none";
        };
    }
    static Object voutMap(String s) {
        if (s == null) return null;
        return switch (s.toLowerCase().trim()) {
            case "original", "keep" -> null;
            default -> s.toLowerCase().trim();
        };
    }

    // ===== 与 BiliFixConfig.stripValue 相同逻辑 =====
    static String stripValue(String raw) {
        if (raw.isEmpty()) return raw;
        if (raw.charAt(0) == '"') {
            int end = raw.indexOf('"', 1);
            if (end > 0) return raw.substring(1, end);
            return raw.substring(1);
        }
        int hash = raw.indexOf('#');
        if (hash >= 0) return raw.substring(0, hash).trim();
        return raw;
    }

    static void check(String name, boolean ok) {
        if (ok) { passed++; System.out.println("  [PASS] " + name); }
        else { failed++; System.out.println("  [FAIL] " + name); }
    }
}
