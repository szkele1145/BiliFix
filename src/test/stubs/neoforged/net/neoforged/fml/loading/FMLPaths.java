// Stub for FmlBridge's first candidate root: net.neoforged.fml
// FmlBridge does Class.forName("net.neoforged." + "fml" + ".loading.FMLPaths"),
// so the real FQN is net.neoforged.fml.loading.FMLPaths.
//
// Shape-correct on purpose: GAMEDIR/CONFIGDIR are enum CONSTANTS whose real
// Path comes from the instance method get() - exactly the shape real FML has.
// If FmlBridge ever stops calling get() and treats the constant as the value,
// fmlDir returns null and the probe fails. That is the regression this guards.
package net.neoforged.fml.loading;

import java.nio.file.Path;
import java.nio.file.Paths;

public enum FMLPaths {
    GAMEDIR,
    CONFIGDIR;

    public Path get() {
        return Paths.get("C:/stub-" + name().toLowerCase());
    }
}
