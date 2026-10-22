import dev.polaris_fix.bilifix.CrashSentinel;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * 探针：取证写文件失败时，必须留下**可见的**线索。
 *
 * <p>背景：CrashSentinel 的取证代码全部包在 {@code catch (Throwable ignored)} 里——
 * 守护绝不能反过来搞崩游戏，这个原则是对的。但完全静默同样是错的：诊断文件
 * （bilifix-diagnostic.txt / bilifix-crash.txt）是原生崩溃后 Java 侧**唯一**的
 * 线索。如果它写不出来（目录只读、磁盘满、杀毒软件锁文件），用户会在"下次崩溃"时
 * 发现根本没有那个文件，却没有任何说明为什么——又一条静默失效路径。</p>
 *
 * <p>本探针断言两件事：</p>
 * <ol>
 *   <li>三处取证失败都必须调用 warnForensicsOnce（源码级）；</li>
 *   <li>该方法**真的**发出 warn，且同一次运行里只发一次（行为级）。</li>
 * </ol>
 *
 * <p>用法：{@code ForensicsFailureWarnProbe <CrashSentinel 源文件路径>}</p>
 */
public final class ForensicsFailureWarnProbe {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.out.println("用法: ForensicsFailureWarnProbe <CrashSentinel.java>");
            System.exit(2);
        }
        Path src = Path.of(args[0]);
        String text = Files.readString(src);

        // --- 1) 源码级断言：失败路径必须调用 warnForensicsOnce ---
        check("存在 warnForensicsOnce 方法",
                text.contains("static void warnForensicsOnce("),
                text);
        check("会话标记失败会告警",
                text.contains("warnForensicsOnce(BiliFixMod.LOGGER, \"会话标记\""),
                text);
        check("退出诊断文件失败会告警",
                text.contains("warnForensicsOnce(BiliFixMod.LOGGER, \"退出诊断文件\""),
                text);
        check("异常终止报告失败会告警",
                text.contains("warnForensicsOnce(BiliFixMod.LOGGER, \"异常终止报告\""),
                text);
        check("告警用 AtomicBoolean 保证只打一次",
                text.contains("AtomicBoolean FORENSICS_WARNED")
                        && text.contains("compareAndSet(false, true)"),
                text);
        check("告警内容提到取证失败",
                text.contains("取证失败"),
                text);

        // --- 2) 行为级断言：真的调用一次，验证 logger 收到 warn ---
        // warnForensicsOnce 是包级可见的，探针不同包，所以用反射。
        // logger 作为参数传入，正是为了让这里能传一个"记录 warn 调用"的替身：
        // BiliFixMod.LOGGER 是 public static final，探针没法替换它。
        //
        // 替身用动态代理实现 org.slf4j.Logger：接口有 40 多个方法，
        // 手写实现既啰嗦又容易漏（漏一个就是编译错误）。代理只拦截
        // "warn" 开头的方法名，其余一律返回默认值。
        java.lang.reflect.Method warn = CrashSentinel.class.getDeclaredMethod(
                "warnForensicsOnce", org.slf4j.Logger.class, String.class, Throwable.class);
        warn.setAccessible(true);

        final boolean[] warned = { false };
        final int[] warnCalls = { 0 };
        // 代理只拦截 "warn" 开头的方法名：其余一律返回默认值。
        // isWarnEnabled 系列返回 true，让 warn 真的"发出去"。
        org.slf4j.Logger spy = (org.slf4j.Logger) java.lang.reflect.Proxy.newProxyInstance(
                ForensicsFailureWarnProbe.class.getClassLoader(),
                new Class<?>[]{ org.slf4j.Logger.class },
                (proxy, method, margs) -> {
                    String name = method.getName();
                    if (name.startsWith("warn")) {
                        warnCalls[0]++;
                        warned[0] = true;
                    }
                    Class<?> rt = method.getReturnType();
                    if (rt == boolean.class) {
                        return name.startsWith("isWarn") ? Boolean.TRUE : Boolean.FALSE;
                    }
                    if (rt == void.class) return null;
                    return null;
                });

        // 第一次：应该告警
        warn.invoke(null, spy, "测试步骤", new RuntimeException("boom"));
        check("第一次失败触发 warn", warned[0], "warned=" + warned[0]);
        check("第一次失败只调用一次 warn", warnCalls[0] == 1, "warnCalls=" + warnCalls[0]);
        // 第二次：不应再告警（退出 hook 会重跑，不能刷屏）
        warned[0] = false;
        warnCalls[0] = 0;
        warn.invoke(null, spy, "测试步骤", new RuntimeException("boom again"));
        check("第二次失败不再告警（不刷屏）", !warned[0], "warned=" + warned[0]);
        check("第二次失败 warn 调用数为 0", warnCalls[0] == 0, "warnCalls=" + warnCalls[0]);

        System.out.println("通过 " + passed + " / 失败 " + failed);
        if (failed > 0) {
            System.out.println("RESULT = FAIL");
            System.exit(1);
        }
        System.out.println("RESULT = PASS");
    }

    private static void check(String name, boolean ok, String ctx) {
        if (ok) {
            passed++;
            System.out.println("  [PASS] " + name);
        } else {
            failed++;
            System.out.println("  [FAIL] " + name);
        }
    }
}
