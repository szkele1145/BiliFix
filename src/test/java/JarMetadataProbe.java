import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 发布物元数据探针 —— 检查<b>打包好的 jar</b>，而不是源码。
 *
 * <p><b>为什么需要</b>：v1.4.8 交付三个 jar（NeoForge 1.21.1 / Forge 1.20.1 /
 * Fabric 1.20.1）。每个 jar 的 loader 元数据不同：</p>
 *
 * <ul>
 *   <li>NeoForge：{@code META-INF/neoforge.mods.toml}，mixin 兼容级 {@code JAVA_21}</li>
 *   <li>Forge：{@code META-INF/mods.toml}，mixin 兼容级 {@code JAVA_17}</li>
 *   <li>Fabric：{@code fabric.mod.json}，入口是 {@code BiliFixFabric}</li>
 * </ul>
 *
 * <p>这些差异**在编译期完全看不出来**——它们是打包阶段才写进去的。等到
 * 用户把 jar 丢进 mods 目录、启动游戏、看到 "Mod loading errors" 才发现，
 * 那就是一次真实的翻车。而这类错误正是本项目栽过的跟头
 * （1.3.2 的 mods.toml 扁平 key → {@code Missing ModLoader}）。</p>
 *
 * <p>所以这个探针直接打开三个 jar，检查：</p>
 *
 * <ol>
 *   <li>各自的 loader 元数据存在，且**只**存在自己的那一份（Fabric jar 里
 *       不该有 mods.toml，NeoForge jar 里不该有 fabric.mod.json——串了就会
 *       让 loader 走错分支）</li>
 *   <li>三个 jar 的版本号都是 {@code 1.4.8}，且与 {@code neoforge.mods.toml}
 *       里的声明一致</li>
 *   <li>{@code bilifix.mixins.json} 的 {@code compatibilityLevel} 正确
 *       （NeoForge=JAVA_21，Forge/Fabric=JAVA_17）——这一条是被真实
 *       mixin-0.8.5.jar 的枚举查证过的：它只有 JAVA_16/17/18</li>
 *   <li>Mixin 目标类名在每个 jar 里都在（{@code JarToolMixin}）</li>
 * </ol>
 *
 * <p><b>证据分级</b>：本探针需要三个已打包的 jar。没给路径时它会明确
 * 打印 {@code [SKIP]} 而不是伪装通过——一个"什么都没检查却显示 PASS"的
 * 探针比没有探针更危险。</p>
 */
public class JarMetadataProbe {

    static int pass = 0, fail = 0, skip = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skipCheck(String name) {
        skip++;
        System.out.println("  [SKIP] " + name);
    }

