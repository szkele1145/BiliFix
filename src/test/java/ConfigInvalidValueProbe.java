import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * 探针：配置里三个字段的"无效值"处理必须**一致**且**都可见**。
 *
 * <p><b>缺陷背景（代码审查发现）</b>：三个配置字段对无效值的处理各不相同：</p>
 * <ul>
 *   <li>{@code hwDecoder = "xyz"} → 回退安全默认并<b>警告</b>（已实现）</li>
 *   <li>{@code vout = ""} → 回退安全默认并<b>警告</b>（v1.4.8 已实现）</li>
 *   <li>{@code verbose = "yes"} → <b>静默</b>变成 false，没有任何提示</li>
 * </ul>
 *
 * <p>这正是 {@code BiliFixConfig.voutValue()} 的注释自己指出的问题：
 * "两个字段行为不一致，早晚会有人踩到"。用户写 {@code verbose = "yes"}（很常见）
 * 后看到的是"配置加载成功"，但日志详细打印没开——设置**静默失效**，
 * 没有任何线索指向原因。</p>
 *
 * <p><b>第二个缺陷：重复 key 静默覆盖</b>。配置里写两次 {@code hwDecoder}，
 * 后者生效且无任何提示——用户改不动配置时无从判断是哪一行在起作用。</p>
 *
 * <p>本探针给 slf4j 装捕获用 provider（{@code test.slf4j.CapturingServiceProvider}），
 * 调用生产的 {@code load()}，断言警告真的发出去了。</p>
 *
 * <p>用法：{@code ConfigInvalidValueProbe [源码路径]}</p>
 */
public class ConfigInvalidValueProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void check(String name, boolean ok, String ctx) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name + "  (" + ctx + ")"); }
    }

    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }

    /** 写一个配置文件并调用生产的 load()（文件名必须是 bilifix.toml） */
    static void loadWith(Path dir, List<String> lines) throws Exception {
        Path f = dir.resolve("bilifix.toml");
        Files.write(f, lines, StandardCharsets.UTF_8);
        BiliFixConfig.setConfigDir(dir);
        BiliFixConfig.load();
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Config invalid-value probe");
        // slf4j 的 provider 是懒加载的：先强制初始化，再清空捕获缓冲
        org.slf4j.LoggerFactory.getLogger("probe-init");
        test.slf4j.CapturingServiceProvider.clear();

        Path dir = Files.createTempDirectory("cfg-invalid");

        // ---------- 1. verbose 的无效值必须被警告 ----------
        // verbose 是布尔字段："true"/"false" 之外的值都是无效的。
        // 旧实现是 "true".equalsIgnoreCase(v)，于是 "yes"/"1"/"on" 全部
        // 静默变成 false。
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of("verbose = \"yes\""));
            check("verbose 的无效值发出警告",
                    test.slf4j.CapturingServiceProvider.hasWarn("verbose"));
            check("verbose 无效值的警告说明该值无效",
                    test.slf4j.CapturingServiceProvider.hasWarn("无效")
                            || test.slf4j.CapturingServiceProvider.hasWarn("不是合法的布尔值")
                            || test.slf4j.CapturingServiceProvider.hasWarn("回退"));
        }

        // ---------- 2. verbose 的合法值不能被误报 ----------
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of("verbose = \"true\""));
            check("verbose = true 不产生无效值警告",
                    !test.slf4j.CapturingServiceProvider.hasWarn("verbose")
                            || !test.slf4j.CapturingServiceProvider.hasWarn("回退"));
        }
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of("verbose = \"false\""));
            check("verbose = false 不产生无效值警告",
                    !test.slf4j.CapturingServiceProvider.hasWarn("回退"));
        }

        // ---------- 3. 三个字段的无效值处理必须一致 ----------
        // hwDecoder / vout 已有警告；verbose 现在也要有。
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of(
                    "hwDecoder = \"definitely-not-a-decoder\"",
                    "vout = \"\"",
                    "verbose = \"maybe\""));
            check("hwDecoder 无效值有警告",
                    test.slf4j.CapturingServiceProvider.hasWarn("hwDecoder"));
            check("vout 无效值有警告",
                    test.slf4j.CapturingServiceProvider.hasWarn("vout"));
            check("verbose 无效值有警告（与前两者一致）",
                    test.slf4j.CapturingServiceProvider.hasWarn("verbose"));
        }

        // ---------- 4. 重复 key 必须可见 ----------
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of(
                    "hwDecoder = \"none\"",
                    "hwDecoder = \"any\""));
            check("重复 key 发出警告",
                    test.slf4j.CapturingServiceProvider.hasWarn("重复"));
            check("重复 key 的警告指出是哪个键",
                    test.slf4j.CapturingServiceProvider.hasWarn("hwDecoder"));
        }

        // ---------- 5. 重复 key 的实际生效值必须是最后一个 ----------
        // 语义要与 TOML 一致：后者覆盖前者。
        {
            loadWith(dir, List.of(
                    "hwDecoder = \"none\"",
                    "hwDecoder = \"any\""));
            check("重复 key 以后一个为准（与 TOML 一致）",
                    "any".equals(BiliFixConfig.hwDecoder),
                    "hwDecoder=" + BiliFixConfig.hwDecoder);
        }

        // ---------- 6. 重复的未知键也要警告 ----------
        {
            test.slf4j.CapturingServiceProvider.clear();
            loadWith(dir, List.of(
                    "foo = 1",
                    "foo = 2"));
            check("重复的未知键也发出警告",
                    test.slf4j.CapturingServiceProvider.hasWarn("重复"));
        }

        // ---------- 7. 源码级 ----------
        Path src = args.length > 0 ? Path.of(args[0])
                : Path.of("src", "main", "java", "dev", "polaris_fix", "bilifix", "config", "BiliFixConfig.java");
        String s = Files.readString(src, StandardCharsets.UTF_8);
        check("源码: load() 含重复键警告", s.contains("重复"));
        check("源码: 不再用裸 equalsIgnoreCase 判定 verbose",
                !s.contains("verbose   = \"true\".equalsIgnoreCase("),
                "verbose 赋值处");
        check("源码: 存在统一的 verbose 校验入口", s.contains("verboseValue"));

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
