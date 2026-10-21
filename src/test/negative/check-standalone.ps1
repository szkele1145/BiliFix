$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))

# Every negative test must be runnable on its own.
#
# Why this matters: run-all-negative-tests.ps1 calls each script with &,
# and PowerShell's & call runs a script in a child scope that can still SEE
# the caller's variables. So a script that used $repo or $jdk without
# defining them passed inside the batch run and failed on its own - and
# running a single negative test is exactly what a human does when a test
# breaks. Four scripts were in that state.
#
# This check is the regression guard for it.

$failed = @()
$scripts = Get-ChildItem (Join-Path $d 'src\test\negative') -Filter 'neg-*.ps1' -File | Sort-Object Name
foreach ($s in $scripts) {
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $s.FullName 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    $ok = $o | Where-Object { $_ -match 'NEGATIVE_TEST_OK' } | Select-Object -First 1
    if ($code -eq 0 -and $ok) {
        Write-Host ("  OK    " + $s.Name)
    } else {
        Write-Host ("  FAIL  " + $s.Name + " (exit " + $code + ")")
        $o | Select-Object -Last 3 | ForEach-Object { Write-Host ("        " + $_) }
        $failed += $s.Name
    }
}
Write-Host ""
Write-Host ("单独可跑的脚本数: " + ($scripts.Count - $failed.Count) + " / " + $scripts.Count)
if ($failed.Count -gt 0) {
    Write-Host ("失败: " + ($failed -join ', '))
    Write-Host "NEGATIVE_TESTS_NOT_STANDALONE"
    exit 1
}
Write-Host "NEGATIVE_TESTS_ALL_STANDALONE"
exit 0
