import dev.polaris_fix.bilifix.BiliFixMod;
import dev.polaris_fix.bilifix.config.BiliFixConfig;

/**
 * 归一化警告探针 —— 钉住"配置归一化那条日志只在真的改了值时才出现"。
 *
 * <p><b>为什么值得一个探针</b>：那条日志是在崩溃排查时读到的，而<b>噪音警告
 * 是最坏的一种</b>——它把注意力引向一个不存在的问题。v1.4.8 前
 * {@code strategyWasNormalized()} 有 3 个假阳性，恰好覆盖两种最常见的真实情况：
 * 全新用户（配置里没有任何键）和只设了 {@code hwDecoder} 的用户。
 * 他们每次启动都会看到</p>
 *
 * <pre>[BiliFix] 配置归一化：hwDecoder 'none' → none, vout 'null' → original</pre>
 *
 * <p>——两个值都没变，却说"被改了"，还把 {@code null} 原样显示出来。
 * 本探针 13 个用例覆盖：未设置、别名、大小写、空白、未知值回退、
 * 以及 {@code keepkeep} 这种"不是别名的近似值"。</p>
 */
public class NormalizedWarningProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void expect(String hwRaw, String voutRaw, boolean wantNormalized) {
        BiliFixConfig.hwDecoder = hwRaw;
        BiliFixConfig.vout = voutRaw;
        boolean got = BiliFixMod.strategyWasNormalized();
        String[] eff = BiliFixMod.effectiveStrategy();
        String label = "hw='" + hwRaw + "' vout='" + voutRaw + "' → 生效 hw=" + eff[0]
                + " vout=" + eff[1] + (wantNormalized ? "（该说明）" : "（不该说明）");
        check(label, got == wantNormalized);
    }

    public static void main(String[] args) {
        System.out.println("Normalized warning probe (only a REAL change may warn)");

        // ---- 1. 未设置 = 未设置：不报警（修前 3 个假阳性） ----
        expect(null, null, false);
        expect(null, "gl,any", false);
        expect("none", null, false);
        expect("none", "none", false);

        // ---- 2. 真的改了值 → 该说明 ----
        expect("gpu", "original", true);          // 未知值回退
        expect("none", "keep", true);             // 别名 keep → 显示 original
        expect("none", "KEEP", true);             // 大小写
        expect("none", "  ORIGINAL  ", true);     // 大小写 + 空白
        expect(" NONE ", "original", true);       // 用户看到的字符串变了

        // ---- 3. keepkeep 不是 keep ----
        // 生效值原样是 keepkeep（落到 default），显示也是 keepkeep，
        // 既没被改写、显示也一致 —— 不该报警。
        expect("none", "keepkeep", false);

        // ---- 4. 源码级：保持探针与生产同源（读指定文件） ----
        String srcPath = (args.length > 0) ? args[0] : "src/main/java/dev/polaris_fix/bilifix/BiliFixMod.java";
        try {
            String src = new String(java.nio.file.Files.readAllBytes(java.nio.file.Path.of(srcPath)),
                    java.nio.charset.StandardCharsets.UTF_8);
            check("源码：strategyWasNormalized 不用子串 replace 别名",
                    !src.contains(".replace(\"keep\", \"original\")"));
            check("源码：策略显示 original 时把 null 映射成 original",
                    src.contains("effVout == null ? \"original\""));
        } catch (Exception e) {
            check("读取源码文件 " + srcPath, false);
        }

        BiliFixConfig.hwDecoder = "none";
        BiliFixConfig.vout = "gl,any";

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
