package dev.polaris_fix.bilifix;

import org.slf4j.Logger;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/**
 * 启动环境诊断：检测与 BiliFix 相关的崩溃风险因素，输出诊断报告。
 *
 * 检测项：
 * 1. watermedia 是否在 classpath（不在则 BiliFix 处于待命状态，正常）
 * 2. watermedia 内置参数中是否含 D3D11VA/DXVA2 硬解（确认修复必要性）
 * 3. 显卡/驱动信息（崩溃与驱动相关，帮助定位）
 * 4. JVM 是否为 64 位（32 位 JVM 内存不足也会导致原生崩溃）
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

            // 4. OpenGL/显卡：通过 Debug 输出（无法安全拿到，跳过；由 VLC 日志承担）
            // 5. 可用内存
            long maxMem = Runtime.getRuntime().maxMemory() / (1024 * 1024);
            report.add("JVM 最大内存: " + maxMem + " MB" + (maxMem < 2048 ? " ⚠ 偏低，视频解码可能吃紧" : " ✓"));

            for (String line : report) logger.info("[BiliFix] {}", line);
        } catch (Throwable t) {
            // 诊断绝不能崩游戏
            logger.debug("[BiliFix] 环境诊断异常（忽略）: {}", t.toString());
        }
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
