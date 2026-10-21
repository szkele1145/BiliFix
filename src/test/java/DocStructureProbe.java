import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * 文档结构探针 —— 盯住 CHANGELOG 的结构不被改坏。
 *
 * <p><b>为什么需要</b>：v1.4.8 的开发过程中，CHANGELOG 的一个
 * {@code ### 修复} 标题被拆成了两行：</p>
 *
 * <pre>
 * ### 修
 *
 * 复
 * - **某条目**……
 * </pre>
 *
 * <p>Markdown 渲染时 {@code ### 修} 仍是标题（三个井号），而 {@code 复}
 * 变成一个<b>孤立段落</b>——整节内容被"降级"了。读者会以为那里没有修复章节。
 * 而且这种损坏<b>不会让任何构建失败</b>：文件语法合法，只是结构错了。</p>
 *
 * <p>根因是用 {@code String.Replace} 往文档里插内容时，<b>锚点跨越了换行</b>，
 * 于是替换文本被塞进了标题中间。本探针把这类结构问题变成红灯。</p>
 *
 * <p>本探针不加载任何生产类——它检查的是<b>发布材料</b>，而发布材料是
 * 用户读到 mod 行为的唯一来源，坏掉的文档和坏掉的代码一样有害。</p>
 */
public class DocStructureProbe {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  [PASS] " + name); }
        else { fail++; System.out.println("  [FAIL] " + name); }
    }

    public static void main(String[] args) {
        System.out.println("Doc structure probe (release material must not be silently broken)");

        String changelogPath = (args.length > 0) ? args[0] : "CHANGELOG.md";
        String text;
        try {
            text = new String(Files.readAllBytes(Path.of(changelogPath)), StandardCharsets.UTF_8);
        } catch (Exception e) {
            check("读取 " + changelogPath, false);
            System.out.println();
            System.out.println("通过 " + pass + " / 失败 " + fail);
            System.out.println("RESULT = FAIL");
            System.exit(1);
            return;
        }

        String[] lines = text.split("\r\n|\n", -1);

        // ---- 1. 标题不得被拆行 / 为空 ----
        // 两种真实出现过的断裂形态（v1.4.8 开发中各出现过一次）：
        //   "### 修"  —— "### 修复" 的最后一个字被 Replace 挤到了下一行
        //   "### "    —— 标题字全部被挤走，只剩井号和空格
        int brokenHeadings = 0;
        for (int i = 0; i < lines.length; i++) {
            String l = lines[i];
            if (l.startsWith("### ") && l.length() <= 5) {
                brokenHeadings++;
                System.out.println("  [FAIL] 第 " + (i + 1) + " 行是断裂/空标题: [" + l + "]");
            }
        }
        check("所有 '### ' 标题行都完整（没有单字或空标题）", brokenHeadings == 0);

        // ---- 2. 标题附近不应有孤立的单字行 ----
        // 断裂的另一半："复" 单独成行。它可能在标题的下一行，也可能隔一个空行。
        int orphanWords = 0;
        for (int i = 0; i < lines.length; i++) {
            String cur = lines[i];
            if (cur.length() != 1) continue;
            if (cur.charAt(0) == '-' || cur.charAt(0) == '*' || cur.charAt(0) == '#') continue;
            // 往上找一个最近的标题（最多隔 2 行空行）
            boolean nearHeading = false;
            for (int k = i - 1; k >= 0 && k >= i - 3; k--) {
                if (lines[k].startsWith("### ")) { nearHeading = true; break; }
                if (lines[k].trim().length() > 0) break;
            }
            if (nearHeading) {
                orphanWords++;
                System.out.println("  [FAIL] 第 " + (i + 1) + " 行是标题附近的孤立单字: [" + cur + "]");
            }
        }
        check("没有标题附近孤立的单字行", orphanWords == 0);

        // ---- 3. 不得有 U+FFFD 替换符（编码损坏） ----
        check("没有 U+FFFD 替换符（编码没坏）", text.indexOf('\uFFFD') < 0);

        // ---- 4. 不得有裸的 "## Unreleased" 之后的结构错乱 ----
        // Unreleased 必须在文件靠前位置，且后面必须至少有一个版本小节
        int unreleased = text.indexOf("## Unreleased");
        check("存在 '## Unreleased' 小节", unreleased >= 0);
        if (unreleased >= 0) {
            int nextVersion = text.indexOf("\n## ", unreleased + 5);
            check("'## Unreleased' 后面有版本小节", nextVersion > unreleased);
        }

        // ---- 5. 小节标题后不得紧跟另一个标题 ----
        // "### A" 后面直接是 "### B" 合法（空小节）；但 "### A" 后面紧跟
        // 另一个标题、且中间没有任何内容，通常意味着上一次插入把结构搞乱了。
        // 这里只查最明确的坏形态：标题行紧跟标题行且前一个标题下面没有任何条目。
        int emptySection = 0;
        for (int i = 0; i < lines.length - 1; i++) {
            if (!lines[i].startsWith("### ")) continue;
            if (!lines[i + 1].startsWith("### ")) continue;
            // 上一节是不是空的（只有标题，没有内容行）
            boolean hasContent = false;
            for (int k = i - 1; k >= 0 && !lines[k].startsWith("### "); k--) {
                if (lines[k].trim().length() > 0) { hasContent = true; break; }
            }
            if (!hasContent) {
                emptySection++;
                System.out.println("  [FAIL] 第 " + (i + 1) + " 行的小节是空的（标题后直接是下一个标题）");
            }
        }
        check("没有空小节（标题后直接是下一个标题）", emptySection == 0);

        System.out.println();
        System.out.println("通过 " + pass + " / 失败 " + fail);
        System.out.println("RESULT = " + (fail == 0 ? "PASS" : "FAIL"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
