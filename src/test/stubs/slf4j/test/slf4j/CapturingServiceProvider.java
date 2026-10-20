package test.slf4j;

import org.slf4j.ILoggerFactory;
import org.slf4j.IMarkerFactory;
import org.slf4j.helpers.BasicMarkerFactory;
import org.slf4j.spi.MDCAdapter;
import org.slf4j.spi.SLF4JServiceProvider;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 测试用的 SLF4J provider：把日志记录到静态列表，供探针断言。
 *
 * <p><b>为什么需要</b>：slf4j-api 在 classpath 上没有 provider 时会退化成 NOP
 * logger——{@code BiliFixMod.LOGGER.warn(...)} 什么都不输出，探针无法验证
 * "该警告的警告有没有发出来"。装上这个 provider 后，警告就能被捕获。</p>
 *
 * <p>生产代码不依赖它：jar 里没有这个类，运行时 slf4j 仍按 NOP 处理
 * （Minecraft 自带 log4j 绑定，行为不变）。</p>
 */
public class CapturingServiceProvider implements SLF4JServiceProvider {

    /** 所有被记录的日志行，格式 "level|message" */
    public static final List<String> LINES = new ArrayList<>();

    public static void clear() {
        LINES.clear();
    }

    public static boolean hasWarn(String fragment) {
        for (String l : LINES) {
            if (l.startsWith("warn|") && l.contains(fragment)) return true;
        }
        return false;
    }

    public static boolean hasInfo(String fragment) {
        for (String l : LINES) {
            if (l.startsWith("info|") && l.contains(fragment)) return true;
        }
        return false;
    }

    public static String dump() {
        return String.join("\n", LINES);
    }

    @Override
    public ILoggerFactory getLoggerFactory() {
        return new ILoggerFactory() {
            @Override
            public org.slf4j.Logger getLogger(String name) {
                return new CapturingLogger(name);
            }
        };
    }

    @Override
    public IMarkerFactory getMarkerFactory() {
        return new BasicMarkerFactory();
    }

    @Override
    public MDCAdapter getMDCAdapter() {
        return new MDCAdapter() {
            @Override public void put(String key, String val) {}
            @Override public String get(String key) { return null; }
            @Override public void remove(String key) {}
            @Override public void clear() {}
            @Override public Map<String, String> getCopyOfContextMap() { return java.util.Collections.emptyMap(); }
            @Override public void setContextMap(Map<String, String> contextMap) {}
            @Override public void clearDequeByKey(String key) {}
            @Override public java.util.Deque<String> getCopyOfDequeByKey(String key) { return new java.util.ArrayDeque<>(); }
            @Override public void pushByKey(String key, String value) {}
            @Override public String popByKey(String key) { return null; }
        };
    }

    @Override
    public String getRequestedApiVersion() {
        return "2.0.99";
    }

    @Override
    public void initialize() {
        // 无需初始化
    }

    /**
     * 记录用的 logger。
     *
     * <p>继承 {@link org.slf4j.helpers.LegacyAbstractLogger}：它实现了
     * {@code org.slf4j.Logger} 的全部方法（含 Marker 重载），而抽象方法只有
     * {@code isXxxEnabled()} 与 {@code handleNormalizedLoggingCall(...)} 两个
     * 入口——手写整个 Logger 接口极易漏方法（编译期才报"未实现抽象方法"）。
     * 不用 {@code NOPLogger} 是因为它的 {@code isTraceEnabled()} 等是
     * {@code final}，无法覆写。</p>
     */
    static final class CapturingLogger extends org.slf4j.helpers.LegacyAbstractLogger {
        private final String name;

        CapturingLogger(String name) { this.name = name; }

        @Override public String getName() { return name; }

        @Override protected String getFullyQualifiedCallerName() { return CapturingLogger.class.getName(); }

        @Override public boolean isTraceEnabled() { return true; }
        @Override public boolean isDebugEnabled() { return true; }
        @Override public boolean isInfoEnabled() { return true; }
        @Override public boolean isWarnEnabled() { return true; }
        @Override public boolean isErrorEnabled() { return true; }

        @Override
        protected void handleNormalizedLoggingCall(org.slf4j.event.Level level,
                                                  org.slf4j.Marker marker,
                                                  String messagePattern,
                                                  Object[] arguments,
                                                  Throwable throwable) {
            String levelName = level.toString().toLowerCase();
            String msg = org.slf4j.helpers.MessageFormatter.arrayFormat(messagePattern, arguments).getMessage();
            LINES.add(levelName + "|" + msg);
        }
    }
}
