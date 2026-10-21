$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for ForensicsVoutProbe.
#
# Purpose: a probe that cannot fail proves nothing. This reverts the
# v1.4.8 forensics display fix in a COPY of the production source and
# requires the probe to fail.
#
# The reverted code writes the raw voutValue() again:
#     sb.append(", vout=").append(BiliFixConfig.voutValue())
# With that, a user who deliberately set vout = "original" finds
# "vout=null" in bilifix-diagnostic.txt - the one file that survives a
# native crash. null reads as "the setting is gone / broken", while the
# truth is "the setting means keep watermedia's own value".
#
# The probe takes the source file path as an argument on purpose: reading
# the working copy would make the source-level assertions check the
# UNREVERTED file and pass against broken code.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"
$tmp = Join-Path $env:TEMP 'forensics-vout-neg'
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$tmp\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$tmp\out" | Out-Null

$src = "$d\src\main\java"
Get-ChildItem $src -Recurse -Filter '*.java' | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $dst = Join-Path "$tmp\src" $rel
    $dd = Split-Path $dst -Parent
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item $_.FullName $dst -Force
}

$target = "$tmp\src\dev\polaris_fix\bilifix\CrashSentinel.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

# BREAK 1: the diagnostic file writes the raw accessor again
$old1 = '              .append(", vout=").append(strategyVout()).append(''\n'');'
$new1 = '              .append(", vout=").append(BiliFixConfig.voutValue()).append(''\n'');'
if (-not $text.Contains($old1)) { Write-Host 'ANCHOR_DIAG_NOT_FOUND'; exit 1 }
$text = $text.Replace($old1, $new1)

# BREAK 2: the session lock writes the raw accessor again
$old2 = '                    + ", vout=" + strategyVout() + "\n";'
$new2 = '                    + ", vout=" + BiliFixConfig.voutValue() + "\n";'
if (-not $text.Contains($old2)) { Write-Host 'ANCHOR_LOCK_NOT_FOUND'; exit 1 }
$text = $text.Replace($old2, $new2)

[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'REVERTED: the forensics files write the raw voutValue() again'

$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'REVERT_COMPILE_FAILED'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\ForensicsVoutProbe.java" 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'PROBE_COMPILE_FAILED'; exit 1 }

$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'ForensicsVoutProbe', "$tmp\src\dev\polaris_fix\bilifix\CrashSentinel.java") `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $d `
        -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"
Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { "  $($_.ToString())" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Write-Host ''
    Write-Host 'NEGATIVE_TEST_FAILED: the probe PASSED against the reverted code - it cannot detect the bug'
    exit 1
}
Write-Host ''
Write-Host ("NEGATIVE_TEST_OK: probe FAILED against the reverted code (exit " + $proc.ExitCode + ")")
exit 0
