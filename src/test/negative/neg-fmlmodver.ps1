# Negative test for FmlModVersionProbe.
# Breaks the FmlBridge.modVersion success path on purpose and asserts the
# probe FAILS - a probe that cannot fail is not evidence.
#
# The break: replace the two-step lookup in the copy of FmlBridge
#   Object dir = c.getMethod("get").invoke(constant);
#   Object info = call(modList, "getModFileById", ...);
#   Object ver  = call(info, "versionString", new Class<?>[0]);
# with a version that never asks for the version string at all - it returns
# the mod id. The probe must then see the WRONG version and fail.
#
# NOTE: the probe's source-level assertions read the file given as args[0];
# this script points it at the BROKEN copy, not the working tree - otherwise
# the assertion would inspect the unbroken file and pass against broken code.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$tmp = Join-Path $env:TEMP ('bilifix-neg-fmlmodver-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host "[neg] 准备临时副本: $tmp"

# 1) copy the production FmlBridge and break the version lookup
$srcDir = Join-Path $tmp 'src\dev\polaris_fix\bilifix'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
$fmlSrc = Join-Path $repo 'src\main\java\dev\polaris_fix\bilifix\FmlBridge.java'
$fmlDst = Join-Path $srcDir 'FmlBridge.java'
$text = [System.IO.File]::ReadAllText($fmlSrc, [System.Text.Encoding]::UTF8)

$old = '                Object ver = call(info, "versionString", new Class<?>[0]);'
$new = '                Object ver = modId; // BROKEN: never asks for the version string'
if (-not $text.Contains($old)) { Write-Host '[neg] 失败：锚点没找到（versionString 调用）'; exit 1 }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText($fmlDst, $text, $utf8)
Write-Host '[neg] 已还原：versionString 查询被移除'

# 2) compile the broken production class + the stubs + the probe
$jdk = Join-Path $repo '.tools\jdk21\bin'
$mixinJar = (Get-ChildItem (Join-Path $repo 'build\fabric\libs') -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$slf4jJar = (Get-ChildItem (Join-Path $repo 'build\fabric\libs') -Filter 'slf4j-api-*.jar' | Select-Object -First 1).FullName
$cpJars = "$mixinJar;$slf4jJar"
$classes = Join-Path $tmp 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null

$stubs = Get-ChildItem (Join-Path $repo 'src\test\stubs-fmlmodlist') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
# Only the broken FmlBridge is compiled - NOT the whole of src/main/java.
# BiliFixMod needs the @Mod annotation (NeoForge stub) and the rest of the
# tree drags in shapes this stub set does not model; the probe only links
# FmlBridge, so compiling just it keeps the negative test focused.
& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -proc:none -cp $cpJars -d $classes $fmlDst @stubs 2>&1 |
    Select-Object -First 6 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：还原后源码编译不过'; exit 1 }

& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -proc:none -cp "$classes;$cpJars" -d $classes (Join-Path $repo 'src\test\java\FmlModVersionProbe.java') 2>&1 |
    Select-Object -First 6 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 3) run the probe - it MUST fail
$o = Join-Path $tmp 'probe-out.txt'
$e = Join-Path $tmp 'probe-err.txt'
$proc = Start-Process -FilePath (Join-Path $jdk 'java.exe') `
    -ArgumentList @('-cp', "$classes;$cpJars", 'FmlModVersionProbe') `
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
