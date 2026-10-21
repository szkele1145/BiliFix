$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for the vout empty-value fallback (v1.4.8).
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# production code in a COPY of the source and requires the probe to fail.
#
# The breakage: voutValue() returns the empty string as-is instead of
# falling back to the safe default. The mixin then writes "--vout ''" -
# an EMPTY video output module name handed to libVLC. That does not
# crash; it just produces no picture, which the user will blame on
# watermedia. hwDecoderValue() already fell back to the safe default for
# the same situation, so the two fields behaved differently - the exact
# kind of drift this project keeps having to hunt down.
#
# The probe reads the source file given as args[0], so it must be pointed
# at the BROKEN COPY - reading the working tree would check the unbroken
# file and pass against broken code.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"

$tmp = Join-Path $env:TEMP ('bilifix-neg-voutempty-' + [guid]::NewGuid().ToString('N').Substring(0,8))
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

# 2) break voutValue(): the empty string is returned as-is again
$target = "$tmp\src\dev\polaris_fix\bilifix\config\BiliFixConfig.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
$old = @'
            default -> {
                if (v.isEmpty()) {
                    BiliFixMod.LOGGER.warn("[BiliFix] vout 配置为空，已回退到安全默认 {}", DEFAULT_VOUT);
                    yield DEFAULT_VOUT;
                }
                yield v;
            }
'@
$new = @'
            default -> v;
'@
if (-not $text.Contains($old)) { Write-Host '[neg] 失败：锚点没找到（voutValue 的空值回退）'; exit 1 }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '[neg] 已还原：vout 空值不再回退（原样返回空串）'

# 3) compile the broken production tree
$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：还原后源码编译不过'; exit 1 }

# 4) compile the probe
& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\ArgumentRewriteProbe.java" 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 5) run the probe against the BROKEN COPY - it MUST fail
$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'ArgumentRewriteProbe') `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $d `
        -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"

Write-Host '[neg] 探针输出：'
Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host "    $($_.ToString().Trim())" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Write-Host '[neg] 失败：探针对坏代码 PASS 了 —— 断言无效！'
    exit 1
}
Write-Host ("[neg] 探针在坏代码上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host 'NEGATIVE_TEST_OK'
exit 0
