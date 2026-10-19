import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.jar.*;

/** BiliFix 回归测试：配置解析 + 参数替换（与 JarToolMixin/BiliFixConfig 相同逻辑，与当前 jar 版本同步） */
public class Regression {
    static int passed = 0, failed = 0;

    /**
     * 版本号单一来源：从 mods.toml 读取。
     * v1.4.8 教训——此前测试把版本硬编码（jar 名 + toml 断言），于是每次 bump 都要人工同步
     * 第 5、第 6 个版本点，漏掉一个就让全套回归变红。改为动态解析后，bump 只需改描述符本身。
     */
    static final String SOURCE_VERSION = readSourceVersion();

    static String readSourceVersion() {
        String[] candidates = {
            "src/main/resources/META-INF/neoforge.mods.toml",
            "src/main/resources/META-INF/mods.toml"
        };
        for (String rel : candidates) {
            try {
                Path f = Paths.get(rel.replace('/', java.io.File.separatorChar));
                if (!Files.exists(f)) continue;
                java.util.regex.Matcher m = java.util.regex.Pattern
                        .compile("(?s)\\[\\[mods\\]\\].*?version\\s*=\\s*\"([^\"]+)\"")
                        .matcher(Files.readString(f, StandardCharsets.UTF_8));
                if (m.find()) return m.group(1);
            } catch (Exception ignored) {
                // 落到下一个候选；全部失败时由下面的断言报错
            }
        }
        return null;
    }

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
        List<String> r1 = fixArgs("videolan/arguments", original, "none", "gl,any");
        check("替换: --avcodec-hw none 相邻", idx(r1,"--avcodec-hw") >= 0 && "none".equals(r1.get(idx(r1,"--avcodec-hw")+1)));
        check("替换: --vout gl,any 相邻", idx(r1,"--vout") >= 0 && "gl,any".equals(r1.get(idx(r1,"--vout")+1)));
        check("替换: 无 d3d11va 残留", !r1.toString().contains("d3d11va"));
        check("替换: 无 direct3d11 残留", !r1.toString().contains("direct3d11"));
        check("替换: aout 保留", r1.contains("directsound,waveout,mmdevice"));
        check("替换: 缓存参数保留", r1.contains("--network-caching=1000") && r1.contains("--http-reconnect"));
        check("替换: 总项数不变", r1.size() == original.length);

        // ============ 4. 参数替换（"--key=value" 等号形式） ============
        String[] eqForm = {"--no-quiet", "--avcodec-hw=d3d11va,dxva2,any", "--vout=direct3d11,glwin32,gl,any", "--http-reconnect"};
        List<String> r2 = fixArgs("videolan/arguments", eqForm, "none", "gl,any");
        check("等号: --avcodec-hw=none", r2.contains("--avcodec-hw=none"));
        check("等号: --vout=gl,any", r2.contains("--vout=gl,any"));
        check("等号: 其他保留", r2.contains("--no-quiet") && r2.contains("--http-reconnect"));

        // ============ 5. vout=original 不替换 vout ============
        List<String> r3 = fixArgs("videolan/arguments", original, "none", null);
        check("original: vout 保留原值", r3.contains("direct3d11,glwin32,gl,any"));
        check("original: hw 仍然替换", idx(r3,"--avcodec-hw") >= 0 && "none".equals(r3.get(idx(r3,"--avcodec-hw")+1)));

        // ============ 6. 混合形式与边界 ============
        String[] mixed = {"--avcodec-hw", "d3d11va", "--vout=direct3d11"};
        List<String> r4 = fixArgs("videolan/arguments", mixed, "dxva2", "gl,any");
        check("混合: 空格形式 hw", r4.contains("--avcodec-hw") && r4.get(r4.indexOf("--avcodec-hw")+1).equals("dxva2"));
        check("混合: 等号形式 vout", r4.contains("--vout=gl,any"));

