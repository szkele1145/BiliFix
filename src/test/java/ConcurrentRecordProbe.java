import dev.polaris_fix.bilifix.CrashSentinel;

import java.lang.reflect.Field;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * 真实并发探针：直接对生产 CrashSentinel.record() 施加并发压力，
 * 验证 MAX_EVENTS 上限是硬保证（而非仅靠源码正则断言 synchronized 存在）。
 *
 * 背景：Regression §14 只断言了 record() 源码里有 synchronized 关键字——
 * 这是"检查药方"而不是"检查疗效"。若未来有人删掉 synchronized 却保留了
 * CopyOnWriteArrayList（仍是线程安全的集合），正则断言会失败，但没有行为
 * 级证据证明 synchronized 真的防住了并发超限。
 */
public class ConcurrentRecordProbe {
    public static void main(String[] args) throws Exception {
        // 反射拿到 EVENTS 集合与 MAX_EVENTS 常量，不改动生产代码
        Class<?> c = CrashSentinel.class;
        Field f = c.getDeclaredField("EVENTS");
        f.setAccessible(true);
        List<?> events = (List<?>) f.get(null);
        Field mf = c.getDeclaredField("MAX_EVENTS");
        mf.setAccessible(true);
        int maxEvents = (int) mf.get(null);
        System.out.println("MAX_EVENTS = " + maxEvents);

        int threads = 32, perThread = 500;
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(threads);
        for (int t = 0; t < threads; t++) {
            final int tid = t;
            pool.submit(() -> {
                try {
                    start.await();
                    for (int i = 0; i < perThread; i++) {
                        CrashSentinel.record("probe thread " + tid + " event " + i);
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    done.countDown();
                }
            });
        }
        start.countDown();
        if (!done.await(60, TimeUnit.SECONDS)) { System.out.println("TIMEOUT"); System.exit(2); }
        pool.shutdown();

        int size = events.size();
        System.out.println("EVENTS size after " + threads + "*" + perThread + " records = " + size);
        boolean hardCap = size <= maxEvents;
        System.out.println("HARD_CAP_HELD = " + hardCap);
        System.out.println("RESULT = " + (hardCap ? "PASS" : "FAIL"));
        System.exit(hardCap ? 0 : 1);
    }
}
