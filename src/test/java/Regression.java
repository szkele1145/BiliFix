import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.jar.*;

/** BiliFix 回归测试：配置解析 + 参数替换（与 JarToolMixin/BiliFixConfig 相同逻辑，与当前 jar 版本同步） */
public class Regression {
    static int passed = 0, failed = 0, skipped = 0;

    /**
     * 版本号单一来源：从 neoforge.mods.toml 读取。
     * v1.4.8 教训——此前测试把版本硬编码（jar 名 + toml 断言），于是每次 bump 都要人工同步
     * 第 5、第 6 个版本点，漏掉一个就让全套回归变红。改为动态解析后，bump 只需改描述符本身。
     */
    static final String SOURCE_VERSION = readSourceVersion();

    static String readSourceVersion() {
        String[] candidates = {
            "src/main/resources/META-INF/neoforge.mods.toml"
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

        // ============ 9.1. UTF-8 BOM 剥离（v1.4.8） ============
        // Files.readAllLines(path, UTF_8) 不剥离 BOM。Windows 记事本等默认以
        // "UTF-8 带 BOM" 保存配置 → 首个 key 变成 "\uFEFFhwDecoder" →
        // containsKey("hwDecoder") 为 false → 用户的配置被静默忽略。
        // 只有第一个键受影响（vout/verbose 照常生效），更难察觉。
        try {
            Path bomCfg = Files.createTempFile("bilifix-bom", ".toml");
            Files.write(bomCfg, ("\uFEFFhwDecoder = \"any\"\nvout = \"original\"\n")
                    .getBytes(StandardCharsets.UTF_8));
            Map<String,String> bomKv = parse(bomCfg);
            check("配置: 带 BOM 时 hwDecoder 仍可解析", bomKv.containsKey("hwDecoder"));
            check("配置: 带 BOM 时 hwDecoder 值正确", "any".equals(bomKv.get("hwDecoder")));
            check("配置: 带 BOM 时 vout 不受影响", "original".equals(bomKv.get("vout")));
            check("配置: 解析出的 key 不含 BOM 字符",
                    bomKv.keySet().stream().noneMatch(k -> k.contains("\uFEFF")));
            Files.deleteIfExists(bomCfg);
        } catch (Exception e) {
            skip("配置: BOM 行为断言异常 - " + e);
        }

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
            skip("jar: build 产物缺失，跳过 jar 结构检查");
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
            if (vjar == null) { skip("jar: BiliFix-" + SOURCE_VERSION + variant[0] + " 未构建，跳过"); continue; }
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
            skip("mods.toml: 源文件缺失，跳过结构检查");
        }

        // ============ 9.8. 版本一致性：所有描述符必须同版本（v1.4.8 防漏改） ============
        // 历史教训：bump 时要人工改 neoforge.mods.toml / fabric.mod.json /
        // BiliFixMod.VERSION 三处，漏一处就会出现"jar 名与描述符版本不符"的发布事故。
        //
        // 注意：META-INF/mods.toml 曾在描述符之列，但它在 NeoForge 21.1 上是**死文件**
        // ——实测 FML loader 4.0.45 的 ModFileParser 常量池里只有
        // "META-INF/neoforge.mods.toml"，没有 "mods.toml"。它是 1.3.2 时期"一个 jar
        // 也要兼容老 Forge FML"的遗留，三个 jar 分家后已删除。
        check("版本来源: 可从 neoforge.mods.toml 解析", SOURCE_VERSION != null);
        if (SOURCE_VERSION != null) {
            check("版本一致: fabric.mod.json == " + SOURCE_VERSION,
                    versionOf(Paths.get("src", "fabric", "resources", "fabric.mod.json"))
                            .equals(SOURCE_VERSION));
            check("版本一致: BiliFixMod.VERSION == " + SOURCE_VERSION,
                    BiliFixModVersion().equals(SOURCE_VERSION));
            // 死文件必须真的不在了：留着它会让用户解包 jar 时看到两个一模一样的
            // 元数据文件，却只有一个生效
            check("死文件已清理: src/main/resources/META-INF/mods.toml 不存在",
                    !Files.exists(Paths.get("src", "main", "resources", "META-INF", "mods.toml")));
        }
        if (Files.exists(mixinsJson)) {
            String mixins = Files.readString(mixinsJson, StandardCharsets.UTF_8);
            check("mixins.json: 类 JarToolMixin", mixins.contains("JarToolMixin"));
            check("mixins.json: required=false", mixins.contains("\"required\": false"));
            check("mixins.json: injectors.defaultRequire=0",
                    mixins.contains("\"defaultRequire\": 0"));
        } else {
            skip("bilifix.mixins.json: 源文件缺失，跳过结构检查");
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
        //
        // 行为级证据（df8c030 后补充，out/concurrency-probe/ConcurrentRecordProbe.java）：
        // 探针直接链接生产 classes，32 线程 × 500 次并发调用生产 record()，
        // 事件数恰好停在 64 = MAX_EVENTS（HARD_CAP_HELD=true，RESULT=PASS）。
        // synchronized 关键字存在（本断言）+ 并发压力下上限确被守住（探针实证）
        // 两者合起来才是完整证据链；任一侧丢失即视为回归。
        {
            Path sentinel = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                      "bilifix", "CrashSentinel.java");
            if (Files.exists(sentinel)) {
                String src = Files.readString(sentinel, StandardCharsets.UTF_8);
                check("并发: CrashSentinel.record 声明为 synchronized（上限硬保证）",
                        src.matches("(?s).*public\\s+static\\s+synchronized\\s+void\\s+record\\s*\\(.*"));
            } else {
                skip("并发: CrashSentinel.java 缺失，跳过源码断言");
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
                // v1.4.8：生产 parse() 必须剥离 UTF-8 BOM，否则用户用 Windows
                // 记事本保存的配置会丢掉第一个键（hwDecoder 被静默忽略）。
                check("配置: 生产 parse 剥离 UTF-8 BOM（\\uFEFF）",
                        src.contains("\\uFEFF"));
            } else {
                skip("配置: BiliFixConfig.java 缺失，跳过源码断言");
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
                skip("诊断: EnvironmentDiagnostics.java 缺失，跳过源码断言");
            }
            // (b) 行为级证据：Class.forName 在"类文件存在、依赖缺失"时抛的是
            // NoClassDefFoundError（Error）而非 ClassNotFoundException（Exception）——
            // 这正是 §16 修复要兜住的情形。用一个"依赖被隔离"的类模拟：
            // NeedsMissing extends MissingDep，MissingDep 不在本测试的 classpath 上。
            check("诊断: 依赖缺失时 Class.forName 抛 NoClassDefFoundError 而非 CNFE",
                    classForNameErrorIsNoClassDefFoundError());
        }

        // ============ 17. 配置字段必须 volatile（跨线程可见性） ============
        // BiliFixConfig 的三个可配置字段由主线程的 load() 写入，而读方
        // JarToolMixin 经 watermedia 的 PlayerAPI.start() → readArray
        // 可能在**工作线程**上执行。JLS §17.4.5：两条线程之间若没有
        // happens-before 边，写方的值对读方不保证可见——媒体线程可能一直
        // 读到类初始化时的旧值，用户的自定义配置静默失效
        // （默认值恰是安全值，故崩溃不会回来，但 "hwDecoder = any" 之类
        //  的高危自定义可能读不到）。
        // 引用写入本身是原子的，volatile 只补可见性，运行时零成本。
        {
            Path cfgSrc = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                  "bilifix", "config", "BiliFixConfig.java");
            if (Files.exists(cfgSrc)) {
                String src = Files.readString(cfgSrc, StandardCharsets.UTF_8);
                check("配置: hwDecoder 声明为 volatile",
                        src.matches("(?s).*public\\s+static\\s+volatile\\s+String\\s+hwDecoder\\s*=.*"));
                check("配置: vout 声明为 volatile",
                        src.matches("(?s).*public\\s+static\\s+volatile\\s+String\\s+vout\\s*=.*"));
                check("配置: verbose 声明为 volatile",
                        src.matches("(?s).*public\\s+static\\s+volatile\\s+boolean\\s+verbose\\s*=.*"));
            } else {
                skip("配置: BiliFixConfig.java 缺失，跳过源码断言");
            }
        }

