$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for FmlBridgeProbe.
# Simulate the exact mistake the FmlBridge javadoc warns about: stop calling the
# instance method get() and treat the enum constant itself as the Path.
# The probe's "三步链路" assertions must then FAIL - proving they actually guard
# the real production code, not a mirrored copy of it.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
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
