package net.neoforged.fml;

/** IConfigurable 的最小桩（探针只需类型存在）。 */
public interface IConfigurable {
    java.util.Map<String, Object> getConfigData();
}