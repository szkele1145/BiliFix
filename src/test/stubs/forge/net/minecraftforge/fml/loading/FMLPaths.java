// Stub for FmlBridge's second candidate root: net.minecraftforge.fml
// FQN = net.minecraftforge.fml.loading.FMLPaths
//
// Shape MISMATCH on purpose: the enum constants exist but there is NO instance
// method get(). Real FML always has get(), so this stub exists only to prove
// FmlBridge degrades to null instead of throwing when the API shape differs.
package net.minecraftforge.fml.loading;

public enum FMLPaths {
    GAMEDIR,
    CONFIGDIR;

    // Intentionally NO get() method - only the enum constants.
    public String describe() { return "shape mismatch: no get()"; }
}
