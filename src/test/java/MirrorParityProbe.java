import dev.polaris_fix.bilifix.config.BiliFixConfig;

/**
 * 镜像一致性探针 —— 钉住"Regression 镜像与生产行为一致"。
 *
 * <p><b>为什么需要</b>：{@code Regression.java} 是本项目的<b>独立镜像</b>测试
 * ——它自己重新实现一遍生产逻辑，不引用生产类。这样做的好处是：镜像与生产
 * 独立出错时，两者不可能同时错，测试就抓到了问题。</p>
 *
 * <p>但代价是：<b>生产行为有意改变时，镜像必须手工同步</b>。一旦忘记同步，
 * 镜像就会给出与生产<b>相反</b>的结论——这比没有镜像更糟：</p>
 * <ul>
 *   <li>有人依据镜像的断言去改生产，会把正确的修复改回去；</li>
 *   <li>有人依据镜像的失败去排查生产，方向从一开始就是错的；</li>
 *   <li>而且<b>没有任何东西会报警</b>——镜像测试全绿，因为镜像和它自己一致。</li>
 * </ul>
 *
 * <p>v1.4.8 实测到的三处分歧（探针存在之前，它们一直静默）：</p>
 * <ul>
 *   <li>{@code hwDecoder = "  ANY  "}：生产 trim 后得 {@code any}，镜像漏 trim
 *       得 {@code none}；</li>
 *   <li>{@code vout = ""}：生产回退安全默认 {@code gl,any}，镜像返回空串；</li>
 *   <li>{@code vout = "   "}：同上。</li>
 * </ul>
 *
 * <p>本探针把镜像的实现<b>复制</b>到本地（保持独立性——不反射生产类，
 * 而是把镜像自己的静态方法拿来对比），逐个输入比对两者输出。<b>不一致即失败</b>。
 * </p>
 */
public class MirrorParityProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    // ---- 镜像实现：从 Regression 反射加载，而不是在这里复制一份 ----
    //
    // 重要：本探针**必须调用 Regression 里真实的镜像实现**。如果把镜像代码
    // 复制到探针里，那么破坏 Regression 时探针察觉不到——它只会验证"我抄的
    // 那份 == 生产"，而真正在跑的 Regression 已经错了。复制一份的版本实测
    // 就是这样：破坏 Regression 的 voutMap 后，行为比对两条仍然 PASS，
    // 只有源码断言发现得了。安全网必须真的连在网���上。
    static Class<?> regressionClass;

    static Object mirrorHwValue(String s) throws Exception {
        java.lang.reflect.Method m = regressionClass.getDeclaredMethod("hwValue", String.class);
        m.setAccessible(true);
        return m.invoke(null, s);
    }

    static Object mirrorVoutValue(String s) throws Exception {
        java.lang.reflect.Method m = regressionClass.getDeclaredMethod("voutMap", String.class);
        m.setAccessible(true);
        return m.invoke(null, s);
    }

    static String norm(Object o) {
        return o == null ? "\u0000NULL" : o.toString();
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Mirror parity probe (Regression mirror vs production)");
        // 加载真正在跑的镜像实现（Regression.class 必须与本探针同在 classpath）
        regressionClass = Class.forName("Regression");

        // ---------- hwDecoder ----------
        String[] hwInputs = {
            null, "none", "disable", "off", "auto", "any", "d3d11va", "dxva2",
            "NONE", "  NONE  ", "  ANY  ", "  any  ", "Auto", "  D3D11VA ",
            "garbage", "", "   ", "  auto  ", "any ", " none"
        };
        int hwDiff = 0;
        StringBuilder hwDetail = new StringBuilder();
        for (String in : hwInputs) {
            BiliFixConfig.hwDecoder = in;
            String prod = BiliFixConfig.hwDecoderValue();
            Object mir = mirrorHwValue(in);
            if (!norm(prod).equals(norm(mir))) {
                hwDiff++;
                hwDetail.append("      input=[").append(in == null ? "null" : in)
                        .append("] prod=").append(prod).append(" mirror=").append(mir).append('\n');
            }
        }
        check("hwDecoder：镜像与生产在 " + hwInputs.length + " 个输入上完全一致" + (hwDiff == 0 ? "" : "（分歧 " + hwDiff + " 处）"),
                hwDiff == 0);
        if (hwDiff > 0) System.out.print(hwDetail);

        // ---------- vout ----------
        String[] voutInputs = {
            null, "original", "keep", "ORIGINAL", "  original  ", "  keep  ",
            "gl,any", "GL,ANY", "  gl,any  ", "gl,any ", "garbage", "", "   ",
            "\t", "direct3d11,glwin32,gl,any"
        };
        int voutDiff = 0;
        StringBuilder voutDetail = new StringBuilder();
        for (String in : voutInputs) {
            BiliFixConfig.vout = in;
            String prod = BiliFixConfig.voutValue();
            Object mir = mirrorVoutValue(in);
            if (!norm(prod).equals(norm(mir))) {
                voutDiff++;
                voutDetail.append("      input=[").append(in == null ? "null" : in)
                        .append("] prod=").append(prod == null ? "null" : "[" + prod + "]")
                        .append(" mirror=").append(mir == null ? "null" : "[" + mir + "]").append('\n');
            }
        }
        check("vout：镜像与生产在 " + voutInputs.length + " 个输入上完全一致" + (voutDiff == 0 ? "" : "（分歧 " + voutDiff + " 处）"),
                voutDiff == 0);
        if (voutDiff > 0) System.out.print(voutDetail);

        // ---------- 具体契约：vout 空值必须回退安全默认 ----------
        BiliFixConfig.vout = "";
        check("契约：生产 vout 空串 → gl,any（不是空串）",
                "gl,any".equals(BiliFixConfig.voutValue()));
        BiliFixConfig.vout = "   ";
        check("契约：生产 vout 纯空白 → gl,any",
                "gl,any".equals(BiliFixConfig.voutValue()));
        BiliFixConfig.vout = "original";
        check("契约：生产 vout original → null（保留原值）",
                BiliFixConfig.voutValue() == null);
        BiliFixConfig.vout = "gl,any";
        check("契约：生产 vout gl,any → gl,any",
                "gl,any".equals(BiliFixConfig.voutValue()));

        BiliFixConfig.hwDecoder = "none";
        BiliFixConfig.vout = "gl,any";

        // ---------- 源码级：Regression 里的镜像必须与本探针的镜像一致 ----------
        // NOTE: 源码断言必须以**文件路径为参数**传入 —— 读取工作副本会让断言
        // 检查到未还原的文件，对坏代码也 PASS（此前已踩过一次）。
        String srcPath = (args.length > 0) ? args[0] : "src/test/java/Regression.java";
        String src = new String(java.nio.file.Files.readAllBytes(java.nio.file.Path.of(srcPath)),
                java.nio.charset.StandardCharsets.UTF_8);
        check("源码：Regression 的 voutMap 有空值回退",
                src.contains("v.isEmpty() ? \"gl,any\" : v"));
        check("源码：Regression 的 hwValue 做了 trim",
                src.contains("s.toLowerCase().trim()"));

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
