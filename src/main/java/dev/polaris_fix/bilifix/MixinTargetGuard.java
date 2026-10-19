package dev.polaris_fix.bilifix;

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
}
