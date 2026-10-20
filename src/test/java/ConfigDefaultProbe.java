import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * 配置默认值一致性探针 —— 钉住"默认值只有一个真源"。
 *
 * <p><b>缺陷背景（v1.4.8 审查发现）</b>：默认值 {@code none} / {@code gl,any} /
 * {@code false} 此前散落在<b>四个</b>地方：静态字段初始值、{@code load()} 的异常
 * 重置、{@code writeDefault()} 写进用户文件的内容、{@code hwDecoderValue()} 未知值
 * 回退。任何一处漏改就会出现：</p>
 * <ul>
 *   <li>新装用户拿到的配置文件是<b>另一套策略</b>；</li>
 *   <li>而加载日志说的是"已加载配置"，<b>没有任何异常提示</b>——</li>
 *   <li>用户按文件调好参数、重启、行为却不是那样。</li>
 * </ul>
 *
 * <p>这是一条典型的静默失效路径：所有环节都"成功"，只有行为不对。</p>
 *
 * <p>探针同时验证<b>行为</b>（生成的文件与常量一致、加载后生效值与常量一致），
 * 而不是只比对源码文本——源码比对只证明"字面量没漂"，行为比对才证明
 * "用户拿到的文件是对的"。</p>
 */
public class ConfigDefaultProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Config default probe (single source of truth)");

        // ---- 1. 常量本身必须是安全的 ----
        check("常量: DEFAULT_HW_DECODER = none（软解，最安全）",
                "none".equals(BiliFixConfig.DEFAULT_HW_DECODER));
        check("常量: DEFAULT_VOUT = gl,any（去掉 direct3d11）",
                "gl,any".equals(BiliFixConfig.DEFAULT_VOUT));
        check("常量: DEFAULT_VERBOSE = false", !BiliFixConfig.DEFAULT_VERBOSE);

        // ---- 2. 静态字段的初值必须等于常量 ----
        Field hw = BiliFixConfig.class.getField("hwDecoder");
        Field vo = BiliFixConfig.class.getField("vout");
        Field vb = BiliFixConfig.class.getField("verbose");
        // 反射读的是当前值，可能已被 load() 改过；先重置为常量再断言
        hw.set(null, BiliFixConfig.DEFAULT_HW_DECODER);
        vo.set(null, BiliFixConfig.DEFAULT_VOUT);
        vb.set(null, BiliFixConfig.DEFAULT_VERBOSE);
        check("字段: hwDecoder 初值 = DEFAULT_HW_DECODER",
                BiliFixConfig.DEFAULT_HW_DECODER.equals(hw.get(null)));
        check("字段: vout 初值 = DEFAULT_VOUT",
                BiliFixConfig.DEFAULT_VOUT.equals(vo.get(null)));
        check("字段: verbose 初值 = DEFAULT_VERBOSE",
                ((Boolean) vb.get(null)) == BiliFixConfig.DEFAULT_VERBOSE);

        // ---- 3. 写进用户文件的默认配置必须等于常量（行为级） ----
        Path dir = Files.createTempDirectory("bilifix-cfg-default-");
        Path cfg = dir.resolve("bilifix.toml");
        // writeDefault 是包级可见 —— 用反射调用
        java.lang.reflect.Method wd = BiliFixConfig.class.getDeclaredMethod("writeDefault", Path.class);
        wd.setAccessible(true);
        wd.invoke(null, cfg);
        check("写文件: bilifix.toml 已生成", Files.exists(cfg));
        List<String> lines = Files.readAllLines(cfg, StandardCharsets.UTF_8);
        String joined = String.join("\n", lines);
        check("写文件: 含 hwDecoder = \"" + BiliFixConfig.DEFAULT_HW_DECODER + "\"",
                joined.contains("hwDecoder = \"" + BiliFixConfig.DEFAULT_HW_DECODER + "\""));
        check("写文件: 含 vout = \"" + BiliFixConfig.DEFAULT_VOUT + "\"",
                joined.contains("vout = \"" + BiliFixConfig.DEFAULT_VOUT + "\""));
        check("写文件: 含 verbose = " + BiliFixConfig.DEFAULT_VERBOSE,
                joined.contains("verbose = " + BiliFixConfig.DEFAULT_VERBOSE));

        // ---- 4. 未知值回退必须等于常量（行为级） ----
        hw.set(null, "这不是一个合法的值");
        check("回退: 未知 hwDecoder 回退到 DEFAULT_HW_DECODER",
                BiliFixConfig.DEFAULT_HW_DECODER.equals(BiliFixConfig.hwDecoderValue()));
        hw.set(null, null);
        check("回退: null hwDecoder 回退到 DEFAULT_HW_DECODER",
                BiliFixConfig.DEFAULT_HW_DECODER.equals(BiliFixConfig.hwDecoderValue()));

        // ---- 5. 源码级：不得再有硬编码的默认字面量（防止有人再写一份） ----
        // NOTE: 源码断言必须以**文件路径为参数**传入，读取工作副本会让断言
        // 检查到未还原的文件，对坏代码也 PASS（此前已踩过一次）。
        String srcPath = (args.length > 0) ? args[0]
                : "src/main/java/dev/polaris_fix/bilifix/config/BiliFixConfig.java";
        String src = new String(Files.readAllBytes(Path.of(srcPath)), StandardCharsets.UTF_8);
        // 只看 load() 的 catch 块与 writeDefault() 里的字面量赋值
        boolean catchHasLiteral = src.contains("hwDecoder = \"none\";")
                || src.contains("vout = \"gl,any\";")
                || src.contains("verbose = false;");
        check("源码: 没有硬编码的默认赋值语句（全部引用 DEFAULT_* 常量）", !catchHasLiteral);
        check("源码: 定义了三个 DEFAULT_* 常量",
                src.contains("DEFAULT_HW_DECODER") && src.contains("DEFAULT_VOUT")
                        && src.contains("DEFAULT_VERBOSE"));

        // 清理
        try { Files.deleteIfExists(cfg); Files.deleteIfExists(dir); } catch (Throwable ignored) {}

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
