import dev.polaris_fix.bilifix.EnvironmentDiagnostics;

import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * 探针：环境诊断里两个"静默失效"点。
 *
 * <p><b>缺陷 1：REG_EXPAND_SZ 的值被静默丢弃</b>。
 * {@code regQueryValue} 的 javadoc 明确声称支持 REG_SZ 与 REG_EXPAND_SZ，
 * 但实现只找字面量 {@code "REG_SZ"}。{@code "REG_EXPAND_SZ"} 里并不含连续的
 * {@code "REG_SZ"}（它是 REG_ + EXPAND_ + SZ），所以 {@code indexOf} 返回 -1，
 * 那一行被静默跳过。驱动描述里带 {@code %SystemRoot%} 这类需展开的值并不罕见，
 * 静默丢弃 = GPU 型号显示不全。</p>
 *
 * <p><b>缺陷 2：regQuery 的数据竞争</b>。
 * 后台线程读进程输出写进一个普通 {@code ArrayList}，主线程 {@code t.join(500)}
 * 超时返回后立刻读这个 list。{@code join} 超时**不建立 happens-before**，
 * 于是主线程可能在后台线程还在写的时候读它——别的线程正在写的同时读普通
 * ArrayList 是数据竞争，可能读到 null 元素或抛 ConcurrentModificationException。
 * 改成 {@link CopyOnWriteArrayList} 即可安全。</p>
 *
 * <p>用法：{@code RegParseAndConcurrencyProbe}</p>
 */
public final class RegParseAndConcurrencyProbe {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) throws Exception {
        System.out.println("Registry parse + concurrency probe");

        // ---------- 1. 解析纯函数 ----------
        Method parse = EnvironmentDiagnostics.class.getDeclaredMethod(
                "parseRegValue", String.class, String.class);
        parse.setAccessible(true);

        // 典型 reg query /v 输出：4 空格缩进 + 名称 + 类型 + 值
        String regSz = "    DriverDesc    REG_SZ    AMD Radeon RX6500 XT";
        String regExpand = "    DriverDesc    REG_EXPAND_SZ    %SystemRoot%\\System32\\drivers\\amdkmdag.sys";
        String regMulti = "    DriverDesc    REG_SZ    Intel(R) UHD Graphics 630 / AMD Radeon(TM) Graphics";

        Object v1 = parse.invoke(null, regSz, "DriverDesc");
        check("REG_SZ 正常解析", "AMD Radeon RX6500 XT".equals(v1), "got=" + v1);

        // 这是本探针的核心：旧实现在这里返回 null（静默丢弃）
        Object v2 = parse.invoke(null, regExpand, "DriverDesc");
        check("REG_EXPAND_SZ 能解析（旧实现返回 null）",
                "%SystemRoot%\\System32\\drivers\\amdkmdag.sys".equals(v2), "got=" + v2);

        // 值里含空格 / 斜杠 / 多个适配器拼接都不能被截断
        Object v3 = parse.invoke(null, regMulti, "DriverDesc");
        check("值含空格与斜杠时不被截断",
                "Intel(R) UHD Graphics 630 / AMD Radeon(TM) Graphics".equals(v3), "got=" + v3);

        // 不含该值名的行必须返回 null
        Object v4 = parse.invoke(null, "    ProviderName    REG_SZ    NVIDIA", "DriverDesc");
        check("不含该值名的行返回 null", v4 == null, "got=" + v4);

        // 类型不识别（REG_DWORD）必须返回 null，而不是把数字当字符串
        Object v5 = parse.invoke(null, "    DriverVersion    REG_DWORD    0x1234", "DriverVersion");
        check("REG_DWORD 不被当作字符串解析", v5 == null, "got=" + v5);

        // 空值必须返回 null（不能返回空串——调用方靠 null 判断"没取到"）
        Object v6 = parse.invoke(null, "    DriverDesc    REG_SZ    ", "DriverDesc");
        check("空值返回 null（不是空串）", v6 == null, "got=" + v6);

        // null 入参不炸
        Object v7 = parse.invoke(null, null, "DriverDesc");
        check("null 行不抛异常", v7 == null, "got=" + v7);

        // ---------- 2. 并发安全 ----------
        // 源级：读流的容器必须是并发容器。
        // 源码路径可由命令行传入——负向测试要把**被破坏的副本**传进来，
        // 否则探针读的是仓库里的原版，破坏根本进不了探针的视野
        // （"破坏没被发现"会被误读成"探针没测到"或"这不算缺陷"）。
        Path src = args.length > 0
                ? Path.of(args[0])
                : Path.of("src", "main", "java", "dev", "polaris_fix", "bilifix",
                        "EnvironmentDiagnostics.java");
        String text = Files.readString(src);
        check("读流容器是 CopyOnWriteArrayList（并发安全）",
                text.contains("CopyOnWriteArrayList<String>"), "source=" + src);
        check("没有用普通 ArrayList 承载后台线程写入",
                !text.contains("var lines = new java.util.ArrayList<String>()"), "source=" + src);

