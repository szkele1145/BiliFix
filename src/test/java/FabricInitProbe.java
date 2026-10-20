import dev.polaris_fix.bilifix.BiliFixMod;
import dev.polaris_fix.bilifix.CrashSentinel;
import dev.polaris_fix.bilifix.FmlBridge;
import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.stream.Stream;

/**
 * Fabric 侧端到端探针 —— 覆盖唯一有独立入口路径的加载器。
 *
 * <p><b>为什么必须有</b>：Fabric 与 NeoForge/Forge 走<b>完全不同的入口</b>：
 * <ul>
 *   <li>NeoForge/Forge：{@code @Mod} 构造器 → 反射拿 {@code FMLPaths}；</li>
 *   <li>Fabric：{@code ModInitializer.onInitialize()} → 显式注入
 *       {@code FabricLoader.getGameDir()/getConfigDir()}。</li>
 * </ul>
 * 而共享核心 {@link BiliFixMod#init(Path, Path)} 里的顺序是<b>有语义的</b>：
 * 先 {@code setConfigDir/setGameDir}，再 {@code BiliFixConfig.load()}。
 * 顺序错了，配置会写到别处而不是游戏目录——<b>静默</b>：模组照样工作，
 * 只是用户的配置永远不生效，也不会报任何错。
 *
 * <p>此前这个探针只存在于 {@code build/}（被 git 忽略）且<b>只打印不断言</b>，
 * 任何回归都不会让构建失败。现在它进版本库、变成断言式、并接入全部构建脚本。
 * </p>
 *
 * <p><b>本探针要证明的事</b>：</p>
 * <ol>
 *   <li>无 FML 时 {@link FmlBridge} 优雅降级为 null（Fabric classpath 上没有 FML）；</li>
 *   <li>注入的 configDir / gameDir 被真正使用——文件落在<b>注入的</b>目录里，
 *       不是工作目录，也不是对方目录；</li>
 *   <li>残留 lock 被判定为"上次异常终止"（原生崩溃指纹路径）。</li>
 * </ol>
 */
public class FabricInitProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Fabric init probe (the loader with its own entry point)");

        Path base = Files.createTempDirectory("bilifix-fabric-probe");
        Path game = Files.createDirectories(base.resolve("game"));
        Path cfg = Files.createDirectories(base.resolve("config"));

        // ---- 1. 无 FML 时必须优雅降级（Fabric classpath 上没有 net.neoforged.fml） ----
        check("FmlBridge.fmlDir(GAMEDIR) 在无 FML 时返回 null", FmlBridge.fmlDir("GAMEDIR") == null);
        check("FmlBridge.fmlDir(CONFIGDIR) 在无 FML 时返回 null", FmlBridge.fmlDir("CONFIGDIR") == null);
        check("FmlBridge.modVersion(watermedia) 在无 FML 时返回 null",
                FmlBridge.modVersion("watermedia") == null);
        check("FmlBridge.modVersion(bilifix) 在无 FML 时返回 null",
                FmlBridge.modVersion("bilifix") == null);

        // ---- 2. 原生崩溃指纹路径（必须**先于**正常流程） ----
        //
        // 关键：CrashSentinel.probed 是**只判定一次**的（幂等，避免重复构造
        // 误报），所以"在同一个进程里 init 两次"**不会**触发判定——此前留在
        // build/ 里的那个探针输出的 "unclean-shutdown fingerprint path
        // exercised" 其实是**假的**：那条路径从未被走过。
        //
        // 真实场景是**跨进程**：上一次游戏进程被原生层打死（没走 shutdown
        // hook → 没删 lock），本次启动才判定。所以这里用一个**新目录**模拟
        // "上次留下的 lock"，并让**第一次** init 就面对它——probed 一旦被置位，
        // 后面就再也不会判定了。
        Path game2 = Files.createDirectories(base.resolve("game2"));
        Path cfg2 = Files.createDirectories(base.resolve("config2"));
        // 模拟上一次会话留下 lock：内容与 markSessionStart 写的同构
        Files.write(game2.resolve(CrashSentinel.SESSION_FILE),
                ("pid=12345\nversion=1.4.8\nstarted=2026-01-01T00:00:00Z\n")
                        .getBytes(StandardCharsets.UTF_8));

        BiliFixMod.init(game2, cfg2);
        Path crash = game2.resolve(CrashSentinel.CRASH_FILE);
        check("残留 lock → 判定为上次异常终止（原生崩溃指纹）", Files.exists(crash));
        if (Files.exists(crash)) {
            String body = new String(Files.readAllBytes(crash), StandardCharsets.UTF_8);
            check("崩溃报告写进了 gameDir", body.contains("BiliFix 异常终止报告"));
            check("崩溃报告写明了排查建议", body.contains("排查建议"));
        } else {
            check("崩溃报告写进了 gameDir", false);
            check("崩溃报告写明了排查建议", false);
        }

        // ---- 3. 正常流程：注入的目录必须被真正使用 ----
        BiliFixMod.init(game, cfg);

        Path cfgFile = cfg.resolve("bilifix.toml");
        Path lock = game.resolve(CrashSentinel.SESSION_FILE);
        check("配置文件落在注入的 configDir 里", Files.exists(cfgFile));
        check("会话 lock 落在注入的 gameDir 里", Files.exists(lock));
        check("配置文件没有落到游戏目录", !Files.exists(game.resolve("bilifix.toml")));
        check("会话 lock 没有落到配置目录", !Files.exists(cfg.resolve(CrashSentinel.SESSION_FILE)));

        // 配置文件内容必须是默认值（DEFAULT_* 常量），不是别的
        if (Files.exists(cfgFile)) {
            String body = new String(Files.readAllBytes(cfgFile), StandardCharsets.UTF_8);
            check("生成的配置文件含 hwDecoder = \"" + BiliFixConfig.DEFAULT_HW_DECODER + "\"",
                    body.contains("hwDecoder = \"" + BiliFixConfig.DEFAULT_HW_DECODER + "\""));
            check("生成的配置文件含 vout = \"" + BiliFixConfig.DEFAULT_VOUT + "\"",
                    body.contains("vout = \"" + BiliFixConfig.DEFAULT_VOUT + "\""));
        } else {
            check("生成的配置文件含 hwDecoder 默认值", false);
            check("生成的配置文件含 vout 默认值", false);
        }

        // ---- 4. 清理 ----
        try (Stream<Path> s = Files.walk(base)) {
            s.sorted(java.util.Comparator.reverseOrder()).forEach(p -> {
                try { Files.deleteIfExists(p); } catch (Throwable ignored) {}
            });
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
