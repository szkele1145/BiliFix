$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Faithful CI simulation.
#
# WHY THIS IS IN THE REPOSITORY
# It used to live in out/, which is git-ignored - the same mistake the
# negative tests made before they were moved into src/test/negative/. The
# evidence that "the CI is green" existed on one machine only; a clone
# could not reproduce it.
#
# Lesson from an earlier round: copying files by hand produced three
# different test counts (110 / 113 / 131) because the copy was not
# identical to what actions/checkout produces. This uses `git ls-files` to
# copy exactly the tracked set, so the simulation matches a real checkout.
#
# The repository root is derived from THIS script's own location, not from
# a hard-coded absolute path: a literal like "C:\Users\<non-ascii>\..." is
# read as ANSI by Windows PowerShell 5.1 when the .ps1 has no BOM, and the
# path silently turns into mojibake.
#
# WHY THE GITHUB WORKFLOW IS NOT TRACKED (yet)
# .github/workflows/ci.yml is excluded via .git/info/exclude: GitHub refuses
# workflow files pushed with a PAT that lacks the "workflow" scope
# ("refusing to allow a Personal Access Token to create or update workflow
# .github/workflows/ci.yml without workflow scope"). The workflow file
# itself lives in the working tree and is updated by hand.
# Until it can be pushed, THIS script is the reproducible CI behaviour: it
# runs the same probe list and the same negative tests, against a copy of
# exactly the tracked files.

$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
Set-Location $root

$tmp = Join-Path $env:TEMP 'ci-faithful'
# JDK resolution: the project's own toolchain first, then JAVA_HOME.
# The GitHub runner has no .tools/jdk21 (it is git-ignored), so a script that
# only knew about the project JDK could never run there - which is exactly
# why the workflow used to carry its own COPY of this script.
$jdkHome = Join-Path $root '.tools\jdk21'
if (-not (Test-Path (Join-Path $jdkHome 'bin\javac.exe'))) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
        $jdkHome = $env:JAVA_HOME
    } else {
        Write-Host '::error::no JDK found (looked for .tools/jdk21 and JAVA_HOME)'
        exit 1
    }
}
$javac = Join-Path $jdkHome 'bin\javac.exe'
$java  = Join-Path $jdkHome 'bin\java.exe'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Copy exactly the tracked files (git ls-files -> relative paths)
# `git ls-files` is what makes this faithful: a hand-written copy list
# silently drifted three times (110 / 113 / 131 assertions) because it did
# not match what actions/checkout produces.
$tracked = git ls-files
if (-not $tracked -or $tracked.Count -eq 0) {
    Write-Host '::error::git ls-files returned nothing - the simulation would run against an EMPTY tree, which looks exactly like a green run'
    exit 1
}
foreach ($rel in $tracked) {
    $src = Join-Path $root $rel
    $dst = Join-Path $tmp $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item $src $dst -Force
}
Write-Host ("TRACKED_FILES_COPIED=" + $tracked.Count)
# --- step: fetch deps ---
New-Item -ItemType Directory -Force -Path "$tmp\out\ci-libs" | Out-Null
$deps = @(
    @{ url = 'https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.7/slf4j-api-2.0.7.jar'; f = 'slf4j-api-2.0.7.jar' },
    @{ url = 'https://repo.spongepowered.org/repository/maven-public/org/spongepowered/mixin/0.8.5/mixin-0.8.5.jar'; f = 'mixin-0.8.5.jar' }
)
foreach ($dep in $deps) {
    $t = Join-Path "$tmp\out\ci-libs" $dep.f
    if (Test-Path $t) { continue }
    # Where a copy of this jar might already be on this machine, in the order
    # that makes the GitHub Actions cache useful:
    #   1. <repo>/out/ci-libs  - where the workflow's "Cache dependency jars"
    #      step downloads them, and what actions/cache restores. Without this
    #      entry the simulation would download its own copy into the temp
    #      tree and the cache would never be hit.
    #   2. <repo>/build/fabric/libs - what the project build already fetched.
    #      Without this fallback a network hiccup kills the whole simulation
    #      and the test suite silently stops running - the worst possible
    #      outcome for a "the CI is green" signal.
    $candidates = @(
        (Join-Path $root "out\ci-libs\$($dep.f)"),
        (Join-Path $root "build\fabric\libs\$($dep.f)")
    )
    $local = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($local) {
        Copy-Item $local $t -Force
        Write-Host "  (offline: reused $local)"
        continue
    }
    Invoke-WebRequest -Uri $dep.url -OutFile $t -UseBasicParsing
}
$cp = (Get-ChildItem "$tmp\out\ci-libs\*.jar" | ForEach-Object { $_.FullName }) -join ';'