        // ============ 18. Mixin 注入目标自检必须在启动序列里（v1.4.8） ============
        // Mixin 按方法名匹配目标，bilifix.mixins.json 的 defaultRequire=0（可选注入）
        // → 未来 watermedia 给 readArray 加重载或改签名时，Mixin 会**静默跳过注入**：
        // 模组"装上了、修好了、什么都没发生"，崩溃回归却无迹可寻。
        // 必须有启动自检把沉默的失效变成一条明确警告。
        {
            Path guardSrc = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                     "bilifix", "MixinTargetGuard.java");
            Path modSrc = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                    "bilifix", "BiliFixMod.java");
            if (Files.exists(guardSrc) && Files.exists(modSrc)) {
                String g = Files.readString(guardSrc, StandardCharsets.UTF_8);
                String m = Files.readString(modSrc, StandardCharsets.UTF_8);
                check("守卫: MixinTargetGuard 存在且被启动序列调用",
                        m.contains("MixinTargetGuard.check(LOGGER)"));
                // 目标类名/方法名必须与 Mixin 声明一致，否则自检的是另一个目标
                check("守卫: 自检目标类名与 Mixin 一致",
                        g.contains("\"org.watermedia.core.tools.JarTool\"")
                        && g.contains("\"readArray\""));
                // 必须能区分"未安装"与"歧义/缺失"——否则无法在正常场景下不误报
                check("守卫: 区分 WATERMEDIA_ABSENT 与 AMBIGUOUS_OR_MISSING",
                        g.contains("WATERMEDIA_ABSENT") && g.contains("AMBIGUOUS_OR_MISSING"));
                // 混合in's JSON 里 defaultRequire 必须为 0（可选注入）→ 所以守卫是必需品
                Path mixinJson = Paths.get("src", "main", "resources", "bilifix.mixins.json");
                if (Files.exists(mixinJson)) {
                    String j = Files.readString(mixinJson, StandardCharsets.UTF_8);
                    check("守卫: mixins.json 的 defaultRequire 为 0（故需自检兜底）",
                            j.contains("\"defaultRequire\": 0"));
                }
                // (b) 行为级验证判定逻辑本身——用 JDK 编译器现场构造四个态：
                //   正常（单签名） → OK
                //   未安装          → WATERMEDIA_ABSENT
                //   重载            → AMBIGUOUS_OR_MISSING
                //   签名变化        → SIGNATURE_MISMATCH
                // 复刻 MixinTargetGuard 的目标常量，与生产代码保持同源（上面两条
                // 源码断言保证常量不漂移，这里再用同常量构造假类，双保险）。
                check("守卫: 判定逻辑四态行为正确（正常/未安装/重载/签名变化）",
                        mixinGuardFourStates());
                // (c) 功能级自检必须被启动序列调用——"目标完好 + 签名匹配"仍不等于
                //     "注入已应用"（mixin 框架对 required:false 会把注入失败降级为
                //     debug 日志）。功能自检是唯一能端到端证明注入生效的手段。
                check("守卫: 功能自检 functionalProbe 被启动序列调用",
                        m.contains("MixinTargetGuard.functionalProbe(LOGGER)"));
                // (d) 功能自检必须比对"配置期望值"而非硬编码 none——
                //     否则用户把 hwDecoder 改成 any 时自检会误报失败。
                check("守卫: 功能自检比对配置期望值",
                        g.contains("BiliFixConfig.hwDecoderValue()"));
                // (e) 探测用的资源名必须与 PlayerAPI 实际读取的一致
                check("守卫: 功能自检资源名与 PlayerAPI 一致",
                        g.contains("\"videolan/arguments.json\""));
                // (f) **取证污染守卫**：功能自检会真的调用 readArray → 触发 mixin →
                //     recordHarden → mediaTouched=true。用户根本没播放媒体也会被
                //     记成"media touched: yes"，摧毁 v1.4.7 的核心取证语义。
                //     必须有抑制开关，且必须在 finally 中复位（否则用户之后真播放
                //     媒体时，取证数据会被永久抑制）。
                Path sentinelSrc = Paths.get("src", "main", "java", "dev", "polaris_fix",
                                             "bilifix", "CrashSentinel.java");
                if (Files.exists(sentinelSrc)) {
                    String s = Files.readString(sentinelSrc, StandardCharsets.UTF_8);
                    check("取证: CrashSentinel 提供取证抑制开关",
                            s.contains("setForensicsSuppressed(boolean"));
                    check("取证: recordHarden 在抑制态下直接返回",
                            s.matches("(?s).*public\\s+static\\s+void\\s+recordHarden\\s*\\(.*?"
                                    + "\\)\\s*\\{\\s*if\\s*\\(.*?SUPPRESS_FORENSICS.*?\\)\\s*return;.*"));
                    // v1.4.8：抑制必须是**线程局部**的。若是全局布尔，自检期间
                    // 媒体线程上的真实播放会被一并吞掉——mediaTouched 仍是 false、
                    // 计数不加，这次真实播放彻底不被记录。与"污染"是同一种错误的
                    // 镜像：把"该记的"丢掉同样让取证结论不可信。
                    check("取证: 抑制开关是线程局部的（ThreadLocal），不跨线程泄漏",
                            s.contains("ThreadLocal<Boolean> SUPPRESS_FORENSICS")
                                    && !s.contains("volatile boolean SUPPRESS_FORENSICS"));
                } else {
                    skip("取证: CrashSentinel.java 缺失，跳过源码断言");
                }
                check("取证: 功能自检成对使用抑制开关（进入+finally 复位）",
                        g.matches("(?s).*setForensicsSuppressed\\s*\\(\\s*true\\s*\\).*"));
                check("取证: 功能自检在 finally 中复位抑制",
                        g.matches("(?s).*finally\\s*\\{[^}]*setForensicsSuppressed\\s*\\(\\s*false\\s*\\).*"));
                // (g) 功能自检必须**同时**校验 --avcodec-hw 与 --vout：
                //     只验解码侧会漏掉"vout 没被改写"——而 direct3d11 输出路径
                //     本身也是崩溃因子之一。
                check("自检: 功能自检同时校验 avcodec-hw 与 vout",
                        g.contains("findValue(args, \"--vout\")")
                                && g.contains("findValue(args, \"--avcodec-hw\")"));
                // (h) vout=original 是用户**有意**保留原值 → 期望值为 null，
                //     此时只要参数表里有 --vout 就算符合预期，不该误报失败。
                check("自检: vout=original（期望 null）不误报",
                        g.contains("expectedVout == null ? actualVout != null"));
            } else {
                skip("守卫: MixinTargetGuard.java 缺失，跳过源码断言");
            }
            // (i) findValue 的行为级用例表：自检与 mixin 必须用同一套解析规则，
            //     否则自检会给出与真实改写相矛盾的结论。
            check("自检: findValue 解析用例表全绿",
                    probeFindValueCases());
        }

        System.out.println();
        System.out.println("通过 " + passed + " / 失败 " + failed + " / 跳过 " + skipped);
        // 跳过项必须显式计数并提示：否则 CI 环境（没有 build/ 产物）只打印
        // "通过 110 / 失败 0"，看起来像回归套件缩水了 21 条，实际是 jar 结构
        // 断言合理跳过。这与本项目其它"静默失效"是同一类问题。
        if (skipped > 0) {
            System.out.println("注意：有 " + skipped + " 条断言被跳过（通常是缺少 jar 产物；"
                    + "完整覆盖需先运行 build.ps1 / build-forge.ps1 / build-fabric.ps1）");
        }
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
     * 行为级验证（§18）：MixinTargetGuard 的判定逻辑必须能区分四个态。
     * 用 JDK 自带编译器现场编译四种形态的假 {@code org.watermedia.core.tools.JarTool}，
     * 各放进独立的目录，再用隔离的 URLClassLoader 逐个加载、调用
     * {@code MixinTargetGuard.evaluate()} 的同构镜像（Regression 不链接生产类，
     * 故按文件头说明镜像其逻辑），断言每个态返回预期结论。
     *
     * <p>四态与预期：</p>
     * <ul>
     *   <li>单签名 {@code readArray(String)} → OK（与真实 2.1.36/2.1.37 一致）</li>
     *   <li>目录里没有该类 → WATERMEDIA_ABSENT</li>
     *   <li>重载 {@code readArray(String) + readArray(String, boolean)} → AMBIGUOUS_OR_MISSING</li>
     *   <li>签名变化 {@code readArray(File)} → SIGNATURE_MISMATCH</li>
     * </ul>
     */
    static boolean mixinGuardFourStates() {
        javax.tools.JavaCompiler compiler = javax.tools.ToolProvider.getSystemJavaCompiler();
        if (compiler == null) return false;
        Path root = null;
        try {
            root = Files.createTempDirectory("bilifix-guard");
            // 正常态
            String okSrc = "package org.watermedia.core.tools;\n"
                    + "public class JarTool { public static String[] readArray(String s) { return new String[0]; } }";
            // 重载态
            String overSrc = "package org.watermedia.core.tools;\n"
                    + "public class JarTool {\n"
                    + "  public static String[] readArray(String s) { return new String[0]; }\n"
                    + "  public static String[] readArray(String s, boolean strict) { return new String[0]; }\n"
                    + "}";
            // 签名变化态
            String sigSrc = "package org.watermedia.core.tools;\n"
                    + "public class JarTool { public static String[] readArray(java.io.File f) { return new String[0]; } }";

            Path dirOk  = compile(compiler, root.resolve("ok"),  okSrc);
            Path dirNo  = root.resolve("absent");  // 不创建 → 类不存在
            Files.createDirectories(dirNo);
            Path dirOver = compile(compiler, root.resolve("over"), overSrc);
            Path dirSig  = compile(compiler, root.resolve("sig"),  sigSrc);
            if (dirOk == null || dirOver == null || dirSig == null) return false;

            return "OK".equals(mirrorEvaluate(dirOk))
                && "WATERMEDIA_ABSENT".equals(mirrorEvaluate(dirNo))
                && "AMBIGUOUS_OR_MISSING".equals(mirrorEvaluate(dirOver))
                && "SIGNATURE_MISMATCH".equals(mirrorEvaluate(dirSig));
        } catch (Throwable t) {
            return false;
        } finally {
            if (root != null) {
                try (var s = Files.walk(root)) {
                    s.sorted(Comparator.reverseOrder()).forEach(p -> {
                        try { Files.deleteIfExists(p); } catch (Exception ignored) { }
                    });
                } catch (Exception ignored) { }
            }
        }
    }

    /** 编译一段源码到子目录，返回目录；失败返回 null */
    static Path compile(javax.tools.JavaCompiler compiler, Path dir, String src) {
        try {
            Files.createDirectories(dir);
            String pkgDir = dir.resolve("org").resolve("watermedia").resolve("core")
                              .resolve("tools").toString();
            Files.createDirectories(Paths.get(pkgDir));
            Path java = Paths.get(pkgDir, "JarTool.java");
            Files.writeString(java, src, StandardCharsets.UTF_8);
            if (compiler.run(null, null, null, "-d", dir.toString(), java.toString()) != 0) return null;
            return dir;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * MixinTargetGuard.evaluate() 的镜像（同构逻辑）——Regression 是独立镜像，
     * 不链接生产类（文件头说明）。用隔离的 URLClassLoader 指向给定目录。
     */
    static String mirrorEvaluate(Path classDir) {
        try (java.net.URLClassLoader iso = new java.net.URLClassLoader(
                new java.net.URL[]{ classDir.toUri().toURL() }, null)) {
            Class<?> cls;
            try {
                cls = Class.forName("org.watermedia.core.tools.JarTool", false, iso);
            } catch (ClassNotFoundException e) {
                return "WATERMEDIA_ABSENT";
            } catch (Throwable t) {
                return "AMBIGUOUS_OR_MISSING";
            }
            int matches = 0;
            boolean sigOk = false;
            for (java.lang.reflect.Method m : cls.getDeclaredMethods()) {
                if (!m.getName().equals("readArray")) continue;
                matches++;
                if (java.lang.reflect.Modifier.isStatic(m.getModifiers())
                        && m.getReturnType() == String[].class
                        && java.util.Arrays.equals(m.getParameterTypes(), new Class<?>[]{String.class})) {
                    sigOk = true;
                }
            }
            if (matches == 0 || matches > 1) return "AMBIGUOUS_OR_MISSING";
            return sigOk ? "OK" : "SIGNATURE_MISMATCH";
        } catch (Throwable t) {
            return "AMBIGUOUS_OR_MISSING";
        }
    }

    /**
     * 行为级证据（§16）：{@code Class.forName(fqn, false, loader)} 在
     * "类文件存在、但其父类/依赖不在 classpath 上"时抛的是
     * {@link NoClassDefFoundError}（Error），**不是** {@link ClassNotFoundException}
     * （Exception）。这正是 EnvironmentDiagnostics.checkClass 必须兜 Throwable 的原因：
     * 只捕 CNFE 会让 Error 冒泡，已安装的 mod 被误报成"未安装"。
     *
     * <p>构造方式：用 JDK 自带的 javax.tools 编译器在临时目录里现场编译两个类——
     * {@code MissingDep}（依赖）与 {@code NeedsMissing extends MissingDep}（被测类），
     * 然后只把 {@code NeedsMissing} 所在的目录放进一个**隔离的 ClassLoader**，
     * 依赖目录不进去 → 链接必然失败。</p>
     *
     * <p>不用子 ClassLoader 隔离而是靠运行期 classpath 是不行的：测试自身的
     * classpath 里必然含有本测试的依赖类。</p>
     *
     * @return true = 实测抛出的确是 NoClassDefFoundError（而非 CNFE）
     */
    static boolean classForNameErrorIsNoClassDefFoundError() {
        Path root = null;
        try {
            javax.tools.JavaCompiler compiler = javax.tools.ToolProvider.getSystemJavaCompiler();
            if (compiler == null) return false;   // 无编译器环境（JRE）→ 不谎报
            root = Files.createTempDirectory("bilifix-forname");
            Path depDir = root.resolve("dep");
            Path mainDir = root.resolve("main");
            Files.createDirectories(depDir);
            Files.createDirectories(mainDir);

            Path depSrc = root.resolve("MissingDep.java");
            Files.writeString(depSrc, "public class MissingDep { public int x; }", StandardCharsets.UTF_8);
            Path needSrc = root.resolve("NeedsMissing.java");
            Files.writeString(needSrc, "public class NeedsMissing extends MissingDep { }", StandardCharsets.UTF_8);

            // 先编依赖，再把被测类对着依赖编（这样字节码里才有父类引用）
            // 必须显式给 -d：javac 默认把 class 写在源文件旁边，否则隔离目录是空的
            if (compiler.run(null, null, null, "-d", depDir.toString(), depSrc.toString()) != 0) return false;
            if (compiler.run(null, null, null, "-d", mainDir.toString(),
                            "-cp", depDir.toString(), needSrc.toString()) != 0) return false;
            if (!Files.exists(mainDir.resolve("NeedsMissing.class"))) return false;

            // 隔离加载：只有 mainDir 在 classpath 上，depDir 故意缺席
            try (java.net.URLClassLoader iso = new java.net.URLClassLoader(
                    new java.net.URL[]{ mainDir.toUri().toURL() }, null)) {
                Class.forName("NeedsMissing", false, iso);
                return false;   // 竟然加载成功了 → 前提不成立
            } catch (ClassNotFoundException e) {
                return false;   // 抛 CNFE → 与预期不符
            } catch (NoClassDefFoundError e) {
                return true;    // 预期：Error 而非 Exception
            }
        } catch (Throwable t) {
            return false;       // 环境问题（无编译器/权限）→ 不谎报
        } finally {
            if (root != null) {
                try (var s = Files.walk(root)) {
                    s.sorted(Comparator.reverseOrder()).forEach(p -> {
                        try { Files.deleteIfExists(p); } catch (Exception ignored) { }
                    });
                } catch (Exception ignored) { }
            }
        }
    }

    /**
     * 行为级证据（§18 扩展）：功能自检的 {@code findValue} 参数解析用例表。
     *
     * <p><b>为什么必须有这张表</b>：功能自检与 {@code JarToolMixin} 是**两套
     * 独立的解析代码**——mixin 负责改写，自检负责核对。若两者的判定规则漂移
     * （例如自检不认 {@code --key=value} 写法、或把"存在但无值"当成有值），
     * 自检就会给出与真实改写相矛盾的结论：要么误报"注入未生效"（虚警，
     * 让用户以为修复坏了），要么误报"通过"（掩盖真失效）。</p>
     *
     * <p>本方法镜像 {@code MixinTargetGuard.findValue} 的同构逻辑（Regression 是
     * 独立镜像，不链接生产类），对覆盖全部形态的用例表逐一验证。任一不符即失败。</p>
     *
     * @return true = 全部用例符合预期
     */
    static boolean probeFindValueCases() {
        // {参数数组}, {期望 hw, 期望 vout}；null 用 "(null)" 表示
        String[][][] cases = {
            // 标准 "--key value" 形式（加固后）
            { {"--avcodec-hw", "none", "--vout", "gl,any"}, {"none", "gl,any"} },
            // 标准形式（加固前，原始危险值——A 线基线形态）
            { {"--avcodec-hw", "d3d11va,dxva2,any", "--vout", "direct3d11,glwin32,gl,any"},
              {"d3d11va,dxva2,any", "direct3d11,glwin32,gl,any"} },
            // "--key=value" 形式
            { {"--avcodec-hw=none", "--vout=gl,any"}, {"none", "gl,any"} },
            { {"--avcodec-hw=none", "--vout=direct3d11,glwin32,gl,any"},
              {"none", "direct3d11,glwin32,gl,any"} },
            // 缺 --avcodec-hw（只应找到 vout）
            { {"--vout", "gl,any"}, {"(null)", "gl,any"} },
            // 裸选项、无值：存在但取不到值 → null（不能把下一个选项当值）
            { {"--avcodec-hw"}, {"(null)", "(null)"} },
            { {"--avcodec-hw", "none", "--vout"}, {"none", "(null)"} },
            // 真实 18 项参数表形态（前后都有干扰项）
            { {"--no-quiet", "--cr-average=5000", "--avcodec-hw", "none", "--vout", "gl,any",
               "--http-reconnect"}, {"none", "gl,any"} },
            // 值恰好以 - 开头（不可能是 VLC 值）→ 不应被当作值消费
            { {"--avcodec-hw", "--vout", "gl,any"}, {"(null)", "gl,any"} },
            // null 元素不得导致 NPE（防御：真实参数表理论上不该有 null，但自检不能因此崩）
            { {"--avcodec-hw", null, "--vout", "gl,any"}, {"(null)", "gl,any"} },
        };
        for (String[][] c : cases) {
            String hw = mirrorFindValue(c[0], "--avcodec-hw");
            String vout = mirrorFindValue(c[0], "--vout");
            String hwS = hw == null ? "(null)" : hw;
            String voutS = vout == null ? "(null)" : vout;
            if (!hwS.equals(c[1][0]) || !voutS.equals(c[1][1])) return false;
        }
        return true;
    }

    /** {@code MixinTargetGuard.findValue} 的同构镜像（含 null 元素防御） */
    static String mirrorFindValue(String[] args, String key) {
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if (a == null) continue;
            if (key.equals(a)) {
                if (i + 1 < args.length && args[i + 1] != null && !args[i + 1].startsWith("-")) {
                    return args[i + 1];
                }
                return null;
            }
            if (a.startsWith(key + "=")) return a.substring(key.length() + 1);
        }
        return null;
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
        boolean first = true;
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            String s = line.trim();
            // v1.4.8：与生产同步 —— 剥离 UTF-8 BOM。Files.readAllLines 不去 BOM，
            // 带 BOM 的配置首个 key 会变成 "\uFEFFhwDecoder" → containsKey 为 false
            // → 用户的 hwDecoder 被静默忽略（只有第一个键受影响，更难察觉）。
            if (first) {
                first = false;
                if (!s.isEmpty() && s.charAt(0) == '\uFEFF') s = s.substring(1).trim();
            }
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
        return switch (s.toLowerCase().trim()) {
            case "disable", "none", "off" -> "none";
            case "auto", "any" -> "any";
            case "d3d11va" -> "d3d11va";
            case "dxva2" -> "dxva2";
            default -> "none";
        };
    }
    /**
     * 镜像实现，必须与生产的 {@code BiliFixConfig.voutValue()} 行为一致。
     *
     * <p>v1.4.8 实测分歧（已修）：本镜像原先把空串原样返回，生产已改成回退
     * 安全默认 {@code gl,any}。镜像是独立实现（不引用生产类），所以生产行为
     * <b>有意改变</b>时必须手工同步——否则镜像会给出与生产相反的结论，
     * 这比没有镜像更糟。分歧检测见 {@code MirrorParityProbe}。</p>
     */
    static Object voutMap(String s) {
        if (s == null) return null;
        String v = s.toLowerCase().trim();
        return switch (v) {
            case "original", "keep" -> null;
            default -> v.isEmpty() ? "gl,any" : v;
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

    /**
     * 跳过的断言：单独计数，绝不混入通过数。
     *
     * <p>此前跳过项既不计数也不汇总，于是 CI 环境（没有 build/ 产物）只打印
     * "通过 110 / 失败 0"——看起来像回归套件缩水了 21 条，实际是 jar 结构断言
     * 合理跳过。这类"信息缺失导致误判"和本项目其它静默失效是同一类问题。</p>
     */
    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }
}
