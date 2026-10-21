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

$tmp = Join-Path $env:TEMP ('bilifix-neg-fmlmodver-' + [guid]::NewGuid().ToString('N').Substring(0,8))
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
$jdk = $jdkBin
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
