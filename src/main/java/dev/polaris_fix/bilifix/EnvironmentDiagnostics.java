package dev.polaris_fix.bilifix;

import org.slf4j.Logger;

import java.util.ArrayList;
import java.util.List;

/**
 * 启动环境诊断：检测与 BiliFix 相关的崩溃风险因素，输出诊断报告。
 *
 * 检测项：
 * 1. watermedia 是否在 classpath（不在则 BiliFix 处于待命状态，正常）
 * 2. JVM 架构与内存（32 位 JVM / 低内存也是原生崩溃风险因素）
 * 3. 操作系统版本
 * 4. GPU 型号（Windows 注册表查询；崩溃与驱动相关，帮助定位）
 */
public final class EnvironmentDiagnostics {
    private EnvironmentDiagnostics() {}

    public static void run(Logger logger) {
        try {
            List<String> report = new ArrayList<>();
            report.add("==== BiliFix 环境诊断 ====");

            // 1. watermedia 存在性
            boolean watermediaPresent = checkClass("org.watermedia.WaterMedia");
            report.add("watermedia: " + (watermediaPresent
                    ? "已安装 ✓（BiliFix 正在守护）"
                    : "未安装（BiliFix 待命，不产生任何开销）"));

            // 2. Java 架构
            String arch = System.getProperty("os.arch", "unknown");
            String vmName = System.getProperty("java.vm.name", "unknown");
            boolean is64 = arch.contains("64") || "aarch64".equals(arch);
            report.add("JVM: " + vmName + " (" + arch + (is64 ? ", 64位 ✓" : ", 32位 ⚠ 32位 JVM 内存受限，建议换 64 位 Java") + ")");

            // 3. 操作系统
            report.add("OS: " + System.getProperty("os.name", "unknown")
                    + " " + System.getProperty("os.version", ""));

            // 4. GPU 检测（Windows 注册表，跨平台安全降级）
            String gpu = detectGpu();
            if (gpu != null) {
                report.add("GPU: " + gpu + (gpu.toLowerCase().contains("basic display") || gpu.toLowerCase().contains("microsoft")
                        ? " ⚠ 使用了基础显示驱动，图形栈可能异常" : ""));
            }

            // 5. 可用内存
            long maxMem = Runtime.getRuntime().maxMemory() / (1024 * 1024);
            report.add("JVM 最大内存: " + maxMem + " MB" + (maxMem < 2048 ? " ⚠ 偏低，视频解码可能吃紧" : " ✓"));

            for (String line : report) logger.info("[BiliFix] {}", line);
        } catch (Throwable t) {
            // 诊断绝不能崩游戏
            logger.debug("[BiliFix] 环境诊断异常（忽略）: {}", t.toString());
        }
    }

    /**
     * 检测 GPU 名称：仅 Windows（注册表查询），非 Windows 返回 null 安全降级。
     * 查询超时/失败均静默——诊断功能永不影响游戏。
     *
     * <p>实现注意：先在后台线程读完进程输出再 waitFor，避免管道缓冲区满导致
     * 的经典死锁（waitFor 与读流顺序颠倒时可能发生）。</p>
     */
    private static String detectGpu() {
        if (!System.getProperty("os.name", "").toLowerCase().contains("win")) return null;
        try {
            Process p = new ProcessBuilder("reg", "query",
                    "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}",
                    "/v", "DriverDesc").redirectErrorStream(true).start();
            // 后台线程读流防死锁
            var reader = new java.io.BufferedReader(new java.io.InputStreamReader(p.getInputStream()));
            var lines = new java.util.ArrayList<String>();
            var t = new Thread(() -> {
                try {
                    String line;
                    while ((line = reader.readLine()) != null) lines.add(line);
                } catch (Throwable ignored) {
                }
            }, "BiliFix-GPU-Detect");
            t.setDaemon(true);
            t.start();
            // 3 秒超时保护
            if (!p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) {
                p.destroyForcibly();
                return null;
            }
            t.join(500);
            for (String line : lines) {
                if (line.contains("DriverDesc") && line.contains("REG_SZ")) {
                    int i = line.indexOf("REG_SZ");
                    String name = line.substring(i + 6).trim();
                    if (!name.isEmpty()) return name;
                }
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    private static boolean checkClass(String fqn) {
        try {
            Class.forName(fqn, false, EnvironmentDiagnostics.class.getClassLoader());
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }
}
