$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for StartupLogTruthProbe.
#
# Purpose: a probe that cannot fail proves nothing. This reverts the
# v1.4.8 startup-log fix in a COPY of the production source and requires
# the probe to fail.
#
# The reverted code prints the RAW config fields again:
#     LOGGER.info("... (策略: hw={}, vout={})",
#             VERSION, BiliFixConfig.hwDecoder, BiliFixConfig.vout);
# With that, the startup line - the first thing anyone reads when
# investigating a crash - can contradict what is actually in effect:
# hwDecoder="gpu" (an unknown value) shows "hw=gpu" while the effective
# value is "none" (software decoding), and hwDecoder="AUTO" shows
# "hw=AUTO" while the effective value is "any" (VLC picks the hardware
# decoder - the very tier that causes the crash).

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"
$tmp = Join-Path $env:TEMP 'startup-neg'

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

$target = "$tmp\src\dev\polaris_fix\bilifix\BiliFixMod.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

# BREAK 1: effectiveStrategy() returns the RAW fields again
$old1 = @'
        String effHw = BiliFixConfig.hwDecoderValue();
        String effVout = BiliFixConfig.voutValue();
        return new String[]{ effHw, effVout == null ? "original" : effVout };
'@
$new1 = @'
        String effHw = BiliFixConfig.hwDecoder;
        String effVout = BiliFixConfig.vout;
        return new String[]{ effHw, effVout == null ? "original" : effVout };
'@
if (-not $text.Contains($old1)) { Write-Host 'ANCHOR_EFFECTIVE_NOT_FOUND'; exit 1 }
$text = $text.Replace($old1, $new1)

# BREAK 2: never report that the configuration was normalized
$old2 = '        return !(hwSame && voutSame) || !(hwIdentical && voutIdentical);'
$new2 = '        return false;'
if (-not $text.Contains($old2)) { Write-Host 'ANCHOR_NORMALIZED_NOT_FOUND'; exit 1 }
$text = $text.Replace($old2, $new2)

[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'REVERTED: the startup line shows the raw config fields again'

$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'REVERT_COMPILE_FAILED'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\StartupLogTruthProbe.java" 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'PROBE_COMPILE_FAILED'; exit 1 }

$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'StartupLogTruthProbe', "$tmp\src\dev\polaris_fix\bilifix\BiliFixMod.java") `
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
