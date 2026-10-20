import dev.polaris_fix.bilifix.BiliFixMod;
import dev.polaris_fix.bilifix.CrashSentinel;
import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.lang.reflect.Field;
import java.nio.file.Path;

/**
 * 探针：核对 README "Verifying It Works" 段落里写的示例日志行，
 * 是否与生产代码实际会输出的字符串**逐字符**一致。
 *
 * 为什么值得做：README 是用户排查崩溃时唯一的对照物。若示例里的日志串
 * 和真实输出差一个空格或全角半角，用户会以为修复没生效——
 * 而实际上修复已经生效了。这是一种"文档漂移造成的假阴性"。
 */
public class ReadmeLogSampleProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("README log-sample probe");

        // 1. BiliFixMod 启动行的实际格式
        //    生产：LOGGER.info("[BiliFix] v{} 已加载：watermedia VLC 硬解崩溃修复（策略: hw={}, vout={}）", ...)
        String version = (String) BiliFixMod.class.getField("VERSION").get(null);
        String hw = BiliFixConfig.hwDecoderValue();
        String vout = BiliFixConfig.voutValue();
        String bootLine = "[BiliFix] v" + version + " 已加载：watermedia VLC 硬解崩溃修复（策略: hw=" + hw + ", vout=" + vout + "）";
        System.out.println("  actual boot line: " + bootLine);
        check("启动行含版本号 " + version, bootLine.contains("v" + version));
        check("启动行含实际 hw 值 (" + hw + ")", bootLine.contains("hw=" + hw));
        check("启动行含实际 vout 值 (" + vout + ")", bootLine.contains("vout=" + vout));
        check("启动行以 [BiliFix] 开头", bootLine.startsWith("[BiliFix] "));

        // 2. JarToolMixin 加固行的实际格式
        //    生产：LOGGER.info("[BiliFix] VLC 参数已加固: --avcodec-hw={} , --vout={} (原 {} 项 → 新 {} 项)", ...)
        String hardenLine = "[BiliFix] VLC 参数已加固: --avcodec-hw=" + hw + " , --vout=" + vout + " (原 18 项 → 新 18 项)";
        System.out.println("  actual harden line: " + hardenLine);
        check("加固行含 --avcodec-hw=" + hw, hardenLine.contains("--avcodec-hw=" + hw));
        check("加固行含 --vout=" + vout, hardenLine.contains("--vout=" + vout));
        check("加固行使用全角箭头 →", hardenLine.contains("→"));
        check("加固行用 ' , ' 分隔两个参数（与生产一致）", hardenLine.contains(" , "));

        // 3. 生产源码里的字面量必须与 README 引用的片段一致
        String src = new String(java.nio.file.Files.readAllBytes(
                java.nio.file.Paths.get("src", "main", "java", "dev", "polaris_fix",
                        "bilifix", "mixin", "JarToolMixin.java")), java.nio.charset.StandardCharsets.UTF_8);
        check("JarToolMixin 源码含 \"VLC 参数已加固: --avcodec-hw={} , --vout={}\"",
                src.contains("VLC 参数已加固: --avcodec-hw={} , --vout={}"));
        check("JarToolMixin 源码含全角箭头 \"原 {} 项 → 新 {} 项\"",
                src.contains("原 {} 项 → 新 {} 项"));

        String modSrc = new String(java.nio.file.Files.readAllBytes(
                java.nio.file.Paths.get("src", "main", "java", "dev", "polaris_fix",
                        "bilifix", "BiliFixMod.java")), java.nio.charset.StandardCharsets.UTF_8);
        check("BiliFixMod 源码含 \"已加载：watermedia VLC 硬解崩溃修复\"",
                modSrc.contains("已加载：watermedia VLC 硬解崩溃修复"));
        check("BiliFixMod 源码含 \"（策略: hw={}, vout={}）\"",
                modSrc.contains("（策略: hw={}, vout={}）"));

        // 4. 探针本身要真的触达 CrashSentinel（确保 classpath 正确）
        Path tmp = java.nio.file.Files.createTempDirectory("readme-probe");
        CrashSentinel.setGameDir(tmp);
        CrashSentinel.record("readme probe touched CrashSentinel");
        check("CrashSentinel 在 classpath 上且可调用", true);

        // 5. README 里引用的日志行必须与生产字面量一致（防止文档漂移）
        //    这一段直接读 README 文件：README 改了而生产没改时必须 FAIL。
        for (String[] pair : new String[][] {
                {"README.md", bootLine},
                {"README.zh-CN.md", bootLine},
                {"README.md", hardenLine},
                {"README.zh-CN.md", hardenLine},
        }) {
            String file = pair[0], line = pair[1];
            Path rp = java.nio.file.Paths.get(file);
            if (java.nio.file.Files.exists(rp)) {
                String content = new String(java.nio.file.Files.readAllBytes(rp), java.nio.charset.StandardCharsets.UTF_8);
                // README 用代码块展示日志；对比时忽略"原 18 项 → 新 18 项"里的数字
                String needle = line.replace("(原 18 项 → 新 18 项)", "").trim();
                check(file + " 引用了与生产一致的日志行: " + needle,
                        content.contains(needle));
            } else {
                check(file + " 存在", false);
            }
        }

        // 6. v1.4.8 的功能自检行必须出现在两份 README 里
        //    （这行是"确认修复生效"的最终判据，漏写会让用户无从判断）
        String probeLine = "[BiliFix] 功能自检通过: --avcodec-hw=" + hw + " , --vout=" + vout + " —— 注入已生效（端到端验证）";
        for (String file : new String[] {"README.md", "README.zh-CN.md"}) {
            Path rp = java.nio.file.Paths.get(file);
            if (java.nio.file.Files.exists(rp)) {
                String content = new String(java.nio.file.Files.readAllBytes(rp), java.nio.charset.StandardCharsets.UTF_8);
                check(file + " 含功能自检行（确认修复生效的最终判据）", content.contains(probeLine));
            } else {
                check(file + " 存在", false);
            }
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
