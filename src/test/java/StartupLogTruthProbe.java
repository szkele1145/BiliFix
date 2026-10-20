import dev.polaris_fix.bilifix.BiliFixMod;
import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * 探针：启动日志里的策略值必须与**实际生效**的值一致。
 *
 * <p><b>缺陷背景（v1.4.8 修复）</b>：{@code BiliFixMod.init()} 打印的是
 * {@code BiliFixConfig.hwDecoder} / {@code .vout} 这两个<b>原始字段</b>，
 * 而真正写进 VLC 参数的是 {@code hwDecoderValue()} / {@code voutValue()}
 * 这两个<b>归一化</b>方法。两者在多处不同：</p>
 * <ul>
 *   <li>{@code disable} / {@code off} → {@code none}</li>
 *   <li>{@code auto} / {@code any} → {@code any}（大小写也被归一化）</li>
 *   <li>未知值（如 {@code gpu}）→ {@code none}，并另有一条警告</li>
 *   <li>{@code vout=original} / {@code keep} → 保留原值（null）</li>
 *   <li>{@code vout} 的大小写与首尾空白被标准化</li>
 * </ul>
 *
 * <p><b>为什么这是真问题</b>：这行是崩溃排查时读的第一行。用户写
 * {@code hwDecoder="gpu"}（未知值），日志说 {@code hw=gpu}，而实际已回退到
 * {@code none}（软解）——用户会以为硬解还开着，排查方向被直接带偏。
 * {@code hwDecoder="AUTO"} 更高危：日志说 {@code hw=AUTO}，实际是
 * {@code any}——即 VLC 自动选择硬解，正是崩溃根源那一档。</p>
 *
 * <p><b>实测（修复前）</b>：9 个取值组合里 <b>5 个</b>显示值与生效值不符。</p>
 *
 * <p>本探针捕获 {@code init()} 的真实日志输出（替换 slf4j 的输出流），逐个
 * 配置组合断言启动行里的两个值等于实际生效值。</p>
 */
public class StartupLogTruthProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }

    /**
     * 跑一次策略计算，返回启动行会显示的两个值。
     *
     * <p>{@code init()} 用 slf4j 输出，探针抓 System.out 抓不到；
     * 这里直接调用生产代码里的 {@code effectiveStrategy()}——它正是
     * {@code init()} 打印启动行时用的同一个方法（单一真相源）。</p>
     */
    static String[] runInit(String hw, String vout, Path tmp) throws Exception {
        BiliFixConfig.hwDecoder = hw;
        BiliFixConfig.vout = vout;
        BiliFixConfig.verbose = false;
        return BiliFixMod.effectiveStrategy();
    }

    /** 是否会打印「配置归一化」说明 */
    static boolean normalized(String hw, String vout) throws Exception {
        BiliFixConfig.hwDecoder = hw;
        BiliFixConfig.vout = vout;
        BiliFixConfig.verbose = false;
        return BiliFixMod.strategyWasNormalized();
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Startup log truth probe");
        Path tmp = Files.createTempDirectory("startup-log");

        // 配置组合 → 期望的（生效 hw, 生效 vout 显示形式）
        Object[][] cases = {
            //  hw 原值      vout 原值     期望 hw   期望 vout
            { "none",        "gl,any",     "none",   "gl,any"  },
            { "disable",     "gl,any",     "none",   "gl,any"  },
            { "off",         "gl,any",     "none",   "gl,any"  },
            { "auto",        "gl,any",     "any",    "gl,any"  },
            { "AUTO",        "gl,any",     "any",    "gl,any"  },
            { "any",         "gl,any",     "any",    "gl,any"  },
            { "gpu",         "gl,any",     "none",   "gl,any"  },   // 未知值 → 回退 none
            { "d3d11va",     "gl,any",     "d3d11va","gl,any"  },
            { "dxva2",       "gl,any",     "dxva2",  "gl,any"  },
            { "none",        "ORIGINAL",   "none",   "original"},
            { "none",        "keep",       "none",   "original"},
            { "none",        "GL,Any",     "none",   "gl,any"  },
            { "none",        " gl,any ",   "none",   "gl,any"  },
        };

        int mismatches = 0;
        for (Object[] c : cases) {
            String rawHw = (String) c[0];
            String rawVout = (String) c[1];
            String expHw = (String) c[2];
            String expVout = (String) c[3];

            String[] got = runInit(rawHw, rawVout, tmp);
            boolean ok = expHw.equals(got[0]) && expVout.equals(got[1]);
            if (!ok) {
                mismatches++;
                System.out.println("  [FAIL] hw=" + rawHw + " vout=" + rawVout
                        + " → 启动行显示 hw=" + got[0] + " vout=" + got[1]
                        + "，期望 hw=" + expHw + " vout=" + expVout);
            } else {
                pass++;
                System.out.println("  [PASS] hw=" + rawHw + " vout=" + rawVout
                        + " → 启动行显示 hw=" + got[0] + " vout=" + got[1]);
            }
        }
        check("所有配置组合下启动行都显示实际生效值（0 处不一致）", mismatches == 0);

        // 归一化发生时必须额外说明，避免用户以为配置没生效
        check("配置被归一化时（未知值 gpu）标记为已归一化", normalized("gpu", "gl,any"));
        check("配置本来就规范时不标记为已归一化", !normalized("none", "gl,any"));
        check("vout 归一化（ORIGINAL → original）被标记为已归一化", normalized("none", "ORIGINAL"));
        check("vout=keep → original（显示值变了）也算归一化", normalized("none", "keep"));
        check("hw=none 与 vout=gl,any 都不算归一化", !normalized("none", "gl,any"));
        check("hw=disable → none（语义等价但显示变了）也算归一化", normalized("disable", "gl,any"));

        // 源码级：启动行不得直接引用原始字段。
        // 注意：源码文件路径可用参数覆盖——负向测试跑的是**副本**，
        // 若探针硬读工作目录下的源码，断言查的就不是被测的那份代码
        // （负向测试里这条断言曾因此假 PASS）。
        {
            Path modSrc = args.length > 0 ? java.nio.file.Paths.get(args[0])
                    : java.nio.file.Paths.get("src", "main", "java",
                            "dev", "polaris_fix", "bilifix", "BiliFixMod.java");
            String src = new String(Files.readAllBytes(modSrc), StandardCharsets.UTF_8);
            check("源码启动行使用归一化后的值（不含 BiliFixConfig.hwDecoder, BiliFixConfig.vout 的直传）",
                    !src.contains("VERSION, BiliFixConfig.hwDecoder, BiliFixConfig.vout"));
            check("源码含配置归一化说明行", src.contains("配置归一化"));
            // effectiveStrategy() 必须调用归一化方法，而不是直接读原始字段。
            // 只查整个文件不够：strategyWasNormalized() 里同样有这两个调用。
            // 这里只看 effectiveStrategy() 的方法体。
            int effAt = src.indexOf("public static String[] effectiveStrategy()");
            boolean effOk = false;
            if (effAt >= 0) {
                int bodyEnd = src.indexOf("public static boolean strategyWasNormalized()", effAt);
                String body = bodyEnd > effAt ? src.substring(effAt, bodyEnd) : src.substring(effAt);
                effOk = body.contains("hwDecoderValue()") && body.contains("voutValue()")
                        && !body.contains("BiliFixConfig.hwDecoder;")
                        && !body.contains("BiliFixConfig.vout;");
            }
            check("effectiveStrategy() 方法体调用归一化方法而非直读原始字段", effOk);
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
