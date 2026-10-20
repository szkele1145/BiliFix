// Minimal FML stub for CI: the production code only needs the @Mod annotation
// and the ModContainer type to COMPILE. At runtime the probes never construct
// BiliFixMod (they read its static VERSION field), so the stub is never
// exercised beyond class loading.
//
// This lets CI compile the production classes without pulling the real
// NeoForge artifacts, which is what lets the behaviour probes run in CI.
package net.neoforged.fml;

public interface ModContainer {
}