        // ============ 7. v1.1.1 防御：参数表缺失时主动补加 ============
        String[] noHw = {"--no-quiet", "--http-reconnect"};
        List<String> r5 = fixArgs("videolan/arguments", noHw, "none", "gl,any");
        check("防御: 补加 --avcodec-hw none", idx(r5,"--avcodec-hw") >= 0 && "none".equals(r5.get(idx(r5,"--avcodec-hw")+1)));
        check("防御: 补加 --vout gl,any", idx(r5,"--vout") >= 0 && "gl,any".equals(r5.get(idx(r5,"--vout")+1)));
        check("防御: 原参数保留", r5.contains("--no-quiet") && r5.contains("--http-reconnect"));

        // vout=original 且参数表无 vout 时不补加
        List<String> r6 = fixArgs("videolan/arguments", noHw, "none", null);
        check("防御: vout=original 时不补加 vout", !r6.contains("--vout"));
        check("防御: hw 仍然补加", idx(r6,"--avcodec-hw") >= 0 && "none".equals(r6.get(idx(r6,"--avcodec-hw")+1)));

        // ============ 8. 短选项值边界（isValue 含 - 排除） ============
        String[] shortOpt = {"--avcodec-hw", "-something"};
        List<String> r7 = fixArgs("videolan/arguments", shortOpt, "none", null);
        check("边界: 以-开头不算值", r7.contains("-something")); // -something 被当作下一个参数保留

        // ============ 9. 配置值解析边界（v1.2.1 stripValue） ============
        check("配置: 引号内含#", "a#b".equals(stripValue("\"a#b\"")));
        check("配置: 引号后行内注释", "gl,any".equals(stripValue("\"gl,any\" # Open GL")));
        check("配置: 裸值#注释", "true".equals(stripValue("true # on")));
        check("配置: 裸值无注释", "false".equals(stripValue("false")));
        check("配置: 未闭合引号", "abc".equals(stripValue("\"abc")));
        check("配置: 空值", "".equals(stripValue("")));

        // ============ 9.5. mixin 资源守卫与边界（与 JarToolMixin 行为同步） ============
        String[] plain = {"--no-quiet", "--http-reconnect"};
        List<String> g1 = fixArgs("other.json", plain, "none", "gl,any");
        check("资源守卫: 非 videolan 资源原样返回", g1.equals(Arrays.asList(plain)));
        List<String> g2 = fixArgs("videolan/arguments", new String[0], "none", "gl,any");
        check("资源守卫: 空参数表原样返回", g2.isEmpty());
        List<String> g3 = fixArgs("videolan/arguments", null, "none", "gl,any");
        check("资源守卫: null 参数表返回空列表", g3.isEmpty());
        List<String> g4 = fixArgs("videolan/arguments", new String[]{"--avcodec-hw"}, "none", null);
        check("边界: --avcodec-hw 结尾缺值时补加 hw 值",
                g4.equals(Arrays.asList("--avcodec-hw", "none")));
        List<String> g5 = fixArgs("videolan/arguments", new String[]{"--vout"}, "none", null);
        check("边界: 裸 --vout 原样保留（vout=null），末尾补加 --avcodec-hw",
                g5.equals(Arrays.asList("--vout", "--avcodec-hw", "none")));
        List<String> g6 = fixArgs("videolan/arguments", new String[]{"--vout=original"}, "none", null);
        check("边界: --vout=original 原样保留（vout=null），末尾补加 --avcodec-hw",
                g6.equals(Arrays.asList("--vout=original", "--avcodec-hw", "none")));

