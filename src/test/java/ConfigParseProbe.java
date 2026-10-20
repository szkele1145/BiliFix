import dev.polaris_fix.bilifix.config.BiliFixConfig;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

/**
 * 探针：配置文件解析。
 *
 * 缺陷背景（v1.4.8 修复）：
 * {@code BiliFixConfig.parse()} 用 {@code Files.readAllLines(path, UTF_8)}，
 * 而该方法**不会剥离 UTF-8 BOM**。Windows 上记事本等编辑器默认以
 * "UTF-8 带 BOM" 保存 → 首个 key 变成 {@code "\uFEFFhwDecoder"} →
 * {@code containsKey("hwDecoder")} 为 false → 用户的 {@code hwDecoder}
 * 配置**被静默忽略**。
 *
 * 隐蔽之处：只有**第一个**键受影响 —— vout/verbose 照常生效，用户会看到
 * "配置好像生效了一半"，完全无法联想到是 BOM。
 *
 * 实证（修复前）：
 *   带 BOM 的解析结果 keys = [?hwDecoder, vout, verbose]
 *   containsKey(hwDecoder) = false
 *   不带 BOM 的解析结果 keys = [hwDecoder, vout, verbose]
 *   containsKey(hwDecoder) = true
 *
 * 本探针反射调用生产的 parse()，覆盖：BOM / 无 BOM / BOM+注释 /
 * BOM+空行 / 引号内嵌 # / 行内注释 / 裸值。
 */
public class ConfigParseProbe {

    static int pass = 0, fail = 0, skipped = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    static void skip(String reason) {
        skipped++;
        System.out.println("  [SKIP] " + reason);
    }

    @SuppressWarnings("unchecked")
    static Map<String, String> parse(Path p) throws Exception {
        Method m = BiliFixConfig.class.getDeclaredMethod("parse", Path.class);
        m.setAccessible(true);
        return (Map<String, String>) m.invoke(null, p);
    }

    static Path write(Path dir, String name, String content, boolean bom) throws Exception {
        Path p = dir.resolve(name);
        byte[] body = content.getBytes(StandardCharsets.UTF_8);
        if (bom) {
            byte[] withBom = new byte[body.length + 3];
            withBom[0] = (byte) 0xEF; withBom[1] = (byte) 0xBB; withBom[2] = (byte) 0xBF;
            System.arraycopy(body, 0, withBom, 3, body.length);
            Files.write(p, withBom);
        } else {
            Files.write(p, body);
        }
        return p;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Config parse probe");
        Path dir = Files.createTempDirectory("cfgparse");

        String body = "hwDecoder = \"any\"\nvout = \"original\"\nverbose = true\n";

        // 1. 不带 BOM（基线）
        Map<String, String> plain = parse(write(dir, "plain.toml", body, false));
        check("无 BOM：hwDecoder 可解析", plain.containsKey("hwDecoder"));
        check("无 BOM：hwDecoder 值正确", "any".equals(plain.get("hwDecoder")));
        check("无 BOM：vout 可解析", "original".equals(plain.get("vout")));
        check("无 BOM：verbose 可解析", "true".equals(plain.get("verbose")));

        // 2. 带 BOM（缺陷场景）
        Map<String, String> bom = parse(write(dir, "bom.toml", body, true));
        check("带 BOM：hwDecoder 可解析（修复前为 false）", bom.containsKey("hwDecoder"));
        check("带 BOM：hwDecoder 值正确", "any".equals(bom.get("hwDecoder")));
        check("带 BOM：vout 可解析", "original".equals(bom.get("vout")));
        check("带 BOM：verbose 可解析", "true".equals(bom.get("verbose")));
        check("带 BOM：解析出的 key 不含 BOM 字符",
                bom.keySet().stream().noneMatch(k -> k.contains("\uFEFF")));

        // 3. BOM + 首行是注释
        Map<String, String> bomComment = parse(write(dir, "bomc.toml",
                "# BiliFix 配置\nhwDecoder = \"d3d11va\"\n", true));
        check("BOM+注释：注释行被跳过", !bomComment.containsKey("# BiliFix 配置"));
        check("BOM+注释：hwDecoder 可解析", "d3d11va".equals(bomComment.get("hwDecoder")));

        // 4. BOM + 首行是空行
        Map<String, String> bomBlank = parse(write(dir, "bomb.toml",
                "\nhwDecoder = \"dxva2\"\n", true));
        check("BOM+空行：hwDecoder 可解析", "dxva2".equals(bomBlank.get("hwDecoder")));

        // 5. 引号内嵌 # （stripValue 的既有能力，防回归）
        Map<String, String> hash = parse(write(dir, "hash.toml",
                "vout = \"gl#x,any\"\n", false));
        check("引号内嵌 # 保留在值里", "gl#x,any".equals(hash.get("vout")));

        // 6. 引号后行内注释
        Map<String, String> inline = parse(write(dir, "inline.toml",
                "vout = \"gl,any\" # 说明\n", false));
        check("引号后行内注释被剥离", "gl,any".equals(inline.get("vout")));

        // 7. 裸值 + 行内注释
        Map<String, String> bare = parse(write(dir, "bare.toml",
                "verbose = true # 打开\n", false));
        check("裸值 + 行内注释", "true".equals(bare.get("verbose")));

        // 8. 空行/无 '=' 行被跳过
        Map<String, String> junk = parse(write(dir, "junk.toml",
                "\n\nnotakeyvalue\n# 注释\nhwDecoder = \"none\"\n", false));
        check("无 '=' 的行被跳过", junk.size() == 1);
        check("有效键仍被解析", "none".equals(junk.get("hwDecoder")));

        // 9. 源码级：parse 必须含 BOM 处理
        String src = new String(Files.readAllBytes(java.nio.file.Paths.get("src", "main", "java",
                "dev", "polaris_fix", "bilifix", "config", "BiliFixConfig.java")),
                StandardCharsets.UTF_8);
        check("源码含 BOM 剥离逻辑（\\uFEFF）", src.contains("\\uFEFF"));

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail + " / 跳过 " + skipped);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
