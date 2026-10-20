import dev.polaris_fix.bilifix.config.BiliFixConfig;
import dev.polaris_fix.bilifix.mixin.JarToolMixin;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;

/**
 * 探针：直接执行生产的参数改写逻辑。
 *
 * 缺口背景：
 * - {@code Regression} 是**独立镜像**，不链接生产类 → 抓不到生产代码自身的 bug
 * - {@code ReadmeLogSampleProbe} 只校验日志**字符串**是否与源码一致 → 不执行改写逻辑
 * - 也就是说，{@code JarToolMixin}（整个修复的核心！）此前**没有任何探针真正跑过
 *   它的改写逻辑**
 *
 * 本探针反射调用生产的 {@code bilifix$makeArgsSafe(String, CallbackInfoReturnable)}，
 * 用真实的 {@code CallbackInfoReturnable} 走完整条路径。
 *
 * 覆盖的分支：
 * - "--key value" 与 "--key=value" 两种 VLC 写法
 * - --avcodec-hw 旧值被丢弃、新值写入
 * - --vout 保留原值（配置 vout=original）时原样透传
 * - 参数表里没有 --avcodec-hw / --vout 时主动追加
 * - 非 videolan/arguments 资源不处理
 * - null / 空数组不处理
 * - 关键安全属性：改写后**不得**残留 d3d11va / dxva2 / direct3d11
 */
