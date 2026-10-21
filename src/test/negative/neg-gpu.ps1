$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

# Negative test for GpuDetectProbe.
#
# Purpose: a probe that cannot fail proves nothing. This reverts the v1.4.8
# GPU fix in a COPY of the production source and requires the probe to fail.
#
# The reverted code is the original implementation: query the adapter CLASS
# key for DriverDesc, which fails with
#   ERROR: The system was unable to find the specified registry key or value.
# so detectGpu() returns null and the GPU line never reaches the report.

$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'
$tmp = Join-Path $env:TEMP 'gpu-neg'
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}
$cp = "$d\build\fabric\libs\slf4j-api-2.0.7.jar;$d\build\fabric\libs\mixin-0.8.5.jar"

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$tmp\src\dev\polaris_fix\bilifix" | Out-Null
New-Item -ItemType Directory -Force -Path "$tmp\out" | Out-Null

# Copy the whole production tree, then revert ONLY EnvironmentDiagnostics.java
# back to the original (class-key) implementation.
$src = "$d\src\main\java"
Get-ChildItem $src -Recurse -Filter '*.java' | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $dst = Join-Path "$tmp\src" $rel
    $dd = Split-Path $dst -Parent
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item $_.FullName $dst -Force
}

$target = "$tmp\src\dev\polaris_fix\bilifix\EnvironmentDiagnostics.java"
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

# Replace the whole fixed detectGpu() + helpers with the ORIGINAL one-liner.
$startMarker = '    private static String detectGpu() {'
$endMarker = '    private static boolean checkClass(String fqn) {'
$si = $text.IndexOf($startMarker)
$ei = $text.IndexOf($endMarker)
if ($si -lt 0 -or $ei -lt 0 -or $ei -lt $si) {
    Write-Host "REVERT_FAILED: markers not found (si=$si ei=$ei)"
    exit 1
}

$original = @'
    private static String detectGpu() {
        if (!System.getProperty("os.name", "").toLowerCase().contains("win")) return null;
        try {
            Process p = new ProcessBuilder("reg", "query",
                    "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}",
                    "/v", "DriverDesc").redirectErrorStream(true).start();
            var reader = new java.io.BufferedReader(new java.io.InputStreamReader(p.getInputStream()));
            var lines = new java.util.ArrayList<String>();
            var t = new Thread(() -> {
                try {
                    String line;
                    while ((line = reader.readLine()) != null) lines.add(line);
                } catch (Throwable ignored) {
                }
            }, "BiliFix-GPU-Detect");
            t.setDaemon(true);
            t.start();
            if (!p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) {
                p.destroyForcibly();
                return null;
            }
            t.join(500);
            for (String line : lines) {
                if (line.contains("DriverDesc") && line.contains("REG_SZ")) {
                    int i = line.indexOf("REG_SZ");
                    String name = line.substring(i + 6).trim();
                    if (!name.isEmpty()) return name;
                }
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

'@
$text = $text.Substring(0, $si) + $original + $text.Substring($ei)
[System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "REVERTED detectGpu() to the original class-key implementation"

# Compile the reverted tree + the CI FML stub
$prod = Get-ChildItem "$tmp\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem "$d\src\test\stubs\ci" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
& $javac -encoding UTF-8 -proc:none -cp $cp -d "$tmp\out" @prod @stubs 2>&1 | Select-Object -First 6 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'REVERT_COMPILE_FAILED'; exit 1 }

& $javac -encoding UTF-8 -proc:none -cp "$tmp\out;$cp" -d "$tmp\out" "$d\src\test\java\GpuDetectProbe.java" 2>&1 | Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host 'PROBE_COMPILE_FAILED'; exit 1 }

# Run the probe against the reverted code - it MUST fail
$proc = Start-Process -FilePath $java -ArgumentList @('-cp', "$tmp\out;$cp", 'GpuDetectProbe') `
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
