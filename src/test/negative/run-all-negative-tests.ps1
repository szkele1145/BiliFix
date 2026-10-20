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
