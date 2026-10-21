$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin -RepoRoot $d
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

# Negative test for ArgumentRewriteProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# production hardening logic in a COPY of the source and requires the
# probe to fail.
#
# Two independent breakages are tested, because a probe that only
# catches one of them would be a weaker guarantee:
#
#   BREAK 1: the old value is no longer discarded - the new value is
#            appended after the old one. The dangerous parameter would
#            still be present, which is exactly the bug this mod
#            exists to prevent.
#   BREAK 2: the "--key=value" form is no longer rewritten, so a
#            watermedia version that uses that form would keep
#            d3d11va.

$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"

function Invoke-Break {
    param([string]$Label, [scriptblock]$Mutate)
    $tmp = Join-Path $env:TEMP ("arg-neg-" + $Label)
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

    $target = "$tmp\src\dev\polaris_fix\bilifix\mixin\JarToolMixin.java"
    $text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
    $text = & $Mutate $text
    [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "--- $Label ---"

    $prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
    $stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 | Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
    if ($LASTEXITCODE -ne 0) { Write-Host "  COMPILE_FAILED"; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; return $false }

    & $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\ArgumentRewriteProbe.java" 2>&1 | Select-Object -First 4 | ForEach-Object { "  $($_.ToString())" }
    if ($LASTEXITCODE -ne 0) { Write-Host "  PROBE_COMPILE_FAILED"; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; return $false }

    $proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'ArgumentRewriteProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $d `
            -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"
    $out = Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue
    $out | Select-String -Pattern '\[FAIL\]|通过 \d+' | ForEach-Object { "  $($_.ToString().Trim())" }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return ($proc.ExitCode -ne 0)
}

# BREAK 1: stop discarding the old value
$b1 = Invoke-Break 'old-value-kept' {
    param($t)
    $old = '                    i = skipOldValue(original, i); // 丢弃旧值'
    $new = '                    // BROKEN ON PURPOSE: old value kept'
    if (-not $t.Contains($old)) { throw 'anchor 1 not found' }
    $t.Replace($old, $new)
}

# BREAK 2: stop rewriting the "--key=value" form
$b2 = Invoke-Break 'equals-form-unrewritten' {
    param($t)
    $old = '                    if (arg.startsWith("--avcodec-hw=")) {'
    $new = '                    if (false) {'
    if (-not $t.Contains($old)) { throw 'anchor 2 not found' }
    $t.Replace($old, $new)
}

Write-Host ''
Write-Host ("BREAK1_detected = " + $b1)
Write-Host ("BREAK2_detected = " + $b2)
if ($b1 -and $b2) {
    Write-Host 'NEGATIVE_TEST_OK: the probe catches both breakages'
    exit 0
}
Write-Host 'NEGATIVE_TEST_FAILED: the probe missed a breakage'
exit 1