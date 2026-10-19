package dev.polaris_fix.bilifix;

import dev.polaris_fix.bilifix.config.BiliFixConfig;
import org.slf4j.Logger;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

/**
 * Mixin 注入目标自检：确认 watermedia 的目标方法签名仍与预期一致。
 *
 * <p><b>为什么需要</b>：本模组的修复依赖一个 Mixin 注入点——
 * {@code JarTool.readArray(String)}。Mixin 按<b>方法名</b>匹配目标，而
 * {@code bilifix.mixins.json} 里 {@code defaultRequire: 0}（可选注入）。
 * 于是存在一个沉默的失效路径：</p>
 * <ul>
 *   <li>未来 watermedia 给 {@code readArray} 加了重载 → 目标不再唯一
 *       → Mixin 解析到多个候选 → <b>静默跳过注入</b>；</li>
 *   <li>未来 watermedia 改了 {@code readArray} 的签名（如加了参数）
 *       → 目标根本找不到 → 同样<b>静默跳过注入</b>。</li>
 * </ul>
 * <p>这两种情况下 BiliFix 都会"装上了、修好了、什么都没发生"——用户只会看到
 * 崩溃回归，却找不到任何线索。本类在启动时做一次自检，把沉默的失效变成
 * 启动日志里的一条警告。</p>
 *
 * <p><b>检查内容</b>：反射读取 {@code org.watermedia.core.tools.JarTool}，
 * 统计名为 {@code readArray} 的方法：
 * <ul>
 *   <li>恰好 1 个，且参数为 {@code (String)}、返回 {@code String[]}、
 *       且为 {@code static} → 目标唯一，Mixin 必然命中；</li>
 *   <li>0 个或 ≥2 个 → 目标歧义/缺失，Mixin 会静默跳过 → 警告。</li>
 * </ul>
 *
 * <p><b>为什么用反射而不是解析字节码</b>：watermedia 不在编译期 classpath 上
 * （Fabric 侧完全没有这个 jar），任何直接引用都会编译失败。用
 * {@link Class#forName} 拿不到类时，判定为"watermedia 未安装"，属正常情况，
 * 不报警——这与 {@link EnvironmentDiagnostics} 的 mod 探测同一套降级原则。</p>
 */
public final class MixinTargetGuard {
    private MixinTargetGuard() {}

    /** 目标类全名（与 JarToolMixin 的 @Mixin(targets=...) 保持一致） */
    private static final String TARGET_CLASS = "org.watermedia.core.tools.JarTool";
    /** 目标方法名（与 @Inject(method=...) 保持一致） */
    private static final String TARGET_METHOD = "readArray";
    /** 期望的参数类型 */
    private static final Class<?>[] EXPECTED_PARAMS = { String.class };
    /** 期望的返回类型 */
    private static final Class<?> EXPECTED_RETURN = String[].class;

    /** 判定结果，便于单测与诊断输出 */
    public enum Status {
        /** 目标唯一且签名完全匹配 —— Mixin 必然命中 */
        OK,
        /** 目标签名不匹配（参数/返回/非 static）—— Mixin 会静默跳过 */
        SIGNATURE_MISMATCH,
        /** 目标方法缺失或存在重载 —— Mixin 会静默跳过 */
        AMBIGUOUS_OR_MISSING,
        /** watermedia 未安装 —— 正常情况，无需报警 */
        WATERMEDIA_ABSENT
    }

