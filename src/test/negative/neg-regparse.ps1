$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded.
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin -RepoRoot $d
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

# Negative test for RegParseAndConcurrencyProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# production code on purpose, in a COPY, and requires the probe to fail.
#
# Two INDEPENDENT breakages, each starting from the pristine copy:
#
#   BREAK 1: REG_EXPAND_SZ support is removed again. The javadoc still
#            claims it, but the parser only looks for the literal
#            "REG_SZ" - which does NOT occur inside "REG_EXPAND_SZ".
#            The value is then silently dropped: the GPU line comes
#            out incomplete and nothing says why.
#
#   BREAK 2: the concurrent container is reverted to a plain
#            ArrayList. The background reader thread writes while the
#            main thread reads after a TIMED-OUT join() - a join
#            timeout establishes no happens-before, so that read races
#            with the writes.

$tmp = Join-Path $env:TEMP ("bilifix-neg-regparse-" + [guid]::NewGuid().ToString('N').Substring(0,8))
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if (-not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
    Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
    exit 1
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Copy the whole production tree (relative layout preserved) + the FML stubs.
$srcDir = Join-Path $tmp 'src'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
Copy-Item "$d\src\main\java\dev" $srcDir -Recurse -Force
$stubDir = Join-Path $tmp 'stubs'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
Copy-Item "$d\src\test\stubs\ci\*" $stubDir -Recurse -Force

$target = Join-Path $srcDir 'dev\polaris_fix\bilifix\EnvironmentDiagnostics.java'
if (-not (Test-Path $target)) { Write-Host "REVERT_FAILED: 目标文件不存在"; exit 1 }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$prodCp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"
if (-not (Test-Path $prodCp.Split(';')[0])) { Write-Host "找不到 slf4j / mixin jar"; exit 1 }

$prodSrc = @(Get-ChildItem (Join-Path $srcDir 'dev') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }) +
           @(Get-ChildItem $stubDir -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })

function Invoke-Probe {
    param([string]$ClassesDir)
    $o = Join-Path $tmp 'probe.out'
    $e = Join-Path $tmp 'probe.err'
    # 传入**被检查的那份源码路径**：负向测试必须让探针看到被破坏的副本，
    # 否则源级断言读的是仓库原版，破坏根本进不了探针的视野。
    $all = [string[]]@('-cp', "$probeOut;$ClassesDir;$prodCp") + [string[]]@('RegParseAndConcurrencyProbe', $target)
    $p = Start-Process -FilePath $java -ArgumentList $all -NoNewWindow -Wait -PassThru `
         -WorkingDirectory $d -RedirectStandardOutput $o -RedirectStandardError $e
    $text = @()
    if (Test-Path $o) { $text += (Get-Content $o -EA SilentlyContinue) }
    if (Test-Path $e) { $text += (Get-Content $e -EA SilentlyContinue) }
    return @{ Code = $p.ExitCode; Text = $text }
}

# Compile the probe once (it does not change).
$probeOut = Join-Path $tmp 'probe'
New-Item -ItemType Directory -Force -Path $probeOut | Out-Null
$baseClasses = Join-Path $tmp 'classes-base'
New-Item -ItemType Directory -Force -Path $baseClasses | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $baseClasses @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "生产代码副本编译失败"; exit 1 }
& $javac -encoding UTF-8 -proc:none -cp "$baseClasses;$prodCp" -d $probeOut "$d\src\test\java\RegParseAndConcurrencyProbe.java" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "探针编译失败"; exit 1 }

$t0 = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

# --- sanity: the UNBROKEN copy must PASS ---
Write-Host "=== 基线：未破坏的副本必须通过 ==="
$r0 = Invoke-Probe -ClassesDir $baseClasses
Write-Host ("  退出码 = " + $r0.Code + "（期望 0）")
$r0.Text | Select-String -Pattern '通过 \d+|RESULT' | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r0.Code -ne 0) {
    $r0.Text | Select-Object -Last 10 | ForEach-Object { Write-Host ("  ! " + $_) }
    Write-Host "NEGATIVE_TEST_SETUP_FAILED"
    exit 1
}

# --- BREAK 1: REG_EXPAND_SZ support removed ---
Write-Host "=== BREAK 1：REG_EXPAND_SZ 支持被去掉 ==="
$t1 = $t0.Replace(@'
        int i = line.indexOf("REG_EXPAND_SZ");
        int typeLen = "REG_EXPAND_SZ".length();
        if (i < 0) {
            i = line.indexOf("REG_SZ");
            typeLen = "REG_SZ".length();
        }
'@, @'
        int i = line.indexOf("REG_SZ");
        int typeLen = "REG_SZ".length();
'@)
if ($t1 -eq $t0) { Write-Host "  ! BREAK 1 锚点缺失（源码已变？）；跳过该破坏"; }
else {
    [System.IO.File]::WriteAllText($target, $t1, $utf8NoBom)
    $c1 = Join-Path $tmp 'classes1'
    New-Item -ItemType Directory -Force -Path $c1 | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp $prodCp -d $c1 @prodSrc 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "BREAK 1 编译失败"; exit 1 }
    $r1 = Invoke-Probe -ClassesDir $c1
    Write-Host ("  退出码 = " + $r1.Code + "（期望 != 0）")
    $r1.Text | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | Select-Object -First 6 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
    if ($r1.Code -eq 0) { Write-Host "  ! 探针在 REG_EXPAND_SZ 被去掉时仍然通过 —— 探针无效"; exit 1 }
}

# --- BREAK 2: concurrent container reverted to plain ArrayList ---
# From the PRISTINE copy, so this breakage is independent of BREAK 1.
Write-Host "=== BREAK 2：并发容器退回普通 ArrayList ==="
$t2 = $t0.Replace('var lines = new java.util.concurrent.CopyOnWriteArrayList<String>();', 'var lines = new java.util.ArrayList<String>();')
if ($t2 -eq $t0) { Write-Host "  ! BREAK 2 锚点缺失（源码已变？）；跳过该破坏" }
else {
    [System.IO.File]::WriteAllText($target, $t2, $utf8NoBom)
    $c2 = Join-Path $tmp 'classes2'
    New-Item -ItemType Directory -Force -Path $c2 | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp $prodCp -d $c2 @prodSrc 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "BREAK 2 编译失败"; exit 1 }
    $r2 = Invoke-Probe -ClassesDir $c2
    Write-Host ("  退出码 = " + $r2.Code + "（期望 != 0）")
    $r2.Text | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | Select-Object -First 6 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
    if ($r2.Code -eq 0) { Write-Host "  ! 探针在并发容器被换回时仍然通过 —— 探针无效"; exit 1 }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "NEGATIVE_TEST_OK"
exit 0
