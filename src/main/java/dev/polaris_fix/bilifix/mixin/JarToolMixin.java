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
            switch (arg) {
                case "--avcodec-hw" -> {
                    sawHw = true;
                    fixed.add("--avcodec-hw");
                    fixed.add(hw);
                    if (i + 1 < original.length && isValue(original[i + 1])) i++;
                }
                case "--vout" -> {
                    sawVout = true;
                    if (vout != null) {
                        fixed.add("--vout");
                        fixed.add(vout);
                        // 跳过原值
                        if (i + 1 < original.length && isValue(original[i + 1])) i++;
                    } else if (i + 1 < original.length && isValue(original[i + 1])) {
                        // vout=original：保留原参数与原值
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
        cir.setReturnValue(fixed.toArray(new String[0]));
    }

    /** VLC 参数值不会以 - 开头（长选项 -- 与短选项 - 都排除） */
    private static boolean isValue(String s) {
        return !s.startsWith("-");
    }
}
