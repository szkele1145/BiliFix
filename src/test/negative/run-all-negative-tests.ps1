# Runs every negative test: each one breaks the production code on purpose and
# asserts that the matching behaviour probe FAILS. A probe that cannot fail is
# not evidence - it is decoration.
#
# These scripts live in src/test/negative/ (under version control) on purpose:
# they used to sit in out/, which is git-ignored, so the evidence that the
# probes can actually fail existed only on one machine.
#
# Requires: the same JDK as the build scripts (.tools/jdk21) and the libs
# cached under build/fabric/libs by a previous build.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Set-Location $repo

# JDK resolution: shared helper (the project's own toolchain first, then
# JAVA_HOME). See src/test/negative/jdk.ps1 for why copying just java.exe +
# javac.exe into .tools/jdk21 does not work on a modular JDK 21.
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin -RepoRoot $repo
if (-not $jdkBin) {
    Write-Host "[neg-all] 缺少 JDK：既没有 .tools\jdk21\bin\javac.exe，也没有 JAVA_HOME"
    exit 1
}
$javaExe = Join-Path $jdkBin 'java.exe'
if (-not (Test-Path $javaExe)) { Write-Host "[neg-all] 缺少 JDK: $javaExe"; exit 1 }

$scripts = Get-ChildItem (Join-Path $repo 'src\test\negative') -Filter 'neg-*.ps1' -File | Sort-Object Name
if ($scripts.Count -eq 0) { Write-Host "[neg-all] 没找到负向测试脚本"; exit 1 }

# WORKING-TREE GUARD
#
# These negative tests break the production code ON PURPOSE, against the REAL
# repository (not a copy) - so a script that resolves its temporary directory
# wrongly can delete or overwrite repository files. That is not hypothetical:
# run-all-negative-tests.ps1 itself was removed by a stray cleanup during
# v1.4.8 development, and nothing noticed until the CI simulation failed much
# later with "cannot find path ... run-all-negative-tests.ps1".
#
# The $tmp guards inside the individual neg-*.ps1 scripts only protect the
# directory they delete; they cannot notice a deletion performed by some OTHER
# script. So the guard has to live here, where the whole run is visible:
# snapshot the working tree before, compare after, and report any difference.
# A negative test that leaves the repository changed has failed, whether or not
# its own assertions passed.
function Get-TreeState {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($rel in (git ls-files)) {
        $full = Join-Path $repo $rel
        if (-not (Test-Path -LiteralPath $full)) {
            $lines.Add("DELETED $rel")
        } else {
            $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
            $lines.Add("$h $rel")
        }
    }
    foreach ($rel in (git ls-files --others --exclude-standard)) {
        $lines.Add("UNTRACKED $rel")
    }
    return ($lines | Sort-Object) -join "`n"
}

$before = Get-TreeState
$beforeCount = ($before -split "`n").Count

# Line endings must be LF, matching the Java sources these scripts anchor on.
#
# This check exists because of a real failure: every negative test below
# anchors on a multi-line here-string taken verbatim from a .java file.
# A CRLF script therefore looks for "...\r\n" while the Java source has
# "...\n", the anchor silently stops matching, and the test reports
# "anchor not found" - which reads like a production regression but is
# really a line-ending mismatch in the test harness.
#
# The failure was easy to misread (9 of 19 tests failed at once) and easy
# to "fix" by rewriting the anchors to match the wrong line endings, which
# would break them again on the next checkout. So the mismatch is now
# caught up front, with a message that names the real cause.
$crlfScripts = @()
foreach ($s in $scripts) {
    $raw = [System.IO.File]::ReadAllText($s.FullName, [System.Text.Encoding]::UTF8)
    if ($raw.Contains("`r`n")) { $crlfScripts += $s.Name }
}
if ($crlfScripts.Count -gt 0) {
    Write-Host "[neg-all] 失败：以下负向测试用了 CRLF 换行，但锚点必须与 Java 源码（LF）一致："
    $crlfScripts | ForEach-Object { Write-Host ("  " + $_) }
    Write-Host "[neg-all] 修复：把这些文件转成 LF 再跑（例如用 UTF-8 无 BOM + LF 写回）"
    Write-Host "NEGATIVE_TESTS_HAVE_FAILURES"
    exit 1
}

$failed = @()
foreach ($s in $scripts) {
    Write-Host ("[neg-all] === " + $s.Name + " ===")
    $out = & $s.FullName 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    $tail = $out | Select-Object -Last 2
    $tail | ForEach-Object { Write-Host "    $_" }
    if ($code -ne 0) {
        Write-Host ("[neg-all] FAIL: " + $s.Name + " (exit " + $code + ")")
        $failed += $s.Name
    } else {
        Write-Host ("[neg-all] OK:   " + $s.Name)
    }
}

Write-Host ""
# WORKING-TREE GUARD (second half): the repository must be byte-identical to
# how it was before the run. A negative test that leaves the tree changed has
# failed - its own assertions passing does not make the damage acceptable.
$after = Get-TreeState
if ($after -ne $before) {
    Write-Host ""
    Write-Host "[neg-all] 失败：负向测试改动了工作树（跑之前 $beforeCount 条，跑之后 $(($after -split "`n").Count) 条）"
    $diff = Compare-Object ($before -split "`n") ($after -split "`n")
    $diff | Select-Object -First 20 | ForEach-Object {
        $tag = if ($_.SideIndicator -eq '<=') { '消失/变更前' } else { '新增/变更后' }
        Write-Host ("  " + $tag + ": " + $_.InputObject)
    }
    if (($diff | Measure-Object).Count -gt 20) {
        Write-Host ("  ... 还有 " + ((($diff | Measure-Object).Count) - 20) + " 处差异")
    }
    Write-Host "[neg-all] 修复：找出是哪条负向测试动了仓库（逐条跑），并检查它的临时目录解析"
    $failed += '工作树被改动'
}
Write-Host ("[neg-all] 负向测试总数: " + $scripts.Count + "  失败: " + $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host ("  FAILED: " + $_) }
    Write-Host "NEGATIVE_TESTS_HAVE_FAILURES"
    exit 1
}

# STANDALONE CHECK
#
# Every negative test must also work on its own, because that is what a
# human does when a test breaks: run that one script. PowerShell's & call
# runs a script in a child scope that can still SEE the caller's variables,
# so a script that used $repo or $jdk without defining them passed inside
# this batch and failed on its own - four scripts were in that state.
#
# The check starts the scripts from a directory that is NOT the repository
# root, so a script that secretly depends on the current directory is caught
# too.
Write-Host ""
Write-Host "[neg-all] 检查每条负向测试能否单独运行"
$standaloneOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'src\test\negative\check-standalone.ps1') 2>&1
$standaloneCode = $LASTEXITCODE
$standaloneOut | Select-String -Pattern '单独可跑的脚本数|NEGATIVE_TESTS_ALL_STANDALONE|NEGATIVE_TESTS_NOT_STANDALONE' |
    ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
if ($standaloneCode -ne 0) {
    $standaloneOut | Select-String -Pattern '^\s+FAIL' | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
    Write-Host "NEGATIVE_TESTS_HAVE_FAILURES"
    exit 1
}

Write-Host "NEGATIVE_TESTS_ALL_OK"
exit 0
