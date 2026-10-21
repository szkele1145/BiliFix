$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for NormalizedWarningProbe.
#
# Purpose: a probe that cannot fail proves nothing. This restores the OLD
# strategyWasNormalized() body - the one that reported a bogus "config was
# normalized" warning for every user who never set vout - in a COPY of the
# source, and requires the probe to fail.
#
# The old body had three false positives, and they covered the two most
# common real situations: a brand-new user (no keys at all) and a user who
# only set hwDecoder. Both saw this on every single launch:
#
#   [BiliFix] 配置归一化：hwDecoder 'none' → none, vout 'null' → original
#
# Neither value changed, and the literal null was printed. A noise warning
# during crash triage is the worst kind: it points at a problem that does
# not exist.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$slf4j = "$d\build\fabric\libs\slf4j-api-2.0.7.jar"
$mixin = (Get-ChildItem "$d\build\fabric\libs" -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$cp = "$slf4j;$mixin"

$tmp = Join-Path $env:TEMP ('bilifix-neg-normwarn-' + [guid]::NewGuid().ToString('N').Substring(0,8))
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

# 1) copy the whole main source tree
$src = "$d\src\main\java"
Get-ChildItem $src -Recurse -Filter '*.java' | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $dst = Join-Path "$tmp\src" $rel
    $dd = Split-Path $dst -Parent
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item $_.FullName $dst -Force
}

# 2) restore the OLD body
$target = "$tmp\src\dev\polaris_fix\bilifix\BiliFixMod.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
$startMarker = '        // 未设置（null）就是未设置'
$endMarker = '        return hwChanged || voutChanged;
    }'
$s = $text.IndexOf($startMarker)
if ($s -lt 0) { Write-Host '[neg] 失败：找不到新的函数体起点'; exit 1 }
$e = $text.IndexOf($endMarker, $s)
if ($e -lt 0) { Write-Host '[neg] 失败：找不到新的函数体终点'; exit 1 }
$oldBody = @'
        String effVoutText = effVout == null ? "original" : effVout;
        String rawVoutNorm = rawVout == null ? null
                : rawVout.toLowerCase().trim().replace("keep", "original");
        boolean hwSame = rawHw != null && rawHw.toLowerCase().trim().equals(effHw);
        boolean voutSame = rawVoutNorm != null && rawVoutNorm.equals(effVoutText);
        boolean hwIdentical = rawHw != null && rawHw.equals(effHw);
        boolean voutIdentical = rawVout != null && rawVout.equals(effVoutText);
        return !(hwSame && voutSame) || !(hwIdentical && voutIdentical);
    }
'@
$text = $text.Substring(0, $s) + $oldBody.TrimEnd() + "`n" + $text.Substring($e + $endMarker.Length)
[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '[neg] 已还原：strategyWasNormalized 回到会误报的旧写法'

# 3) compile
$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 |
    Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：还原后源码编译不过'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\NormalizedWarningProbe.java" 2>&1 |
    Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 4) run against the OLD behaviour - it MUST fail
#    The probe reads the source file given as args[0]; point it at the
#    BROKEN COPY, never at the working tree.
$brokenSrc = "$tmp\src\dev\polaris_fix\bilifix\BiliFixMod.java"
$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'NormalizedWarningProbe', $brokenSrc) `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
        -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"

Write-Host '[neg] 探针输出：'
Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Write-Host '[neg] 失败：探针对旧代码 PASS 了 —— 断言无效！'
    exit 1
}
Write-Host ("[neg] 探针在旧代码上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host 'NEGATIVE_TEST_OK'
exit 0
