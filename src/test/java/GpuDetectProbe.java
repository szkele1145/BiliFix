import dev.polaris_fix.bilifix.EnvironmentDiagnostics;

import java.lang.reflect.Method;

/**
 * 探针：验证 detectGpu() 在真实 Windows 上能取到 GPU 名称。
 *
 * 缺陷背景（v1.4.8 修复）：
 * 显示适配器类 GUID {4d36e968-e325-11ce-bfc1-08002be10318} 本身没有
 * DriverDesc 值——它在每个适配器子键（0000、0001…）里。旧实现对父键执行
 * reg query /v DriverDesc，直接失败：
 *   ERROR: The system was unable to find the specified registry key or value.
 * 于是 detectGpu() 恒返回 null，GPU 行从未出现在诊断报告里。
 *
 * 实证（本机）：
 *   父键查询  -> 失败
 *   逐子键     -> 0000 -> AMD Radeon RX6500 XT
 *                 0001 -> GameViewer Virtual Display Adapter
 *
 * 本探针反射调用生产私有方法，验证它现在真的拿得到名字。
 */
public class GpuDetectProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("GPU detection probe");
        String os = System.getProperty("os.name", "");
        boolean isWindows = os.toLowerCase().contains("win");
        System.out.println("  os.name = " + os);

        Method m = EnvironmentDiagnostics.class.getDeclaredMethod("detectGpu");
        m.setAccessible(true);
        String gpu = (String) m.invoke(null);
        System.out.println("  detectGpu() = " + (gpu == null ? "null" : "\"" + gpu + "\""));

        if (!isWindows) {
            skip("非 Windows，GPU 检测按设计返回 null");
            System.out.println();
            System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
            System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
            System.exit(fail == 0 ? 0 : 1);
            return;
        }

        // 1. 必须拿到非空 GPU 名称（旧实现恒为 null）
        check("Windows 上 detectGpu() 返回非空 GPU 名称", gpu != null && !gpu.isBlank());

        // 2. 不得包含 reg 的错误文本
        check("结果不含 reg 错误文本", gpu == null || !gpu.toLowerCase().contains("error")
                && !gpu.toLowerCase().contains("unable to find"));

        // 3. 不得包含换行/制表等 reg 原始格式残留
        check("结果无 reg 原始格式残留（无 \\r \\n \\t）",
                gpu == null || (!gpu.contains("\r") && !gpu.contains("\n") && !gpu.contains("\t")));

        // 4. 不得为空串或纯空白
        check("结果非空白", gpu != null && !gpu.isBlank());

        // 5. 重复调用必须稳定（不应偶发返回 null）
        String gpu2 = (String) m.invoke(null);
        check("重复调用结果一致（稳定，非偶发）", gpu == null ? gpu2 == null : gpu.equals(gpu2));

        // 6. 源码级：不得再出现对父键直接 /v DriverDesc 的调用形态
        // 源码路径可由命令行传入——负向测试要把**被破坏的副本**传进来，
        // 否则源级断言读的是仓库里的原版，破坏根本进不了探针的视野
        // （"破坏没被发现"会被误读成"探针没测到"或"这不算缺陷"）。
        java.nio.file.Path srcPath = args.length > 0
                ? java.nio.file.Path.of(args[0])
                : java.nio.file.Paths.get("src", "main", "java", "dev", "polaris_fix",
                        "bilifix", "EnvironmentDiagnostics.java");
        String src = new String(java.nio.file.Files.readAllBytes(srcPath),
                java.nio.charset.StandardCharsets.UTF_8);
        check("源码含 CLASS_KEY_GUID 常量（子键查询的前提）", src.contains("CLASS_KEY_GUID"));
        check("源码含 regQueryValue（逐子键取值）", src.contains("regQueryValue"));

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
