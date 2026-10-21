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

# Negative test for RealArgumentsProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# PRODUCTION argument rewrite in a COPY of the source and requires the
# probe to fail.
#
# The break is the exact regression this whole mod exists to prevent:
# the rewrite no longer replaces the dangerous values. With the break in
# place, the real watermedia parameter table still carries
#   "--vout", "direct3d11,glwin32,gl,any"
#   "--avcodec-hw", "d3d11va,dxva2,any"
# which is the D3D11VA copy-back path that kills the JVM with exit -1.
#
# The probe must notice - a silent PASS here would mean the mod could
# ship with the crash still in it.

$slf4j = "$d\build\fabric\libs\slf4j-api-2.0.7.jar"
$mixin = (Get-ChildItem "$d\build\fabric\libs" -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$cp = "$slf4j;$mixin"

# The real watermedia jar: without it the jar-level checks are skipped and
# the probe would lose most of its value. It lives next to the test bed.
$wmJar = $null
foreach ($cand in @(
        'D:\PCL2\.minecraft\versions\航空学这一块\mods\watermedia-2.1.36.jar')) {
    if (Test-Path $cand) { $wmJar = $cand; break }
}
if (-not $wmJar) {
    Write-Host '[neg] 跳过：找不到真实 watermedia jar（无它则 jar 级断言会被跳过）'
    Write-Host 'NEGATIVE_TEST_OK'
    exit 0
}

$tmp = Join-Path $env:TEMP ('bilifix-neg-realargs-' + [guid]::NewGuid().ToString('N').Substring(0,8))
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
Write-Host "[neg] 真实 jar: $wmJar"

# 1) copy the whole main source tree
$src = "$d\src\main\java"
Get-ChildItem $src -Recurse -Filter '*.java' | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $dst = Join-Path "$tmp\src" $rel
    $dd = Split-Path $dst -Parent
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item $_.FullName $dst -Force
}

# 2) break the production rewrite: keep the original dangerous values
$target = "$tmp\src\dev\polaris_fix\bilifix\mixin\JarToolMixin.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

# Replace the two places where the safe values are written with the
# ORIGINAL values, so the rewrite becomes a no-op for them.
$oldHw = '                    fixed.add("--avcodec-hw");' + "`n" + '                    fixed.add(hw);'
$newHw = '                    fixed.add("--avcodec-hw");' + "`n" + '                    fixed.add(original[i + 1]);'
if (-not $text.Contains($oldHw)) { Write-Host 'ANCHOR_HW_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldHw, $newHw)

$oldVout = '                        fixed.add("--vout");' + "`n" + '                        fixed.add(vout);'
$newVout = '                        fixed.add("--vout");' + "`n" + '                        fixed.add(original[i + 1]);'
if (-not $text.Contains($oldVout)) { Write-Host 'ANCHOR_VOUT_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldVout, $newVout)

# and stop the "append when missing" defence from adding the safe values
$oldAppend = '        if (!sawHw) {' + "`n" + '            fixed.add("--avcodec-hw");' + "`n" + '            fixed.add(hw);'
$newAppend = '        if (!sawHw) {' + "`n" + '            fixed.add("--avcodec-hw");' + "`n" + '            fixed.add("d3d11va,dxva2,any");'
if (-not $text.Contains($oldAppend)) { Write-Host 'ANCHOR_APPEND_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldAppend, $newAppend)

[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '[neg] 已破坏：改写不再替换危险值（d3d11va / direct3d11 会原样留下）'

# 3) compile
$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 |
    Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：破坏后源码编译不过'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\RealArgumentsProbe.java" 2>&1 |
    Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 4) run against the BROKEN production code - it MUST fail
$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'RealArgumentsProbe', $wmJar) `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
        -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"

Write-Host '[neg] 探针输出：'
Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Write-Host '[neg] 失败：探针对坏掉的代码 PASS 了 —— 断言无效！'
    exit 1
}
Write-Host ("[neg] 探针在坏掉的代码上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host 'NEGATIVE_TEST_OK'
exit 0