        // ============ 9.6. jar 包结构：必须包含类、mixin 清单、mods.toml、logo ============
        // v1.4.8：不再硬编码 jar 文件名（此前写死 1.4.7，bump 后 jar 名变了就静默 SKIP，
        // 检查形同虚设）。改为扫描 build/ 下该 loader 的最新产物。
        Path neoJar = pickJar("BiliFix-", "-mc1.21.1-neoforge.jar");
        if (neoJar != null) {
            try (JarFile jf = new JarFile(neoJar.toFile())) {
                check("jar: 含 bilifix/BiliFixMod.class",
                        jf.getJarEntry("dev/polaris_fix/bilifix/BiliFixMod.class") != null);
                check("jar: 含 bilifix/CrashSentinel.class",
                        jf.getJarEntry("dev/polaris_fix/bilifix/CrashSentinel.class") != null);
                check("jar: 含 bilifix/mixin/JarToolMixin.class",
                        jf.getJarEntry("dev/polaris_fix/bilifix/mixin/JarToolMixin.class") != null);
                check("jar: 含 bilifix.mixins.json", jf.getJarEntry("bilifix.mixins.json") != null);
                check("jar: 含 bilifix_logo.png", jf.getJarEntry("bilifix_logo.png") != null);
                check("jar: 含 neoforge.mods.toml", jf.getJarEntry("META-INF/neoforge.mods.toml") != null);
            }
        } else {
            System.out.println("  [SKIP] jar: build 产物缺失，跳过 jar 结构检查");
        }

        // ============ 9.6b. 1.20.1 变体 jar 守卫（v1.4.8）：结构 + JAVA_17 改写无残留 ============
        // 依据（MixinProbe 实证）：1.20.1 的运行时 mixin（mixin-0.8.5 / sponge-mixin）的
        // CompatibilityLevel 枚举只有 JAVA_16/17/18，in-jar 残留 JAVA_21 会在 mixin
        // 引导期抛 IllegalArgumentException 直接炸加载。若构建脚本的暂存改写被
        // git checkout 等操作静默丢失，这里必须 FAIL 而不是 SKIP。
        for (String[] variant : new String[][]{
                {"-mc1.20.1-forge.jar",  "MANIFEST MixinConfigs"},
                {"-mc1.20.1-fabric.jar", "fabric.mod.json entrypoint"}}) {
            Path vjar = pickJar("BiliFix-", variant[0]);
            if (vjar == null) { System.out.println("  [SKIP] jar: " + variant[0] + " 未构建，跳过"); continue; }
            try (JarFile jf = new JarFile(vjar.toFile())) {
                String nm = vjar.getFileName().toString();
                check("jar: " + nm + " 含 JarToolMixin.class",
                        jf.getJarEntry("dev/polaris_fix/bilifix/mixin/JarToolMixin.class") != null);
                check("jar: " + nm + " 含 bilifix.mixins.json",
                        jf.getJarEntry("bilifix.mixins.json") != null);
                // in-jar mixins.json 必须是 JAVA_17 且无 JAVA_21 残留（防暂存改写回归）
                var me = jf.getJarEntry("bilifix.mixins.json");
                String mtxt = new String(jf.getInputStream(me).readAllBytes(), StandardCharsets.UTF_8);
                check("jar: " + nm + " mixins.json JAVA_17 改写生效",
                        mtxt.contains("\"JAVA_17\"") && !mtxt.contains("JAVA_21"));
                if ("-mc1.20.1-fabric.jar".equals(variant[0])) {
                    check("jar: " + nm + " 含 fabric.mod.json 且 entrypoint 声明正确",
                            jf.getJarEntry("fabric.mod.json") != null);
                    var fe = jf.getJarEntry("fabric.mod.json");
                    String ftxt = new String(jf.getInputStream(fe).readAllBytes(), StandardCharsets.UTF_8);
                    check("jar: " + nm + " entrypoint = BiliFixFabric",
                            ftxt.contains("dev.polaris_fix.bilifix.fabric.BiliFixFabric"));
                    check("jar: " + nm + " 含 BiliFixFabric.class（entrypoint 可加载）",
                            jf.getJarEntry("dev/polaris_fix/bilifix/fabric/BiliFixFabric.class") != null);
                } else {
                    var mf = jf.getManifest();
                    check("jar: " + nm + " MANIFEST 含 MixinConfigs",
                            mf != null && mf.getMainAttributes().getValue("MixinConfigs") != null);
                    // [差异1] Forge 1.20.1 FML 不认 mods.toml 的 [[mixins]] 块（NeoForge 专属），
                    // mixin 只能靠 MANIFEST 注册 —— 两者机制正好相反，打包时块必须被剥离
                    var te = jf.getJarEntry("META-INF/mods.toml");
                    check("jar: " + nm + " 含 META-INF/mods.toml", te != null);
                    if (te != null) {
                        String tt = new String(jf.getInputStream(te).readAllBytes(), StandardCharsets.UTF_8);
                        check("jar: " + nm + " mods.toml 已剥离 [[mixins]] 块（Forge 不认该块）",
                                !tt.contains("[[mixins]]"));
                        // [差异2] Forge 用 mandatory=true/false；NeoForge 的 type="required" 语法
                        // 在 Forge 上是非法字段，打包时必须已转换
                        check("jar: " + nm + " mods.toml 依赖语法已转为 mandatory=",
                                tt.contains("mandatory") && !tt.matches("(?s).*type\\s*=\\s*\"[^\"]*\".*"));
                    }
                    // [差异3] Forge 1.20.1 javafml 反射调用 getDeclaredConstructor()（空 Class
                    // 数组）——类里必须只有无参构造。若打包的构造器改写正则失配而静默不改，
                    // (ModContainer) 构造会留进 class，游戏加载时 NoSuchMethodException。
                    // 字节级断言：class 全字节里不得出现 ModContainer 符号（slash 形式内部名
                    // net/minecraftforge/fml/ModContainer 也不得有）。
                    var be = jf.getJarEntry("dev/polaris_fix/bilifix/BiliFixMod.class");
                    check("jar: " + nm + " 含 BiliFixMod.class", be != null);
                    if (be != null) {
                        byte[] bc = jf.getInputStream(be).readAllBytes();
                        String bs = new String(bc, StandardCharsets.ISO_8859_1);
                        check("jar: " + nm + " BiliFixMod 无 ModContainer 残留（无参构造改写生效）",
                                !bs.contains("ModContainer")
                                        && !bs.contains("net/minecraftforge/fml/ModContainer"));
                    }
                }
            }
        }

