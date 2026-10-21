$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$utf8bom = New-Object System.Text.UTF8Encoding($true)

# Simulate the GitHub Actions runner end-to-end:
#   checkout -> setup JDK -> cache restore -> fetch (skipped if cached) ->
#   the single simulation step.
#
# The point: the workflow cannot be pushed with the current token, so this is
# the only way to check that the steps actually work together. A workflow
# that has never been executed is a guess, not evidence.

$tmp = Join-Path $env:TEMP 'ci-runner-sim'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Write-Host "=== step 0: checkout (git clone) ==="
# git writes "Cloning into ..." to stderr. Under $ErrorActionPreference='Stop'
# a native command's stderr becomes a terminating error even with 2>&1, so
# the clone runs through Start-Process with real file redirection.
$co = Join-Path $tmp 'clone.out'
$ce = Join-Path $tmp 'clone.err'
$cp = Start-Process -FilePath 'git' -ArgumentList @('clone','--depth','1',"file:///$($d -replace '\\','/')","$tmp\repo") `
    -NoNewWindow -Wait -PassThru -RedirectStandardOutput $co -RedirectStandardError $ce
if ($cp.ExitCode -ne 0) {
    Get-Content $ce -EA SilentlyContinue | Select-Object -Last 3 | ForEach-Object { "  ! $_" }
    exit 1
}
Write-Host "  clone 完成"
$repo = "$tmp\repo"
Set-Location $repo
Write-Host ("  跟踪文件数 = " + (git ls-files).Count)

Write-Host "=== step 1: setup JDK 21 (actions/setup-java -> JAVA_HOME) ==="
# The runner gets a COMPLETE JDK in JAVA_HOME. The project toolchain
# (.tools/jdk21) is git-ignored, so a clone has none - the scripts fall back
# to JAVA_HOME.
$env:JAVA_HOME = "$d\.tools\jdk21"
Write-Host ("  JAVA_HOME = " + $env:JAVA_HOME)

Write-Host "=== step 2: cache restore (actions/cache -> out/ci-libs) ==="
New-Item -ItemType Directory -Force -Path "$repo\out\ci-libs" | Out-Null
# simulate a cache hit: the jars are already there
Copy-Item "$d\out\ci-libs\slf4j-api-2.0.7.jar" "$repo\out\ci-libs\" -Force
Copy-Item "$d\out\ci-libs\mixin-0.8.5.jar"      "$repo\out\ci-libs\" -Force
Write-Host "  out/ci-libs 已就绪（模拟缓存命中）"

Write-Host "=== step 3: fetch dependency jars (should skip - already cached) ==="
$deps = @(
    @{ url = 'https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.7/slf4j-api-2.0.7.jar'; f = 'slf4j-api-2.0.7.jar' },
    @{ url = 'https://repo.spongepowered.org/repository/maven-public/org/spongepowered/mixin/0.8.5/mixin-0.8.5.jar'; f = 'mixin-0.8.5.jar' }
)
$fetched = 0
foreach ($dep in $deps) {
    $t = Join-Path "$repo\out\ci-libs" $dep.f
    if (-not (Test-Path $t)) {
        Write-Host "  (would download $($dep.f))"
        $fetched++
    } else {
        Write-Host "  命中缓存: $($dep.f)"
    }
}
Write-Host "  实际下载数 = $fetched （期望 0）"

Write-Host "=== step 4: the single simulation step ==="
New-Item -ItemType Directory -Force -Path "$repo\build\fabric\libs" | Out-Null
Copy-Item "$repo\out\ci-libs/slf4j-api-2.0.7.jar" "$repo\build\fabric/libs/slf4j-api-2.0.7.jar"
Copy-Item "$repo\out/ci-libs/mixin-0.8.5.jar"        "$repo\build/fabric/libs/mixin-0.8.5.jar"
# Use `powershell` (Windows PowerShell 5.1), not `pwsh`: the GitHub runner
# has pwsh, but a developer machine may not, and the script has to run in
# both places. 5.1 is also the stricter interpreter, so passing there is a
# stronger check than passing under pwsh 7.
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\src\test\ci-faithful.ps1" 2>&1 | ForEach-Object { $_.ToString() }
$code = $LASTEXITCODE
$out | Select-String -Pattern 'offline|TRACKED_FILES|REGRESSION_EXIT|PROBES_FAILED|NEGATIVE_TESTS_FAILED|ALL_GREEN|::error' |
    Select-Object -Last 10 | ForEach-Object { "  $($_.ToString().Trim())" }
Write-Host ("  仿真 EXIT=" + $code)

# A clone has no .tools/jdk21, so the simulation must have used JAVA_HOME -
# but on the runner JAVA_HOME points at the runner JDK, and the workflow
# copies it into .tools/jdk21 anyway. Either path must work.
Write-Host ""
Write-Host "=== 清理 ==="
Set-Location $d
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($code -eq 0 -and $fetched -eq 0) { Write-Host "RUNNER_SIM=ALL_GREEN" } else { Write-Host "RUNNER_SIM=HAS_FAILURES" }
