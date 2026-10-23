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

# Negative test for FabricInitProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# production code in a COPY of the source and requires the probe to fail.
#
# The break: BiliFixMod.init() loads the config BEFORE the injected
# directories are set. The config file then lands wherever the fallback
# says (the working directory) instead of in the injected config dir.
#
# Why that matters: the mod keeps working - only the user's settings
# stop taking effect, and nothing says why. It is exactly the kind of
# silent failure this project keeps hunting down, and the Fabric path is
# the one loader that goes through the explicit injection.

$slf4j = "$d\build\fabric\libs\slf4j-api-2.0.7.jar"
$mixin = (Get-ChildItem "$d\build\fabric\libs" -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$cp = "$slf4j;$mixin"

$tmp = Join-Path $env:TEMP ('bilifix-neg-fabricinit-' + [guid]::NewGuid().ToString('N').Substring(0,8))
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

# 2) break BiliFixMod.init(): load the config BEFORE the dirs are injected
$target = "$tmp\src\dev\polaris_fix\bilifix\BiliFixMod.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
$old = @'
        if (configDir != null) BiliFixConfig.setConfigDir(configDir);
        if (gameDir != null) CrashSentinel.setGameDir(gameDir);
        BiliFixConfig.load();
'@
$new = @'
        BiliFixConfig.load();
        if (configDir != null) BiliFixConfig.setConfigDir(configDir);
        if (gameDir != null) CrashSentinel.setGameDir(gameDir);
'@
if (-not $text.Contains($old)) { Write-Host '[neg] 失败：锚点没找到（init 的注入顺序）'; exit 1 }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '[neg] 已还原：init 先 load 配置再注入目录（配置会落到别处）'

# 3) compile the broken production tree
$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：还原后源码编译不过'; exit 1 }

# 4) compile the probe
& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\FabricInitProbe.java" 2>&1 |
    Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 5) run the probe against the BROKEN COPY - it MUST fail
$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'FabricInitProbe') `
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