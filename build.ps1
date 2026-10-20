# Build script (PowerShell, Windows)
# Requires: local Minecraft runtime JDK (javac/jar), NeoForge 21.1 libs, mixin 0.8.5, watermedia jar
# Usage: ./build.ps1 [-WatermediaJar <path>] [-OutDir <dir>]
#
# Test coverage note: the regression tests cover ARG REPLACEMENT + CONFIG PARSING logic only.
# They do NOT cover jar packaging or mods.toml structure - the two areas that caused the
# v1.3.2 incidents. Those are guarded by the post-build jar integrity check and the
# FML structure precheck list (docs/postmortem-1.3.2.md). Keep all three layers green.

param(
    [string]$WatermediaJar = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
# Locate script dir ($PSScriptRoot can be empty in some invocation styles)
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'build' }

# ---- Locate a JDK 21 (javac/jar/java): env override > PATH > common Minecraft runtime locations ----
$javac = $null
if ($env:BILIFIX_JAVAC) {
    $javac = $env:BILIFIX_JAVAC
} else {
    $fromPath = Get-Command javac -ErrorAction SilentlyContinue
    if ($fromPath) { $javac = $fromPath.Source }
}
if (-not $javac) {
    # Probe order: project toolchain JDK > MC runtime (may be a trimmed JRE) > user JDKs
    $home2 = $env:USERPROFILE
    $candidates = @(
        "$root\.tools\jdk21\bin\javac.exe",                                  # project toolchain (full JDK 21)
        "$env:APPDATA\.minecraft\runtime\java-runtime-delta\bin\javac.exe",  # MC runtime (trimmed to JRE by PCL updates)
        "C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\javac.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $javac = $c; break } }
}
if (-not $javac) { throw "javac not found. Set BILIFIX_JAVAC=<path to javac.exe>, place a JDK 21 in .tools\jdk21, or add one to PATH" }
$jdkBin = Split-Path -Parent $javac
$jar = Join-Path $jdkBin 'jar.exe'
$javaExe = Join-Path $jdkBin 'java.exe'

# ---- Locate game libraries dir: env override > PCL default > vanilla default ----
$lib = $env:BILIFIX_LIBS
if (-not $lib) { $lib = 'D:\PCL2\.minecraft\libraries' }
if (-not (Test-Path $lib)) { $lib = "$env:APPDATA\.minecraft\libraries" }
if (-not (Test-Path $lib)) { throw "game libraries dir not found. Set BILIFIX_LIBS=<path to .minecraft\libraries>" }
$mcDir = Split-Path -Parent $lib

if (-not (Test-Path $javac)) { throw "javac not found: $javac (Minecraft runtime JDK required)" }
# Locate watermedia jar for the @Mixin target: param > mods folder of the game dir
if (-not $WatermediaJar) {
    $probe = Get-ChildItem "$mcDir\versions\*\mods\watermedia-*.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($probe) { $WatermediaJar = $probe.FullName }
}
if (-not (Test-Path $WatermediaJar)) { Write-Warning "watermedia jar not found - compile continues (@Pseudo target missing is only a warning)" }

# Version (read from mods.toml - FML structure: version = "x" inside [[mods]])
$toml = Get-Content "$root\src\main\resources\META-INF\neoforge.mods.toml" -Raw -Encoding UTF8
if ($toml -match '(?s)\[\[mods\]\].*?version\s*=\s*"([^"]+)"') { $version = $Matches[1] } else { throw "cannot read version from mods.toml" }
Write-Host "Building BiliFix v$version"

# Classpath
$cp = @(
    "$lib\org\spongepowered\mixin\0.8.5\mixin-0.8.5.jar",
    "$lib\net\neoforged\fancymodloader\loader\4.0.45\loader-4.0.45.jar",
    "$lib\net\neoforged\mergetool\2.0.0\mergetool-2.0.0-api.jar",
    "$lib\net\neoforged\neoforge\21.1.248\neoforge-21.1.248-universal.jar",
    "$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar",
    $WatermediaJar
) -join ';'

# Clean + compile
Remove-Item "$OutDir\classes","$OutDir\jar" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$OutDir\classes","$OutDir\jar\META-INF" | Out-Null
$srcs = Get-ChildItem "$root\src\main\java" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$jargs = @("--release","21","-encoding","UTF-8","-proc:none","-cp",$cp,"-d","$OutDir\classes") + $srcs
$p = Start-Process -FilePath $javac -ArgumentList $jargs -NoNewWindow -Wait -PassThru -RedirectStandardError "$OutDir\javac-stderr.txt" -RedirectStandardOutput "$OutDir\javac-stdout.txt"
if ($p.ExitCode -ne 0) { Get-Content "$OutDir\javac-stderr.txt" -ErrorAction SilentlyContinue; throw "compile failed" }
Write-Host "Compile OK" -ForegroundColor Green

# Regression tests
if (Test-Path "$root\src\test\java\Regression.java") {
    New-Item -ItemType Directory -Force -Path "$OutDir\test" | Out-Null
    & $javac -encoding UTF-8 -d "$OutDir\test" "$root\src\test\java\Regression.java"
    & $javaExe -cp "$OutDir\test" Regression
    if ($LASTEXITCODE -ne 0) { throw "regression tests failed" }
    Write-Host "Regression tests OK" -ForegroundColor Green
}

# Behaviour-level concurrency probe (v1.4.8).
# Regression is an independent mirror (it does not link the production classes),
# so it cannot call the production CrashSentinel.record() directly. Its §14
# assertion only checks that the `synchronized` keyword is present - that is
# "checking the prescription", not the effect. This probe links the production
# classes and hammers the real method: 32 threads x 500 records must leave the
# event list at exactly MAX_EVENTS.
if (Test-Path "$root\src\test\java\ConcurrentRecordProbe.java") {
    $probeOut = "$OutDir\concurrency-probe"
    New-Item -ItemType Directory -Force -Path $probeOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes" -d $probeOut "$root\src\test\java\ConcurrentRecordProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "concurrency probe compile failed" }
    & $javaExe -cp "$probeOut;$OutDir\classes" ConcurrentRecordProbe
    if ($LASTEXITCODE -ne 0) { throw "concurrency probe FAILED (event cap not held under load)" }
    Write-Host "Concurrency probe OK" -ForegroundColor Green
}

