$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$tmp = Join-Path $env:TEMP ('bilifix-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Prove the standalone check can FAIL.
#
# The bug it guards against was real: four negative tests used $repo / $jdk
# without defining them. They passed inside the batch run (PowerShell's &
# call lets a child script SEE the caller's variables) and failed on their
# own. The standalone check exists to catch exactly that, so it has to be
# shown failing - a check that cannot fail is decoration.
#
# The broken script is planted in a TEMPORARY directory, not in the
# repository: a script that dies half-way through would otherwise leave a
# stray file in the working tree.
#
# NOTE: native command stderr becomes a terminating error under
# $ErrorActionPreference='Stop' even with 2>&1, so the child processes run
# through Start-Process with real file redirection.

$broken = @'
$ErrorActionPreference = 'Stop'
# Deliberately uses $repo without defining it - the hidden coupling.
$probe = Join-Path $repo 'src\test\java\Regression.java'
Write-Host ("[neg-broken] " + $probe)
exit 0
'@ -split "`r?`n"

$plantDir = Join-Path $tmp 'planted'
New-Item -ItemType Directory -Force -Path $plantDir | Out-Null
$brokenPath = Join-Path $plantDir 'neg-zz-broken.ps1'
[System.IO.File]::WriteAllText($brokenPath, ($broken -join "`n"), $utf8bom)

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList, [string]$WorkDir)
    $o = Join-Path $tmp 'o.txt'
    $e = Join-Path $tmp 'e.txt'
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
         -WorkingDirectory $WorkDir -RedirectStandardOutput $o -RedirectStandardError $e
    $text = @()
    if (Test-Path $o) { $text += (Get-Content $o -EA SilentlyContinue) }
    if (Test-Path $e) { $text += (Get-Content $e -EA SilentlyContinue) }
    return @{ Code = $p.ExitCode; Text = $text }
}

$check = "$d\src\test\negative\check-standalone.ps1"

Write-Host "--- 1) 单独跑这个坏脚本（应失败：repo 未定义）---"
$r1 = Invoke-Native -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$brokenPath) -WorkDir $env:TEMP
Write-Host ("  EXIT=" + $r1.Code + " （期望 != 0）")
$r1.Text | Select-Object -Last 2 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }

Write-Host "--- 2) 守卫应报出它（并点名）---"
$r2 = Invoke-Native -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$check,'-ExtraDir',$plantDir) -WorkDir $env:TEMP
Write-Host ("  守卫 EXIT=" + $r2.Code + " （期望 != 0）")
$r2.Text | Select-String -Pattern 'FAIL|单独可跑的脚本数|NEGATIVE_TESTS' | Select-Object -Last 6 |
    ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
$named = @($r2.Text | Where-Object { $_ -match 'neg-zz-broken' }).Count -gt 0
Write-Host ("  点名了坏脚本 = " + $named + " （期望 True）")

Write-Host "--- 3) 不带额外目录时守卫应全绿 ---"
$r3 = Invoke-Native -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$check) -WorkDir $env:TEMP
Write-Host ("  守卫 EXIT=" + $r3.Code + " （期望 0）")
$r3.Text | Select-String -Pattern '单独可跑的脚本数|NEGATIVE_TESTS' | Select-Object -Last 3 |
    ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }

Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
if ($r1.Code -ne 0 -and $r2.Code -ne 0 -and $named -and $r3.Code -eq 0) {
    Write-Host "STANDALONE_CHECK_CAUGHT_IT"
    exit 0
}
Write-Host "STANDALONE_CHECK_DID_NOT_CATCH_IT"
exit 1
