package dev.polaris_fix.bilifix.fabric;

import dev.polaris_fix.bilifix.BiliFixMod;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.loader.api.FabricLoader;

/**
 * Fabric 侧入口。
 *
 * <p>三端共用同一份启动核心 {@link BiliFixMod#init(java.nio.file.Path, java.nio.file.Path)}，
 * 本类只负责一件事：把 Fabric 的目录喂给它。FML 的 {@code FMLPaths} 在 Fabric 上
 * 不存在，所以必须由这里显式注入 —— 注入后共享代码里的反射兜底不会被触发。</p>
 *
 * <p>注入顺序有语义：{@code init} 内部会先 {@code setConfigDir/setGameDir}
 * 再读配置、写取证文件，因此这里不需要（也不应该）自己提前碰这些静态状态。</p>
 */
public class BiliFixFabric implements ModInitializer {

    @Override
    public void onInitialize() {
        FabricLoader loader = FabricLoader.getInstance();
        BiliFixMod.init(loader.getGameDir(), loader.getConfigDir());
    }
}