public class ArgumentRewriteProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }

    /** 反射调用生产的改写方法 */
    static String[] rewrite(String resource, String[] input) throws Exception {
        Method m = JarToolMixin.class.getDeclaredMethod(
                "bilifix$makeArgsSafe", String.class, CallbackInfoReturnable.class);
        m.setAccessible(true);
        // cancellable 必须为 true：CallbackInfoReturnable.setReturnValue() 内部会先
        // 调用 cancel()，而 cancel() 在非 cancellable 时抛 CancellationException。
        // 生产 mixin 声明的正是 cancellable = true，所以这里必须与之一致。
        CallbackInfoReturnable<String[]> cir = new CallbackInfoReturnable<>("readArray", true, input);
        m.invoke(null, resource, cir);
        return cir.getReturnValue();
    }

    /** 生产配置：改写用的 hw/vout 取自 BiliFixConfig，这里设置成确定值 */
    static void setConfig(String hw, String vout, boolean verbose) throws Exception {
        java.lang.reflect.Field fHw = BiliFixConfig.class.getDeclaredField("hwDecoder");
        java.lang.reflect.Field fVout = BiliFixConfig.class.getDeclaredField("vout");
        java.lang.reflect.Field fVer = BiliFixConfig.class.getDeclaredField("verbose");
        fHw.setAccessible(true); fVout.setAccessible(true); fVer.setAccessible(true);
        fHw.set(null, hw); fVout.set(null, vout); fVer.set(null, verbose);
    }

    static boolean contains(String[] arr, String s) {
        return Arrays.asList(arr).contains(s);
    }

    static int indexOf(String[] arr, String s) {
        return Arrays.asList(arr).indexOf(s);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Argument rewrite probe (production JarToolMixin)");

        // 1. 默认配置（hw=none, vout=gl,any）下的核心改写
        setConfig("none", "gl,any", false);
        String[] in = {
                "--no-video-title-show", "--network-caching=300", "--avcodec-hw", "d3d11va,dxva2,any",
                "--vout", "direct3d11,glwin32,gl,any", "--fullscreen"
        };
        String[] out = rewrite("videolan/arguments.json", in);

        check("返回非 null", out != null);
        check("--avcodec-hw 仍是独立一项", contains(out, "--avcodec-hw"));
        check("--avcodec-hw 的值已改为 none",
                indexOf(out, "--avcodec-hw") >= 0 && indexOf(out, "--avcodec-hw") + 1 < out.length
                        && "none".equals(out[indexOf(out, "--avcodec-hw") + 1]));
        check("--vout 的值已改为 gl,any",
                indexOf(out, "--vout") >= 0 && indexOf(out, "--vout") + 1 < out.length
                        && "gl,any".equals(out[indexOf(out, "--vout") + 1]));
        check("旧值 d3d11va,dxva2,any 已丢弃", !contains(out, "d3d11va,dxva2,any"));
        check("旧值 direct3d11,glwin32,gl,any 已丢弃", !contains(out, "direct3d11,glwin32,gl,any"));
        check("其余参数原样保留（--no-video-title-show）", contains(out, "--no-video-title-show"));
        check("其余参数原样保留（--network-caching=300）", contains(out, "--network-caching=300"));
        check("其余参数原样保留（--fullscreen）", contains(out, "--fullscreen"));
        check("项数不变（旧值被替换而非叠加）", out.length == in.length);

        // 安全属性（最关键的一条）：改写后不得残留任何危险硬解/输出参数
        for (String s : out) {
            String lower = s.toLowerCase();
            check("改写后不含 d3d11va（实际: " + s + "）", !lower.contains("d3d11va"));
            check("改写后不含 dxva2（实际: " + s + "）", !lower.contains("dxva2"));
            check("改写后不含 direct3d11（实际: " + s + "）", !lower.contains("direct3d11"));
        }

        // 2. "--key=value" 写法
        String[] in2 = {"--avcodec-hw=d3d11va,dxva2,any", "--vout=direct3d11,glwin32,gl,any", "--x=1"};
        String[] out2 = rewrite("videolan/arguments.json", in2);
        check("= 写法：--avcodec-hw=none", contains(out2, "--avcodec-hw=none"));
        check("= 写法：--vout=gl,any", contains(out2, "--vout=gl,any"));
        check("= 写法：旧 d3d11va 值已丢弃", !contains(out2, "--avcodec-hw=d3d11va,dxva2,any"));
        check("= 写法：旧 direct3d11 值已丢弃", !contains(out2, "--vout=direct3d11,glwin32,gl,any"));
        check("= 写法：其他参数保留", contains(out2, "--x=1"));
        check("= 写法：项数不变", out2.length == in2.length);

        // 3. 参数表里没有 --avcodec-hw / --vout 时主动追加
        String[] in3 = {"--only-one=1"};
        String[] out3 = rewrite("videolan/arguments.json", in3);
        check("缺 --avcodec-hw 时主动追加", contains(out3, "--avcodec-hw"));
        check("追加的 --avcodec-hw 值为 none",
                indexOf(out3, "--avcodec-hw") >= 0 && indexOf(out3, "--avcodec-hw") + 1 < out3.length
                        && "none".equals(out3[indexOf(out3, "--avcodec-hw") + 1]));
        check("缺 --vout 时主动追加", contains(out3, "--vout"));
        check("追加的 --vout 值为 gl,any",
                indexOf(out3, "--vout") >= 0 && indexOf(out3, "--vout") + 1 < out3.length
                        && "gl,any".equals(out3[indexOf(out3, "--vout") + 1]));
        check("追加后原参数仍在", contains(out3, "--only-one=1"));

        // 4. vout=original：保留原值不动
        setConfig("none", "original", false);
        String[] in4 = {"--avcodec-hw", "d3d11va,dxva2,any", "--vout", "direct3d11,glwin32,gl,any"};
        String[] out4 = rewrite("videolan/arguments.json", in4);
        check("vout=original：--vout 保留原值",
                indexOf(out4, "--vout") >= 0 && indexOf(out4, "--vout") + 1 < out4.length
                        && "direct3d11,glwin32,gl,any".equals(out4[indexOf(out4, "--vout") + 1]));
        check("vout=original：--avcodec-hw 仍被加固为 none",
                indexOf(out4, "--avcodec-hw") >= 0 && indexOf(out4, "--avcodec-hw") + 1 < out4.length
                        && "none".equals(out4[indexOf(out4, "--avcodec-hw") + 1]));
        check("vout=original：未出现重复的 --vout", countOf(out4, "--vout") == 1);
        check("vout=original：项数不变", out4.length == in4.length);

        setConfig("none", "gl,any", false);

        // 5. 非 videolan/arguments 资源不处理
        String[] in5 = {"--avcodec-hw", "d3d11va,dxva2,any"};
        String[] out5 = rewrite("some/other/file.json", in5);
        check("非 arguments 资源：数组原样返回", Arrays.equals(in5, out5));

        // 6. null / 空数组不处理
        check("null 资源：原样返回", Arrays.equals(in5, rewrite(null, in5)));
        check("空数组：原样返回", rewrite("videolan/arguments.json", new String[0]).length == 0);

        // 7. 源码级：改写逻辑必须在生产 mixin 里
        String src = new String(Files.readAllBytes(Paths.get("src", "main", "java", "dev",
                "polaris_fix", "bilifix", "mixin", "JarToolMixin.java")),
                java.nio.charset.StandardCharsets.UTF_8);
        check("生产 mixin 含 @Inject(method = \"readArray\")", src.contains("method = \"readArray\""));
        check("生产 mixin 含 @At(\"RETURN\")", src.contains("@At(\"RETURN\")"));
        check("生产 mixin 含 cancellable = true", src.contains("cancellable = true"));
        check("生产 mixin 含 @Pseudo", src.contains("@Pseudo"));

        // 8. 配置映射分支：hwDecoderValue() / voutValue() 的全部别名
        //    （这决定了"用户改配置后会发生什么"，此前无任何探针覆盖）
        //    生产只暴露无参版本：先写字段，再读值——走的是真实代码路径。
        check("hwDecoder=disable → none", hwValue("disable").equals("none"));
        check("hwDecoder=none → none", hwValue("none").equals("none"));
        check("hwDecoder=off → none", hwValue("off").equals("none"));
        check("hwDecoder=  NONE  （大小写+空白）→ none", hwValue("  NONE  ").equals("none"));
        check("hwDecoder=auto → any", hwValue("auto").equals("any"));
        check("hwDecoder=any → any", hwValue("any").equals("any"));
        check("hwDecoder=d3d11va → d3d11va（用户显式要求时照办）",
                hwValue("d3d11va").equals("d3d11va"));
        check("hwDecoder=dxva2 → dxva2", hwValue("dxva2").equals("dxva2"));
        check("hwDecoder=未知值 → 回退 none（安全默认）", hwValue("garbage").equals("none"));
        check("hwDecoder=null → none", hwValue(null).equals("none"));

        check("vout=original → null（保留原值）", voutValue("original") == null);
        check("vout=keep → null（保留原值）", voutValue("keep") == null);
        check("vout=ORIGINAL（大小写）→ null", voutValue("ORIGINAL") == null);
        check("vout=  original  （空白）→ null", voutValue("  original  ") == null);
        check("vout=gl,any → gl,any", "gl,any".equals(voutValue("gl,any")));
        check("vout=GL,ANY → 小写化", "gl,any".equals(voutValue("GL,ANY")));
        // v1.4.8：空串此前原样返回，会让 mixin 写出 `--vout ""`——一个空的视频
        // 输出模块名交给 libVLC。不崩，只是没画面，比崩溃更隐蔽（用户会怪
        // watermedia）。hwDecoder 早就回退安全默认了，两个字段行为必须一致。
        check("vout=空串 → 回退安全默认 gl,any（不是空串！）",
                "gl,any".equals(voutValue("")));
        check("vout=纯空白 → 回退安全默认 gl,any",
                "gl,any".equals(voutValue("   ")));
        check("vout=null → null（保留原值）", voutValue(null) == null);

        // 9. 配置为空串时不得崩（生产 load() 允许空值落盘）
        setConfig("", "", false);
        String[] out9 = rewrite("videolan/arguments.json",
                new String[]{"--avcodec-hw", "d3d11va,dxva2,any", "--vout", "direct3d11,glwin32,gl,any"});
        check("空配置：不抛异常且返回非 null", out9 != null);
        check("空配置：--avcodec-hw 仍被替换（值随配置）", contains(out9, "--avcodec-hw"));
        check("空配置：旧 d3d11va 值已丢弃", !contains(out9, "d3d11va,dxva2,any"));
        // v1.4.8：这一组此前**只查了 hw**，vout 漏了——于是"空 vout 会写出
        // --vout ''"这个缺陷在探针里毫无痕迹。补上。
        check("空配置：--vout 的值不是空串（不能把空模块名交给 libVLC）",
                indexOf(out9, "--vout") >= 0
                        && indexOf(out9, "--vout") + 1 < out9.length
                        && !out9[indexOf(out9, "--vout") + 1].isEmpty());
        check("空配置：--vout 回退到安全默认 gl,any",
                indexOf(out9, "--vout") >= 0
                        && indexOf(out9, "--vout") + 1 < out9.length
                        && "gl,any".equals(out9[indexOf(out9, "--vout") + 1]));
        check("空配置：旧的 direct3d11 vout 值已丢弃",
                !contains(out9, "direct3d11,glwin32,gl,any"));
        setConfig("none", "gl,any", false);

        // 10. hwDecoder=auto（用户显式要硬解）时，参数里应出现 any 而不是 none
        setConfig("auto", "gl,any", false);
        String[] out10 = rewrite("videolan/arguments.json",
                new String[]{"--avcodec-hw", "d3d11va,dxva2,any"});
        check("hwDecoder=auto → --avcodec-hw 值为 any",
                indexOf(out10, "--avcodec-hw") >= 0 && indexOf(out10, "--avcodec-hw") + 1 < out10.length
                        && "any".equals(out10[indexOf(out10, "--avcodec-hw") + 1]));
        check("hwDecoder=auto：旧 d3d11va 值仍被丢弃", !contains(out10, "d3d11va,dxva2,any"));
        setConfig("none", "gl,any", false);

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }

    static int countOf(String[] arr, String s) {
        int n = 0;
        for (String a : arr) if (s.equals(a)) n++;
        return n;
    }

    /** 写入 hwDecoder 字段后读回生产算出的值（走真实代码路径） */
    static String hwValue(String raw) throws Exception {
        setConfig(raw, "gl,any", false);
        return BiliFixConfig.hwDecoderValue();
    }

    /** 写入 vout 字段后读回生产算出的值（走真实代码路径） */
    static String voutValue(String raw) throws Exception {
        setConfig("none", raw, false);
        return BiliFixConfig.voutValue();
    }
}