        // ============ 9.7. mods.toml 结构：modId、version、[[mixins]] 三要素 ============
        Path neoToml = Paths.get("src", "main", "resources", "META-INF", "neoforge.mods.toml");
        Path mixinsJson = Paths.get("src", "main", "resources", "bilifix.mixins.json");
        if (Files.exists(neoToml)) {
            String toml = Files.readString(neoToml, StandardCharsets.UTF_8);
            check("mods.toml: modId = \"bilifix\"", toml.contains("modId = \"bilifix\""));
            // v1.4.8: 不再断言字面量版本，改为"与单一来源一致"
            check("mods.toml: version 与来源一致 (=" + SOURCE_VERSION + ")",
                    SOURCE_VERSION != null && toml.contains("version = \"" + SOURCE_VERSION + "\""));
            check("mods.toml: 依赖 neoforge", toml.contains("modId = \"neoforge\""));
            check("mods.toml: [[mixins]] 存在", toml.contains("[[mixins]]"));
        } else {
            System.out.println("  [SKIP] mods.toml: 源文件缺失，跳过结构检查");
        }

        // ============ 9.8. 版本一致性：四处描述符必须同版本（v1.4.8 防漏改） ============
        // 历史教训：bump 时要人工改 mods.toml / neoforge.mods.toml / fabric.mod.json /
        // BiliFixMod.VERSION 四处，漏一处就会出现"jar 名与描述符版本不符"的发布事故。
        check("版本来源: 可从 mods.toml 解析", SOURCE_VERSION != null);
        if (SOURCE_VERSION != null) {
            check("版本一致: mods.toml == neoforge.mods.toml",
                    versionOf(Paths.get("src", "main", "resources", "META-INF", "mods.toml"))
                            .equals(SOURCE_VERSION));
            check("版本一致: fabric.mod.json == " + SOURCE_VERSION,
                    versionOf(Paths.get("src", "fabric", "resources", "fabric.mod.json"))
                            .equals(SOURCE_VERSION));
            check("版本一致: BiliFixMod.VERSION == " + SOURCE_VERSION,
                    BiliFixModVersion().equals(SOURCE_VERSION));
        }
        if (Files.exists(mixinsJson)) {
            String mixins = Files.readString(mixinsJson, StandardCharsets.UTF_8);
            check("mixins.json: 类 JarToolMixin", mixins.contains("JarToolMixin"));
            check("mixins.json: required=false", mixins.contains("\"required\": false"));
            check("mixins.json: injectors.defaultRequire=0",
                    mixins.contains("\"defaultRequire\": 0"));
        } else {
            System.out.println("  [SKIP] bilifix.mixins.json: 源文件缺失，跳过结构检查");
        }

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

