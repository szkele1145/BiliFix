$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded.
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

# Negative test for ConfigInvalidValueProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# production code on purpose, in a COPY, and requires the probe to fail.
#
# Two INDEPENDENT breakages, each starting from the pristine copy:
#
#   BREAK 1: verbose goes back to a silent "true".equalsIgnoreCase(v) -
#            "yes" / "1" / "on" silently become false with no warning,
#            while hwDecoder and vout DO warn on invalid values.
#            Three fields, three different behaviours.
#
#   BREAK 2: duplicate-key detection is removed. The same key written
#            twice is silently overwritten (last one wins) and the user
#            who cannot figure out which line is in effect gets no clue.

$tmp = Join-Path $env:TEMP ("bilifix-neg-cfginvalid-" + [guid]::NewGuid().ToString('N').Substring(0,8))
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if (-not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
    Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
    exit 1
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$srcDir = Join-Path $tmp 'src'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
Copy-Item "$d\src\main\java\dev" $srcDir -Recurse -Force
$stubDir = Join-Path $tmp 'stubs'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
Copy-Item "$d\src\test\stubs\ci\*" $stubDir -Recurse -Force

$target = Join-Path $srcDir 'dev\polaris_fix\bilifix\config\BiliFixConfig.java'
if (-not (Test-Path $target)) { Write-Host "REVERT_FAILED: 目标文件不存在"; exit 1 }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$prodCp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"

$prodSrc = @(Get-ChildItem (Join-Path $srcDir 'dev') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }) +
           @(Get-ChildItem $stubDir -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })

# Capturing slf4j provider (same as the unknown-key probe needs).
$capOut = Join-Path $tmp 'cap'
New-Item -ItemType Directory -Force -Path "$capOut\META-INF\services" | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $capOut "$d\src\test\stubs\slf4j\test\slf4j\CapturingServiceProvider.java"
if ($LASTEXITCODE -ne 0) { Write-Host "capturing provider 编译失败"; exit 1 }
[System.IO.File]::WriteAllText("$capOut\META-INF\services\org.slf4j.spi.SLF4JServiceProvider", "test.slf4j.CapturingServiceProvider`n", (New-Object System.Text.UTF8Encoding($false)))

function Invoke-Probe {
    param([string]$ClassesDir)
    $o = Join-Path $tmp 'probe.out'
    $e = Join-Path $tmp 'probe.err'
    # 传入**被检查的那份源码路径**：源级断言必须对着被破坏的副本
    $all = [string[]]@('-cp', "$probeOut;$capOut;$ClassesDir;$prodCp") + [string[]]@('ConfigInvalidValueProbe', $target)
    $p = Start-Process -FilePath $java -ArgumentList $all -NoNewWindow -Wait -PassThru `
         -WorkingDirectory $d -RedirectStandardOutput $o -RedirectStandardError $e
    $text = @()
    if (Test-Path $o) { $text += (Get-Content $o -EA SilentlyContinue) }
    if (Test-Path $e) { $text += (Get-Content $e -EA SilentlyContinue) }
    return @{ Code = $p.ExitCode; Text = $text }
}

# Compile the probe once.
$probeOut = Join-Path $tmp 'probe'
New-Item -ItemType Directory -Force -Path $probeOut | Out-Null
$baseClasses = Join-Path $tmp 'classes-base'
New-Item -ItemType Directory -Force -Path $baseClasses | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $baseClasses @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "生产代码副本编译失败"; exit 1 }
& $javac -encoding UTF-8 -proc:none -cp "$baseClasses;$capOut;$prodCp" -d $probeOut "$d\src\test\java\ConfigInvalidValueProbe.java" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "探针编译失败"; exit 1 }

$t0 = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

# --- sanity: the UNBROKEN copy must PASS ---
Write-Host "=== 基线：未破坏的副本必须通过 ==="
$r0 = Invoke-Probe -ClassesDir $baseClasses
Write-Host ("  退出码 = " + $r0.Code + "（期望 0）")
$r0.Text | Select-String -Pattern '通过 \d+|RESULT' | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r0.Code -ne 0) {
    $r0.Text | Select-String -Pattern '\[FAIL\]' | Select-Object -First 5 | ForEach-Object { Write-Host ("  ! " + $_) }
    Write-Host "NEGATIVE_TEST_SETUP_FAILED"
    exit 1
}

# --- BREAK 1: verbose back to silent equalsIgnoreCase ---
Write-Host "=== BREAK 1：verbose 回到静默判定 ==="
$t1 = $t0.Replace('if (kv.containsKey("verbose"))  verbose   = parseBoolean(kv.get("verbose"));',
                  'if (kv.containsKey("verbose"))  verbose   = "true".equalsIgnoreCase(kv.get("verbose"));')
if ($t1 -eq $t0) { Write-Host "  ! BREAK 1 锚点缺失（源码已变？）"; exit 1 }
[System.IO.File]::WriteAllText($target, $t1, $utf8NoBom)
$c1 = Join-Path $tmp 'classes1'
New-Item -ItemType Directory -Force -Path $c1 | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $c1 @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "BREAK 1 编译失败"; exit 1 }
$r1 = Invoke-Probe -ClassesDir $c1
Write-Host ("  退出码 = " + $r1.Code + "（期望 != 0）")
$r1.Text | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | Select-Object -First 6 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r1.Code -eq 0) { Write-Host "  ! 探针在 verbose 静默判定下仍然通过 —— 探针无效"; exit 1 }

# --- BREAK 2: duplicate-key detection removed ---
# From the PRISTINE copy, so this breakage is independent of BREAK 1.
Write-Host "=== BREAK 2：重复键检测被去掉 ==="
$t2 = $t0.Replace(@'
            if (kv.containsKey(k) && !DUPLICATE_KEYS.contains(k)) {
                DUPLICATE_KEYS.add(k);
            }
'@, '')
if ($t2 -eq $t0) { Write-Host "  ! BREAK 2 锚点缺失（源码已变？）"; exit 1 }
[System.IO.File]::WriteAllText($target, $t2, $utf8NoBom)
$c2 = Join-Path $tmp 'classes2'
New-Item -ItemType Directory -Force -Path $c2 | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $c2 @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "BREAK 2 编译失败"; exit 1 }
$r2 = Invoke-Probe -ClassesDir $c2
Write-Host ("  退出码 = " + $r2.Code + "（期望 != 0）")
$r2.Text | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | Select-Object -First 6 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r2.Code -eq 0) { Write-Host "  ! 探针在重复键检测被去掉时仍然通过 —— 探针无效"; exit 1 }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "NEGATIVE_TEST_OK"
exit 0
