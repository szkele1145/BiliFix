package dev.polaris_fix.bilifix;

import dev.polaris_fix.bilifix.config.BiliFixConfig;
import net.neoforged.fml.ModContainer;
import net.neoforged.fml.common.Mod;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Path;

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
 *
 * <p>v1.4.0：新增崩溃诊断守护（CrashSentinel）——JVM 退出时把修复运行状态
 * 写入游戏目录 bilifix-diagnostic.txt，为无声崩溃留下 Java 侧的最后线索。</p>
 *
 * <p>v1.4.7：新增会话取证。原生崩溃<b>不会执行 shutdown hook</b>，所以单靠
 * 退出时写文件无法区分"干净退出"与"被原生层打死"。现在启动时留
 * bilifix-session.lock、干净退出时删除；下次启动若发现残留 lock，即判定
 * 上次为异常终止（原生崩溃指纹）并在日志中给出针对性排查建议。</p>
 */
@Mod(BiliFixMod.MOD_ID)
public class BiliFixMod {
    public static final String MOD_ID = "bilifix";
    public static final String VERSION = "1.4.8";
    public static final Logger LOGGER = LoggerFactory.getLogger("BiliFix");

    public BiliFixMod(ModContainer container) {
        init(FmlBridge.fmlDir("GAMEDIR"), FmlBridge.fmlDir("CONFIGDIR"));
    }

    /**
     * loader 无关的初始化核心：NeoForge/Forge 由构造器调用，Fabric 由 entrypoint 调用。
     *
     * <p>把核心逻辑集中在这里，是为了让三端共用同一份启动序列（顺序有语义：
     * 先注入目录 → 再读配置 → 再检测上次异常终止 → 最后注册守护）。</p>
     *
     * @param gameDir   游戏目录（null = 不写取证文件，退化为无取证模式）
     * @param configDir 配置目录（null = 由 configPath() 走 FML 兜底）
     */
    /**
     * 实际生效的策略值（已归一化），用于启动行与诊断输出。
     *
     * <p><b>为什么要归一化后再显示</b>：真正写进 VLC 参数的是
     * {@code hwDecoderValue()} / {@code voutValue()}，而不是配置文件里的原始字符串。
     * 两者在多处不同：{@code disable}/{@code off} → {@code none}、
     * {@code auto}/{@code any} → {@code any}、未知值（如 {@code gpu}）→ {@code none}
     * （并另有一条警告）、{@code vout=original}/{@code keep} → 保留原值、
     * 大小写与首尾空白被标准化。</p>
     *
     * <p>若显示原始值，用户写 {@code hwDecoder="gpu"} 会看到 {@code hw=gpu}
     * 而实际已回退到 {@code none}（软解），排查方向被直接带偏——而启动行正是
     * 崩溃排查时读的第一行。实测：9 个取值组合里 5 个显示值与生效值不符。</p>
     *
     * @return {@code [hw, vout]}；vout 为 {@code "original"} 表示"保留原值"
     */
    public static String[] effectiveStrategy() {
        String effHw = BiliFixConfig.hwDecoderValue();
        String effVout = BiliFixConfig.voutValue();
        return new String[]{ effHw, effVout == null ? "original" : effVout };
    }

    /**
     * 归一化是否改变了用户写下的值（用于额外打印一行说明）。
     *
     * @return true = 配置被归一化过，值得告诉用户
     */
    public static boolean strategyWasNormalized() {
        String effHw = BiliFixConfig.hwDecoderValue();
        String effVout = BiliFixConfig.voutValue();
        String rawHw = BiliFixConfig.hwDecoder;
        String rawVout = BiliFixConfig.vout;
        String effVoutText = effVout == null ? "original" : effVout;
        // vout=original / keep 都表示"保留原值"，对用户是同一种语义
        String rawVoutNorm = rawVout == null ? null
                : rawVout.toLowerCase().trim().replace("keep", "original");
        // 语义等价（忽略大小写与 keep/original 之别）→ 不算归一化
        boolean hwSame = rawHw != null && rawHw.toLowerCase().trim().equals(effHw);
        boolean voutSame = rawVoutNorm != null && rawVoutNorm.equals(effVoutText);
        // 显示一致（逐字符）→ 也不算：用户看到的字符串没变
        boolean hwIdentical = rawHw != null && rawHw.equals(effHw);
        boolean voutIdentical = rawVout != null && rawVout.equals(effVoutText);
        // 只要"用户写的"与"用户看到的"不完全一致，就值得说明一句。
        // 例：vout=ORIGINAL → 启动行显示 original（大小写变了）；
        //     vout=keep    → 启动行显示 original（语义别名变了）。
        return !(hwSame && voutSame) || !(hwIdentical && voutIdentical);
    }

    public static void init(Path gameDir, Path configDir) {
        if (configDir != null) BiliFixConfig.setConfigDir(configDir);
        if (gameDir != null) CrashSentinel.setGameDir(gameDir);
        BiliFixConfig.load();
        // 启动行必须打印**实际生效**的归一化值，而不是配置文件里的原始字符串。
        // 见 effectiveStrategy() 的 javadoc。
        String[] strategy = effectiveStrategy();
        LOGGER.info("[BiliFix] v{} 已加载：watermedia VLC 硬解崩溃修复（策略: hw={}, vout={}）",
                VERSION, strategy[0], strategy[1]);
        // 显示值与配置原值不同时明确说明，避免用户以为配置没生效
        if (strategyWasNormalized()) {
            LOGGER.info("[BiliFix] 配置归一化：hwDecoder '{}' → {}, vout '{}' → {}",
                    BiliFixConfig.hwDecoder, strategy[0],
                    BiliFixConfig.vout, strategy[1]);
        }
        EnvironmentDiagnostics.run(LOGGER);
        // Mixin 注入目标自检：未来 watermedia 改签名/加重载时，Mixin 会静默跳过注入，
        // 修复无声失效、崩溃回归却无迹可寻。这里把它变成启动时的一条明确警告。
        MixinTargetGuard.check(LOGGER);
        // 功能级自检：真正调用一次 readArray，验证注入端到端生效
        // （目标存在 + 签名匹配 ≠ 注入已应用；required:false 会把注入失败降级为 debug 日志）
        MixinTargetGuard.functionalProbe(LOGGER);
        // 顺序关键：先检测上次是否异常终止（残留 lock），再注册本次的守护
        if (gameDir != null) {
            String crash = CrashSentinel.detectUncleanShutdown(gameDir);
            if (crash != null) LOGGER.warn("[BiliFix] {}", crash);
        }
        CrashSentinel.register();
        CrashSentinel.markSessionStart(gameDir);
        CrashSentinel.record("mod constructed, v" + VERSION);
    }
}