# FmlBridge probe (v1.4.8): FmlBridge is the only production class with no
# coverage, and it sits on the critical path - CrashSentinel.gameDirectory()
# uses it to find the game directory, so a silent null means the forensic files
# cannot be written, exactly when a crash makes them matter.
# The probe uses stub FML classes placed under the REAL package name, so the
# production Class.forName -> enum constant -> get() -> Path chain runs end to
# end instead of being mirrored in the test.
if (Test-Path "$root\src\test\java\FmlBridgeProbe.java") {
    $fmlOut = "$OutDir\fmlbridge-probe"
    New-Item -ItemType Directory -Force -Path $fmlOut | Out-Null
    $stubSrcs = Get-ChildItem "$root\src\test\stubs" -Recurse -Filter '*.java' |
        Where-Object { $_.FullName -notlike '*\stubs\slf4j\*' } | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes" -d $fmlOut @stubSrcs "$root\src\test\java\FmlBridgeProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "FmlBridge probe compile failed" }
    & $javaExe -cp "$fmlOut;$OutDir\classes" FmlBridgeProbe
    if ($LASTEXITCODE -ne 0) { throw "FmlBridge probe FAILED (fmlDir chain or the no-throw contract broke)" }
    Write-Host "FmlBridge probe OK" -ForegroundColor Green
}

# FmlModVersion probe: FmlBridge.modVersion's SUCCESS path. It was untested -
# FmlBridgeProbe only covered the "ModList absent" degradation. Real FML
# (javap, 2026-10-21) has getModFileById on the concrete class returning the
# IModFileInfo INTERFACE with a package-private implementation. If that path
# breaks, EnvironmentDiagnostics reports an installed watermedia as missing.
# Its stubs live in a separate directory so the classpath of FmlBridgeProbe
# above still has no ModList (that environment is what its probe needs).
if (Test-Path "$root\src\test\java\FmlModVersionProbe.java") {
    $fmvOut = "$OutDir\fmlmodver-probe"
    New-Item -ItemType Directory -Force -Path $fmvOut | Out-Null
    $mvStubs = Get-ChildItem "$root\src\test\stubs-fmlmodlist" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes" -d $fmvOut @mvStubs "$root\src\test\java\FmlModVersionProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "FmlModVersion probe compile failed" }
    $fmvP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fmvOut;$OutDir\classes", 'FmlModVersionProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fmvOut\stdout.txt" -RedirectStandardError "$fmvOut\stderr.txt"
    Get-Content "$fmvOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fmvP.ExitCode -ne 0) { throw "FmlModVersion probe FAILED (modVersion success path or the no-throw contract broke)" }
    Write-Host "FmlModVersion probe OK" -ForegroundColor Green
}

