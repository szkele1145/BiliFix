# Negative test for ConfigDefaultProbe.
# Breaks the single-source-of-truth on purpose and asserts the probe FAILS.
#
# The break: in the copy of BiliFixConfig, the load() catch block resets the
# fields to hard-coded literals instead of the DEFAULT_* constants. That is
# exactly the drift the probe exists to catch: the file written to the user
# would say one thing while the exception path silently uses another.
#
# The probe's source-level assertion reads the file given as args[0], so it
# must be pointed at the BROKEN COPY - reading the working tree would make
# the assertion check the unbroken file and pass against broken code.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$tmp = Join-Path $env:TEMP ('bilifix-neg-cfgdefault-' + [guid]::NewGuid().ToString('N').Substring(0,8))
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host "[neg] 准备临时副本: $tmp"

# 1) copy the production config class and break the default constants
$srcDir = Join-Path $tmp 'src\dev\polaris_fix\bilifix\config'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
$cfgSrc = Join-Path $repo 'src\main\java\dev\polaris_fix\bilifix\config\BiliFixConfig.java'
$cfgDst = Join-Path $srcDir 'BiliFixConfig.java'
$text = [System.IO.File]::ReadAllText($cfgSrc, [System.Text.Encoding]::UTF8)

# Break 1: the catch block goes back to hard-coded literals (the old shape).
$old = @'
            hwDecoder = DEFAULT_HW_DECODER;
            vout = DEFAULT_VOUT;
            verbose = DEFAULT_VERBOSE;
'@
$new = @'
            hwDecoder = "none";
            vout = "gl,any";
            verbose = false;
'@
if (-not $text.Contains($old)) { Write-Host '[neg] 失败：锚点没找到（catch 块的重置）'; exit 1 }
$text = $text.Replace($old, $new)

# Break 2: the file written to the user drifts away from the constant.
$q = [char]34; $bs = [char]92
$old2 = 'lines.add("vout = ' + $bs + $q + '" + DEFAULT_VOUT + "' + $bs + $q + '");'
$new2 = 'lines.add("vout = ' + $bs + $q + 'direct3d11,glwin32,gl,any' + $bs + $q + '");'
if (-not $text.Contains($old2)) { Write-Host '[neg] 失败：锚点没找到（writeDefault 的 vout）'; exit 1 }
$text = $text.Replace($old2, $new2)

[System.IO.File]::WriteAllText($cfgDst, $text, $utf8)
Write-Host '[neg] 已还原：默认值漂移（catch 块用字面量 + 写文件用 direct3d11）'

# 2) compile the broken production class + the probe
$jdk = Join-Path $repo '.tools\jdk21\bin'
$slf4jJar = (Get-ChildItem (Join-Path $repo 'build\fabric\libs') -Filter 'slf4j-api-*.jar' | Select-Object -First 1).FullName
$cpJars = $slf4jJar
$classes = Join-Path $tmp 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null

# Compile the WHOLE main source tree from the temp copy (with the broken
# BiliFixConfig) - the production classes are mutually dependent, so compiling
# a subset would only produce "cannot find symbol" noise. The @Mod annotation
# comes from the NeoForge stub under src/test/stubs/ci.
$ciStubs = Get-ChildItem (Join-Path $repo 'src\test\stubs\ci') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$mainSrc = Join-Path $tmp 'src\main\java\dev\polaris_fix\bilifix'
New-Item -ItemType Directory -Force -Path $mainSrc | Out-Null
Copy-Item (Join-Path $repo 'src\main\java\dev\polaris_fix\bilifix\*') $mainSrc -Recurse -Force
Copy-Item $cfgDst (Join-Path $mainSrc 'config\BiliFixConfig.java') -Force
$allMain = Get-ChildItem $mainSrc -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$mixinJar = (Get-ChildItem (Join-Path $repo 'build\fabric\libs') -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$cpJars = "$slf4jJar;$mixinJar"

& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -proc:none -cp $cpJars -d $classes @allMain @ciStubs 2>&1 |
    Select-Object -First 6 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：还原后源码编译不过'; exit 1 }

& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -proc:none -cp "$classes;$cpJars" -d $classes (Join-Path $repo 'src\test\java\ConfigDefaultProbe.java') 2>&1 |
    Select-Object -First 6 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 3) run the probe against the BROKEN COPY - it MUST fail
$o = Join-Path $tmp 'probe-out.txt'
$e = Join-Path $tmp 'probe-err.txt'
$proc = Start-Process -FilePath (Join-Path $jdk 'java.exe') `
    -ArgumentList @('-cp', "$classes;$cpJars", 'ConfigDefaultProbe', $cfgDst) `
    -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
    -RedirectStandardOutput $o -RedirectStandardError $e

Write-Host '[neg] 探针输出：'
Get-Content $o -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

if ($proc.ExitCode -eq 0) {
    Write-Host '[neg] 失败：探针对坏代码 PASS 了 —— 断言无效！'
    exit 1
}
Write-Host ("[neg] 探针在坏代码上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host 'NEGATIVE_TEST_OK'
exit 0
