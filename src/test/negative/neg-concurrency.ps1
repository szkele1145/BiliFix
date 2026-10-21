$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin -RepoRoot $d
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

$slf4j = "$d\build\fabric\libs\slf4j-api-2.0.7.jar"
$tmp = Join-Path $env:TEMP 'conc-neg4'
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$tmp\dev\polaris_fix\bilifix\config" | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

Copy-Item "$d\src\test\java\ConcurrentRecordProbe.java" -Destination $tmp -Force
Copy-Item "$d\src\main\java\dev\polaris_fix\bilifix\CrashSentinel.java" -Destination "$tmp\dev\polaris_fix\bilifix" -Force
Copy-Item "$d\src\main\java\dev\polaris_fix\bilifix\config\BiliFixConfig.java" -Destination "$tmp\dev\polaris_fix\bilifix\config" -Force
Copy-Item "$d\src\main\java\dev\polaris_fix\bilifix\FmlBridge.java" -Destination "$tmp\dev\polaris_fix\bilifix" -Force

# BiliFixMod stub - no BOM, only the LOGGER field BiliFixConfig needs
$stub = @'
package dev.polaris_fix.bilifix;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class BiliFixMod {
    public static final String VERSION = "1.4.8";
    public static final Logger LOGGER = LoggerFactory.getLogger("BiliFix");
}
'@
[System.IO.File]::WriteAllText("$tmp\dev\polaris_fix\bilifix\BiliFixMod.java", $stub, $utf8)

# remove synchronized -> the probe must FAIL
$sentinelPath = "$tmp\dev\polaris_fix\bilifix\CrashSentinel.java"
$c = [System.IO.File]::ReadAllText($sentinelPath, [System.Text.Encoding]::UTF8)
$mod = $c -replace 'public static synchronized void record\(', 'public static void record('
if ($mod -eq $c) { Write-Host 'REPLACE_FAILED'; exit 1 }
[System.IO.File]::WriteAllText($sentinelPath, $mod, $utf8)
Write-Host 'synchronized removed from the copy'

$srcs = @(
    $sentinelPath,
    "$tmp\dev\polaris_fix\bilifix\config\BiliFixConfig.java",
    "$tmp\dev\polaris_fix\bilifix\BiliFixMod.java",
    "$tmp\dev\polaris_fix\bilifix\FmlBridge.java",
    "$tmp\ConcurrentRecordProbe.java"
)
& $javac -encoding UTF-8 -proc:none -cp $slf4j -d "$tmp\out" $srcs 2>&1 |
    Select-Object -First 6 | ForEach-Object { "  $_" }
Write-Host ("JAVAC_EXIT=" + $LASTEXITCODE)
if ($LASTEXITCODE -ne 0) { Remove-Item $tmp -Recurse -Force; exit 1 }

$out = & $java '-Dstdout.encoding=UTF-8' -cp "$tmp\out;$slf4j" ConcurrentRecordProbe 2>&1
$out | ForEach-Object { "  $_" }
$probeExit = $LASTEXITCODE
Write-Host ("PROBE_EXIT=" + $probeExit)
Write-Host ("NEGATIVE_TEST_" + $(if ($probeExit -ne 0) { 'EFFECTIVE (probe caught the regression)' } else { 'INEFFECTIVE (probe passed anyway - useless)' }))

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# IMPORTANT: the probe's exit code is 1 ON PURPOSE - a negative test succeeds
# when the probe fails. Exiting with $LASTEXITCODE would report that as a
# failure of this script. The verdict has to be stated explicitly.
if ($probeExit -eq 0) {
    Write-Host "NEGATIVE_TEST_INEFFECTIVE"
    exit 1
}
Write-Host "NEGATIVE_TEST_OK"
exit 0