# README drift probe (v1.4.8): the READMEs quote the exact log lines a user
# should look for. If the production format string changes and the READMEs are
# not updated, the user sees a log that does not match the documentation and
# wrongly concludes the fix did not apply. This probe compares the README
# files against the real production literals.
if (Test-Path "$root\src\test\java\ReadmeLogSampleProbe.java") {
    $rmOut = "$OutDir\readme-probe"
    New-Item -ItemType Directory -Force -Path $rmOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar" -d $rmOut "$root\src\test\java\ReadmeLogSampleProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "README probe compile failed" }
    Push-Location $root
    # SLF4J prints "No SLF4J providers were found." to stderr when only the API
    # jar is on the classpath. That is a harmless notice, but PowerShell turns
    # native stderr into an error record that aborts the build even though the
    # probe passed. Start-Process with redirected streams keeps them apart;
    # the exit code is the verdict.
    $rmCp = "$rmOut;$OutDir\classes;$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar"
    $rmP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', $rmCp, 'ReadmeLogSampleProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$rmOut\stdout.txt" -RedirectStandardError "$rmOut\stderr.txt"
    Pop-Location
    Get-Content "$rmOut\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    # Start-Process does not update $LASTEXITCODE - use the process exit code.
    if ($rmP.ExitCode -ne 0) { throw "README probe FAILED (README log samples drifted from the production output)" }
    Write-Host "README probe OK" -ForegroundColor Green
}

# GPU detection probe (v1.4.8). The old implementation queried the display
# adapter CLASS key for DriverDesc, but that value lives in the per-adapter
# subkeys (0000, 0001, ...) - the class key query fails with
#   ERROR: The system was unable to find the specified registry key or value.
# so the GPU line never reached the report. This probe calls the real
# detectGpu() and requires a non-blank GPU name on Windows.
if (Test-Path "$root\src\test\java\GpuDetectProbe.java") {
    $gpuOut = "$OutDir\gpu-probe"
    New-Item -ItemType Directory -Force -Path $gpuOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar" -d $gpuOut "$root\src\test\java\GpuDetectProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "GPU probe compile failed" }
    $gpuP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$gpuOut;$OutDir\classes;$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar", 'GpuDetectProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$gpuOut\stdout.txt" -RedirectStandardError "$gpuOut\stderr.txt"
    Get-Content "$gpuOut\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    if ($gpuP.ExitCode -ne 0) { throw "GPU probe FAILED (detectGpu returned nothing - the GPU line never reaches the report)" }
    Write-Host "GPU probe OK" -ForegroundColor Green
}

# Argument rewrite probe (v1.4.8). The core of the fix is the argument
# rewriting in JarToolMixin. Until now nothing actually EXECUTED it:
# Regression is an independent mirror and the README probe only compares
# log strings. This probe calls the production method with a real
# CallbackInfoReturnable and checks the dangerous parameters are gone.
$mixinJar = "$lib\org\spongepowered\mixin\0.8.5\mixin-0.8.5.jar"
$slf4jJar = "$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar"
if ((Test-Path "$root\src\test\java\ArgumentRewriteProbe.java") -and (Test-Path $mixinJar)) {
    $arOut = "$OutDir\arg-probe"
    New-Item -ItemType Directory -Force -Path $arOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$mixinJar;$slf4jJar" -d $arOut "$root\src\test\java\ArgumentRewriteProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Argument rewrite probe compile failed" }
    $arP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$arOut;$OutDir\classes;$mixinJar;$slf4jJar", 'ArgumentRewriteProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$arOut\stdout.txt" -RedirectStandardError "$arOut\stderr.txt"
    Get-Content "$arOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($arP.ExitCode -ne 0) { throw "Argument rewrite probe FAILED (the hardening logic did not behave as required)" }
    Write-Host "Argument rewrite probe OK" -ForegroundColor Green
}

