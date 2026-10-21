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

$jdk = Join-Path $repo '.tools\jdk21\bin'
$javaExe = Join-Path $jdk 'java.exe'
if (-not (Test-Path $javaExe)) { Write-Host "[neg-all] 缺少 JDK: $javaExe"; exit 1 }

$scripts = Get-ChildItem (Join-Path $repo 'src\test\negative') -Filter 'neg-*.ps1' -File | Sort-Object Name
if ($scripts.Count -eq 0) { Write-Host "[neg-all] 没找到负向测试脚本"; exit 1 }

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
Write-Host ("[neg-all] 负向测试总数: " + $scripts.Count + "  失败: " + $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host ("  FAILED: " + $_) }
    Write-Host "NEGATIVE_TESTS_HAVE_FAILURES"
    exit 1
}
Write-Host "NEGATIVE_TESTS_ALL_OK"
exit 0
