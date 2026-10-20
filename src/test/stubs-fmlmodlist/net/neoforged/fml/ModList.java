package net.neoforged.fml;

import net.neoforged.fml.language.IModFileInfo;

/**
 * ModList 的测试桩（形状对齐真实 FML）。
 *
 * <p><b>为什么需要它</b>：{@code FmlBridge.modVersion} 的<b>成功路径</b>此前
 * 零覆盖——探针只测了"ModList 不存在"时的降级。而成功路径恰恰是真实 FML
 * 最特殊的形状：</p>
 *
 * <ul>
 *   <li>{@code getModFileById} 声明在**具体类**上 → 类查找能命中；</li>
 *   <li>它返回的 {@code IModFileInfo} 是**接口**，实现类是<b>包私有</b>的
 *       → {@code versionString()} 只在接口上声明，{@code getClass().getMethod()}
 *       找不到，<b>必须走接口回退</b>。</li>
 * </ul>
 *
 * <p>桩的形状照抄真实 FML（javap 实证，2026-10-21）：
 * {@code net.neoforged.fml.ModList} 是具体类，
 * {@code getModFileById(String)} 返回 {@code IModFileInfo}，
 * 其实现是包私有的 {@code ModFileInfo}。</p>
 */
public class ModList {

    private static final ModList INSTANCE = new ModList();

    private ModList() {}

    public static ModList get() {
        return INSTANCE;
    }

    /** 真实实现返回 null（map.get），不抛异常——这里保持一致。 */
    public IModFileInfo getModFileById(String modId) {
        if ("watermedia".equals(modId)) return new ModFileInfo("2.1.36");
        if ("bilibili_media".equals(modId)) return new ModFileInfo("2.3");
        return null;
    }

    /**
     * 包私有的实现类：镜像真实 FML 里 {@code IModFileInfo} 的实现是包私有的，
     * 因此 {@code versionString()} 只能通过接口找到。
     */
    static final class ModFileInfo implements IModFileInfo {
        private final String version;

        ModFileInfo(String version) { this.version = version; }

        @Override
        public String versionString() { return version; }

        @Override
        public java.util.List<IModInfo> getMods() { return java.util.List.of(); }

        @Override
        public java.util.List<LanguageSpec> requiredLanguageLoaders() { return java.util.List.of(); }

        @Override
        public boolean showAsResourcePack() { return false; }

        @Override
        public java.util.Map<String, Object> getFileProperties() { return java.util.Map.of(); }

        @Override
        public String getLicense() { return "MIT"; }

        @Override
        public String moduleName() { return "test"; }

        @Override
        public java.util.List<String> usesServices() { return java.util.List.of(); }

        @Override
        public IModFile getFile() { return null; }

        @Override
        public IConfigurable getConfig() { return null; }
    }
}