# Forensics suppression probe (v1.4.8). The startup self-check suppresses the
# forensic counters so it does not fake a "media touched" signal. That
# suppression must be THREAD-LOCAL: a global flag would also swallow a real
# media playback happening on the media thread at the same time, losing the
# very evidence the diagnostic file exists to provide.
if (Test-Path "$root\src\test\java\ForensicsSuppressionProbe.java") {
    $fsOut = "$OutDir\forensics-probe"
    New-Item -ItemType Directory -Force -Path $fsOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $fsOut "$root\src\test\java\ForensicsSuppressionProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Forensics suppression probe compile failed" }
    $fsP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fsOut;$OutDir\classes;$slf4jJar", 'ForensicsSuppressionProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fsOut\stdout.txt" -RedirectStandardError "$fsOut\stderr.txt"
    Get-Content "$fsOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fsP.ExitCode -ne 0) { throw "Forensics suppression probe FAILED (the suppression leaks across threads)" }
    Write-Host "Forensics suppression probe OK" -ForegroundColor Green
}

# Config parse probe (v1.4.8). A UTF-8 BOM in the config file must not make
# the parser drop the first key - Windows editors save with a BOM by default,
# which would silently ignore the user's hwDecoder setting.
if (Test-Path "$root\src\test\java\ConfigParseProbe.java") {
    $cpOut = "$OutDir\cfgparse-probe"
    New-Item -ItemType Directory -Force -Path $cpOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $cpOut "$root\src\test\java\ConfigParseProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Config parse probe compile failed" }
    $cpP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$cpOut;$OutDir\classes;$slf4jJar", 'ConfigParseProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$cpOut\stdout.txt" -RedirectStandardError "$cpOut\stderr.txt"
    Get-Content "$cpOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($cpP.ExitCode -ne 0) { throw "Config parse probe FAILED (the parser does not handle a UTF-8 BOM)" }
    Write-Host "Config parse probe OK" -ForegroundColor Green
}

# Mixin target guard probe (v1.4.8). The whole fix rides on one optional
# mixin injection (defaultRequire: 0), so the guard that turns a silent
# skip into a visible warning must be verified against real stub classes,
# not just mirrored.
if (Test-Path "$root\src\test\java\MixinTargetGuardProbe.java") {
    $gdOut = "$OutDir\guard-probe"
    New-Item -ItemType Directory -Force -Path $gdOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $gdOut "$root\src\test\java\MixinTargetGuardProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Mixin target guard probe compile failed" }
    $gdP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$gdOut;$OutDir\classes;$slf4jJar", 'MixinTargetGuardProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$gdOut\stdout.txt" -RedirectStandardError "$gdOut\stderr.txt"
    Get-Content "$gdOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($gdP.ExitCode -ne 0) { throw "Mixin target guard probe FAILED (the guard does not detect the silent skip)" }
    Write-Host "Mixin target guard probe OK" -ForegroundColor Green
}

