import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * 真实参数表探针 —— 用 watermedia **真实 jar 里**的参数表形状验证改写。
 *
 * <p><b>为什么需要这一层</b>：此前所有关于参数表的断言都基于<b>手写的假数据</b>
 * （stub 返回的数组）。假数据只能证明"改写逻辑对假数据成立"，证明不了
 * "对 watermedia 真的给的那份参数表成立"。而整个修复的价值全押在这份表上。</p>
 *
 * <p><b>实测的真实参数表</b>（watermedia 2.1.36 jar 里的
 * {@code videolan/arguments.json}，2026-10-21 用 {@code javap} + zip 读取确认）：</p>
 *
 * <pre>
 * "--no-quiet",
 * "--cr-average=5000", "--swscale-mode=0",
 * "--network-synchronisation", "--network-caching=1000",
 * "--live-caching=1000", "--file-caching=1000",
 * "--aout", "directsound,waveout,mmdevice",
 * "--vout", "direct3d11,glwin32,gl,any",
 * "--avcodec-skip-idct=4", "--avcodec-fast",
 * "--avcodec-hw", "d3d11va,dxva2,any",
 * "--no-metadata-network-access", "--no-file-logging", "--http-reconnect"
 * </pre>
 *
 * <p>这就是<b>根因本身</b>：{@code --vout direct3d11,...} 首选 D3D11 vout，
 * {@code --avcodec-hw d3d11va,dxva2,any} 强制硬解。D3D11VA 的解码表面经 vlcj
 * 回调拷回 Java 堆时，原生层会直接崩溃并杀死整个 JVM（退出码 -1、无 Java 堆栈）。</p>
 *
 * <p>另一个实测事实：{@code videolan/arguments_linux.json} <b>根本没有</b>
 * {@code --vout} 与 {@code --avcodec-hw}——这正是 mixin 里"参数表中没有就主动
 * 追加"的分支存在的理由。本探针一并覆盖这个形状。</p>
 *
 * <p><b>本探针不加载真实 jar</b>（37 MB，且依赖 gson 与 native 库），
 * 而是把<b>从真实 jar 里读出来的参数表</b>固定在这里当装置——这样它在 CI 上
 * 也能跑。参数表本身是记录下来的证据，见本类的 javadoc。</p>
 */
