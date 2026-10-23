$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
. (Join-Path (Split-Path -Parent $PSCommandPath) 'deps.ps1')
# The negative tests compile a copy of the production sources, which import
# org.slf4j / org.spongepowered - so the two dependency jars must be on the
# classpath. They used to be taken from build\fabric\libs, a BUILD ARTIFACT:
# on a fresh clone every negative test died with "package org.slf4j does not
# exist" before running a single assertion. Initialize-DepJars fetches them
# (cache / MC libraries / Maven) and fails loudly if it cannot.
$depCp = Initialize-DepJars -RepoRoot $d
if (-not $depCp) { Write-Host "依赖 jar 不可用（slf4j-api / mixin）——无法编译生产代码副本"; exit 1 }
$jdkBin = Resolve-JdkBin -RepoRoot $d
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

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

$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"
$tmp = Join-Path $env:TEMP 'cfg-neg'
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