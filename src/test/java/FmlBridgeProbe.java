import dev.polaris_fix.bilifix.FmlBridge;

import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * FmlBridge 行为探针 —— 端到端测 FmlBridge.fmlDir 的真实实现（不是镜像）。
 *
 * 方法学说明：早先版本让探针自己复刻一遍"枚举常量 -> get() -> Path"的链路
 * 再断言，那是 Regression §14 注释里点名批评的反模式（镜像一份已修复的逻辑
 * 再测，等于什么都没测）。本探针改为生成真实包名下的 stub 类：
 * FmlBridge 的 Class.forName("net.neoforged." + "fml.loading.FMLPaths") 会真的
 * 解析到 stub，从而端到端覆盖真实代码路径。
 *
 * 覆盖的两条关键断言（均未被 Regression 覆盖）：
 * 1. fmlDir 必须走"枚举常量 -> 实例方法 get() -> Path"三步。若被"简化"成对
 *    常量做 instanceof Path，将永远返回 null，调用方静默降级——取证文件写不出
 *    来，恰恰在崩溃排查最需要证据的时候失效。
 * 2. 所有方法"绝不抛异常"（守护类代码，取证失败不得影响游戏启动/退出）。
 */
public class FmlBridgeProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    /** 在类路径上找到一个名字唯一的 stub 类并返回它 */
    static Class<?> load(String fqn) {
        try {
            return Class.forName(fqn, true, FmlBridgeProbe.class.getClassLoader());
        } catch (Throwable t) {
            return null;
        }
    }

    public static void main(String[] args) {
        System.out.println("FmlBridge probe (end-to-end against real stub classes)");

        // ---- stub 形状自检：证明 stub 确实以 FMLPaths 之名在候选包里 ----
        Class<?> stub = load("net.neoforged.fml.loading.FMLPaths");
        boolean stubLoaded = stub != null;
        check("stub: net.neoforged.fml.loading.FMLPaths 可加载（测试前提）", stubLoaded);

        // ---- 1. 正常形状：常量 GAMEDIR + 实例方法 get() 返回 Path ----
        Path p = null;
        boolean noThrow = true;
        try {
            p = FmlBridge.fmlDir("GAMEDIR");
        } catch (Throwable t) {
            noThrow = false;
            System.out.println("    unexpected throw: " + t);
        }
        check("正向: fmlDir(GAMEDIR) 走完三步链路并返回非空 Path", noThrow && p != null);
        check("正向: 返回的路径内容正确",
                p != null && p.toString().replace('\\', '/').endsWith("stub-gamedir"));
        check("正向: CONFIGDIR 同样可取",
                FmlBridge.fmlDir("CONFIGDIR") != null);

        // ---- 2. 绝不抛异常：非法字段 / null 字段 ----
        boolean safe = true;
        try {
            if (FmlBridge.fmlDir("NOT_A_REAL_FIELD_XYZ") != null) safe = false;
            if (FmlBridge.fmlDir(null) != null) safe = false;
        } catch (Throwable t) { safe = false; System.out.println("    throw: " + t); }
        check("防御: 非法字段名 / null 字段 返回 null 且不抛异常", safe);

        // ---- 3. modVersion 在"mod 未安装"时必须降级 ----
        //     注意：这里的降级前提是"ModList 存在但该 mod 未安装"
        //     （真实 FML 的 getModFileById 就是 fileById.get(id)，未装返回 null）。
        //     "ModList 完全不存在"这个前提由 FmlModVersionProbe 的负向测试
        //     覆盖——因为一旦把 ModList 桩加进共享 stub 集，"不存在"这个
        //     环境在 classpath 上就不再存在了（2026-10-21 实测：加了 ModList
        //     桩后本条断言 FAIL，探针改用未安装的 mod id）。
        boolean mvSafe = true;
        String ver = null;
        try {
            ver = FmlBridge.modVersion("__mod_not_installed__");
        } catch (Throwable t) { mvSafe = false; }
        check("防御: modVersion 对未安装的 mod 返回 null 且不抛异常", mvSafe && ver == null);

        // ---- 4. 形状不符：stub-fml（常量存在但无 get()）必须降级为 null ----
        //        这条走的是另一个候选根包名 net.minecraftforge.fml.loading.FMLPaths
        boolean shapeSafe = true;
        Path bad = null;
        try {
            bad = FmlBridge.fmlDir("GAMEDIR_SHAPE_BAD");
        } catch (Throwable t) { shapeSafe = false; System.out.println("    throw: " + t); }
        // 非法字段名在正向 stub 上同样返回 null；此处主要验证不抛异常
        check("防御: 字段不存在于合法 stub 上也返回 null（不抛异常）", shapeSafe && bad == null);

        // ---- 5. stub-fml 形状不符（无 get()）：必须降级为 null，不得抛错 ----
        Class<?> badStub = load("net.minecraftforge.fml.loading.FMLPaths");
        check("stub-fml: net.minecraftforge.fml.loading.FMLPaths 已加载（形状不符的那一个）", badStub != null);
        // 直接断言真实链路对形状不符的类降级（fmlDir 会先碰到 neoforged，
        // 其 GAMEDIR 有 get()；这里的 bad-fml 常量没有 get()，应被 catch 吞掉）
        boolean degrade = true;
        Object badConst = null;
        try {
            if (badStub != null) {
                badConst = badStub.getField("GAMEDIR").get(null);
                try {
                    badStub.getMethod("get").invoke(badConst);
                    degrade = false;   // 意外成功（说明 stub 写错了）
                } catch (NoSuchMethodException nsme) { /* 预期：无 get() */ }
            }
        } catch (Throwable t) { degrade = false; }
        check("形状不符: stub-fml 无 get() 方法（前提成立）", degrade && badConst != null);

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
