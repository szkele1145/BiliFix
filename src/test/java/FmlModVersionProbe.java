import dev.polaris_fix.bilifix.FmlBridge;

/**
 * {@code FmlBridge.modVersion} 成功路径探针 —— 端到端覆盖此前零覆盖的分支。
 *
 * <p><b>覆盖缺口（v1.4.8 审查发现）</b>：{@code FmlBridgeProbe} 只测了
 * "ModList 不存在"时的降级（返回 null 不抛异常）。成功路径——找到 ModList、
 * 调 {@code getModFileById}、调 {@code versionString}——<b>从未被执行过</b>。</p>
 *
 * <p><b>为什么成功路径重要</b>：真实 FML 的形状（javap 实证，2026-10-21）：</p>
 * <ul>
 *   <li>{@code getModFileById} 声明在**具体类**上 → 类查找能命中；</li>
 *   <li>返回的 {@code IModFileInfo} 是**接口**，实现类是<b>包私有</b>的
 *       → {@code versionString()} 只在接口上声明。</li>
 * </ul>
 *
 * <p><b>实测澄清</b>：{@code Class.getMethod()} 会搜索类、父类<b>以及实现的
 * 接口</b>上的 public 方法（2026-10-21 实测确认）——即使实现类是包私有的，
 * {@code getMethod("versionString")} 依然能命中。所以
 * {@code FmlBridge.call()} 的类查找路径就够用，其 {@code getInterfaces()}
 * 接口回退是<b>冗余保险</b>（为接口继承链更复杂的形状兜底），不是本场景的
 * 必需路径。探针把这条实测事实钉成断言。</p>
 *
 * <p>若成功路径整体坏掉（例如 {@code modVersion} 永远返回 null），
 * {@code EnvironmentDiagnostics} 会把已安装的 watermedia 报成"未安装"——
 * 诊断输出直接撒谎。</p>
 *
 * <p>桩形状照抄真实 FML：{@code ModList} 是具体类、单例，
 * {@code getModFileById} 对未安装 mod 返回 null（不抛异常，字节码实证：
 * 就是 {@code fileById.get(id)} + checkcast）。</p>
 */
public class FmlModVersionProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    public static void main(String[] args) {
        System.out.println("FmlModVersion probe (success path + interface fallback)");

        // ---- 前提：ModList stub 在候选根包上可加载 ----
        Class<?> ml = null;
        try {
            ml = Class.forName("net.neoforged.fml.ModList", true, FmlModVersionProbe.class.getClassLoader());
        } catch (Throwable t) {
            System.out.println("    stub load throw: " + t);
        }
        check("前提: net.neoforged.fml.ModList 桩可加载（测试前提）", ml != null);

        // ---- 1. 成功路径：已安装的 mod → 版本号（走接口回退） ----
        String wm = null;
        boolean noThrow = true;
        try {
            wm = FmlBridge.modVersion("watermedia");
        } catch (Throwable t) {
            noThrow = false;
            System.out.println("    unexpected throw: " + t);
        }
        check("成功路径: modVersion(watermedia) 返回 2.1.36（不抛异常）", noThrow && "2.1.36".equals(wm));

        String bm = null;
        try {
            bm = FmlBridge.modVersion("bilibili_media");
        } catch (Throwable t) {
            noThrow = false;
            System.out.println("    unexpected throw: " + t);
        }
        check("成功路径: modVersion(bilibili_media) 返回 2.3", noThrow && "2.3".equals(bm));

        // ---- 2. 未安装的 mod → null（真实 FML 就是 fileById.get → null） ----
        String missing = null;
        try {
            missing = FmlBridge.modVersion("__no_such_mod__");
        } catch (Throwable t) {
            noThrow = false;
            System.out.println("    unexpected throw: " + t);
        }
        check("未安装: modVersion 返回 null（不抛异常，与真实 FML 一致）", noThrow && missing == null);

        // ---- 3. 证据级断言：方法查找为什么能命中（实测确认的事实） ----
        //     实测（2026-10-21，Class.getMethod 的 JLS 行为）：getMethod 会
        //     在类、其父类**以及它实现的接口**上查找 public 方法。所以即使
        //     实现类是包私有的、versionString() 只在接口上声明，
        //     getMethod 依然能找到它。
        //     → FmlBridge.call() 的**类查找路径**就能命中；getInterfaces()
        //     的接口回退是**冗余保险**（为接口继承链更复杂的形状兜底），
        //     不是本场景的必需路径。
        //     这里把该事实钉成断言：将来若有人误以为"getMethod 找不到接口
        //     方法"而把 call() 改坏，这条会先提醒他重新核对实测。
        try {
            Class<?> impl = Class.forName("net.neoforged.fml.ModList$ModFileInfo",
                    true, FmlModVersionProbe.class.getClassLoader());
            boolean implNotPublic = !java.lang.reflect.Modifier.isPublic(impl.getModifiers());
            check("前提: 实现类是包私有的（与真实 FML 形状一致）", implNotPublic);
            boolean classLookupHits = false;
            try {
                impl.getMethod("versionString");
                classLookupHits = true;
            } catch (NoSuchMethodException ignored) {
            }
            check("事实: getMethod(versionString) 在包私有实现类上**能**命中"
                    + "（getMethod 会搜索接口上的 public 方法）", classLookupHits);
            boolean ifaceLookupHits = false;
            for (Class<?> i : impl.getInterfaces()) {
                try {
                    i.getMethod("versionString");
                    ifaceLookupHits = true;
                } catch (NoSuchMethodException ignored) {
                }
            }
            check("事实: 实现类的直接接口上也有 versionString（回退保险也可达）", ifaceLookupHits);
            check("端到端: 两条查找路径至少有一条命中 → modVersion 拿到版本号",
                    classLookupHits || ifaceLookupHits);
            check("端到端: 取到的确实是接口方法的返回值", "2.1.36".equals(wm));
        } catch (Throwable t) {
            check("前提: 实现类可加载（测试前提）", false);
            System.out.println("    throw: " + t);
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
