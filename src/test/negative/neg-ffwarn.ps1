$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$jdkBin = $null
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

# Negative test for ForensicsFailureWarnProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# production warning logic in a COPY of the source and requires the
# probe to fail.
#
# Two independent breakages are tested, because a probe that only
# catches one of them would be a weaker guarantee:
#
#   BREAK 1: the forensics failures are swallowed silently again - the
#            catch blocks go back to `catch (Throwable ignored)` and the
#            warn call is gone. The user then gets no diagnostic file
#            and no explanation, which is the whole silent-failure path
#            this probe exists to prevent.
#
#   BREAK 2: the "warn only once" guarantee is gone - the atomic flag
#            is replaced by a plain boolean, so the shutdown hook
#            re-running the forensics code can spam the log.

$tmp = Join-Path $env:TEMP ("bilifix-neg-ffwarn-" + [guid]::NewGuid().ToString('N').Substring(0,8))
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
    Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
    exit 1
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$srcDir = Join-Path $tmp 'src'
$mainDir = Join-Path $srcDir 'dev\polaris_fix\bilifix'
New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
# 整个 main 源码树都要拷：生产类引用了 config 子包（BiliFixConfig 等）
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
Copy-Item "$d\src\main\java\dev" $srcDir -Recurse -Force
# FML stub：BiliFixMod 引用 net.neoforged.fml.ModContainer / common.Mod，
# 真实 FML 不在 classpath 上（那是 mod 加载器提供的）
$stubDir = Join-Path $tmp 'stubs'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
Copy-Item "$d\src\test\stubs\ci\*" $stubDir -Recurse -Force
$cs = Join-Path $srcDir 'dev\polaris_fix\bilifix\CrashSentinel.java'

$slf4j = (Get-ChildItem (Join-Path $d 'build\fabric\libs') -Filter 'slf4j-api-*.jar' | Select-Object -First 1).FullName
if (-not $slf4j) { Write-Host "找不到 slf4j-api"; exit 1 }
$mixinJar = (Get-ChildItem (Join-Path $d 'build\fabric\libs') -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
if (-not $mixinJar) { Write-Host "找不到 mixin jar"; exit 1 }
$prodCp = "$slf4j;$mixinJar"

function Invoke-Probe {
    param([string]$ProbeOut, [string[]]$Cp, [string[]]$ProbeArgs)
    $o = Join-Path $tmp 'probe.out'
    $e = Join-Path $tmp 'probe.err'
    $all = [string[]]@('-cp', ($Cp -join ';')) + [string[]]$ProbeArgs + [string[]]@('ForensicsFailureWarnProbe', $cs)
    $p = Start-Process -FilePath $java -ArgumentList $all -NoNewWindow -Wait -PassThru `
         -WorkingDirectory $tmp -RedirectStandardOutput $o -RedirectStandardError $e
    $text = @()
    if (Test-Path $o) { $text += (Get-Content $o -EA SilentlyContinue) }
    if (Test-Path $e) { $text += (Get-Content $e -EA SilentlyContinue) }
    return @{ Code = $p.ExitCode; Text = $text }
}

# compile the production copy + the probe
$classes = Join-Path $tmp 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
$prodSrc = @(Get-ChildItem (Join-Path $srcDir 'dev') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }) + @(Get-ChildItem $stubDir -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $classes @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "生产代码副本编译失败"; exit 1 }
$probeOut = Join-Path $tmp 'probe'
New-Item -ItemType Directory -Force -Path $probeOut | Out-Null
& $javac -encoding UTF-8 -proc:none -cp "$classes;$prodCp" -d $probeOut "$d\src\test\java\ForensicsFailureWarnProbe.java" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "探针编译失败"; exit 1 }

# --- sanity: the UNBROKEN copy must PASS ---
Write-Host "=== 基线：未破坏的副本必须通过 ==="
$r0 = Invoke-Probe -ProbeOut $probeOut -Cp @("$probeOut;$classes;$prodCp") -ProbeArgs @()
Write-Host ("  退出码 = " + $r0.Code + "（期望 0）")
$r0.Text | Select-String -Pattern '通过 \d+|RESULT' | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r0.Code -ne 0) {
    $r0.Text | Select-Object -Last 8 | ForEach-Object { Write-Host ("  ! " + $_) }
    Write-Host "NEGATIVE_TEST_SETUP_FAILED"
    exit 1
}

# --- BREAK 1: the warning is gone (silent catch again) ---
Write-Host "=== BREAK 1：取证失败恢复为静默吞掉 ==="
$t0 = [System.IO.File]::ReadAllText($cs, [System.Text.Encoding]::UTF8)
$t1 = $t0
$t1 = $t1.Replace('warnForensicsOnce(BiliFixMod.LOGGER, "会话标记", t);', '')
$t1 = $t1.Replace('warnForensicsOnce(BiliFixMod.LOGGER, "退出诊断文件", t);', '')
$t1 = $t1.Replace('warnForensicsOnce(BiliFixMod.LOGGER, "异常终止报告", t);', '')
[System.IO.File]::WriteAllText($cs, $t1, $utf8NoBom)
$classes1 = Join-Path $tmp 'classes1'
New-Item -ItemType Directory -Force -Path $classes1 | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $classes1 @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "BREAK 1 编译失败"; exit 1 }
$r1 = Invoke-Probe -ProbeOut $probeOut -Cp @("$probeOut;$classes1;$prodCp") -ProbeArgs @()
Write-Host ("  退出码 = " + $r1.Code + "（期望 != 0）")
$r1.Text | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | Select-Object -First 6 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r1.Code -eq 0) { Write-Host "  ! 探针在缺告警时仍然通过 —— 探针无效"; exit 1 }

# --- BREAK 2: the "warn once" guarantee is gone ---
# 从**原始**副本出发（不是从 BREAK 1 的残骸），这样这个破坏是独立的：
# 只去掉"只打一次"的短路，告警本身仍然在。
Write-Host "=== BREAK 2：'只告警一次' 的保证被去掉 ==="
$t2 = $t0.Replace('if (!FORENSICS_WARNED.compareAndSet(false, true)) return;', '')
[System.IO.File]::WriteAllText($cs, $t2, $utf8NoBom)
$classes2 = Join-Path $tmp 'classes2'
New-Item -ItemType Directory -Force -Path $classes2 | Out-Null
& $javac -encoding UTF-8 -proc:none -cp $prodCp -d $classes2 @prodSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "BREAK 2 编译失败"; exit 1 }
$r2 = Invoke-Probe -ProbeOut $probeOut -Cp @("$probeOut;$classes2;$prodCp") -ProbeArgs @()
Write-Host ("  退出码 = " + $r2.Code + "（期望 != 0）")
$r2.Text | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | Select-Object -First 6 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($r2.Code -eq 0) { Write-Host "  ! 探针在'只告警一次'被破坏时仍然通过 —— 探针无效"; exit 1 }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "NEGATIVE_TEST_OK"
exit 0
