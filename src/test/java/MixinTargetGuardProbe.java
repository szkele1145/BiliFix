import org.slf4j.Logger;

import java.io.File;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 探针：Mixin 注入目标自检（{@code MixinTargetGuard}）。
 *
 * <p><b>为什么这个类必须有行为探针</b>：整个修复依赖一个 Mixin 注入点，
 * 而 {@code bilifix.mixins.json} 里 {@code defaultRequire: 0}（可选注入）。
 * 于是存在一条沉默的失效路径——目标签名变了，Mixin 静默跳过，BiliFix
 * "装上了、修好了、什么都没发生"，用户只看到崩溃回归，日志里没有任何线索。
 * {@code MixinTargetGuard} 就是把这条沉默路径变成启动日志里一条警告的唯一手段。
 * 它此前只有镜像覆盖（{@code Regression} §18），镜像抓不到生产代码自身的 bug。</p>
 *
 * <p><b>怎么测</b>：生产代码用
 * {@code Class.forName("org.watermedia.core.tools.JarTool", false, MixinTargetGuard.class.getClassLoader())}
 * 找目标，类名是硬编码常量，无法在同一个 JVM 里换掉。所以本探针：
 * <ol>
 *   <li>运行时用 {@code ToolProvider.getSystemJavaCompiler()} 编译出多个形态的
 *       stub（签名完全匹配 / 多一个重载 / 完全没有该方法 / 返回类型不对 /
 *       完全不存在），每个形态一个 class 目录；</li>
 *   <li>为每个形态建一个<b>子类优先</b>的 {@link URLClassLoader}：对
 *       {@code org.watermedia.*} 与 {@code dev.polaris_fix.bilifix.*} 先找自己，
 *       其余（如 slf4j）委派给父加载器。于是
 *       {@code MixinTargetGuard.class.getClassLoader()} 指向该子类加载器，
 *       目标解析就会落到对应的 stub 上；</li>
 *   <li>反射调用生产类的 {@code evaluate()} / {@code check(Logger)} /
 *       {@code functionalProbe(Logger)}，断言判定结果与日志内容。</li>
 * </ol>
 *
 * <p><b>关键判据</b>：{@code functionalProbe} 必须能分辨"注入已生效"与"没生效"——
 * 这正是它存在的理由。stub 返回加固后的参数 → true；返回 d3d11va /
 * direct3d11 → false。</p>
 *
 * <p><b>本探针验证什么、不验证什么</b>：stub 的 {@code readArray} 是普通 Java
 * 方法，<b>没有</b>经过 mixin 变换——它直接返回预设的参数表。所以本探针验证的是
 * <b>守卫的判定逻辑</b>（该判 OK 时判 OK、该报警时报警、该判"注入未生效"时判
 * 未生效），<b>不是</b> mixin 在重载场景下的真实行为。mixin 遇到同名重载究竟
 * 是"注入到全部同名方法"还是"静默跳过"，由 mixin 框架决定，不在本探针范围。</p>
 */