# Startup log truth probe (v1.4.8). The startup line is the first thing
# anyone reads when investigating a crash, so it must show the value that
# is actually in effect - not the raw string the user typed.
if (Test-Path "$root\src\test\java\StartupLogTruthProbe.java") {
    $slOut = "$OutDir\startuplog-probe"
    New-Item -ItemType Directory -Force -Path $slOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $slOut "$root\src\test\java\StartupLogTruthProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Startup log truth probe compile failed" }
    $slP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$slOut;$OutDir\classes;$slf4jJar", 'StartupLogTruthProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$slOut\stdout.txt" -RedirectStandardError "$slOut\stderr.txt"
    Get-Content "$slOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($slP.ExitCode -ne 0) { throw "Startup log truth probe FAILED (the startup line does not show the effective value)" }
    Write-Host "Startup log truth probe OK" -ForegroundColor Green

    # Forensics vout probe: the diagnostics file must not say "vout=null"
    # when the user deliberately set vout=original.
    $fvOut = "$OutDir\forensicsvout-probe"
    New-Item -ItemType Directory -Force -Path $fvOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $fvOut "$root\src\test\java\ForensicsVoutProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Forensics vout probe compile failed" }
    $fvP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fvOut;$OutDir\classes;$slf4jJar", 'ForensicsVoutProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fvOut\stdout.txt" -RedirectStandardError "$fvOut\stderr.txt"
    Get-Content "$fvOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fvP.ExitCode -ne 0) { throw "Forensics vout probe FAILED (the diagnostics file misreports the vout strategy)" }
    Write-Host "Forensics vout probe OK" -ForegroundColor Green

    # Unknown config key probe: a mistyped config key must be VISIBLE, not silently dropped.
    # Needs the capturing slf4j provider on the test classpath: slf4j-api without a
    # provider degrades to a NOP logger, so BiliFixMod.LOGGER.warn(...) produces
    # nothing and the probe could not tell "warning not emitted" from "warning not captured".
    $ukOut = "$OutDir\unknownkey-probe"
    New-Item -ItemType Directory -Force -Path $ukOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $ukOut "$root\src\test\stubs\slf4j\test\slf4j\CapturingServiceProvider.java"
    if ($LASTEXITCODE -ne 0) { throw "Unknown key probe: capturing slf4j provider compile failed" }
    New-Item -ItemType Directory -Force -Path "$ukOut\META-INF\services" | Out-Null
    [System.IO.File]::WriteAllText("$ukOut\META-INF\services\org.slf4j.spi.SLF4JServiceProvider", "test.slf4j.CapturingServiceProvider`n", (New-Object System.Text.UTF8Encoding($false)))
    & $javac -encoding UTF-8 -proc:none -cp "$ukOut;$OutDir\classes;$slf4jJar" -d $ukOut "$root\src\test\java\UnknownConfigKeyProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Unknown config key probe compile failed" }
    $ukP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$ukOut;$OutDir\classes;$slf4jJar", 'UnknownConfigKeyProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$ukOut\stdout.txt" -RedirectStandardError "$ukOut\stderr.txt"
    Get-Content "$ukOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($ukP.ExitCode -ne 0) { throw "Unknown config key probe FAILED (a mistyped config key is silently ignored)" }
    Write-Host "Unknown config key probe OK" -ForegroundColor Green

    # Config default probe: the default values (none / gl,any / false) used to be
    # hard-coded in FOUR places - the field initialisers, the load() exception
    # reset, the file written to the user, and the unknown-value fallback. Any one
    # of them drifting means the user's config file says one thing while the
    # effective behaviour is another - and the log says "config loaded", so
    # nothing points at the cause.
    $cdOut = "$OutDir\cfgdefault-probe"
    New-Item -ItemType Directory -Force -Path $cdOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $cdOut "$root\src\test\java\ConfigDefaultProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Config default probe compile failed" }
    $cdP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$cdOut;$OutDir\classes;$slf4jJar", 'ConfigDefaultProbe', 'src/main/java/dev/polaris_fix/bilifix/config/BiliFixConfig.java') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$cdOut\stdout.txt" -RedirectStandardError "$cdOut\stderr.txt"
    Get-Content "$cdOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($cdP.ExitCode -ne 0) { throw "Config default probe FAILED (the default values have more than one source of truth)" }
    Write-Host "Config default probe OK" -ForegroundColor Green
    # Mirror parity probe: the Regression mirror is an INDEPENDENT
    # re-implementation of the production logic, so when production changes
    # on purpose the mirror has to be updated BY HAND. When it is not, the
    # mirror gives the opposite answer from production while every mirror
    # test still passes - the worst possible state for a safety net.
    # Three real divergences were measured this way (v1.4.8).
    $mpOut = "$OutDir\mirrorparity-probe"
    New-Item -ItemType Directory -Force -Path $mpOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $mpOut "$root\src\test\java\Regression.java" "$root\src\test\java\MirrorParityProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Mirror parity probe compile failed" }
    $mpP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$mpOut;$OutDir\classes;$slf4jJar", 'MirrorParityProbe', 'src/test/java/Regression.java') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$mpOut\stdout.txt" -RedirectStandardError "$mpOut\stderr.txt"
    Get-Content "$mpOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($mpP.ExitCode -ne 0) { throw "Mirror parity probe FAILED (the regression mirror disagrees with production)" }
    Write-Host "Mirror parity probe OK" -ForegroundColor Green
    # Fabric init probe: the Fabric loader is the ONLY one with its own
    # entry point (ModInitializer -> explicit directory injection), so the
    # injection order inside BiliFixMod.init() is semantic. Load the config
    # before the dirs are injected and the config file lands somewhere else
    # entirely - silently, with no error.
    $fiOut = "$OutDir\fabricinit-probe"
    New-Item -ItemType Directory -Force -Path $fiOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$slf4jJar" -d $fiOut "$root\src\test\java\FabricInitProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Fabric init probe compile failed" }
    $fiP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fiOut;$OutDir\classes;$slf4jJar", 'FabricInitProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fiOut\stdout.txt" -RedirectStandardError "$fiOut\stderr.txt"
    Get-Content "$fiOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fiP.ExitCode -ne 0) { throw "Fabric init probe FAILED" }
    Write-Host "Fabric init probe OK" -ForegroundColor Green

    # Null element probe: a null entry in the argument array must not make the
    # hardening logic throw. JarTool.readArray is a GENERAL method - watermedia
    # may read other JSON with it, and a null entry would blow up switch (arg).
    $neOut = "$OutDir\nullelem-probe"
    New-Item -ItemType Directory -Force -Path $neOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$OutDir\classes;$mixinJar;$slf4jJar" -d $neOut "$root\src\test\java\NullElementProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Null element probe compile failed" }
    $neP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$neOut;$OutDir\classes;$mixinJar;$slf4jJar", 'NullElementProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$neOut\stdout.txt" -RedirectStandardError "$neOut\stderr.txt"
    Get-Content "$neOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($neP.ExitCode -ne 0) { throw "Null element probe FAILED (a null argument entry crashes the hardening logic)" }
    Write-Host "Null element probe OK" -ForegroundColor Green

    # Negative tests: every probe must be able to FAIL. Each script breaks the
    # production code on purpose and asserts the matching probe fails. A probe
    # that cannot fail is decoration, not evidence.
    # NOTE: these scripts need .tools/jdk21 and the cached libs under
    # build/fabric/libs - both exist by the time this block runs.
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\src\test\negative\run-all-negative-tests.ps1" 2>&1 |
        Select-String -Pattern '^\[neg-all\]|NEGATIVE_TESTS_' | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Negative tests FAILED (a probe cannot detect the regression it claims to cover)" }
    Write-Host "Negative tests OK" -ForegroundColor Green
}