    /**
     * 执行自检并输出结果。
     *
     * @param logger 日志器
     * @return 判定结果（便于调用方做额外处理）
     */
    public static Status check(Logger logger) {
        Status status = evaluate();
        switch (status) {
            case OK -> logger.info("[BiliFix] Mixin 注入目标自检通过: {}.{}(String) 唯一匹配",
                    TARGET_CLASS, TARGET_METHOD);
            case WATERMEDIA_ABSENT -> logger.info("[BiliFix] 未检测到 watermedia，Mixin 注入目标自检跳过");
            case SIGNATURE_MISMATCH -> logger.warn(
                    "[BiliFix] ⚠ Mixin 注入目标签名已变化（{}.{}），本版本修复可能不生效。"
                    + "请向 BiliFix 反馈该 watermedia 版本。", TARGET_CLASS, TARGET_METHOD);
            case AMBIGUOUS_OR_MISSING -> logger.warn(
                    "[BiliFix] ⚠ Mixin 注入目标缺失或存在重载（{}.{}），本版本修复可能不生效。"
                    + "请向 BiliFix 反馈该 watermedia 版本。", TARGET_CLASS, TARGET_METHOD);
        }
        return status;
    }

    /**
     * 纯判定逻辑（不依赖 logger，便于单测）。
     */
    public static Status evaluate() {
        Class<?> cls;
        try {
            cls = Class.forName(TARGET_CLASS, false, MixinTargetGuard.class.getClassLoader());
        } catch (ClassNotFoundException e) {
            return Status.WATERMEDIA_ABSENT;
        } catch (Throwable t) {
            // 类在但链接失败：仍视为"已安装"，只是无法核验签名 → 按歧义处理
            return Status.AMBIGUOUS_OR_MISSING;
        }

        int matches = 0;
        boolean signatureOk = false;
        try {
            for (Method m : cls.getDeclaredMethods()) {
                if (!m.getName().equals(TARGET_METHOD)) continue;
                matches++;
                if (Modifier.isStatic(m.getModifiers())
                        && m.getReturnType() == EXPECTED_RETURN
                        && java.util.Arrays.equals(m.getParameterTypes(), EXPECTED_PARAMS)) {
                    signatureOk = true;
                }
            }
        } catch (Throwable t) {
            return Status.AMBIGUOUS_OR_MISSING;
        }

        if (matches == 0) return Status.AMBIGUOUS_OR_MISSING;   // 目标消失
        if (matches > 1) return Status.AMBIGUOUS_OR_MISSING;    // 重载 → 歧义
        return signatureOk ? Status.OK : Status.SIGNATURE_MISMATCH;
    }

