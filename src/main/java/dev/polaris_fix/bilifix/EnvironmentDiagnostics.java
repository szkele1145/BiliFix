package dev.polaris_fix.bilifix;

import org.slf4j.Logger;

import java.util.ArrayList;
import java.util.List;

/**
 * 启动环境诊断：检测与 BiliFix 相关的崩溃风险因素，输出诊断报告。
 *
 * 检测项：
 * 1. 前置链路版本感知：watermedia / bilibili_media / waterframes（FML ModList 运行时 API）
 * 2. JVM 架构（32 位 JVM 本身也是原生崩溃风险因素）
 * 3. 操作系统版本
 * 4. GPU 型号（Windows 注册表查询；崩溃与驱动相关，帮助定位）
 * 5. 可用内存上限（解码吃紧时会放大原生层问题）
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
     *
     * <p><b>必须逐个子键查询（v1.4.8 修复）</b>：显示适配器类 GUID
     * {@code {4d36e968-e325-11ce-bfc1-08002be10318}} 本身<b>没有</b>
     * {@code DriverDesc} 值——该值在每个适配器子键（{@code 0000}、{@code 0001}…）里。
     * 对父键执行 {@code reg query /v DriverDesc} 会直接失败：
     * <pre>ERROR: The system was unable to find the specified registry key or value.</pre>
     * 旧实现因此让 GPU 行<b>永远不出现在诊断报告里</b>（本机实证：父键查询失败，
     * 逐子键查询得到 "AMD Radeon RX6500 XT"）。而 GPU/驱动信息恰恰是
     * 原生崩溃排查最需要的一环。</p>
     */
    private static String detectGpu() {
        if (!System.getProperty("os.name", "").toLowerCase().contains("win")) return null;
        try {
            // 1) 列出适配器子键（reg query <父键> 的输出里，子键是完整的
            //    HKEY_LOCAL_MACHINE\...\0000 路径；值行以 4 个空格开头）
            List<String> subKeys = new ArrayList<>();
            for (String line : regQuery(CLASS_KEY_GUID, null)) {
                String t = line.trim();
                if (t.isEmpty()) continue;
                // 子键路径以 HKEY_ 开头；值行是 "名称    REG_SZ    值"
                if (!t.regionMatches(true, 0, "HKEY_", 0, 5)) continue;
                int last = t.lastIndexOf('\\');
                if (last < 0 || last == t.length() - 1) continue;
                String sub = t.substring(last + 1);
                // 只接受形如 0000 的子键（显示适配器实例键）
                if (sub.length() == 4 && sub.chars().allMatch(Character::isDigit)) {
                    subKeys.add(sub);
                }
            }
            if (subKeys.isEmpty()) {
                // 兜底：老系统/异常环境下父键本身可能有值，仍试一次
                return regQueryValue(CLASS_KEY_GUID, "DriverDesc");
            }
            // 2) 逐个子键取 DriverDesc
            StringBuilder names = new StringBuilder();
            for (String sub : subKeys) {
                String desc = regQueryValue(CLASS_KEY_GUID + "\\" + sub, "DriverDesc");
                if (desc == null || desc.isEmpty()) continue;
                if (names.length() > 0) names.append(" / ");
                names.append(desc);
            }
            return names.length() == 0 ? null : names.toString();
        } catch (Throwable ignored) {
        }
        return null;
    }

    /** 显示适配器类 GUID（其下每个子键对应一块适配器） */
    private static final String CLASS_KEY_GUID =
            "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}";

    /**
     * 执行 reg query 并返回输出行；{@code valueName} 为 null 时只列出子键。
     * 失败/超时/非 Windows 一律返回空结果——诊断永不影响游戏。
     */
    private static List<String> regQuery(String key, String valueName) {
        List<String> out = new ArrayList<>();
        try {
            List<String> args = new ArrayList<>();
            args.add("reg");          // 可执行程序（ProcessBuilder(List) 的第 0 项是命令本身）
            args.add("query");
            args.add(key);
            if (valueName != null) {
                args.add("/v");
                args.add(valueName);
            }
            Process p = new ProcessBuilder(args).redirectErrorStream(true).start();
            // 后台线程读流防死锁（管道缓冲区满时 waitFor 会与读流互相等待）
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
                return out;
            }
            t.join(500);
            for (String line : lines) out.add(line);
        } catch (Throwable ignored) {
        }
        return out;
    }

    /**
     * 读取某个注册表键下的字符串值（REG_SZ / REG_EXPAND_SZ）。
     *
     * <p>解析 {@code reg query} 的输出格式：{@code <name>    REG_SZ    <value>}。
     * 注意值本身可能含空格，故按 REG_SZ 之后的第一个分隔符切分再 trim。</p>
     */
    private static String regQueryValue(String key, String valueName) {
        for (String line : regQuery(key, valueName)) {
            if (!line.contains(valueName)) continue;
            int i = line.indexOf("REG_SZ");
            if (i < 0) continue;
            String value = line.substring(i + "REG_SZ".length()).trim();
            // reg 对 REG_SZ 输出 "    <value>"，去掉前导分隔空格即可
            if (!value.isEmpty()) return value;
        }
        return null;
    }

    private static boolean checkClass(String fqn) {
        try {
            // initialize=false：只验证类可加载，不跑 <clinit>，静态依赖不会被执行
            Class.forName(fqn, false, EnvironmentDiagnostics.class.getClassLoader());
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        } catch (Throwable t) {
            // 类文件存在但依赖缺失等（NoClassDefFoundError / LinkageError）：
            // 这恰恰证明 mod 的 jar 在 classpath 上——存在性判定仍应为 true。
            // 捕 Throwable 与 run() 的"诊断绝不能崩游戏"同一原则。
            //
            // 探针实证（ForNameProbe2，运行时 classpath 故意不含依赖类）：
            //   Class.forName("NeedsMissing", false, loader) → java.lang.NoClassDefFoundError
            //   （initialize=false 同样会触发链接并抛错，不是 ClassNotFoundException）
            // 只捕 ClassNotFoundException 会让这个 Error 冒泡到 modLine 的
            // catch(Throwable) → 走"未安装"分支 → 已安装的 mod 被报成未安装。
            return true;
        }
    }

    /**
     * 生成一行 mod 状态报告：通过 FML ModList 查 mod 的版本（运行时 API，统一来源）。
     * FML 不可用时（Fabric / 极端早期）回退到 classpath 检测，只报存在性不报版本。
     * 版本值含 "${}" 未替换占位符（上游打包瑕疵）时视为无版本。
     */
    private static String modLine(String modId, String presentNote, String absentNote) {
        try {
            String ver = FmlBridge.modVersion(modId);
            if (ver != null) {
                boolean usable = !ver.isBlank() && !ver.contains("${");
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
