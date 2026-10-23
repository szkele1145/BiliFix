$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
. (Join-Path (Split-Path -Parent $PSCommandPath) 'deps.ps1')
# The negative tests compile a copy of the production sources, which import
# org.slf4j / org.spongepowered - so the two dependency jars must be on the
# classpath. They used to be taken from build\fabric\libs, a BUILD ARTIFACT:
# on a fresh clone every negative test died with "package org.slf4j does not
# exist" before running a single assertion. Initialize-DepJars fetches them
# (cache / MC libraries / Maven) and fails loudly if it cannot.
$depCp = Initialize-DepJars -RepoRoot $d
if (-not $depCp) { Write-Host "依赖 jar 不可用（slf4j-api / mixin）——无法编译生产代码副本"; exit 1 }
$jdkBin = Resolve-JdkBin -RepoRoot $d
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

# Negative test for FmlBridgeProbe.
# Simulate the exact mistake the FmlBridge javadoc warns about: stop calling the
# instance method get() and treat the enum constant itself as the Path.
# The probe's "三步链路" assertions must then FAIL - proving they actually guard
# the real production code, not a mirrored copy of it.

$tmp = Join-Path $env:TEMP 'fmlbridge-neg2'
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}
$utf8 = New-Object System.Text.UTF8Encoding($false)

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$tmp\src\dev\polaris_fix\bilifix" | Out-Null

# Copy the production FmlBridge and break the get() call inside it.
$fml = [System.IO.File]::ReadAllText("$d\src\main\java\dev\polaris_fix\bilifix\FmlBridge.java", [System.Text.Encoding]::UTF8)
$broken = $fml.Replace(
    'Object dir = c.getMethod("get").invoke(constant); // 常量.get() -> Path',
    'Object dir = constant; // BROKEN: skip get(), treat the constant as the value')
if ($broken -eq $fml) {
    # fallback: any invoke of get() on the constant
    $broken = $fml -replace 'Object dir = c\.getMethod\("get"\)\.invoke\(constant\);', 'Object dir = constant; // BROKEN'
}
if ($broken -eq $fml) { Write-Host 'REPLACE_FAILED'; exit 1 }
[System.IO.File]::WriteAllText("$tmp\src\dev\polaris_fix\bilifix\FmlBridge.java", $broken, $utf8)
Write-Host 'get() call removed from the copy of FmlBridge'

# Compile the BROKEN FmlBridge + the stubs + the probe.
# NOTE: the slf4j stub must be EXCLUDED here. It implements the SLF4J 2.x
# service provider API and needs slf4j-api on the compile classpath, which
# this stub set does not have - javac fails with "package org.slf4j does not
# exist" (the same trap the three build scripts had to solve).
$stubSrcs = Get-ChildItem "$d\src\test\stubs" -Recurse -Filter '*.java' |
    Where-Object { $_.FullName -notlike '*\stubs\slf4j\*' } | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -d "$tmp\out" @stubSrcs "$tmp\src\dev\polaris_fix\bilifix\FmlBridge.java" "$d\src\test\java\FmlBridgeProbe.java" 2>&1 |
    Select-Object -First 6 | ForEach-Object { "  $_" }
Write-Host ("JAVAC_EXIT=" + $LASTEXITCODE)
if ($LASTEXITCODE -ne 0) { Remove-Item $tmp -Recurse -Force; exit 1 }

$out = & $java '-Dstdout.encoding=UTF-8' -cp "$tmp\out;$d\build\fabric\libs\slf4j-api-2.0.7.jar" FmlBridgeProbe 2>&1
$out | ForEach-Object { "  $_" }
$probeExit = $LASTEXITCODE
Write-Host ("PROBE_EXIT=" + $probeExit)
if ($probeExit -ne 0) {
    Write-Host 'NEGATIVE_TEST_EFFECTIVE (the probe caught the missing get() in the real FmlBridge)'
} else {
    Write-Host 'NEGATIVE_TEST_INEFFECTIVE (probe passed anyway - it is not testing the production code)'
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# The probe's exit code is 1 ON PURPOSE - a negative test succeeds when the
# probe fails. Exiting with $LASTEXITCODE would report that as a failure of
# this script, so the verdict has to be stated explicitly.
if ($probeExit -ne 0) {
    Write-Host 'NEGATIVE_TEST_OK'
    exit 0
}
Write-Host 'NEGATIVE_TEST_INEFFECTIVE (probe passed anyway - it is not testing the production code)'
exit 1