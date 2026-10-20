package net.neoforged.fml;

/** IModInfo 的最小桩（探针只需类型存在）。 */
public interface IModInfo {
    String getModId();
    String getVersion();
}