Set-Location $tmp

# --- javac with a retry ---
# A single "Access is denied" on javac.exe (process-creation throttling by the
# host's endpoint protection) used to abort the whole CI simulation, because
# the script invokes javac about twenty times in a row. A flaky host must not
# look like a broken codebase, so every javac call goes through here.
function Invoke-Javac {
    param([string[]]$JavacArgs)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & $javac @JavacArgs 2>&1 | Select-Object -First 5 | ForEach-Object { "  $_" }
        if ($LASTEXITCODE -eq 0) { return 0 }
        if ($attempt -lt 3) {
            Write-Host "  (javac failed on attempt $attempt, retrying...)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    return 1
}

# --- step: regression ---
New-Item -ItemType Directory -Force -Path 'out/ci-test' | Out-Null
$rc = Invoke-Javac @('-encoding','UTF-8','-d','out/ci-test','src/test/java/Regression.java')
if ($rc -ne 0) { Write-Host 'REGRESSION_COMPILE_FAILED'; exit 1 }
$regOut = & $java -cp out/ci-test Regression 2>&1
$regExit = $LASTEXITCODE
$regOut | Select-String -Pattern '\d+' | Select-Object -Last 3 | ForEach-Object { "  REGRESSION: $($_.ToString().Trim())" }
Write-Host ("  REGRESSION_EXIT=" + $regExit)
$skip = $regOut | Select-String -Pattern '跳过 (\d+)' | Select-Object -Last 1
if ($skip) { Write-Host ("  NOTICE: 跳过 " + $skip.Matches[0].Groups[1].Value + " 条断言（预期）") }

# --- step: compile production ---
New-Item -ItemType Directory -Force -Path 'out/ci-prod' | Out-Null
$prod = Get-ChildItem 'src/main/java' -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem 'src/test/stubs/ci' -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$rc = Invoke-Javac (@('-encoding','UTF-8','-proc:none','-cp',$cp,'-d','out/ci-prod') + $prod + $stubs)
$prodExit = $rc
Write-Host ("  PROD_COMPILE_EXIT=" + $prodExit)
if ($prodExit -ne 0) { exit 1 }

# --- javac with a retry ---
# A single "Access is denied" on javac.exe (process-creation throttling by the
# host's endpoint protection) used to abort the whole CI simulation, because
# the script invokes javac about twenty times in a row. A flaky host must not
# look like a broken codebase, so every javac call goes through here.
function Invoke-Javac {
    param([string[]]$JavacArgs)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & $javac @JavacArgs 2>&1 | Select-Object -First 5 | ForEach-Object { "  $_" }
        if ($LASTEXITCODE -eq 0) { return 0 }
        if ($attempt -lt 3) {
            Write-Host "  (javac failed on attempt $attempt, retrying...)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    return 1
}

# --- step: behaviour probes ---
# FmlBridgeProbe runs WITHOUT a ModList stub on the classpath - that absence is
# exactly the environment its "ModList absent" degradation assertion needs.
# FmlModVersionProbe needs a ModList stub (it covers the SUCCESS path) and
# therefore gets its own, separate stub set and classpath.
$fmlStubs = Get-ChildItem 'src/test/stubs/neoforged','src/test/stubs/forge' -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$modListStubs = Get-ChildItem 'src/test/stubs-fmlmodlist' -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$probes = @(
    @{ name = 'ConcurrentRecordProbe'; stubs = $false },
    @{ name = 'FmlBridgeProbe';        stubs = $true  },
    @{ name = 'FmlModVersionProbe';    stubs = 'fmlmodlist' },
    @{ name = 'ReadmeLogSampleProbe';  stubs = $false },
    @{ name = 'GpuDetectProbe';         stubs = $false },
    @{ name = 'ArgumentRewriteProbe';   stubs = $false },
    @{ name = 'ForensicsSuppressionProbe'; stubs = $false },
    @{ name = 'ConfigParseProbe';      stubs = $false },
    @{ name = 'MixinTargetGuardProbe'; stubs = $false },
    @{ name = 'StartupLogTruthProbe';  stubs = $false },
    @{ name = 'ForensicsVoutProbe';    stubs = $false },
    @{ name = 'UnknownConfigKeyProbe'; stubs = $false; slf4jProvider = $true },
    @{ name = 'NullElementProbe';      stubs = $false },
    @{ name = 'ConfigDefaultProbe';    stubs = $false },
    @{ name = 'MirrorParityProbe';     stubs = $false },
    @{ name = 'FabricInitProbe';      stubs = $false },
    @{ name = 'NormalizedWarningProbe'; stubs = $false },
    @{ name = 'RealArgumentsProbe';     stubs = $false },
    @{ name = 'DocStructureProbe';      stubs = $false },
    @{ name = 'JarMetadataProbe';       stubs = $false }
)
$failed = 0
foreach ($p in $probes) {
    $dir = "out/ci-probe-$($p.name)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $extra = @()
    if ($p.stubs -eq $true) { $extra = $fmlStubs }
    elseif ($p.stubs -eq 'fmlmodlist') { $extra = $modListStubs }
    if ($p.slf4jProvider) {
        # slf4j-api without a provider degrades to a NOP logger -> the warning
        # this probe asserts on could not be observed at all. Install a capturing
        # provider and register it through the SPI service file.
        # NOTE: the SPI path must be ABSOLUTE - [System.IO.File]::WriteAllText
        # resolves a relative path against the PROCESS current directory
        # (C:\Users), not against PowerShell's Set-Location target, so a
        # relative path silently writes the file into the wrong directory.
        $dirAbs = Join-Path (Get-Location) $dir
        $rc = Invoke-Javac @('-encoding','UTF-8','-proc:none','-cp',"out/ci-prod;$cp",'-d',$dirAbs,'src/test/stubs/slf4j/test/slf4j/CapturingServiceProvider.java')
        if ($rc -ne 0) { Write-Host "  ::error::$($p.name) slf4j provider compile failed"; $failed++; continue }
        New-Item -ItemType Directory -Force -Path (Join-Path $dirAbs 'META-INF\services') | Out-Null
        # NOTE: no BOM - Set-Content -Encoding UTF8 in Windows PowerShell 5.1 writes
        # a BOM, and ServiceLoader does not strip it -> the provider never loads
        # and the probe would silently see no logs at all.
        [System.IO.File]::WriteAllText((Join-Path $dirAbs 'META-INF\services\org.slf4j.spi.SLF4JServiceProvider'),
            "test.slf4j.CapturingServiceProvider`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($p.name -eq 'MirrorParityProbe') {
        # The probe loads the mirror implementation by reflection, so the
        # Regression class has to be compiled next to it.
        $rc = Invoke-Javac @('-encoding','UTF-8','-proc:none','-cp',"$dir;out/ci-prod;$cp",'-d',"$dir",'src/test/java/Regression.java')
        if ($rc -ne 0) { Write-Host "  ::error::$($p.name) Regression compile failed"; $failed++; continue }
    }
    $rc = Invoke-Javac (@('-encoding','UTF-8','-proc:none','-cp',"$dir;out/ci-prod;$cp",'-d',$dir,"src/test/java/$($p.name).java") + $extra)
    if ($rc -ne 0) { Write-Host "  ::error::$($p.name) compile failed"; $failed++; continue }
    $probeArgs = @()
    if ($p.name -eq 'NullElementProbe') {
        # The source-level assertions read the file given as args[0]; passing it
        # explicitly keeps the probe honest even if the working directory moves.
        $probeArgs = @('src/main/java/dev/polaris_fix/bilifix/mixin/JarToolMixin.java')
    }
    if ($p.name -eq 'ConfigDefaultProbe') {
        # Same reason: the source-level assertion must look at THIS checkout's
        # BiliFixConfig, not at whatever file the probe happens to find.
        $probeArgs = @('src/main/java/dev/polaris_fix/bilifix/config/BiliFixConfig.java')
    }
    if ($p.name -eq 'MirrorParityProbe') {
        $probeArgs = @('src/test/java/Regression.java')
    }
    if ($p.name -eq 'NormalizedWarningProbe') {
        $probeArgs = @('src/main/java/dev/polaris_fix/bilifix/BiliFixMod.java')
    }
    if ($p.name -eq 'RealArgumentsProbe') {
        $probeArgs = @()
    }
    if ($p.name -eq 'DocStructureProbe') {
        $probeArgs = @('CHANGELOG.md')
    }
    $proc = Start-Process -FilePath $java -ArgumentList (@('-cp', "$dir;out/ci-prod;$cp", $p.name) + $probeArgs) `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $PWD `
            -RedirectStandardOutput "$dir/stdout.txt" -RedirectStandardError "$dir/stderr.txt"
    Get-Content "$dir/stdout.txt" | Select-String -Pattern '通过 \d+ / 失败 \d+|RESULT' | ForEach-Object { "  $($p.name): $($_.ToString().Trim())" }
    if ($proc.ExitCode -ne 0) { Write-Host "  ::error::$($p.name) FAILED exit=$($proc.ExitCode)"; $failed++ }
}
Write-Host ("  PROBES_FAILED=" + $failed)
Write-Host ("FAITHFUL_CI_SIM=" + $(if ($regExit -eq 0 -and $prodExit -eq 0 -and $failed -eq 0) { 'ALL_GREEN' } else { 'HAS_FAILURES' }))

# --- step: negative tests ---
# A probe that cannot fail is not evidence. Each negative test breaks the
# production code on purpose and asserts the matching probe FAILS.
# These scripts live in src/test/negative/ (version controlled) so the evidence
# that the probes can actually fail is in the repository, not on one machine.
#
# NOTE: they run against the REAL repository, not the temporary copy: they need
# .tools/jdk21 and the cached libs under build/fabric/libs, and both are
# git-ignored (so they are absent from the copy) while the copy itself is the
# point of the simulation. The production code they break is read from the real
# working tree - which is exactly what CI checks out anyway.
Write-Host "  --- negative tests ---"
$negFailed = 0
Push-Location $root
& powershell -NoProfile -ExecutionPolicy Bypass -File 'src/test/negative/run-all-negative-tests.ps1' 2>&1 |
    Select-String -Pattern '^\[neg-all\]|NEGATIVE_TESTS_' | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { $negFailed++ }
Pop-Location
Write-Host ("  NEGATIVE_TESTS_FAILED=" + $negFailed)

# --- step: encoding hygiene ---
# Every .ps1 in this repository that contains non-ASCII text must carry a
# UTF-8 BOM.
#
# Why: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI (the machine's
# code page), so Chinese text - and any non-ASCII path derived from the
# script's own location - turns into mojibake. That does not always fail
# loudly: a mojibake quote character inside a string is a PARSE error, so
# the script dies with a confusing "Array index expression is missing or
# not valid" instead of saying "your file lost its BOM". It has happened
# three times in this project, always after a tool rewrote a file.
#
# So the rule is checked here, in CI, rather than remembered.
$encFailed = 0
$encScanned = 0
$encScripts = Get-ChildItem $root -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notmatch '\\(\.git|build|out|\.tools|node_modules)\\' }
foreach ($f in $encScripts) {
    $encScanned++
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    $nonAscii = @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -gt 0
    if ($nonAscii -and -not $hasBom) {
        $encFailed++
        Write-Host ("  [ENC] 缺少 UTF-8 BOM（Windows PowerShell 5.1 会按 ANSI 读，中文会乱码）: " + $f.FullName.Replace("$root\", ''))
    }
    # and it must parse
    $parseErr = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErr) | Out-Null
    if ($parseErr.Count -gt 0) {
        $encFailed++
        Write-Host ("  [ENC] 语法错误 行 " + $parseErr[0].Extent.StartLineNumber + ": " + $parseErr[0].Message + "  -> " + $f.FullName.Replace("$root\", ''))
    }
}
Write-Host ("  ENCODING_SCRIPTS_SCANNED=" + $encScanned)
Write-Host ("  ENCODING_FAILURES=" + $encFailed)

if ($negFailed -eq 0 -and $failed -eq 0 -and $regExit -eq 0 -and $prodExit -eq 0 -and $encFailed -eq 0) {
    Write-Host "FAITHFUL_CI_SIM_WITH_NEG=ALL_GREEN"
} else {
    Write-Host "FAITHFUL_CI_SIM_WITH_NEG=HAS_FAILURES"
}

Set-Location $root
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($regExit -ne 0 -or $prodExit -ne 0 -or $failed -gt 0 -or $negFailed -gt 0 -or $encFailed -gt 0) { exit 1 }