package dev.polaris_fix.bilifix.mixin;

import dev.polaris_fix.bilifix.BiliFixMod;
import dev.polaris_fix.bilifix.config.BiliFixConfig;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.ArrayList;
import java.util.List;

/**
 * 拦截 watermedia 的 JarTool.readArray(String)。
 *
 * PlayerAPI.start() 通过它读取 videolan/arguments.json 得到 VLC 启动参数，
 * 随后创建 MediaPlayerFactory。我们在这里把参数替换成安全版本：
 * <ul>
 *   <li>--avcodec-hw ... → --avcodec-hw <hwDecoder 配置>（默认 none 软解）</li>
 *   <li>--vout ...       → --vout <vout 配置>（默认 gl,any；配置 original 则不动）</li>
 * </ul>
 * 其余参数原样保留。支持 "--key value" 与 "--key=value" 两种 VLC 参数写法。
 *
 * <p>鲁棒性设计：</p>
 * <ul>
 *   <li>@Pseudo：watermedia 未安装时本 Mixin 静默跳过，绝不硬失败</li>
 *   <li>若参数表中没有 --avcodec-hw / --vout，主动追加安全值，防止未来 watermedia
 *       改参数表导致修复失效</li>
 * </ul>
 *
 * <p>并发性（第 5 轮审查结论）：readArray 仅由 PlayerAPI.start() 在启动线程
 * 串行调用一次（registerFactory 本身是 synchronized）；本 Mixin 无共享可变状态，
 * 无并发风险。覆盖范围：一切经 watermedia 播放的模组（netmusic、waterframes、
 * create_waterframes 等）都在此入口统一受益。</p>
 */
@Pseudo
@Mixin(targets = "org.watermedia.core.tools.JarTool", remap = false)
public class JarToolMixin {

    @Inject(method = "readArray", at = @At("RETURN"), cancellable = true)
    private static void bilifix$makeArgsSafe(String resource, CallbackInfoReturnable<String[]> cir) {
        if (resource == null || !resource.contains("videolan/arguments")) return;
        String[] original = cir.getReturnValue();
        if (original == null || original.length == 0) return;

        String hw = BiliFixConfig.hwDecoderValue();
        String vout = BiliFixConfig.voutValue();

        List<String> fixed = new ArrayList<>(original.length + 4);
        boolean sawHw = false;
        boolean sawVout = false;

        for (int i = 0; i < original.length; i++) {
            String arg = original[i];
            // null 元素防御：switch (arg) 与 arg.startsWith(...) 都会对 null 抛 NPE
            // （String 的 hashCode 被调用）。真实 arguments.json 里不会有 null（Gson
            // 不产出 null 元素），但 readArray 是**通用**方法——watermedia 将来用它
            // 读别的 JSON，其值完全可以含 null。
            //
            // 后果不可接受：本 mixin 是"绝对安全的加固点"，一个 NPE 从这里冒进
            // watermedia 的 PlayerAPI.start() 会让**媒体播放直接失败**——加固点
            // 反而成了故障源。
            //
            // null 元素**丢弃**而不是保留：它不可能是有效的 VLC 参数，保留下去
            // 等于把坏数据交给 libVLC。而且它若正好落在某个选项的**值位置**，
            // 保留它会让那个选项读到 null 值——丢弃更接近真实语义。
            if (arg == null) continue;
            switch (arg) {
                case "--avcodec-hw" -> {
                    sawHw = true;
                    fixed.add("--avcodec-hw");
                    fixed.add(hw);
                    i = skipOldValue(original, i); // 丢弃旧值
                }
                case "--vout" -> {
                    sawVout = true;
                    if (vout != null) {
                        fixed.add("--vout");
                        fixed.add(vout);
                        i = skipOldValue(original, i); // 丢弃旧值
                    } else if (i + 1 < original.length && isValue(original[i + 1])) {
                        // vout=original：保留原参数与原值（消费掉，防重复处理）
                        fixed.add("--vout");
                        fixed.add(original[i + 1]);
                        i++;
                    }
                    // vout==null 且无值（如单独的 --vout）：原样保留
                    else fixed.add("--vout");
                }
                default -> {
                    if (arg.startsWith("--avcodec-hw=")) {
                        sawHw = true;
                        fixed.add("--avcodec-hw=" + hw);
                    } else if (arg.startsWith("--vout=")) {
                        sawVout = true;
                        if (vout != null) fixed.add("--vout=" + vout);
                        else fixed.add(arg); // vout=original：原样保留
                    } else {
                        fixed.add(arg);
                    }
                }
            }
        }

        // 未来防御：参数表中没有 --avcodec-hw 时主动补加，确保修复始终生效
        if (!sawHw) {
            fixed.add("--avcodec-hw");
            fixed.add(hw);
            BiliFixMod.LOGGER.info("[BiliFix] 参数表中未找到 --avcodec-hw，已主动追加安全值: {}", hw);
        }
        if (vout != null && !sawVout) {
            fixed.add("--vout");
            fixed.add(vout);
            BiliFixMod.LOGGER.info("[BiliFix] 参数表中未找到 --vout，已主动追加: {}", vout);
        }

        if (BiliFixConfig.verbose) {
            BiliFixMod.LOGGER.info("[BiliFix] 原始参数 ({}): {}", original.length, String.join(" ", original));
            BiliFixMod.LOGGER.info("[BiliFix] 替换参数 ({}): {}", fixed.size(), String.join(" ", fixed));
        } else {
            BiliFixMod.LOGGER.info("[BiliFix] VLC 参数已加固: --avcodec-hw={} , --vout={} (原 {} 项 → 新 {} 项)",
                    hw, vout == null ? "(保留原值)" : vout, original.length, fixed.size());
        }
        // 上报给崩溃诊断守护（v1.4.0）：无声崩溃时留下一份"修复确实生效过"的证据
        // （verbose 配置时附带完整参数序列，进诊断文件）
        dev.polaris_fix.bilifix.CrashSentinel.recordHarden(original.length, fixed.size(),
                BiliFixConfig.verbose ? String.join(" ", fixed) : null);
        cir.setReturnValue(fixed.toArray(new String[0]));
    }

    /**
     * VLC 参数值不会以 - 开头（长选项 -- 与短选项 - 都排除）。
     *
     * <p>null 视为"不是值"：参数表里出现 null 元素时不能因它抛 NPE
     * （见循环里的 null 防御注释）。返回 false 时调用方会原样保留该元素。</p>
     */
    private static boolean isValue(String s) {
        return s != null && !s.startsWith("-");
    }

    /** 若 args[i+1] 是值（不以 - 开头），返回 i+1 跳过它；否则返回 i。用于丢弃被替换掉的旧值。 */
    private static int skipOldValue(String[] args, int i) {
        return (i + 1 < args.length && isValue(args[i + 1])) ? i + 1 : i;
    }
}
