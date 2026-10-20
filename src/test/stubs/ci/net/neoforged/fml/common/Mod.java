// Minimal FML stub for CI: mirrors net.neoforged.fml.common.Mod closely enough
// for the production @Mod(BiliFixMod.MOD_ID) declaration to compile.
package net.neoforged.fml.common;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Mod {
    String value();
}
