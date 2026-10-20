import dev.polaris_fix.bilifix.CrashSentinel;
import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * 探针：取证文件里的策略行必须是人类可读、与实际生效一致的。
 *
 * <p><b>缺陷背景（v1.4.8 修复）</b>：{@code writeDiagnostic} 与
 * {@code markSessionStart} 直接写 {@code voutValue()} 的返回值。用户显式配置
 * {@code vout = "original"}（或 {@code keep}）时它返回 {@code null}——含义是
 * "保留 watermedia 原值"，但文件里就写成了 {@code vout=null}，用户会以为
 * 配置丢失或损坏。实测（修复前）：</p>
 *
 * <pre>
 *   vout=gl,any   -> strategy: hw=none, vout=gl,any
 *   vout=original -> strategy: hw=none, vout=null     ← 误导
 *   vout=keep     -> strategy: hw=none, vout=null     ← 误导
 *   vout=ORIGINAL -> strategy: hw=none, vout=null     ← 误导
 * </pre>
 *
 * <p>诊断文件 {@code bilifix-diagnostic.txt} 是原生崩溃后 Java 侧<b>唯一</b>
 * 留下的东西，用户会照它排查——显示形式必须让用户读得懂。</p>
 */
public class ForensicsVoutProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Forensics vout display probe");
        Path game = Files.createTempDirectory("forensics-vout");
        CrashSentinel.setGameDir(game);
        Class<?> cs = Class.forName("dev.polaris_fix.bilifix.CrashSentinel");
        Method m = cs.getDeclaredMethod("writeDiagnostic", Path.class);
        m.setAccessible(true);

        // (1) vout=original / keep / ORIGINAL → 诊断文件显示 original，不显示 null
        for (String vout : new String[]{"original", "keep", "ORIGINAL"}) {
            BiliFixConfig.hwDecoder = "none";
            BiliFixConfig.vout = vout;
            m.invoke(null, game);
            String txt = Files.readString(game.resolve("bilifix-diagnostic.txt"), StandardCharsets.UTF_8);
            String line = "";
            for (String l : txt.split("\\R")) if (l.startsWith("strategy:")) line = l.trim();
            check("vout=" + vout + " → 诊断文件显示 original（而非 null）",
                    line.equals("strategy: hw=none, vout=original"));
            check("vout=" + vout + " → 诊断文件不含 vout=null",
                    !txt.contains("vout=null"));
        }

        // (2) 普通 vout 值原样显示
        BiliFixConfig.hwDecoder = "none";
        BiliFixConfig.vout = "gl,any";
        m.invoke(null, game);
        {
            String txt = Files.readString(game.resolve("bilifix-diagnostic.txt"), StandardCharsets.UTF_8);
            check("vout=gl,any → 原样显示", txt.contains("strategy: hw=none, vout=gl,any"));
        }

        // (3) session lock（下次启动要读的文件）同样修复
        {
            BiliFixConfig.vout = "original";
            CrashSentinel.markSessionStart(game);
            String lock = Files.readString(game.resolve("bilifix-session.lock"), StandardCharsets.UTF_8);
            check("session lock: vout=original → 显示 original", lock.contains("vout=original"));
            check("session lock: 不含 vout=null", !lock.contains("vout=null"));
        }

        // (4) 源码级：诊断与会话文件不再直写 voutValue()（必须经过 strategyVout）
        {
            Path src = args.length > 0 ? Path.of(args[0])
                    : Path.of("src", "main", "java", "dev", "polaris_fix", "bilifix", "CrashSentinel.java");
            String s = Files.readString(src, StandardCharsets.UTF_8);
            check("源码: strategyVout() 存在且含 null → original 映射",
                    s.contains("private static String strategyVout()"));
            check("源码: writeDiagnostic/markSessionStart 走 strategyVout()",
                    s.contains("vout=\" + strategyVout()"));
            // 两个调用点都不应再直写 voutValue()
            int diag = s.indexOf("private static void writeDiagnostic");
            int lockAt = s.indexOf("public static void markSessionStart");
            boolean clean = true;
            if (diag > 0) {
                String seg = s.substring(diag, s.indexOf("private static Path gameDirectory()", diag));
                clean &= !seg.contains("BiliFixConfig.voutValue()");
            }
            if (lockAt > 0) {
                String seg = s.substring(lockAt, s.indexOf("private static void writeDiagnostic", lockAt));
                clean &= !seg.contains("BiliFixConfig.voutValue()");
            }
            check("源码: 两个写入点都不再直写 voutValue()", clean);
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