    /**
     * 功能级自检：真正调用一次 {@code readArray("videolan/arguments.json")}，
     * 检查返回的参数是否已被本模组加固。
     *
     * <p><b>为什么要功能级</b>：{@link #evaluate()} 只证明"目标类存在且签名唯一"，
     * 证明不了"Mixin 注入真的应用了"。mixin 框架对 {@code required:false} 的
     * 配置会把注入失败降级为 debug 日志（正常日志级别下不可见）——于是还剩
     * 最后一条静默失效路径：<b>目标完好、签名匹配、但注入没打上</b>。
     * 唯一可靠的判据是端到端的：调用一次，看返回值。</p>
     *
     * <p><b>时序依据</b>：本方法在 mod 构造时调用。mixin 转换发生在<b>类加载</b>
     * 时——JarTool 此前从未被加载（无人触碰），本方法第一次触发其加载，
     * MixinTransformer 已在链上（mod 构造前 mixin 系统已激活），
     * 所以此刻看到的就是被注入后的方法。</p>
     *
     * <p><b>安全性</b>（javap 字节码实证）：JarTool 的 {@code <clinit>} 只建
     * log4j Marker 与 Gson 实例；readArray 只读 jar 内资源 + Gson 解析，
     * 无网络、无原生库、无文件写入——可安全调用。</p>
     *
     * <p>裸 JVM 探针（无 mixin 环境）验证过：该探测在"没有 mixin"时正确报告
     * 参数未被加固（能分辨"修了"与"没修"）。</p>
     *
     * @param logger 日志器
     * @return true = 参数已被加固（修复链路端到端生效）；
     *         false = 参数仍是原始危险值（注入未生效）或无法判定
     */
    public static boolean functionalProbe(Logger logger) {
        // 取证抑制：本次调用会真的触发 mixin → recordHarden → mediaTouched=true。
        // 若不抑制，用户根本没播放媒体也会被记成"media touched: yes"，
        // 摧毁 v1.4.7 建立的核心取证语义。try/finally 保证成对复位。
        CrashSentinel.setForensicsSuppressed(true);
        try {
            Class<?> cls = Class.forName(TARGET_CLASS, true, MixinTargetGuard.class.getClassLoader());
            Method readArray = cls.getDeclaredMethod(TARGET_METHOD, String.class);
            String[] args = (String[]) readArray.invoke(null, PROBE_RESOURCE);
            if (args == null) {
                logger.warn("[BiliFix] ⚠ 功能自检无法判定：readArray({}) 返回 null", PROBE_RESOURCE);
                return false;
            }
            // 两项都要验：--avcodec-hw 是解码侧（D3D11VA 崩溃根源），--vout 是输出侧
            // （direct3d11 同样是危险路径）。只验前者会漏掉"vout 没被改写"。
            String expectedHw = BiliFixConfig.hwDecoderValue();
            String expectedVout = BiliFixConfig.voutValue();
            String actualHw = findValue(args, "--avcodec-hw");
            String actualVout = findValue(args, "--vout");
            boolean hwOk = expectedHw.equals(actualHw);
            // expectedVout == null 表示用户显式设 vout=original（有意保留原值）→
            // 此时只要参数表里有 --vout 就算符合预期，不误报。
            boolean voutOk = expectedVout == null ? actualVout != null : expectedVout.equals(actualVout);

            if (hwOk && voutOk) {
                logger.info("[BiliFix] 功能自检通过: --avcodec-hw={} , --vout={} —— 注入已生效（端到端验证）",
                        expectedHw, expectedVout == null ? "(保留原值)" : expectedVout);
                return true;
            }
            logger.warn("[BiliFix] ⚠ 功能自检失败：实际 --avcodec-hw={}（期望 {}）, --vout={}（期望 {}）。"
                    + "Mixin 注入未生效或配置不匹配，本版本修复可能不工作！请向 BiliFix 反馈。",
                    actualHw == null ? "(缺失)" : actualHw, expectedHw,
                    actualVout == null ? "(缺失)" : actualVout,
                    expectedVout == null ? "(保留原值)" : expectedVout);
            return false;
        } catch (ClassNotFoundException e) {
            // watermedia 未安装：与 evaluate() 同一判定，正常情况，静默
            return false;
        } catch (Throwable t) {
            // 探测本身失败（资源缺、链接错…）：不干扰游戏，只在 debug 级留痕
            logger.debug("[BiliFix] 功能自检异常（忽略）: {}", t.toString());
            return false;
        } finally {
            // 必须复位：否则之后用户真的播放媒体时，取证数据会被永久抑制
            CrashSentinel.setForensicsSuppressed(false);
        }
    }

    /**
     * 从 VLC 参数数组中取出某个长选项的值。
     *
     * <p>同时支持 {@code "--key value"} 与 {@code "--key=value"} 两种 VLC 写法
     * （与 {@code JarToolMixin} 的解析规则保持一致——自检与实际改写必须用同一套
     * 判定，否则自检会给出与真实行为相矛盾的结论）。</p>
     *
     * @return 找到的值；该选项不存在时返回 null
     */
    private static String findValue(String[] args, String key) {
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if (a == null) continue;
            if (key.equals(a)) {
                // "--key value" 形式：值必须不以 "-" 开头（VLC 值不会以 - 开头）
                if (i + 1 < args.length && args[i + 1] != null && !args[i + 1].startsWith("-")) {
                    return args[i + 1];
                }
                return null;   // 存在但无值（如单独的 --vout）
            }
            if (a.startsWith(key + "=")) {
                return a.substring(key.length() + 1);
            }
        }
        return null;
    }

    /** 功能探测用的资源名：与 PlayerAPI 实际读取的完全一致（javap 实证） */
    private static final String PROBE_RESOURCE = "videolan/arguments.json";
}