public class RealArgumentsProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    /** watermedia 2.1.36 的 videolan/arguments.json，原样。 */
    static final String[] REAL_WINDOWS_ARGS = {
        "--no-quiet",
        "--cr-average=5000",
        "--swscale-mode=0",
        "--network-synchronisation",
        "--network-caching=1000",
        "--live-caching=1000",
        "--file-caching=1000",
        "--aout", "directsound,waveout,mmdevice",
        "--vout", "direct3d11,glwin32,gl,any",
        "--avcodec-skip-idct=4",
        "--avcodec-fast",
        "--avcodec-hw", "d3d11va,dxva2,any",
        "--no-metadata-network-access",
        "--no-file-logging",
        "--http-reconnect"
    };

    /** watermedia 2.1.36 的 videolan/arguments_linux.json，原样（没有 vout / avcodec-hw）。 */
    static final String[] REAL_LINUX_ARGS = {
        "--no-quiet",
        "--network-synchronisation",
        "--network-caching=1000",
        "--live-caching=1000",
        "--file-caching=1000",
        "--no-metadata-network-access",
        "--no-file-logging",
        "--http-reconnect"
    };

    // ---------- 改写：直接调用生产的 JarToolMixin（不抄一份） ----------
    //
    // 这里**必须**走生产代码：此前本文件里有一份手抄的 rewrite()，
    // 那正是"镜像漂移"的病根——生产改了规则，副本不会跟着改，
    // 于是探针对着过期副本说 PASS，而生产已经坏了。
    // ArgumentRewriteProbe 同样反射调用生产，两者走同一条路径。

    static String[] rewrite(String[] original, String hw, String vout) throws Exception {
        setConfig(hw, vout);
        java.lang.reflect.Method m = Class.forName("dev.polaris_fix.bilifix.mixin.JarToolMixin")
                .getDeclaredMethod("bilifix$makeArgsSafe", String.class,
                        org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable.class);
        m.setAccessible(true);
        org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable<String[]> cir =
                new org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable<>("readArray", true, original);
        m.invoke(null, "videolan/arguments.json", cir);
        return cir.getReturnValue();
    }

    /** 生产配置：改写用的 hw/vout 取自 BiliFixConfig。 */
    static void setConfig(String hw, String vout) throws Exception {
        java.lang.reflect.Field fHw = BiliFixConfig.class.getDeclaredField("hwDecoder");
        java.lang.reflect.Field fVout = BiliFixConfig.class.getDeclaredField("vout");
        java.lang.reflect.Field fVer = BiliFixConfig.class.getDeclaredField("verbose");
        fHw.setAccessible(true); fVout.setAccessible(true); fVer.setAccessible(true);
        fHw.set(null, hw); fVout.set(null, vout); fVer.set(null, false);
    }

    static String valueOf(String[] args, String key) {
        for (int i = 0; i < args.length; i++) {
            if (key.equals(args[i]) && i + 1 < args.length) return args[i + 1];
            if (args[i] != null && args[i].startsWith(key + "=")) return args[i].substring(key.length() + 1);
        }
        return null;
    }

    static boolean contains(String[] args, String needle) {
        for (String a : args) if (needle.equals(a)) return true;
        return false;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Real arguments probe (the parameter table watermedia actually ships)");

        // ================= 1. Windows 真实参数表 =================
        String[] fixed = rewrite(REAL_WINDOWS_ARGS, "none", "gl,any");

        check("真实表：--avcodec-hw 变成 none（软解，绕开 D3D11VA 拷贝回 Java 堆）",
                "none".equals(valueOf(fixed, "--avcodec-hw")));
        check("真实表：--vout 变成 gl,any（去掉 D3D11 vout 偏好）",
                "gl,any".equals(valueOf(fixed, "--vout")));
        check("真实表：危险值 d3d11va,dxva2,any 不再出现",
                !contains(fixed, "d3d11va,dxva2,any"));
        check("真实表：危险值 direct3d11,glwin32,gl,any 不再出现",
                !contains(fixed, "direct3d11,glwin32,gl,any"));
        check("真实表：其余参数原样保留（--no-quiet）", contains(fixed, "--no-quiet"));
        check("真实表：其余参数原样保留（--aout）", contains(fixed, "--aout"));
        check("真实表：其余参数原样保留（--http-reconnect）", contains(fixed, "--http-reconnect"));
        check("真实表：参数数量不变（改写是替换，不是增删）",
                fixed.length == REAL_WINDOWS_ARGS.length);
        check("真实表：--avcodec-hw 恰好出现一次", count(fixed, "--avcodec-hw") == 1);
        check("真实表：--vout 恰好出现一次", count(fixed, "--vout") == 1);
        check("真实表：没有残留 d3d11va 字样",
                !String.join(" ", fixed).contains("d3d11va"));

        // ================= 2. Linux 真实参数表（没有 vout / avcodec-hw） =================
        String[] linuxFixed = rewrite(REAL_LINUX_ARGS, "none", "gl,any");
        check("Linux 真实表：主动追加 --avcodec-hw none", "none".equals(valueOf(linuxFixed, "--avcodec-hw")));
        check("Linux 真实表：主动追加 --vout gl,any", "gl,any".equals(valueOf(linuxFixed, "--vout")));
        check("Linux 真实表：原参数全部保留（--no-quiet）", contains(linuxFixed, "--no-quiet"));
        check("Linux 真实表：原参数全部保留（--file-caching=1000）",
                contains(linuxFixed, "--file-caching=1000"));
        check("Linux 真实表：参数数量 = 原 + 4（两组各加 2 项）",
                linuxFixed.length == REAL_LINUX_ARGS.length + 4);

        // ================= 3. vout=original：保留原值 =================
        String[] keep = rewrite(REAL_WINDOWS_ARGS, "none", null);
        check("vout=original：--vout 保留原值 direct3d11,glwin32,gl,any",
                "direct3d11,glwin32,gl,any".equals(valueOf(keep, "--vout")));
        check("vout=original：--avcodec-hw 仍被改为 none（两条独立）",
                "none".equals(valueOf(keep, "--avcodec-hw")));
        check("vout=original：参数数量不变", keep.length == REAL_WINDOWS_ARGS.length);

        // ================= 4. 设备级证据：真实 jar 的签名 =================
        // 真实 jar 里的 readArray 签名（2026-10-21 javap 实测）：
        //   public static java.lang.String[] readArray(java.lang.String) throws java.io.IOException;
        // 以及 PlayerAPI.<clinit> 里确实是 invokestatic readArray -> registerFactory。
        // 这里固化这两条事实，防止有人"改签名"时无人察觉。
        String jarPath = (args.length > 0) ? args[0] : null;
        if (jarPath != null && Files.exists(Path.of(jarPath))) {
            String cp = readConstantPoolText(jarPath, "org/watermedia/core/tools/JarTool.class");
            // 常量池里存的是**分离**的 UTF-8 常量：方法名 "readArray" 与描述符
            // "(Ljava/lang/String;)[Ljava/lang/String;"，不是拼接好的完整签名。
            // 所以这里查两段，而不是查一整句——查一整句永远查不到。
            check("真实 jar：JarTool 里有 readArray 方法", cp.contains("readArray"));
            check("真实 jar：readArray 描述符是 (String) -> String[]",
                    cp.contains("(Ljava/lang/String;)[Ljava/lang/String;"));
            check("真实 jar：readArray 是 static（方法名常量前有 ACC_STATIC 标记）",
                    isStaticMethod(jarPath, "org/watermedia/core/tools/JarTool.class", "readArray"));
            check("真实 jar：PlayerAPI 确实调用 readArray（不是 readArrayAndParse）",
                    readPlayerApiUses(jarPath));
            // 更强的一条：readArrayAndParse 是另一个重载，若 PlayerAPI 走的是它，
            // 我们的 Mixin（method = "readArray"）就打空了。
            String pa = readConstantPoolText(jarPath, "org/watermedia/api/player/PlayerAPI.class");
            check("真实 jar：PlayerAPI 没有引用 readArrayAndParse（我们的 Mixin 打的就是这条路）",
                    !pa.contains("readArrayAndParse"));
        } else {
            System.out.println("  [SKIP] 真实 jar 检查（未提供 jar 路径）");
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }

    static int count(String[] a, String needle) {
        int n = 0;
        for (String s : a) if (needle.equals(s)) n++;
        return n;
    }

    /** 读真实 jar 里某个 class 的字节，转成 ISO-8859-1 文本（常量池里的 UTF-8 常量原样可查）。 */
    static String readConstantPoolText(String jarPath, String entry) {
        try (java.util.zip.ZipFile zf = new java.util.zip.ZipFile(jarPath)) {
            java.util.zip.ZipEntry e = zf.getEntry(entry);
            if (e == null) return "";
            try (java.io.InputStream in = zf.getInputStream(e)) {
                return new String(in.readAllBytes(), StandardCharsets.ISO_8859_1);
            }
        } catch (Exception e) {
            return "";
        }
    }

    /**
     * 解析 class 文件的方法表，判定某个方法是否 {@code static}。
     *
     * <p>不能靠文本扫描判 static：常量池里只有名字和描述符，"static" 这个
     * 信息在 {@code access_flags} 里。所以这里老老实实解析 class 文件：</p>
     * <pre>
     * u4 magic, u2 minor, u2 major, u2 constant_pool_count, cp_info[count-1],
     * u2 access_flags, u2 this_class, u2 super_class, u2 interfaces_count,
     * u2 interfaces[], u2 fields_count, field_info[], u2 methods_count, method_info[]
     * </pre>
     *
     * @param methodName 方法名
     * @return true = 存在同名且带 ACC_STATIC 的方法
     */
    static boolean isStaticMethod(String jarPath, String entry, String methodName) {
        try (java.util.zip.ZipFile zf = new java.util.zip.ZipFile(jarPath)) {
            java.util.zip.ZipEntry e = zf.getEntry(entry);
            if (e == null) return false;
            byte[] b;
            try (java.io.InputStream in = zf.getInputStream(e)) {
                b = in.readAllBytes();
            }
            return parseStaticMethod(b, methodName);
        } catch (Exception e) {
            return false;
        }
    }

    static boolean parseStaticMethod(byte[] b, String methodName) {
        final int ACC_STATIC = 0x0008;
        if (b.length < 10) return false;
        // magic 是 0xCAFEBABE（无符号 32 位）。u4 返回 long，而 0xCAFEBABE 作为
        // int 字面量是**负数**——直接比较会永远不等，必须按无符号比。
        if (u4(b, 0) != 0xCAFEBABEL) return false;

        int p = 8;                          // magic(4) + minor(2) + major(2)
        int cpCount = u2(b, p); p += 2;

        // 走一遍常量池：既要把 UTF-8 常量取出来（方法名要用），
        // 也必须知道每项占多少字节才能走到后面的字段/方法表。
        String[] utf8 = new String[cpCount];
        for (int i = 1; i < cpCount; i++) {
            int tag = u1(b, p); p += 1;
            switch (tag) {
                case 1: { // CONSTANT_Utf8
                    int len = u2(b, p); p += 2;
                    utf8[i] = new String(b, p, len, StandardCharsets.UTF_8);
                    p += len;
                    break;
                }
                case 7: case 8: case 16: case 19: case 20: p += 2; break; // Class/String/MethodType/Module/Package
                case 15: p += 3; break;                                    // MethodHandle
                case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18:
                    p += 4; break;                                         // Integer/Float/*ref
                case 5: case 6: p += 8; i++; break;                        // Long/Double 占两个槽位
                default: return false;                                     // 未知 tag -> 放弃
            }
        }

        p += 2;                           // access_flags
        p += 2;                           // this_class
        p += 2;                           // super_class
        int ifCount = u2(b, p); p += 2 + 2 * ifCount;   // interfaces

        // fields：access(2) name(2) desc(2) attributes_count(2) + attributes
        int fieldCount = u2(b, p); p += 2;
        for (int i = 0; i < fieldCount; i++) {
            p += 6;                       // access, name, desc
            p = skipAttributes(b, p);
        }

        // methods
        int methodCount = u2(b, p); p += 2;
        for (int i = 0; i < methodCount; i++) {
            int access = u2(b, p); p += 2;
            int nameIdx = u2(b, p); p += 2;
            p += 2;                       // descriptor_index
            p = skipAttributes(b, p);
            if (nameIdx < utf8.length && methodName.equals(utf8[nameIdx])) {
                return (access & ACC_STATIC) != 0;
            }
        }
        return false;
    }

    /** 跳过 attributes_count 指向的属性列表，返回下一个结构的位置。 */
    static int skipAttributes(byte[] b, int p) {
        int attrCount = u2(b, p); p += 2;
        for (int a = 0; a < attrCount; a++) {
            p += 2;                       // attribute_name_index
            int len = (int) u4(b, p); p += 4;
            p += len;                     // attribute_info
        }
        return p;
    }

    static int u1(byte[] b, int p) { return b[p] & 0xFF; }

    static int u2(byte[] b, int p) { return ((b[p] & 0xFF) << 8) | (b[p + 1] & 0xFF); }

    static long u4(byte[] b, int p) {
        return ((long) (b[p] & 0xFF) << 24) | ((b[p + 1] & 0xFF) << 16)
             | ((b[p + 2] & 0xFF) << 8) | (b[p + 3] & 0xFF);
    }

    /**
     * PlayerAPI 的常量池里是否引用了 readArray。
     *
     * <p>常量池里存的是<b>方法引用</b>（NameAndType + Methodref），不是完整的
     * "readArray" 字符串——但方法的 <b>Name</b> 确实以 UTF-8 常量的形式存在，
     * 所以文本扫描能可靠地找到它。</p>
     */
    static boolean readPlayerApiUses(String jarPath) {
        try (java.util.zip.ZipFile zf = new java.util.zip.ZipFile(jarPath)) {
            java.util.zip.ZipEntry e = zf.getEntry("org/watermedia/api/player/PlayerAPI.class");
            if (e == null) return false;
            try (java.io.InputStream in = zf.getInputStream(e)) {
                byte[] b = in.readAllBytes();
                String txt = new String(b, StandardCharsets.ISO_8859_1);
                return txt.contains("readArray");
            }
        } catch (Exception e) {
            return false;
        }
    }
}