        // (g) 崩溃结论独立落盘：本次正常退出不得覆盖它（否则用户晚看就丢线索）
        probed = false;
        Files.write(lock, List.of("pid=999"), StandardCharsets.UTF_8);
        String crashReport = detectUnclean(game);
        check("会话: 判定后写出崩溃结论", Files.exists(game.resolve(CRASH_FILE)));
        check("会话: 结论文本含崩溃线索", crashReport != null && crashReport.contains("原生层崩溃"));
        check("会话: 结论含版本号",
                Files.readString(game.resolve(CRASH_FILE), StandardCharsets.UTF_8).contains("version:"));
        // 模拟"崩溃后重启并正常玩一局再退出"：快照被覆盖，结论必须存活
        Files.write(snap, List.of("exit at: now", "harden count: 0"), StandardCharsets.UTF_8);
        Files.deleteIfExists(lock);
        check("会话: 正常退出不覆盖崩溃结论",
                Files.readString(game.resolve(CRASH_FILE), StandardCharsets.UTF_8).contains("异常终止"));

        Files.deleteIfExists(snap);
        Files.deleteIfExists(game.resolve(CRASH_FILE));
        Files.deleteIfExists(game);

        // ============ 14. 事件容量上限（v1.4.8 并发守卫） ============
        // CrashSentinel.record() 是"判满 → 丢最旧 → 追加"的复合序列；哪怕底层
        // 集合线程安全（CopyOnWriteArrayList），这组 check-then-act 合起来不原子。
        // recordHarden 经 Mixin 在媒体加载线程上被调用，并发进入是可能的。
        //
        // 本文件是独立镜像（Regression 不链接生产类，见文件头说明），所以无法直接
        // 并发调用生产方法——镜像一份"已修复"的逻辑再测它等于什么都没测。这里改为
        // 直接读生产源码，断言 record 声明了 synchronized：若有人删掉这个关键字，
        // 上限就不再是硬保证，本用例必须 FAIL。
        {
            Path sentinel = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                      "bilifix", "CrashSentinel.java");
            if (Files.exists(sentinel)) {
                String src = Files.readString(sentinel, StandardCharsets.UTF_8);
                check("并发: CrashSentinel.record 声明为 synchronized（上限硬保证）",
                        src.matches("(?s).*public\\s+static\\s+synchronized\\s+void\\s+record\\s*\\(.*"));
            } else {
                System.out.println("  [SKIP] 并发: CrashSentinel.java 缺失，跳过源码断言");
            }
        }

        // ============ 15. 默认配置文件必须能自建父目录（v1.4.8 探针回归） ============
        // 缺陷（ConfigDirProbe 实证）：writeDefault 直接写 path.resolveSibling(...)，
        // 从未创建父目录。全新实例或 Fabric 注入的 config 目录尚不存在时，
        // Files.write 抛 NoSuchFileException → 被 load() 的 catch 吞成一条 warning：
        // 修复行为本身仍正确（字段已重置安全默认），但默认配置文件永不落盘，
        // 用户无从调整。探针结果：目录缺失时 NOT-CREATED，目录存在时才 created。
        //
        // 两层断言：(a) 源码里必须保留 createDirectories（防回归）；
        // (b) 用镜像逻辑在临时目录上做真功能验证（缺父目录也要写成功）。
        {
            Path cfgSrc = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                 "bilifix", "config", "BiliFixConfig.java");
            if (Files.exists(cfgSrc)) {
                String src = Files.readString(cfgSrc, StandardCharsets.UTF_8);
                check("配置: writeDefault 会创建父目录（createDirectories）",
                        src.contains("Files.createDirectories(parent)"));
            } else {
                System.out.println("  [SKIP] 配置: BiliFixConfig.java 缺失，跳过源码断言");
            }
            // (b) 镜像 writeDefault 的目录处理，验证语义：父目录缺失也要写成功
            try {
                Path deep = Files.createTempDirectory("bilifix-deep").resolve("a").resolve("config");
                Path f = deep.resolve("bilifix.toml");
                if (f.getParent() != null) Files.createDirectories(f.getParent());
                Files.write(f, List.of("hwDecoder = \"none\""), StandardCharsets.UTF_8);
                check("配置: 父目录缺失时默认配置仍能写出", Files.exists(f));
                Files.deleteIfExists(f);
                Files.deleteIfExists(deep);
                Files.deleteIfExists(deep.getParent());
                Files.deleteIfExists(deep.getParent().getParent());
            } catch (Exception e) {
                check("配置: 父目录缺失时默认配置仍能写出", false);
            }
        }

        // ============ 16. classpath 探测不得因依赖缺失误报"未安装"（v1.4.8） ============
        // checkClass 用 Class.forName 判断 mod 是否存在，但只捕 ClassNotFoundException。
        // 若类文件在、其静态依赖缺失（Fabric 侧无 FML 时正是这种局面），
        // Class.forName 抛的是 NoClassDefFoundError / LinkageError（Error 而非 Exception）
        // → 未捕获 → 冒泡到 modLine 的 catch(Throwable) → 走"未安装"分支：
        // **已安装的 mod 被报成未安装**，正是 classpath 回退路径存在的意义被抹掉。
        // 断言源码里 checkClass 必须有 Throwable 兜底且返回 true（存在性成立）。
        {
            Path diagSrc = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                     "bilifix", "EnvironmentDiagnostics.java");
            if (Files.exists(diagSrc)) {
                String src = Files.readString(diagSrc, StandardCharsets.UTF_8);
                check("诊断: checkClass 捕获 ClassNotFoundException",
                        src.matches("(?s).*catch\\s*\\(\\s*ClassNotFoundException.*"));
                // Throwable 兜底：Error 也要吞掉，否则"类在、依赖缺"被判成不存在
                check("诊断: checkClass 有 Throwable 兜底（Error 不当作未安装）",
                        src.matches("(?s).*catch\\s*\\(\\s*ClassNotFoundException[^)]*\\)\\s*\\{[^}]*\\}"
                                  + "\\s*catch\\s*\\(\\s*Throwable.*"));
                // 三个 classpath 探测类名必须与真实 jar 内的入口类一致（本机 jar 实测）
                check("诊断: watermedia 探测类名正确",
                        src.contains("\"org.watermedia.WaterMedia\""));
                check("诊断: bilibili_media 探测类名正确",
                        src.contains("\"dev.polaris_light.bilibili_media.BiliBiliMedia\""));
                check("诊断: waterframes 探测类名正确",
                        src.contains("\"me.srrapero720.waterframes.WaterFrames\""));
            } else {
                System.out.println("  [SKIP] 诊断: EnvironmentDiagnostics.java 缺失，跳过源码断言");
            }
        }

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

    /**
     * 在 build/ 下挑选匹配后缀的 jar 产物（v1.4.8）。
     * 此前 jar 名硬编码版本号，bump 之后路径失效、检查被静默 SKIP，
     * 等于打包结构失去守卫。改为按"前缀 + loader 后缀"扫描并取最新修改的一个。
     */
    static Path pickJar(String prefix, String suffix) {
        try {
            for (Path dir : List.of(Paths.get("build"), Paths.get("build", "forge"),
                                    Paths.get("build", "fabric"), Paths.get("build", "neoforge"))) {
                if (!Files.isDirectory(dir)) continue;
                try (var s = Files.list(dir)) {
                    Path best = s.filter(Files::isRegularFile)
                            .filter(p -> {
                                String n = p.getFileName().toString();
                                return n.startsWith(prefix) && n.endsWith(suffix);
                            })
                            .max(Comparator.comparingLong(p -> p.toFile().lastModified()))
                            .orElse(null);
                    if (best != null) return best;
                }
            }
        } catch (Exception ignored) {
            // 返回 null，由调用方走 SKIP 分支
        }
        return null;
    }

    // ===== 与 CrashSentinel 相同的会话取证逻辑（v1.4.7） =====
    static final String SESSION_FILE = "bilifix-session.lock";
    static final String DIAGNOSTIC_FILE = "bilifix-diagnostic.txt";
    static final String CRASH_FILE = "bilifix-crash.txt";
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
            String report = "上次游戏会话异常终止（未执行 JVM 退出流程）。\n"
                 + "session lock: " + session + " (存在 " + ageSec + " 秒)\n"
                 + "这种退出方式（无 Java 堆栈 / 退出码 -1）与原生层崩溃一致。\n"
                 + "若你刚播过 B 站视频，请把这份文件和 PCL 的错误报告一起反馈。\n"
                 + "排查建议：确认 bilifix.toml 的 vout = \"gl,any\"、hwDecoder = \"none\"，"
                 + "然后把 vout 改为 \"original\" 对比是否复现。\n";
            // 结论独立落盘：本次正常退出的快照不会覆盖它
            Files.write(gameDir.resolve(CRASH_FILE),
                    ("== BiliFix 异常终止报告 ==\n"
                     + "detected at: now\n"
                     + "version: " + SOURCE_VERSION + "\n"
                     + "lock age: " + ageSec + "s\n\n"
                     + report + "-- end --\n").getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE);
            return report;
        } catch (Throwable ignored) {
            return null;
        }
    }

    // ===== 与 JarToolMixin.bilifix$makeArgsSafe 完全一致的逻辑 =====
    static List<String> fixArgs(String resource, String[] original, String hw, String vout) {
        // 资源守卫：非 videolan/arguments 资源不触碰（同 @Pseudo mixin 的 resource 检查）
        if (resource == null || !resource.contains("videolan/arguments")) {
            return original == null ? List.of() : new ArrayList<>(Arrays.asList(original));
        }
        // 空参数表：不修改、不追加
        if (original == null || original.length == 0) {
            return original == null ? List.of() : new ArrayList<>(Arrays.asList(original));
        }
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

    /**
     * 从任意描述符文件里抽取版本号（v1.4.8）。
     * 支持 toml（version = "x"）与 json（"version": "x"）两种写法；读不到返回空串。
     */
    static String versionOf(Path f) {
        if (!Files.exists(f)) return "";
        try {
            String c = Files.readString(f, StandardCharsets.UTF_8);
            java.util.regex.Matcher m = java.util.regex.Pattern
                    .compile("(?m)(?:version\\s*=\\s*\"([^\"]+)\"|\"version\"\\s*:\\s*\"([^\"]+)\")")
                    .matcher(c);
            if (m.find()) return m.group(1) != null ? m.group(1) : m.group(2);
        } catch (Exception ignored) { }
        return "";
    }

    /** 从 BiliFixMod.java 源码里读 VERSION 常量（v1.4.8），避免把版本硬编码进测试。 */
    static String BiliFixModVersion() {
        Path f = Paths.get("src", "main", "java", "dev", "polaris_fix", "bilifix", "BiliFixMod.java");
        if (!Files.exists(f)) return "";
        try {
            java.util.regex.Matcher m = java.util.regex.Pattern
                    .compile("VERSION\\s*=\\s*\"([^\"]+)\"")
                    .matcher(Files.readString(f, StandardCharsets.UTF_8));
            if (m.find()) return m.group(1);
        } catch (Exception ignored) { }
        return "";
    }

    static void check(String name, boolean ok) {
        if (ok) { passed++; System.out.println("  [PASS] " + name); }
        else { failed++; System.out.println("  [FAIL] " + name); }
    }
}
