package dev.polaris_fix.bilifix;

import java.lang.reflect.Method;
import java.nio.file.Path;

/**
 * FML 反射桥：让同一份源码既能被 NeoForge/Forge 编译，也能被 Fabric 编译。
 *
 * <p>为什么必须反射：{@code net.neoforged.fml.*} 与 {@code net.minecraftforge.fml.*}
 * 在 Fabric 的 classpath 上<b>完全不存在</b>。JVM 的惰性解析（{@code getstatic} 只在
 * 执行时解析）能救运行时，但救不了 javac —— 编译期符号缺失就是编译失败。把包名放进
 * 字符串、用 {@link Class#forName} 查找，编译期就不需要这些类。</p>
 *
 * <p>字符串刻意拆成 {@code "net.neoforged." + "fml..."} 两段拼接：Forge 变体的构建
 * 脚本会做全文替换 {@code net.neoforged.fml → net.minecraftforge.fml}，拼接写法可以
 * 避免把两个候选包名替换成同一个值（即使被替换也只是冗余，不影响正确性）。</p>
 *
 * <p>所有方法都<b>绝不抛异常</b>：查不到就返回 null，由调用方决定降级行为。
 * 这是守护类代码，取证失败绝不允许影响游戏启动或退出。</p>
 */
public final class FmlBridge {

    private FmlBridge() {}

    /** 候选 FML 根包：NeoForge 与 Forge 1.20.1 的包名差异仅在前缀 */
    private static final String[] ROOTS = {
        "net.neoforged." + "fml",
        "net.minecraftforge." + "fml"
    };

    /**
     * 读取 FML 的目录常量（{@code GAMEDIR} / {@code CONFIGDIR}）。
     *
     * <p><b>关键实现细节</b>：{@code FMLPaths} 是 {@code enum}，{@code GAMEDIR} 与
     * {@code CONFIGDIR} 是枚举<b>常量</b>（类型为 {@code FMLPaths} 本身），
     * 真正的 {@code Path} 要通过实例方法 {@code get()} 取得。所以必须
     * "先取常量、再调 get()"，直接对字段值做 {@code instanceof Path} 永远是 false。</p>
     *
     * @param field {@code "GAMEDIR"} 或 {@code "CONFIGDIR"}
     * @return 目录；FML 不可用或 API 形状不符时返回 null
     */
    public static Path fmlDir(String field) {
        for (String root : ROOTS) {
            try {
                Class<?> c = Class.forName(root + ".loading.FMLPaths");
                Object constant = c.getField(field).get(null);   // 枚举常量
                Object dir = c.getMethod("get").invoke(constant); // 常量.get() -> Path
                if (dir instanceof Path p) return p;
            } catch (Throwable ignored) {
                // 换下一个候选包名
            }
        }
        return null;
    }

    /**
     * 通过 FML 的 {@code ModList} 查某个 mod 的版本字符串。
     *
     * <p>等价于 {@code ModList.get().getModFileById(modId).versionString()}，
     * 全程反射。{@code getModFileById} 由 public 接口 {@code IModList} 声明，
     * 但实现类可能是包私有的，故查找方法时先看类、再看接口，并
     * {@code setAccessible(true)} 以避开非法访问检查。</p>
     *
     * @param modId 模组 id
     * @return 版本字符串；FML 不可用或 mod 未安装时返回 null
     */
    public static String modVersion(String modId) {
        for (String root : ROOTS) {
            try {
                Class<?> modListCls = Class.forName(root + ".ModList");
                Object modList = modListCls.getMethod("get").invoke(null);
                if (modList == null) continue;
                Object info = call(modList, "getModFileById", new Class<?>[]{String.class}, modId);
                if (info == null) continue;
                Object ver = call(info, "versionString", new Class<?>[0]);
                if (ver instanceof String s) return s;
            } catch (Throwable ignored) {
                // 换下一个候选包名
            }
        }
        return null;
    }

    /** 反射调用实例方法：先找类上的 public 方法，再找接口上的（应对包私有实现类）。 */
    private static Object call(Object target, String name, Class<?>[] types, Object... args)
            throws Exception {
        Method m = null;
        try {
            m = target.getClass().getMethod(name, types);
        } catch (Throwable ignored) {
            for (Class<?> iface : target.getClass().getInterfaces()) {
                try {
                    m = iface.getMethod(name, types);
                    break;
                } catch (Throwable ignored2) {
                    // 继续找下一个接口
                }
            }
        }
        if (m == null) throw new NoSuchMethodException(name);
        m.setAccessible(true);
        return m.invoke(target, args);
    }
}
