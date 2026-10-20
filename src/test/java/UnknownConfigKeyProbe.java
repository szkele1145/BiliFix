import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * 探针：写错的配置键必须**可见**，不能被静默忽略。
 *
 * <p><b>缺陷背景（v1.4.8 修复）</b>：{@code parse()} 会把配置文件里的
 * <b>所有</b> 键都放进 map，而 {@code load()} 只取
 * {@code hwDecoder} / {@code vout} / {@code verbose} 三个——其余键
 * <b>无声丢弃</b>，日志里只有一句"已加载配置"，没有任何线索。</p>
 *
 * <p>实测（修复前）：</p>
 * <pre>
 *   配置写 hwdecoder = "any"   （大小写写错）
 *   日志: [BiliFix] 已加载配置: .../bilifix.toml
 *   结果: 用户以为自己设了硬解 any，实际生效 none（软解），且没有任何提示
 * </pre>
 *
 * <p>这与 UTF-8 BOM 是同族缺陷：用户改了配置、文件也"加载成功"、但设置
 * 没生效，日志里没有任何指向原因的东西。</p>
 *
 * <p>本探针给 slf4j 装一个捕获用 provider（{@code test.slf4j.CapturingServiceProvider}），
 * 然后调用生产的 {@code load()}，断言警告真的发出去了、且内容能指向正确键名。</p>
 */
public class UnknownConfigKeyProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    /**
     * 写一个配置文件并调用生产的 load()。
     * <b>文件名必须是 bilifix.toml</b>——load() 经 configPath() 只认这个名字，
     * 写成别的会走"生成默认配置"分支，探针就测了个空。
     */
    static void loadWith(Path dir, List<String> lines) throws Exception {
        Path f = dir.resolve("bilifix.toml");
        Files.write(f, lines, StandardCharsets.UTF_8);
        BiliFixConfig.setConfigDir(dir);
        BiliFixConfig.load();
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Unknown config key probe");
        // slf4j 的 provider 是懒加载的：先强制初始化，再清空捕获缓冲
        org.slf4j.LoggerFactory.getLogger("probe-init");
        test.slf4j.CapturingServiceProvider.clear();

        Path dir = Files.createTempDirectory("unknown-key");

        // (1) 大小写写错 → 必须警告，并指出正确键名
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of("hwdecoder = \"any\""));
            boolean warned = test.slf4j.CapturingServiceProvider.hasWarn("hwdecoder")
                    && test.slf4j.CapturingServiceProvider.hasWarn("hwDecoder");
            check("键名大小写写错 → 发出警告并指出正确键名", warned);
            check("键名大小写写错 → 警告说明该设置未生效",
                    test.slf4j.CapturingServiceProvider.hasWarn("未生效"));
            check("键名大小写写错 → 警告说明键名区分大小写",
                    test.slf4j.CapturingServiceProvider.hasWarn("区分大小写"));
        }

        // (2) 真正未知的键 → 必须警告
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of("hwDecorder = \"any\"", "whatever = 1"));
            check("未知键 → 发出警告", test.slf4j.CapturingServiceProvider.hasWarn("hwDecorder")
                    && test.slf4j.CapturingServiceProvider.hasWarn("whatever"));
            check("未知键 → 警告列出已知键",
                    test.slf4j.CapturingServiceProvider.hasWarn("hwDecoder")
                            && test.slf4j.CapturingServiceProvider.hasWarn("verbose"));
        }

        // (3) 全部键都正确 → 不该有多余警告
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of(
                    "hwDecoder = \"none\"", "vout = \"gl,any\"", "verbose = false"));
            check("键名全对 → 不发未识别键警告",
                    !test.slf4j.CapturingServiceProvider.hasWarn("未识别")
                            && !test.slf4j.CapturingServiceProvider.hasWarn("拼写不对"));
        }

        // (4) 注释行不是键 → 不能被当成未识别键
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of(
                    "# BiliFix 配置", "# hwDecoder = \"none\"", "hwDecoder = \"none\""));
            check("注释行不被当成未识别键",
                    !test.slf4j.CapturingServiceProvider.hasWarn("未识别")
                            && !test.slf4j.CapturingServiceProvider.hasWarn("拼写不对"));
        }

        // (5) 写错的键确实没生效（值仍是默认/其它键的值）
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of("hwdecoder = \"any\""));
            check("写错的键确实没生效（hwDecoder 仍是 none）",
                    "none".equals(BiliFixConfig.hwDecoder));
        }

        // (6) 源码级：load() 必须对未知键发警告
        {
            Path src = args.length > 0 ? Path.of(args[0])
                    : Path.of("src", "main", "java", "dev", "polaris_fix", "bilifix", "config", "BiliFixConfig.java");
            String s = Files.readString(src, StandardCharsets.UTF_8);
            check("源码: load() 含未识别键警告", s.contains("未识别的键"));
            check("源码: load() 含拼写不对提示", s.contains("拼写不对"));
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