public class MixinTargetGuardProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skip(String name, String reason) {
        skipped++;
        System.out.println("  [SKIP] " + name + " — " + reason);
    }

    // ==================== stub 形态 ====================

    static String stub(String body) {
        return "package org.watermedia.core.tools;\n"
             + "public class JarTool {\n"
             + body
             + "}\n";
    }

    /** 形态 → stub 源码 */
    static Map<String, String> variants() {
        Map<String, String> v = new LinkedHashMap<>();
        // 签名完全匹配，返回加固后的参数（空格分隔形式）
        v.put("exact-hardened", stub(
                "    public static String[] readArray(String name) {\n"
              + "        return new String[]{\"--avcodec-hw\", \"none\", \"--vout\", \"gl,any\"};\n"
              + "    }\n"));
        // 签名完全匹配，但返回的是危险原值（= 注入没打上）
        v.put("exact-dangerous", stub(
                "    public static String[] readArray(String name) {\n"
              + "        return new String[]{\"--avcodec-hw\", \"d3d11va\", \"--vout\", \"direct3d11\"};\n"
              + "    }\n"));
        // 签名完全匹配，返回 null
        v.put("exact-null", stub(
                "    public static String[] readArray(String name) {\n"
              + "        return null;\n"
              + "    }\n"));
        // 签名完全匹配，参数用 "--key=value" 形式（VLC 的另一种写法）
        v.put("exact-equals-form", stub(
                "    public static String[] readArray(String name) {\n"
              + "        return new String[]{\"--avcodec-hw=none\", \"--vout=gl,any\"};\n"
              + "    }\n"));
        // 多了重载 → 目标不再唯一 → Mixin 会静默跳过
        v.put("overload", stub(
                "    public static String[] readArray(String name) {\n"
              + "        return new String[]{\"--avcodec-hw\", \"none\", \"--vout\", \"gl,any\"};\n"
              + "    }\n"
              + "    public static String[] readArray(String name, int flags) {\n"
              + "        return new String[0];\n"
              + "    }\n"));
        // 完全没有 readArray
        v.put("missing-method", stub(
                "    public static String[] other(String name) {\n"
              + "        return new String[0];\n"
              + "    }\n"));
        // 返回类型不对（String 而非 String[]）且非 static
        v.put("wrong-signature", stub(
                "    public String readArray(String name) {\n"
              + "        return \"nope\";\n"
              + "    }\n"));
        return v;
    }

    /** 形态 → 期望的 evaluate() 结果（Status 枚举名） */
    static String expectedStatus(String variant) {
        switch (variant) {
            case "exact-hardened":
            case "exact-dangerous":
            case "exact-null":
            case "exact-equals-form":
                return "OK";
            case "overload":
            case "missing-method":
                return "AMBIGUOUS_OR_MISSING";
            case "wrong-signature":
                return "SIGNATURE_MISMATCH";
            default:
                return null;   // absent：类根本不存在
        }
    }

    /** 形态 → 期望的 functionalProbe() 结果 */
    static boolean expectedFunctional(String variant) {
        switch (variant) {
            case "exact-hardened":
            case "exact-equals-form":
            case "overload":
                return true;
            default:
                return false;
        }
    }

    // ==================== 子类优先加载器 ====================

    static final class VariantLoader extends URLClassLoader {
        VariantLoader(URL[] urls, ClassLoader parent) {
            super(urls, parent);
        }

        @Override
        protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            synchronized (getClassLoadingLock(name)) {
                Class<?> c = findLoadedClass(name);
                if (c == null) {
                    boolean childFirst = name.startsWith("org.watermedia.")
                            || name.startsWith("dev.polaris_fix.bilifix.");
                    if (childFirst) {
                        try {
                            c = findClass(name);
                        } catch (ClassNotFoundException e) {
                            c = super.loadClass(name, false);
                        }
                    } else {
                        c = super.loadClass(name, false);
                    }
                }
                if (resolve) resolveClass(c);
                return c;
            }
        }
    }

    // ==================== 日志捕获 ====================

    static final class LogCapture implements InvocationHandler {
        final List<String> entries = new ArrayList<>();

        @Override
        public Object invoke(Object proxy, Method m, Object[] args) {
            String fmt = "";
            if (args != null && args.length > 0 && args[0] instanceof String) fmt = (String) args[0];
            entries.add(m.getName() + "|" + fmt);
            Class<?> rt = m.getReturnType();
            if (rt == boolean.class) return Boolean.FALSE;
            if (rt == String.class) return "";
            return null;
        }

        boolean has(String level, String fragment) {
            for (String e : entries) {
                int i = e.indexOf('|');
                if (i < 0) continue;
                if (e.substring(0, i).equals(level) && e.substring(i + 1).contains(fragment)) return true;
            }
            return false;
        }
    }

    static Logger capture(LogCapture sink) {
        return (Logger) Proxy.newProxyInstance(
                MixinTargetGuardProbe.class.getClassLoader(),
                new Class<?>[]{ Logger.class }, sink);
    }

    // ==================== 工具 ====================

    /**
     * 生产类所在目录。
     *
     * <p><b>关键</b>：必须是 {@code MixinTargetGuard.class} 的 CodeSource，
     * 而不是探针自己的——否则 {@code MixinTargetGuard} 由父加载器加载，
     * 它内部的 {@code MixinTargetGuard.class.getClassLoader()} 就不是
     * VariantLoader，目标类永远从父加载器解析，stub 形态完全不起作用
     * （实测：所有形态都退化成 WATERMEDIA_ABSENT）。</p>
     */
    static URL productionClassesUrl() throws Exception {
        java.security.CodeSource cs = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard")
                .getProtectionDomain().getCodeSource();
        if (cs != null && cs.getLocation() != null) return cs.getLocation();
        URL r = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard")
                .getResource("MixinTargetGuard.class");
        if (r == null) throw new IllegalStateException("cannot locate the production classes directory");
        return new File(r.getPath()).getParentFile().toURI().toURL();
    }

    static Path compileStub(Path base, String variant, String source) throws Exception {
        Path src = base.resolve(variant + "-src");
        Path out = base.resolve(variant + "-classes");
        Path f = src.resolve("org").resolve("watermedia").resolve("core").resolve("tools").resolve("JarTool.java");
        Files.createDirectories(f.getParent());
        Files.createDirectories(out);
        Files.write(f, source.getBytes(StandardCharsets.UTF_8));

        // 用外部 javac 进程编译 stub：在进程内调用 ToolProvider 编译器会受
        // 运行时的 classpath 约束（实测报 NoClassDefFoundError: gson），
        // 而外部进程是干净的、且与构建脚本用的是同一个 JDK。
        String javac = System.getProperty("java.home") + File.separator + "bin"
                + File.separator + "javac" + (isWindows() ? ".exe" : "");
        Process proc = new ProcessBuilder(javac, "-d", out.toString(), f.toString())
                .redirectErrorStream(true)
                .start();
        String log = new String(proc.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        int rc = proc.waitFor();
        if (rc != 0) {
            throw new IllegalStateException("stub compile failed for " + variant
                    + " (exit " + rc + ")\n" + log);
        }
        return out;
    }

    static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase().contains("win");
    }

    // ==================== 主流程 ====================

    public static void main(String[] args) throws Exception {
        System.out.println("Mixin target guard probe");

        Path base = Files.createTempDirectory("guard-probe");
        URL prodUrl = productionClassesUrl();

        // ---- 1. 形态：类完全不存在 → WATERMEDIA_ABSENT（正常情况，不该报警） ----
        {
            ClassLoader child = new VariantLoader(new URL[]{ prodUrl },
                    MixinTargetGuardProbe.class.getClassLoader());
            Class<?> guard = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard", true, child);
            Object status = guard.getMethod("evaluate").invoke(null);
            check("类不存在 → evaluate() = WATERMEDIA_ABSENT",
                    "WATERMEDIA_ABSENT".equals(String.valueOf(status)));

            LogCapture sink = new LogCapture();
            Object s2 = guard.getMethod("check", Logger.class).invoke(null, capture(sink));
            check("类不存在 → check() 也返回 WATERMEDIA_ABSENT",
                    "WATERMEDIA_ABSENT".equals(String.valueOf(s2)));
            check("类不存在 → 记 info 而不是 warn（不是故障）", sink.has("info", "未检测到 watermedia"));
            check("类不存在 → 不产生警告", !sink.has("warn", "可能不生效"));

            // functionalProbe 在类不存在时必须静默返回 false
            LogCapture sink2 = new LogCapture();
            Object fp = guard.getMethod("functionalProbe", Logger.class).invoke(null, capture(sink2));
            check("类不存在 → functionalProbe() = false", Boolean.FALSE.equals(fp));
        }

        // ---- 2. 各形态：编译 stub 并断言判定 ----
        for (Map.Entry<String, String> e : variants().entrySet()) {
            String variant = e.getKey();
            Path stubDir = compileStub(base, variant, e.getValue());
            ClassLoader child = new VariantLoader(new URL[]{ stubDir.toUri().toURL(), prodUrl },
                    MixinTargetGuardProbe.class.getClassLoader());
            Class<?> guard = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard", true, child);

            Object status = guard.getMethod("evaluate").invoke(null);
            check(variant + " → evaluate() = " + expectedStatus(variant),
                    expectedStatus(variant).equals(String.valueOf(status)));

            LogCapture sink = new LogCapture();
            guard.getMethod("check", Logger.class).invoke(null, capture(sink));
            switch (expectedStatus(variant)) {
                case "OK":
                    check(variant + " → check() 记 info「自检通过」", sink.has("info", "Mixin 注入目标自检通过"));
                    break;
                case "AMBIGUOUS_OR_MISSING":
                    check(variant + " → check() 记 warn「缺失或存在重载」",
                            sink.has("warn", "缺失或存在重载"));
                    break;
                case "SIGNATURE_MISMATCH":
                    check(variant + " → check() 记 warn「签名已变化」",
                            sink.has("warn", "签名已变化"));
                    break;
                default:
                    break;
            }
            if (!"OK".equals(expectedStatus(variant))) {
                check(variant + " → check() 明确提示「可能不生效」", sink.has("warn", "可能不生效"));
            }

            LogCapture fsink = new LogCapture();
            Object fp = guard.getMethod("functionalProbe", Logger.class).invoke(null, capture(fsink));
            check(variant + " → functionalProbe() = " + expectedFunctional(variant),
                    Boolean.valueOf(expectedFunctional(variant)).equals(fp));
        }

        // ---- 3. functionalProbe 的日志措辞 ----
        {
            Path stubDir = compileStub(base, "exact-hardened", variants().get("exact-hardened"));
            ClassLoader child = new VariantLoader(new URL[]{ stubDir.toUri().toURL(), prodUrl },
                    MixinTargetGuardProbe.class.getClassLoader());
            Class<?> guard = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard", true, child);
            LogCapture sink = new LogCapture();
            guard.getMethod("functionalProbe", Logger.class).invoke(null, capture(sink));
            check("功能自检通过 → info 含「端到端验证」", sink.has("info", "端到端验证"));
        }
        {
            Path stubDir = compileStub(base, "exact-dangerous", variants().get("exact-dangerous"));
            ClassLoader child = new VariantLoader(new URL[]{ stubDir.toUri().toURL(), prodUrl },
                    MixinTargetGuardProbe.class.getClassLoader());
            Class<?> guard = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard", true, child);
            LogCapture sink = new LogCapture();
            guard.getMethod("functionalProbe", Logger.class).invoke(null, capture(sink));
            check("功能自检失败 → warn 含「注入未生效」", sink.has("warn", "注入未生效"));
        }
        {
            Path stubDir = compileStub(base, "exact-null", variants().get("exact-null"));
            ClassLoader child = new VariantLoader(new URL[]{ stubDir.toUri().toURL(), prodUrl },
                    MixinTargetGuardProbe.class.getClassLoader());
            Class<?> guard = Class.forName("dev.polaris_fix.bilifix.MixinTargetGuard", true, child);
            LogCapture sink = new LogCapture();
            guard.getMethod("functionalProbe", Logger.class).invoke(null, capture(sink));
            check("readArray 返回 null → warn 含「返回 null」", sink.has("warn", "返回 null"));
        }

        // ---- 4. 源码级：判定不得把"类存在但签名不对"当成"未安装" ----
        {
            String src = new String(Files.readAllBytes(java.nio.file.Paths.get("src", "main", "java",
                    "dev", "polaris_fix", "bilifix", "MixinTargetGuard.java")), StandardCharsets.UTF_8);
            check("源码含 4 种判定状态", src.contains("AMBIGUOUS_OR_MISSING")
                    && src.contains("SIGNATURE_MISMATCH")
                    && src.contains("WATERMEDIA_ABSENT") && src.contains("OK"));
            check("源码对 ClassNotFoundException 之外的 Throwable 也降级处理",
                    src.contains("catch (Throwable t)"));
        }

        deleteTree(base);

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }

    static void deleteTree(Path p) {
        try {
            if (!Files.exists(p)) return;
            Files.walk(p).sorted(java.util.Comparator.reverseOrder()).forEach(x -> {
                try { Files.deleteIfExists(x); } catch (Exception ignored) { }
            });
        } catch (Exception ignored) { }
    }
}
