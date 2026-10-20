package net.neoforged.fml.language;

import net.neoforged.fml.IConfigurable;
import net.neoforged.fml.IModFile;
import net.neoforged.fml.IModInfo;

/**
 * {@code IModFileInfo} 的测试桩（形状对齐真实 FML 的同名接口）。
 *
 * <p>真实接口（javap 实证）：</p>
 * <pre>
 * public interface net.neoforged.neoforgespi.language.IModFileInfo {
 *     List&lt;IModInfo&gt; getMods();
 *     List&lt;LanguageSpec&gt; requiredLanguageLoaders();
 *     boolean showAsResourcePack();
 *     Map&lt;String, Object&gt; getFileProperties();
 *     String getLicense();
 *     String moduleName();
 *     String versionString();
 *     List&lt;String&gt; usesServices();
 *     IModFile getFile();
 *     IConfigurable getConfig();
 * }
 * </pre>
 *
 * <p>注意 {@code versionString()} 声明在**接口**上——这正是
 * {@code FmlBridge.call()} 的接口回退分支存在的理由：真实实现类是包私有的，
 * {@code target.getClass().getMethod("versionString")} 找不到它。</p>
 */
public interface IModFileInfo {

    java.util.List<IModInfo> getMods();

    java.util.List<LanguageSpec> requiredLanguageLoaders();

    boolean showAsResourcePack();

    java.util.Map<String, Object> getFileProperties();

    String getLicense();

    String moduleName();

    String versionString();

    java.util.List<String> usesServices();

    IModFile getFile();

    IConfigurable getConfig();

    /** 语言规格（真实接口里的嵌套类型）。 */
    interface LanguageSpec {
        String getLanguage();
    }
}