        // 行为级：证明普通 ArrayList 在"join 超时后立刻读"的模式下确实会出问题，
        // 而 CopyOnWriteArrayList 不会。
        //
        // 关键：竞态必须**可靠地**制造出来。早期版本让 writer 写 20 万次然后
        // 主线程直接迭代——实测 writer 早写完了，一次都没炸（arrayListBroke=false），
        // 探针因此误报。修法：用 volatile 计数标志等 writer 确实写够一定量，
        // 再开始迭代——那时 writer 必然还在写（还剩几十万次要写），
        // 迭代器的 modCount 检查必然命中并抛 ConcurrentModificationException。
        boolean arrayListBroke;
        try {
            arrayListBroke = concurrentReadWhileWriting(new ArrayList<>());
        } catch (Throwable t) {
            arrayListBroke = true;
        }
        check("普通 ArrayList 并发读写确实会出问题（说明修复有必要）",
                arrayListBroke, "arrayListBroke=" + arrayListBroke);

        boolean cowSafe;
        try {
            cowSafe = !concurrentReadWhileWriting(new CopyOnWriteArrayList<>());
        } catch (Throwable t) {
            cowSafe = false;
        }
        check("CopyOnWriteArrayList 并发读写安全", cowSafe, "cowSafe=" + cowSafe);

        // 反向自检：上面那套机制**必须**能抓到 ArrayList 的问题，
        // 否则"ArrayList 没坏"只是探针没测到，不是 ArrayList 安全。
        // 这里用一个不共享的 list（无并发）跑同一套流程，期望：不报错。
        boolean noRaceClean;
        try {
            noRaceClean = !concurrentReadWhileWriting(new ArrayList<>(), false);
        } catch (Throwable t) {
            noRaceClean = false;
        }
        check("无并发时同一套流程不报错（排除探针本身误报）", noRaceClean, "noRaceClean=" + noRaceClean);

        System.out.println();
        System.out.println("通过 " + passed + " / 失败 " + failed);
        if (failed > 0) {
            System.out.println("RESULT = FAIL");
            System.exit(1);
        }
        System.out.println("RESULT = PASS");
    }

    /**
     * 模拟 regQuery 的模式：后台线程持续写，主线程在 join 超时后立刻读。
     *
     * <p>时序控制：主线程忙等一个 volatile 计数 ≥ 1000 才开始迭代，
     * 保证迭代开始时 writer 必然还在写（还剩几十万次），
     * 普通迭代器这时 modCount 检查必然命中。</p>
     *
     * @param sink   被测容器
     * @param race   true = 真并发（主线程等 writer 开写后立刻迭代）；
     *               false = 反向自检（writer 写完后主线程才迭代，期望不出错）
     * @return 是否观测到损坏（null 元素 / ConcurrentModificationException）
     */
    private static boolean concurrentReadWhileWriting(List<String> sink, boolean race) throws Exception {
        final int writes = 500_000;
        final java.util.concurrent.atomic.AtomicInteger written =
                new java.util.concurrent.atomic.AtomicInteger(0);
        CountDownLatch started = new CountDownLatch(1);
        Thread writer = new Thread(() -> {
            started.countDown();
            for (int i = 0; i < writes; i++) {
                sink.add("line-" + i);
                written.incrementAndGet();
            }
        });
        writer.setDaemon(true);
        writer.start();
        started.await(1, TimeUnit.SECONDS);

        boolean broke = false;
        if (race) {
            // 等 writer 确实开写（≥1000 条），它必然还在写（才 0.2%）
            while (written.get() < 1000) Thread.onSpinWait();
            // 主线程在 writer 还在写时迭代 —— join 超时后的真实场景
            try {
                for (int round = 0; round < 50; round++) {
                    for (String s : sink) {
                        if (s == null) { broke = true; break; }
                    }
                    if (broke) break;
                }
            } catch (Throwable t) {
                broke = true; // 最常见的：ConcurrentModificationException
            }
        }
        writer.join(3000);
        if (!broke) {
            // 收尾检查：writer 结束后按理应一条不缺
            try {
                for (String s : sink) if (s == null) { broke = true; break; }
            } catch (Throwable t) {
                broke = true;
            }
        }
        return broke;
    }

    private static boolean concurrentReadWhileWriting(List<String> sink) throws Exception {
        return concurrentReadWhileWriting(sink, true);
    }

    private static void check(String name, boolean ok, String ctx) {
        if (ok) {
            passed++;
            System.out.println("  [PASS] " + name);
        } else {
            failed++;
            System.out.println("  [FAIL] " + name + "  (" + ctx + ")");
        }
    }
}
