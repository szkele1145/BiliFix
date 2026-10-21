param(
    # Additional directories to scan for neg-*.ps1 (used by the self-test to
    # plant a broken script outside the repository).
    [string[]]$ExtraDir
)

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
#
# The scripts are started from a directory that is NOT the repository root,
# so a script that secretly depends on the current directory is caught too.
#
# NOTE: the child processes run through Start-Process with real file
# redirection. With & plus 2>&1, a child that writes to stderr makes the
# caller's $ErrorActionPreference='Stop' turn it into a TERMINATING error:
# the loop would die at the first failing script and the report would name
# nothing. The check has to report every broken script, not just the first.

$tmp = Join-Path $env:TEMP ('bilifix-standalone-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Invoke-Script {
    param([string]$Path)
    $o = Join-Path $tmp 'o.txt'
    $e = Join-Path $tmp 'e.txt'
    $p = Start-Process -FilePath 'powershell' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $env:TEMP `
        -RedirectStandardOutput $o -RedirectStandardError $e
    $text = @()
    if (Test-Path $o) { $text += (Get-Content $o -EA SilentlyContinue) }
    if (Test-Path $e) { $text += (Get-Content $e -EA SilentlyContinue) }
    return @{ Code = $p.ExitCode; Text = $text }
}

$failed = @()
$dirs = @((Join-Path $d 'src\test\negative'))
if ($ExtraDir) { $dirs += $ExtraDir }
$scripts = @()
foreach ($dir in $dirs) {
    if (Test-Path $dir) {
        $scripts += (Get-ChildItem $dir -Filter 'neg-*.ps1' -File | Sort-Object Name)
    }
}
foreach ($s in $scripts) {
    $r = Invoke-Script -Path $s.FullName
    $ok = $r.Text | Where-Object { $_ -match 'NEGATIVE_TEST_OK' } | Select-Object -First 1
    if ($r.Code -eq 0 -and $ok) {
        Write-Host ("  OK    " + $s.Name)
    } else {
        Write-Host ("  FAIL  " + $s.Name + " (exit " + $r.Code + ")")
        $r.Text | Select-Object -Last 3 | ForEach-Object { Write-Host ("        " + $_.ToString().Trim()) }
        $failed += $s.Name
    }
}
Remove-Item $tmp -Recurse -Force -EA SilentlyContinue

Write-Host ""
Write-Host ("单独可跑的脚本数: " + ($scripts.Count - $failed.Count) + " / " + $scripts.Count)
if ($failed.Count -gt 0) {
    Write-Host ("失败: " + ($failed -join ', '))
    Write-Host "NEGATIVE_TESTS_NOT_STANDALONE"
    exit 1
}
Write-Host "NEGATIVE_TESTS_ALL_STANDALONE"
exit 0
