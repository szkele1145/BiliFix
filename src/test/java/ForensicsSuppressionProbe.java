import dev.polaris_fix.bilifix.CrashSentinel;

import java.lang.reflect.Field;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 探针：取证抑制开关的并发正确性。
 *
 * 缺陷背景：
 * {@code MixinTargetGuard.functionalProbe()} 在启动时真的调用一次
 * {@code JarTool.readArray}，这会触发 mixin → {@code recordHarden} →
 * {@code mediaTouched = true}。为了让"用户根本没播放媒体"不被记成
 * "media touched: yes"，自检用 try/finally 把
 * {@code CrashSentinel.setForensicsSuppressed(true)} 打开、结束时复位。
 *
 * 但 suppressForensics 是<b>全局静态布尔</b>，不是线程局部的：
 * 1. 自检进行中（线程 A），媒体加载线程 B 真的播放了媒体 →
 *    B 的 recordHarden 被 A 的抑制吞掉 → 这次真实播放<b>不被记录</b>
 *    （mediaTouched 仍是 false、计数不加）——取证丢失
 * 2. A 的 finally 无条件 setForensicsSuppressed(false) →
 *    如果此时还有别的自检在跑，那一个的抑制也被清掉了
 *
 * 修复方向：抑制改为<b>线程局部</b>（ThreadLocal），或改为<b>计数器</b>
 * （成对进入/退出）。本探针验证修复后的行为。
 */
public class ForensicsSuppressionProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }

    /** 反射读取 private static 字段 */
    static Object getStatic(String cls, String field) throws Exception {
        Class<?> c = Class.forName(cls);
        Field f = c.getDeclaredField(field);
        f.setAccessible(true);
        return f.get(null);
    }

    static void setStatic(String cls, String field, Object v) throws Exception {
        Class<?> c = Class.forName(cls);
        Field f = c.getDeclaredField(field);
        f.setAccessible(true);
        f.set(null, v);
    }

    /**
     * 重置 harden 计数。HARDEN_COUNT 是 static final，不能整体替换，
     * 只能改它内部的 AtomicLong 值。
     */
    static void resetHardenCount() throws Exception {
        Field f = Class.forName("dev.polaris_fix.bilifix.CrashSentinel")
                .getDeclaredField("HARDEN_COUNT");
        f.setAccessible(true);
        ((java.util.concurrent.atomic.AtomicLong) f.get(null)).set(0);
    }

    static long hardenCount() {
        try {
            return ((java.util.concurrent.atomic.AtomicLong)
                    getStatic("dev.polaris_fix.bilifix.CrashSentinel", "HARDEN_COUNT")).get();
        } catch (Exception e) {
            return -1;
        }
    }

    /** 读取当前线程视角下的抑制标志（不抛异常，供 lambda 使用） */
    static boolean suppressedNow() {
        try {
            Object v = getStatic("dev.polaris_fix.bilifix.CrashSentinel", "SUPPRESS_FORENSICS");
            if (v instanceof ThreadLocal) {
                return Boolean.TRUE.equals(((ThreadLocal<?>) v).get());
            }
            return Boolean.TRUE.equals(v);
        } catch (Exception e) {
            return false;
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Forensics suppression probe");

        // 1. 基本语义：抑制时 recordHarden 不计数、不置 mediaTouched
        setStatic("dev.polaris_fix.bilifix.CrashSentinel", "mediaTouched", Boolean.FALSE);
        resetHardenCount();
        CrashSentinel.setForensicsSuppressed(true);
        CrashSentinel.recordHarden(18, 18, null);
        boolean touchedWhileSuppressed = CrashSentinel.mediaTouched();
        long countWhileSuppressed = ((java.util.concurrent.atomic.AtomicLong)
                getStatic("dev.polaris_fix.bilifix.CrashSentinel", "HARDEN_COUNT")).get();
        CrashSentinel.setForensicsSuppressed(false);

        check("抑制期间 recordHarden 不置 mediaTouched", !touchedWhileSuppressed);
        check("抑制期间 recordHarden 不递增计数", countWhileSuppressed == 0);

        // 2. 解除抑制后正常记录
        CrashSentinel.recordHarden(18, 18, null);
        check("解除抑制后 mediaTouched 变为 true", CrashSentinel.mediaTouched());
        check("解除抑制后计数递增", ((java.util.concurrent.atomic.AtomicLong)
                getStatic("dev.polaris_fix.bilifix.CrashSentinel", "HARDEN_COUNT")).get() == 1);

        // 3. 关键：抑制必须是**线程局部**的。
        //    线程 A 抑制时，线程 B 的真实播放**不能**被吞掉。
        //    注意：必须先重置 mediaTouched 与计数——第 2 步已把 mediaTouched
        //    置为 true，否则 B 线程读到的会是残留值，让断言失去意义。
        setStatic("dev.polaris_fix.bilifix.CrashSentinel", "mediaTouched", Boolean.FALSE);
        resetHardenCount();
        final CountDownLatch aIn = new CountDownLatch(1);
        final CountDownLatch bDone = new CountDownLatch(1);
        final AtomicInteger bSaw = new AtomicInteger(-1);
        final AtomicInteger aSuppOk = new AtomicInteger(1);
        final java.util.concurrent.atomic.AtomicLong bCount = new java.util.concurrent.atomic.AtomicLong(-1);

        Thread a = new Thread(() -> {
            CrashSentinel.setForensicsSuppressed(true);
            aIn.countDown();
            try {
                bDone.await(5, java.util.concurrent.TimeUnit.SECONDS);
            } catch (InterruptedException ignored) {
            }
            // A 线程自己的抑制此刻必须仍为 true（前置条件）
            if (!suppressedNow()) {
                aSuppOk.set(0);
            }
            CrashSentinel.setForensicsSuppressed(false);
        }, "suppressor");

        Thread b = new Thread(() -> {
            try {
                aIn.await(5, java.util.concurrent.TimeUnit.SECONDS);
            } catch (InterruptedException ignored) {
            }
            // 前置条件：B 线程的抑制标志必须是 false（修复后即如此）。
            // 这正是要验证的点——旧实现下这里是 true（全局布尔），B 的真实
            // 播放会被吞掉。
            if (suppressedNow()) {
                bSaw.set(-2);   // 抑制泄漏到了别的线程 —— 这就是缺陷本身
                bDone.countDown();
                return;
            }
            // B 线程的真实播放：绝不能被 A 的抑制影响
            CrashSentinel.recordHarden(18, 18, null);
            bSaw.set(CrashSentinel.mediaTouched() ? 1 : 0);
            bCount.set(hardenCount());
            bDone.countDown();
        }, "player");

        a.start(); b.start();
        a.join(8000); b.join(8000);

        check("A 线程的抑制在其存续期间确实生效（前置条件）", aSuppOk.get() == 1);
        check("B 线程未继承 A 的抑制（抑制不跨线程泄漏）", bSaw.get() != -2);
        check("B 线程的真实播放未被 A 的抑制吞掉（mediaTouched 被置位）", bSaw.get() == 1);
        check("B 线程的真实播放未被 A 的抑制吞掉（计数已递增）", bCount.get() > countWhileSuppressed);

        // 4. 抑制标志本身在 B 线程中应为 false
        Object supp = getStatic("dev.polaris_fix.bilifix.CrashSentinel", "SUPPRESS_FORENSICS");
        String type = supp.getClass().getName();
        System.out.println("  (SUPPRESS_FORENSICS 的实际类型: " + type + ")");
        check("抑制标志是线程局部的（ThreadLocal），不是全局布尔",
                type.contains("ThreadLocal"));

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
