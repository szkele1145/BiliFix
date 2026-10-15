package dev.polaris_fix.bilifix;

import org.slf4j.Logger;

import java.util.ArrayList;
import java.util.List;

/**
 * 启动环境诊断：检测与 BiliFix 相关的崩溃风险因素，输出诊断报告。
 *
 * 检测项：
 * 1. 前置链路版本感知：watermedia / bilibili_media / waterframes（FML ModList 运行时 API）
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

            // 1. 前置链路版本感知（FML ModList 运行时 API，统一拿任意 mod 版本）
            report.add("watermedia: " + modLine("watermedia", "BiliFix 正在守护", "BiliFix 待命，不产生任何开销"));
            report.add("bilibili_media: " + modLine("bilibili_media", "前置链路就绪", "未安装（B 站解析不可用，不影响 netmusic 等场景）"));
            report.add("waterframes: " + modLine("waterframes", "播放屏幕就绪", "未安装"));

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

    /**
     * 生成一行 mod 状态报告：通过 FML ModList 查 mod 的版本（运行时 API，统一来源）。
     * FML 不可用时（极端早期）回退到 classpath 检测，只报存在性不报版本。
     * 版本值含 "${}" 未替换占位符（上游打包瑕疵）时视为无版本。
     */
    private static String modLine(String modId, String presentNote, String absentNote) {
        try {
            var mi = net.neoforged.fml.ModList.get().getModFileById(modId);
            if (mi != null) {
                String ver = mi.versionString();
                boolean usable = ver != null && !ver.isBlank() && !ver.contains("${");
                return "已安装 ✓" + (usable ? "（版本 " + ver + "）" : "") + "（" + presentNote + "）";
            }
        } catch (Throwable ignored) {
            // ModList 不可用时回退 classpath 检测
        }
        // 回退：classpath 探测常见入口类
        String probe = switch (modId) {
            case "watermedia" -> "org.watermedia.WaterMedia";
            case "bilibili_media" -> "dev.polaris_light.bilibili_media.BiliBiliMedia";
            case "waterframes" -> "me.srrapero720.waterframes.WaterFrames";
            default -> null;
        };
        if (probe != null && checkClass(probe)) return "已安装（版本未知）（" + presentNote + "）";
        return absentNote;
    }
}
