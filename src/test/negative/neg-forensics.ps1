$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for ForensicsSuppressionProbe.
#
# Purpose: a probe that cannot fail proves nothing. This reverts the
# v1.4.8 forensics-suppression fix in a COPY of the production source
# and requires the probe to fail.
#
# The reverted code is the original global boolean:
#     private static volatile boolean suppressForensics = false;
# With that, the startup self-check's suppression also swallows a REAL
# media playback happening on the media thread at the same time, so
# mediaTouched stays false and the harden count does not move - the
# forensic evidence for "the user really played media" is lost.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"
$tmp = Join-Path $env:TEMP 'fs-neg'

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

# 1) field: ThreadLocal -> global volatile boolean
$oldField = '    private static final ThreadLocal<Boolean> SUPPRESS_FORENSICS = ThreadLocal.withInitial(() -> Boolean.FALSE);'
$newField = '    private static volatile boolean SUPPRESS_FORENSICS = false;'
if (-not $text.Contains($oldField)) { Write-Host 'ANCHOR_FIELD_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldField, $newField)

# 2) setter
$oldSet = @'
    public static void setForensicsSuppressed(boolean suppress) {
        SUPPRESS_FORENSICS.set(suppress);
    }
'@
$newSet = @'
    public static void setForensicsSuppressed(boolean suppress) {
        SUPPRESS_FORENSICS = suppress;
    }
'@
if (-not $text.Contains($oldSet)) { Write-Host 'ANCHOR_SETTER_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldSet, $newSet)

# 3) reader
$oldGet = '        if (Boolean.TRUE.equals(SUPPRESS_FORENSICS.get())) return;'
$newGet = '        if (SUPPRESS_FORENSICS) return;'
if (-not $text.Contains($oldGet)) { Write-Host 'ANCHOR_READER_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldGet, $newGet)

[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'REVERTED to the global boolean implementation'

$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'REVERT_COMPILE_FAILED'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\ForensicsSuppressionProbe.java" 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'PROBE_COMPILE_FAILED'; exit 1 }

$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'ForensicsSuppressionProbe') `
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