# Package
# NOTE: no timestamp post-processing - patching entry times via ZipArchive Update mode
# corrupted the jar (DOS timestamp epoch boundary at 1980-01-01 produced an invalid
# central directory: "invalid entry size (expected 0 but got 154 bytes)" at game load).
# The jar tool's META-INF timestamps being "now" is harmless; correctness > reproducibility.
$stage = "$OutDir\jar"
Copy-Item "$OutDir\classes\dev" "$stage\dev" -Recurse -Force
Copy-Item "$root\src\main\resources\bilifix.mixins.json" "$stage\" -Force
Copy-Item "$root\src\main\resources\bilifix_logo.png" "$stage\" -Force
Copy-Item "$root\src\main\resources\META-INF\neoforge.mods.toml" "$stage\META-INF\" -Force
Copy-Item "$root\src\main\resources\META-INF\mods.toml" "$stage\META-INF\" -Force
@"
Manifest-Version: 1.0
Implementation-Title: BiliFix
Implementation-Version: $version
"@ | Out-File "$OutDir\MANIFEST.MF" -Encoding ascii
Push-Location $stage
# Naming convention: <mod>-<version>-mc<gameVersion>-<loader>.jar
& $jar cfm "$OutDir\BiliFix-$version-mc1.21.1-neoforge.jar" "$OutDir\MANIFEST.MF" dev bilifix.mixins.json bilifix_logo.png META-INF/neoforge.mods.toml META-INF/mods.toml
Pop-Location
# Post-build jar integrity check: read EVERY entry fully via .NET ZipArchive (strict path,
# matching how FML consumes jars). Catches corrupted central directories at build time
# instead of at game launch (see the 1.3.2 incident: "invalid entry size").
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$jarOut = "$OutDir\BiliFix-$version-mc1.21.1-neoforge.jar"
$zc = [System.IO.Compression.ZipFile]::OpenRead($jarOut)
$failCount = 0
foreach ($e in $zc.Entries) {
    try {
        $ms = New-Object System.IO.MemoryStream
        $e.Open().CopyTo($ms)
        if ($ms.Length -ne $e.Length) { $failCount++; Write-Host "  BAD entry size: $($e.FullName) declared=$($e.Length) actual=$($ms.Length)" -ForegroundColor Red }
    } catch {
        $failCount++
        Write-Host "  UNREADABLE entry: $($e.FullName) - $($_.Exception.Message)" -ForegroundColor Red
    }
}
$total = $zc.Entries.Count
$zc.Dispose()
if ($failCount -gt 0) { throw "jar integrity check FAILED: $failCount of $total entries corrupt" }
Write-Host "Jar integrity: $total/$total entries OK" -ForegroundColor Green
Write-Host "Packaged: $jarOut ($((Get-Item $jarOut).Length) bytes)" -ForegroundColor Green
# Housekeeping: remove older-version jars from build/ (all published versions are recoverable from source)
Get-ChildItem "$OutDir" -Filter 'BiliFix-*-mc*.jar' | Where-Object { $_.Name -ne (Split-Path $jarOut -Leaf) } | Remove-Item -Force -ErrorAction SilentlyContinue
