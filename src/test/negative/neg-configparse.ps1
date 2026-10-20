$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for ConfigParseProbe.
#
# Purpose: a probe that cannot fail proves nothing. This reverts the
# v1.4.8 BOM fix in a COPY of the production source and requires the
# probe to fail.
#
# The reverted code is the original parse():
#     for (String line : Files.readAllLines(path, UTF_8)) {
#         String s = line.trim();
#         if (s.isEmpty() || s.startsWith("#")) continue;
#         ...
#     }
# Files.readAllLines does NOT strip a UTF-8 BOM, so with a BOM-prefixed
# file the first key becomes "\uFEFFhwDecoder" and the user's hwDecoder
# setting is silently ignored.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"
$tmp = Join-Path $env:TEMP 'cfg-neg'

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

$target = "$tmp\src\dev\polaris_fix\bilifix\config\BiliFixConfig.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

$oldBlock = @'
        Map<String, String> kv = new LinkedHashMap<>();
        boolean first = true;
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            String s = line.trim();
'@
$newBlock = @'
        Map<String, String> kv = new LinkedHashMap<>();
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            String s = line.trim();
'@
if (-not $text.Contains($oldBlock)) { Write-Host 'ANCHOR_LOOP_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldBlock, $newBlock)

$oldBom = @'
            if (first) {
                first = false;
                if (!s.isEmpty() && s.charAt(0) == '\uFEFF') s = s.substring(1).trim();
            }
'@
if (-not $text.Contains($oldBom)) { Write-Host 'ANCHOR_BOM_NOT_FOUND'; exit 1 }
$text = $text.Replace($oldBom, '')

[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'REVERTED to the BOM-unaware parse()'

$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'REVERT_COMPILE_FAILED'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\ConfigParseProbe.java" 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'PROBE_COMPILE_FAILED'; exit 1 }

$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'ConfigParseProbe') `
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
