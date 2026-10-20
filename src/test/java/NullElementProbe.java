import dev.polaris_fix.bilifix.mixin.JarToolMixin;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.lang.reflect.Method;

/**
 * 探针：参数数组里的 null 元素绝不能让加固逻辑抛 NPE。
 *
 * <p><b>缺陷背景（v1.4.8 修复）</b>：{@code bilifix$makeArgsSafe} 的循环里
 * {@code switch (arg)} 对 null 元素抛
 * {@code NullPointerException: Cannot invoke "String.hashCode()"}。
 * 真实的 {@code videolan/arguments.json} 经 Gson 解析不会有 null 元素，但
 * {@code JarTool.readArray} 是<b>通用</b>方法——watermedia 将来用它读别的
 * JSON，其值完全可以含 null。</p>
 *
 * <p><b>后果不可接受</b>：本 mixin 是"绝对安全的加固点"，一个 NPE 从这里
 * 冒进 watermedia 的 {@code PlayerAPI.start()} 会让<b>媒体播放直接失败</b>——
 * 加固点反而成了故障源。</p>
 *
 * <p>修复语义：null 元素<b>丢弃</b>（它不可能是有效的 VLC 参数；且若它正好
 * 落在某个选项的值位置，保留它会让该选项读到 null 值）。
 * {@code isValue(null)} 也必须返回 false（而不是 NPE），这样
 * {@code skipOldValue} 与 vout 的原值保留分支才不会因 null 值崩溃。</p>
 */
public class NullElementProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static String[] rewrite(String[] input) throws Exception {
        Method m = JarToolMixin.class.getDeclaredMethod(
                "bilifix$makeArgsSafe", String.class, CallbackInfoReturnable.class);
        m.setAccessible(true);
        CallbackInfoReturnable<String[]> cir = new CallbackInfoReturnable<>("readArray", true, input);
        m.invoke(null, "videolan/arguments.json", cir);
        return cir.getReturnValue();
    }

    /**
     * 改写并把异常转成"失败"而不是让探针自己崩掉。
     *
     * <p>关键：坏代码会让 mixin 抛 NPE。若探针不接住，探针自己以异常退出，
     * 只能看到"exit 1"而看不到<b>哪条断言</b>失败——负向测试的输出会变得
     * 难以判读。这里接住异常并记成一条失败断言。</p>
     */
    static String[] rewriteSafely(String[] input) {
        try {
            return rewrite(input);
        } catch (Throwable t) {
            Throwable c = (t instanceof java.lang.reflect.InvocationTargetException) ? t.getCause() : t;
            lastError = c;
            return null;
        }
    }

    static Throwable lastError;

    static void setConfig(String hw, String vout) throws Exception {
        java.lang.reflect.Field fHw = dev.polaris_fix.bilifix.config.BiliFixConfig.class.getDeclaredField("hwDecoder");
        java.lang.reflect.Field fVout = dev.polaris_fix.bilifix.config.BiliFixConfig.class.getDeclaredField("vout");
        java.lang.reflect.Field fVer = dev.polaris_fix.bilifix.config.BiliFixConfig.class.getDeclaredField("verbose");
        fHw.setAccessible(true); fVout.setAccessible(true); fVer.setAccessible(true);
        fHw.set(null, hw); fVout.set(null, vout); fVer.set(null, false);
    }

    static int count(String[] arr, String s) {
        int n = 0;
        if (arr == null) return 0;
        for (String a : arr) if (java.util.Objects.equals(a, s)) n++;
        return n;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Null element probe (production JarToolMixin)");
        setConfig("none", "gl,any");

        // 1. 核心场景：null 元素夹在参数中间 —— 绝不能抛 NPE，且安全值照常生效
        {
            lastError = null; String[] r = rewriteSafely(new String[]{
                    "--avcodec-hw", "d3d11va", null, "--vout", "direct3d11,glwin32,gl,any", "--fullscreen"});
            check("含 null 元素 → 不抛 NPE（返回非 null）", r != null && lastError == null);
            check("null 元素被丢弃（结果里没有 null）",
                    r != null && !Arrays_hasNull(r));
            if (lastError != null) System.out.println("      (异常: " + lastError + ")");
            check("null 旁边 --avcodec-hw 仍被改为 none", count(r, "none") == 1);
            check("null 旁边 --vout 仍被改为 gl,any", count(r, "gl,any") == 1);
            check("d3d11va 不残留", count(r, "d3d11va") == 0);
        }

        // 2. null 在值位置：--avcodec-hw 后面跟 null
        {
            lastError = null; String[] r = rewriteSafely(new String[]{"--avcodec-hw", null, "--vout", "gl,any"});
            check("null 值位置 → 不抛 NPE", r != null && lastError == null);
            if (lastError != null) System.out.println("      (异常: " + lastError + ")");
            check("null 值位置 → --avcodec-hw 的值是 none（坏值被安全值顶替）",
                    r != null && count(r, "none") == 1);
            check("null 值位置 → 无 null 残留", r != null && !Arrays_hasNull(r));
        }

        // 3. null 在 --vout 值位置（vout=original 场景）
        {
            setConfig("none", "original");
            lastError = null; String[] r = rewriteSafely(new String[]{"--vout", null, "--fullscreen"});
            check("vout=original + null 值 → 不抛 NPE", r != null && lastError == null);
            if (lastError != null) System.out.println("      (异常: " + lastError + ")");
            check("vout=original + null 值 → 无 null 残留", r != null && !Arrays_hasNull(r));
            check("vout=original + null 值 → --vout 仍在", r != null && count(r, "--vout") == 1);
            setConfig("none", "gl,any");
        }

        // 4. 全 null 数组
        {
            lastError = null; String[] r = rewriteSafely(new String[]{null, null});
            check("全 null 数组 → 不抛 NPE", r != null && lastError == null);
            if (lastError != null) System.out.println("      (异常: " + lastError + ")");
            check("全 null 数组 → 结果只含补加的安全值", r != null && r.length >= 2 && !Arrays_hasNull(r));
        }

        // 5. 源码级：循环开头必须有 null 防御（防止未来重构把它删了）
        {
            java.nio.file.Path src = args.length > 0 ? java.nio.file.Path.of(args[0])
                    : java.nio.file.Path.of("src", "main", "java", "dev", "polaris_fix", "bilifix", "mixin", "JarToolMixin.java");
            String s = java.nio.file.Files.readString(src);
            check("源码: isValue 对 null 返回 false（s != null &&）", s.contains("s != null && !s.startsWith"));
            check("源码: 循环里有 null 防御（continue）", s.contains("if (arg == null) continue;"));
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 0");
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }

    static boolean Arrays_hasNull(String[] arr) {
        for (String a : arr) if (a == null) return true;
        return false;
    }
}
