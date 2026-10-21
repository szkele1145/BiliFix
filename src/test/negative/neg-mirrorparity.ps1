$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

# Negative test for MirrorParityProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# REGRESSION MIRROR in a COPY of the source and requires the probe to
# fail.
#
# The break: the mirror's voutMap goes back to returning the empty
# string as-is (the shape it had before v1.4.8), while production now
# falls back to the safe default "gl,any". The mirror is an
# independent re-implementation, so when production's behaviour changes
# on purpose the mirror has to be updated BY HAND - and when it is not,
# the mirror gives the OPPOSITE answer from production while every
# mirror test still passes. That is the worst possible state for a
# safety net.
#
# The probe reads the source file given as args[0], so it must be
# pointed at the BROKEN COPY - reading the working tree would check the
# unbroken file and pass against broken code.

$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'
$slf4j = "$d\build\fabric\libs\slf4j-api-2.0.7.jar"
$mixin = (Get-ChildItem "$d\build\fabric\libs" -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$cp = "$slf4j;$mixin"

$tmp = Join-Path $env:TEMP ('bilifix-neg-mirrorparity-' + [guid]::NewGuid().ToString('N').Substring(0,8))
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$tmp\out" | Out-Null
Write-Host "[neg] 准备临时副本: $tmp"

# 1) copy the production tree (unchanged) and the mirror (broken)
$src = "$d\src\main\java"
Get-ChildItem $src -Recurse -Filter '*.java' | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $dst = Join-Path "$tmp\src" $rel
    $dd = Split-Path $dst -Parent
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item $_.FullName $dst -Force
}
$regDst = "$tmp\src\Regression.java"
Copy-Item "$d\src\test\java\Regression.java" $regDst -Force

# 2) break the mirror: voutMap returns the empty string as-is again
$text = [System.IO.File]::ReadAllText($regDst, [System.Text.Encoding]::UTF8)
$old = @'
    static Object voutMap(String s) {
        if (s == null) return null;
        String v = s.toLowerCase().trim();
        return switch (v) {
            case "original", "keep" -> null;
            default -> v.isEmpty() ? "gl,any" : v;
        };
    }
'@
$new = @'
    static Object voutMap(String s) {
        if (s == null) return null;
        String v = s.toLowerCase().trim();
        return switch (v) {
            case "original", "keep" -> null;
            default -> v;
        };
    }
'@
if (-not $text.Contains($old)) { Write-Host '[neg] 失败：锚点没找到（voutMap 的空值回退）'; exit 1 }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText($regDst, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '[neg] 已还原：镜像的 voutMap 不再回退（原样返回空串）'

# 3) compile the production tree (unchanged) + the BROKEN mirror
#    The broken Regression.class MUST be on the probe's classpath - the
#    probe loads the mirror by reflection, so a broken mirror that is not
#    compiled simply would not be exercised at all.
$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | Where-Object { $_.Name -ne 'Regression.java' } | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：生产源码编译不过'; exit 1 }
& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" $regDst 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：破坏后的镜像编译不过'; exit 1 }

# 4) compile the probe
& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\MirrorParityProbe.java" 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 5) run the probe against the BROKEN COPY - it MUST fail
$proc = Start-Process -FilePath $java `
        -ArgumentList @('-cp', "$tmp\out;$cp", 'MirrorParityProbe', $regDst) `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
        -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"

Write-Host '[neg] 探针输出：'
Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Write-Host '[neg] 失败：探针对坏代码 PASS 了 —— 断言无效！'
    exit 1
}
Write-Host ("[neg] 探针在坏代码上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host 'NEGATIVE_TEST_OK'
exit 0
