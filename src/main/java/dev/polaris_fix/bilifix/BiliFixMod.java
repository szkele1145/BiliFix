package dev.polaris_fix.bilifix;

import dev.polaris_fix.bilifix.config.BiliFixConfig;
import net.neoforged.fml.ModContainer;
import net.neoforged.fml.common.Mod;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * BiliFix —— watermedia/libVLC 崩溃修复模组
 *
 * <p>现象：整合包播放 B 站视频（bilibili_media + watermedia）一段时间后，
 * 游戏进程无声退出（退出码 -1），日志里只有 VLC 的输出、没有 Java 崩溃堆栈。</p>
 *
 * <p>根因：watermedia 创建 VLC 实例时强制启用 D3D11VA/DXVA2 硬解码
 * （--avcodec-hw d3d11va,dxva2,any）。解码线程将硬解表面经 vlcj 回调拷贝到
 * Java 堆时，在部分显卡驱动/多线程场景下原生层直接崩溃，杀死整个 JVM。</p>
 *
 * <p>修复：Mixin 拦截 watermedia 读取 videolan/arguments.json 的入口
 * （JarTool.readArray），运行时把危险参数替换为安全值：
 * <ul>
 *   <li>--avcodec-hw d3d11va,dxva2,any → --avcodec-hw none（软解，最稳）</li>
 *   <li>--vout direct3d11,glwin32,gl,any → --vout gl,any（去掉 D3D11 vout 偏好）</li>
 * </ul></p>
 *
 * <p>配置：.minecraft/config/bilifix.toml（hwDecoder / vout / verbose），修改后重启游戏生效。</p>
 */
@Mod(BiliFixMod.MOD_ID)
public class BiliFixMod {
    public static final String MOD_ID = "bilifix";
    public static final String VERSION = "1.3.0";
    public static final Logger LOGGER = LoggerFactory.getLogger("BiliFix");

    public BiliFixMod(ModContainer container) {
        BiliFixConfig.load();
        LOGGER.info("[BiliFix] v{} 已加载：watermedia VLC 硬解崩溃修复（策略: hw={}, vout={}）",
                VERSION, BiliFixConfig.hwDecoder, BiliFixConfig.vout);
        EnvironmentDiagnostics.run(LOGGER);
    }
}