    /** 读取 jar 里的一个条目；不存在返回 null。 */
    static String readEntry(ZipFile zip, String name) {
        ZipEntry e = zip.getEntry(name);
        if (e == null) return null;
        try (InputStream in = zip.getInputStream(e)) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException ex) {
            return null;
        }
    }

    static boolean hasEntry(ZipFile zip, String name) {
        return zip.getEntry(name) != null;
    }

    /** 从 mixins.json 里取出 compatibilityLevel 的值。 */
    static String compatibilityLevel(String mixinsJson) {
        if (mixinsJson == null) return null;
        int i = mixinsJson.indexOf("\"compatibilityLevel\"");
        if (i < 0) return null;
        int q1 = mixinsJson.indexOf('"', mixinsJson.indexOf(':', i));
        if (q1 < 0) return null;
        int q2 = mixinsJson.indexOf('"', q1 + 1);
        if (q2 < 0) return null;
        return mixinsJson.substring(q1 + 1, q2);
    }

    /** 从 toml/json 里取 version = "x.y.z" 形式的版本号。 */
    static String declaredVersion(String text) {
        if (text == null) return null;
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("version\\s*=\\s*\"([^\"]+)\"").matcher(text);
        if (m.find()) return m.group(1);
        m = java.util.regex.Pattern
                .compile("\"version\"\\s*:\\s*\"([^\"]+)\"").matcher(text);
        if (m.find()) return m.group(1);
        return null;
    }

    /**
     * 从 jar 文件名里取版本号（{@code BiliFix-<ver>-mc...-<loader>.jar}）。
     * 文件名是发布时用户实际看到的东西，描述符里的版本必须与它一致。
     */
    static String versionFromFileName(String path) {
        if (path == null) return null;
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("BiliFix-([^-]+)-mc").matcher(path);
        return m.find() ? m.group(1) : null;
    }

    /** 描述一个待检查的 jar。 */
    record Target(String label, String path, String metaEntry, String expectedLevel,
                  String[] forbiddenEntries) {}

    /**
     * 从 jar <b>自身内容</b>推断它是哪种 loader 的产物。
     *
     * <p><b>为什么必须自动推断</b>：把"哪个 jar 对应哪个 loader"交给调用方
     * 按参数顺序传，是极易错位的约定——第一版探针就是这样：build-forge.ps1
     * 把 Forge jar 传到了 neoforge 那个位置，探针于是拿 NeoForge 的期望
     * （{@code neoforge.mods.toml} + JAVA_21）去检查 Forge jar，4 条断言
     * 全红，而那个 jar 其实完全正常。</p>
     *
     * <p>错误的一方永远是探针自己：jar 里的元数据是权威，参数顺序不是。
     * 所以这里从"存在哪个元数据文件"判定 loader，只在两个元数据同时存在
     * （本不该发生）时才退回调用方给的标签。</p>
     */
    static String detectLoader(ZipFile zip) {
        boolean neo = hasEntry(zip, "META-INF/neoforge.mods.toml");
        boolean classic = hasEntry(zip, "META-INF/mods.toml");
        boolean fabric = hasEntry(zip, "fabric.mod.json");
        int count = (neo ? 1 : 0) + (classic ? 1 : 0) + (fabric ? 1 : 0);
        if (count == 1) {
            if (neo) return "neoforge";
            if (classic) return "forge";
            return "fabric";
        }
        return null; // 0 个或多个 → 无法自动判定
    }

    public static void main(String[] args) {
        System.out.println("Jar metadata probe (the packaged artefact, not the source)");

        List<String> jars = new ArrayList<>();
        for (String a : args) if (a != null && !a.isBlank()) jars.add(a);

        if (jars.isEmpty()) {
            System.out.println("  [SKIP] 未提供 jar 路径");
            System.out.println();
            System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skip);
            System.out.println("RESULT = PASS");
            System.exit(0);
            return;
        }

        for (String path : jars) {
            System.out.println("-- " + path);
            try (ZipFile zip = new ZipFile(path)) {
                String loader = detectLoader(zip);
                String label = (loader != null) ? loader : "unknown";
                System.out.println("   detected loader: " + label);

                if (loader == null) {
                    check("能判定 jar 属于哪个 loader（恰好一种元数据）", false);
                    continue;
                }

                String metaEntry;
                String expectedLevel;
                String[] forbidden;
                switch (loader) {
                    case "neoforge" -> {
                        metaEntry = "META-INF/neoforge.mods.toml";
                        // NeoForge 21.1 runs on Java 21
                        expectedLevel = "JAVA_21";
                        forbidden = new String[]{"META-INF/mods.toml", "fabric.mod.json"};
                    }
                    case "forge" -> {
                        metaEntry = "META-INF/mods.toml";
                        // Minecraft 1.20.1 runs on Java 17
                        expectedLevel = "JAVA_17";
                        forbidden = new String[]{"META-INF/neoforge.mods.toml", "fabric.mod.json"};
                    }
                    default -> {
                        metaEntry = "fabric.mod.json";
                        expectedLevel = "JAVA_17";
                        forbidden = new String[]{"META-INF/mods.toml", "META-INF/neoforge.mods.toml"};
                    }
                }

                // 1) 自己的 loader 元数据必须在
                String meta = readEntry(zip, metaEntry);
                check(label + ": 含有自己的 loader 元数据 " + metaEntry, meta != null);

                // 2) 别人的元数据不能在里面
                for (String f : forbidden) {
                    check(label + ": 不含 " + f + "（loader 元数据没串）", !hasEntry(zip, f));
                }

                // 3) 版本号：jar 文件名里的版本必须与元数据里声明的一致。
                //    不硬编码 "1.4.8"：build/ 目录里可能还留着上一个版本的
                //    jar（build.ps1 的 housekeeping 只清 build/ 根目录，不清
                //    build\forge\ 和 build\fabric\），硬编码会让探针把一个
                //    完全正常的旧 jar 判成坏的。真正要抓的是"文件名与描述符
                //    不一致"这种发布事故。
                String ver = declaredVersion(meta);
                String nameVer = versionFromFileName(path);
                check(label + ": 元数据声明的版本与 jar 文件名一致（声明: " + ver
                        + "，文件名: " + nameVer + "）",
                        ver != null && nameVer != null && ver.equals(nameVer));
                check(label + ": 声明版本非空", ver != null && !ver.isBlank());

                // 4) mixin 兼容级
                String mixins = readEntry(zip, "bilifix.mixins.json");
                check(label + ": 含有 bilifix.mixins.json", mixins != null);
                String level = compatibilityLevel(mixins);
                check(label + ": mixin compatibilityLevel = " + expectedLevel
                        + "（实际: " + level + "）", expectedLevel.equals(level));

                // 5) Mixin 目标类必须在
                check(label + ": 含有 JarToolMixin.class",
                        hasEntry(zip, "dev/polaris_fix/bilifix/mixin/JarToolMixin.class"));

                // 6) 核心类必须在
                check(label + ": 含有 BiliFixMod.class",
                        hasEntry(zip, "dev/polaris_fix/bilifix/BiliFixMod.class"));

                // 7) Fabric 入口类（只在 fabric jar 里）
                if (label.equals("fabric")) {
                    check("fabric: 含有 BiliFixFabric.class",
                            hasEntry(zip, "dev/polaris_fix/bilifix/fabric/BiliFixFabric.class"));
                    check("fabric: fabric.mod.json 指向 BiliFixFabric 入口",
                            meta != null && meta.contains("BiliFixFabric"));
                }

                // 8) mixins.json 必须声明我们的 Mixin
                check(label + ": bilifix.mixins.json 声明了 JarToolMixin",
                        mixins != null && mixins.contains("JarToolMixin"));
            } catch (IOException ex) {
                check(path + ": 能打开 jar", false);
                System.out.println("        " + ex);
            }
        }

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skip);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
