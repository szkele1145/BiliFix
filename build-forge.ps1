# Forge 1.20.1 variant builder.
# Produces BiliFix-<version>-mc1.20.1-forge.jar from the SAME sources with 3 import
# substitutions (net.neoforged.* -> net.minecraftforge.*) + Forge-flavored mods.toml.
# Layout: src/main/java is shared; this script stages patched copies into build/forge.
#
# Usage: ./build-forge.ps1

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'build\forge'
$javac = $env:BILIFIX_JAVAC
if (-not $javac) { $t = Get-Command javac -ErrorAction SilentlyContinue; if ($t) { $javac = $t.Source } }
if (-not $javac) {
    # MC runtime is a trimmed JRE (no javac) - probe local JDKs instead.
    # NOTE: --release 17 works on any JDK >= 17, so a 21 JDK is fine here too
    # (v1.4.8: .jdks/ is no longer guaranteed to exist; probe every known location).
    foreach ($probe in @(
        "$env:BILIFIX_JAVAC",
        "$root\.tools\jdk21\bin\javac.exe",
        "$env:USERPROFILE\.jdks\ms-17.0.19\bin\javac.exe",
        'C:\jdk17\bin\javac.exe',
        'C:\jdk21\bin\javac.exe',
        "$env:APPDATA\.minecraft\runtime\java-runtime-delta\bin\javac.exe"
    )) {
        if ($probe -and (Test-Path $probe)) { $javac = $probe; break }
    }
}
if (-not $javac) { throw 'no JDK found: set BILIFIX_JAVAC or install one (--release 17 needs JDK >= 17)' }
$jar = $javac -replace 'javac\.exe$', 'jar.exe'

# Forge 1.20.1 deps (downloaded on demand into build\forge\libs)
$libs = Join-Path $OutDir 'libs'
New-Item -ItemType Directory -Force -Path $libs, "$OutDir\classes", "$OutDir\src", "$OutDir\jar\META-INF" | Out-Null
$deps = @(
    @{ u = 'https://repo.spongepowered.org/repository/maven-public/org/spongepowered/mixin/0.8.5/mixin-0.8.5.jar'; f = 'mixin-0.8.5.jar' },
    @{ u = 'https://maven.minecraftforge.net/net/minecraftforge/fmlcore/1.20.1-47.3.0/fmlcore-1.20.1-47.3.0.jar'; f = 'fmlcore.jar' },
    @{ u = 'https://maven.minecraftforge.net/net/minecraftforge/javafmllanguage/1.20.1-47.3.0/javafmllanguage-1.20.1-47.3.0.jar'; f = 'javafmllang.jar' },
    @{ u = 'https://maven.minecraftforge.net/net/minecraftforge/fmlloader/1.20.1-47.3.0/fmlloader-1.20.1-47.3.0.jar'; f = 'fmlloader.jar' },
    @{ u = 'https://maven.minecraftforge.net/net/minecraftforge/forgespi/7.0.1/forgespi-7.0.1.jar'; f = 'forgespi.jar' },
    @{ u = 'https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.7/slf4j-api-2.0.7.jar'; f = 'slf4j-api-2.0.7.jar' }
)
$proxy = $env:HTTPS_PROXY
foreach ($d in $deps) {
    $dest = Join-Path $libs $d.f
    if (-not (Test-Path $dest)) {
        Write-Host "fetching $($d.f)..."
        Invoke-WebRequest -Uri $d.u -OutFile $dest -Proxy $proxy -UseBasicParsing
    }
}
$cp = (Get-ChildItem "$libs\*.jar" | ForEach-Object { $_.FullName }) -join ';'
# watermedia for the Mixin target (probe the game dirs; optional)
$wm = Get-ChildItem 'D:\PCL2\.minecraft\versions\*\mods\watermedia-2.1*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wm) { $cp += ';' + $wm.FullName } else { Write-Warning 'watermedia jar not found - @Pseudo makes this build-optional' }

# ---- stage patched sources ----
$srcDir = Join-Path $root 'src\main\java'
# Note: Forge 1.20.1 javafml requires a NO-ARG mod constructor
# (FMLModContainer calls getDeclaredConstructor() with an empty Class array),
# while NeoForge injects ModContainer. So besides the import swap we rewrite
# the BiliFixMod constructor to no-arg form for the Forge variant.
Get-ChildItem $srcDir -Recurse -Filter '*.java' | ForEach-Object {
    $rel = $_.FullName.Substring($srcDir.Length + 1)
    $dest = Join-Path "$OutDir\src" $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    $c = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    $c = $c -replace 'net\.neoforged\.fml', 'net.minecraftforge.fml'
    if ($_.Name -eq 'BiliFixMod.java') {
        $c = $c -replace 'public BiliFixMod\(ModContainer container\)', 'public BiliFixMod()'
        # drop the now-unused ModContainer import on the Forge side
        $c = $c -replace '(?m)^import net\.minecraftforge\.fml\.ModContainer;\s*\r?\n', ''
        # HARD ASSERT: if the ctor-rewrite regex ever fails to match (e.g. the source
        # signature changes), the class would keep a (ModContainer) ctor. Forge 1.20.1
        # javafml reflects getDeclaredConstructor() with an empty Class array, so the
        # game would fail at runtime with NoSuchMethodException. Fail the build instead.
        if ($c -match 'ModContainer') { throw 'forge staging failed: ModContainer reference left in BiliFixMod.java' }
    }
    [System.IO.File]::WriteAllText($dest, $c, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- Forge-flavored mods.toml ----
# Per the official Forge 1.20.1 docs (docs.minecraftforge.net/en/1.20.1/gettingstarted/modfiles):
#  - NO [[mixins]] block support (that's NeoForge-only) -> mixin config goes via
#    MANIFEST MixinConfigs instead
#  - dependency field is `mandatory=true`, NOT `type="required"`
$toml = Get-Content (Join-Path $root 'src\main\resources\META-INF\neoforge.mods.toml') -Raw -Encoding UTF8
$toml = $toml -replace 'loaderVersion = "\[4,\)"', 'loaderVersion = "[47,)"'
$toml = $toml -replace 'versionRange = "\[21,\)"', 'versionRange = "[47,)"'   # neoforge dep
$toml = $toml -replace 'modId = "neoforge"', 'modId = "forge"'
$toml = $toml -replace 'versionRange = "\[1\.21\.1,\)"', 'versionRange = "[1.20.1,)"'  # minecraft dep
# NeoForge [[mixins]] block is NOT supported by Forge 1.20.1 FML - strip it
$toml = $toml -replace '(?ms)\[\[mixins\]\]\s*\r?\nconfig\s*=\s*"[^"]+"\s*\r?\n', ''
# NeoForge `type = "required"/"optional"` -> Forge `mandatory = true/false`
$toml = $toml -replace 'type = "required"', 'mandatory = true'
$toml = $toml -replace 'type = "optional"', 'mandatory = false'
$ver = [regex]::Match($toml, '(?s)\[\[mods\]\].*?version\s*=\s*"([^"]+)"').Groups[1].Value
$jarName = "BiliFix-$ver-mc1.20.1-forge.jar"

# ---- compile ----
$srcs = Get-ChildItem "$OutDir\src" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$p = Start-Process -FilePath $javac -ArgumentList (@("--release","17","-encoding","UTF-8","-proc:none","-cp",$cp,"-d","$OutDir\classes") + $srcs) -NoNewWindow -Wait -PassThru -RedirectStandardError "$OutDir\javac-stderr.txt"
if ($p.ExitCode -ne 0) { Get-Content "$OutDir\javac-stderr.txt" -Encoding UTF8 | Select-Object -First 8; throw 'forge compile failed' }
Write-Host 'Compile OK (Forge, --release 17)' -ForegroundColor Green

# ---- package ----
$stage = "$OutDir\jar"
# clean staging to prevent nested-copy duplication (dev/dev/... incident)
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$stage\META-INF" | Out-Null
Copy-Item "$OutDir\classes\dev" "$stage\dev" -Recurse -Force
# ---- mixins.json: JAVA_21 -> JAVA_17 (v1.4.8) ----
# PROVEN against the real mixin-0.8.5.jar (MixinProbe): its CompatibilityLevel enum
# has ONLY JAVA_16/JAVA_17/JAVA_18, so "JAVA_21" throws
#   IllegalArgumentException: No enum constant ...CompatibilityLevel.JAVA_21
# at mixin bootstrap. The shared resource keeps JAVA_21 for the NeoForge 1.21.1 main
# line, so the 1.20.1 variants must downgrade it at staging time.
$mixinsSrc = Join-Path $root 'src\main\resources\bilifix.mixins.json'
$mixinsTxt = [System.IO.File]::ReadAllText($mixinsSrc, [System.Text.Encoding]::UTF8)
if ($mixinsTxt -notmatch '"compatibilityLevel"\s*:\s*"JAVA_21"') {
    # HARD FAIL, not a warning: the downgrade below is a string replace, so if the
    # source no longer says JAVA_21 the replace is a no-op and the jar ships with
    # whatever compatibilityLevel the source has. Mixin only rejects an unknown
    # level at BOOTSTRAP time ("No enum constant ...CompatibilityLevel.JAVA_xx"),
    # i.e. inside the game - the worst possible moment to find out. The
    # post-replace check below cannot catch this case (there is no JAVA_21 left
    # to find), so the source shape has to be asserted here.
    throw 'bilifix.mixins.json: expected "compatibilityLevel": "JAVA_21" in the source (the 1.20.1 variants downgrade it to JAVA_17) - source has changed'
}
$mixinsTxt = $mixinsTxt -replace '"compatibilityLevel"\s*:\s*"JAVA_21"', '"compatibilityLevel": "JAVA_17"'
if ($mixinsTxt -match 'JAVA_21') { throw 'mixins.json still contains JAVA_21 after downgrade' }
[System.IO.File]::WriteAllText("$stage\bilifix.mixins.json", $mixinsTxt, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'mixins.json staged with compatibilityLevel=JAVA_17' -ForegroundColor Green
Copy-Item (Join-Path $root 'src\main\resources\bilifix_logo.png') "$stage\" -Force
[System.IO.File]::WriteAllText("$stage\META-INF\mods.toml", $toml, (New-Object System.Text.UTF8Encoding($false)))
@"
Manifest-Version: 1.0
Implementation-Title: BiliFix
Implementation-Version: $ver
MixinConfigs: bilifix.mixins.json
"@ | Out-File "$OutDir\MANIFEST.MF" -Encoding ascii
Push-Location $stage
& $jar cfm "$OutDir\$jarName" "$OutDir\MANIFEST.MF" dev bilifix.mixins.json bilifix_logo.png META-INF/mods.toml
Pop-Location

# ---- integrity gate ----
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zc = [System.IO.Compression.ZipFile]::OpenRead("$OutDir\$jarName")
$fail = 0
foreach ($e in $zc.Entries) { try { $ms = New-Object System.IO.MemoryStream; $e.Open().CopyTo($ms) } catch { $fail++ } }
$total = $zc.Entries.Count
$zc.Dispose()
if ($fail -gt 0) { throw "forge jar integrity check FAILED ($fail of $total)" }
Write-Host "Forge jar: $OutDir\$jarName ($((Get-Item "$OutDir\$jarName").Length) bytes, $total/$total entries OK)" -ForegroundColor Green

# ---- tests (v1.4.8) ----
# Previously only build.ps1 ran tests, so running ONLY build-forge.ps1 gave zero
# coverage: a broken CrashSentinel/BiliFixConfig change would sail straight into
# the 1.20.1 Forge jar. Same two steps as build.ps1, run after packaging so the
# §9.6b jar structure assertions cover this variant's output too.
Push-Location $root
try {
    $testDir = Join-Path $OutDir 'test'
    New-Item -ItemType Directory -Force -Path $testDir | Out-Null
    & $javac -encoding UTF-8 -d $testDir (Join-Path $root 'src\test\java\Regression.java')
    if ($LASTEXITCODE -ne 0) { throw 'regression compile failed' }
    $javaExe = $javac -replace 'javac\.exe$', 'java.exe'
    & $javaExe -cp $testDir Regression
    if ($LASTEXITCODE -ne 0) { throw 'regression tests failed' }
    Write-Host 'Regression tests OK' -ForegroundColor Green

    $probeDir = Join-Path $OutDir 'concurrency-probe'
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp (Join-Path $OutDir 'classes') -d $probeDir (Join-Path $root 'src\test\java\ConcurrentRecordProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'concurrency probe compile failed' }
    & $javaExe -cp "$probeDir;$(Join-Path $OutDir 'classes')" ConcurrentRecordProbe
    if ($LASTEXITCODE -ne 0) { throw 'concurrency probe FAILED (event cap not held under load)' }
    Write-Host 'Concurrency probe OK' -ForegroundColor Green

    # FmlBridge probe: FmlBridge is the one production class with no coverage and
    # sits on the critical path (CrashSentinel.gameDirectory()). Stub FML classes
    # live under the REAL package name so the production forName -> constant ->
    # get() -> Path chain runs end to end.
    $fmlDir = Join-Path $OutDir 'fmlbridge-probe'
    New-Item -ItemType Directory -Force -Path $fmlDir | Out-Null
    $stubSrcs = Get-ChildItem (Join-Path $root 'src\test\stubs') -Recurse -Filter '*.java' |
        Where-Object { $_.FullName -notlike '*\stubs\slf4j\*' } | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp (Join-Path $OutDir 'classes') -d $fmlDir @stubSrcs (Join-Path $root 'src\test\java\FmlBridgeProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe compile failed' }
    & $javaExe -cp "$fmlDir;$(Join-Path $OutDir 'classes')" FmlBridgeProbe
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe FAILED (fmlDir chain or the no-throw contract broke)' }
    Write-Host 'FmlBridge probe OK' -ForegroundColor Green

    # FmlModVersion probe: FmlBridge.modVersion's SUCCESS path (it was
    # untested - FmlBridgeProbe only covered the "ModList absent" degradation).
    # Real FML returns the IModFileInfo INTERFACE with a package-private
    # implementation; if that path breaks, EnvironmentDiagnostics reports an
    # installed watermedia as missing. Its stubs live in a separate directory
    # so the FmlBridgeProbe classpath above still has no ModList.
    $fmvDir = Join-Path $OutDir 'fmlmodver-probe'
    New-Item -ItemType Directory -Force -Path $fmvDir | Out-Null
    $mvStubs = Get-ChildItem (Join-Path $root 'src\test\stubs-fmlmodlist') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp (Join-Path $OutDir 'classes') -d $fmvDir @mvStubs (Join-Path $root 'src\test\java\FmlModVersionProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'FmlModVersion probe compile failed' }
    $fmvP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fmvDir;$(Join-Path $OutDir 'classes')", 'FmlModVersionProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fmvDir\stdout.txt" -RedirectStandardError "$fmvDir\stderr.txt"
    Get-Content "$fmvDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fmvP.ExitCode -ne 0) { throw 'FmlModVersion probe FAILED (modVersion success path or the no-throw contract broke)' }
    Write-Host 'FmlModVersion probe OK' -ForegroundColor Green

    # README drift probe: the READMEs quote the exact log lines users look for.
    $rmDir = Join-Path $OutDir 'readme-probe'
    New-Item -ItemType Directory -Force -Path $rmDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp (Join-Path $OutDir 'classes') -d $rmDir (Join-Path $root 'src\test\java\ReadmeLogSampleProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'README probe compile failed' }
    $slf4jJar = (Get-ChildItem "$libs\slf4j-api*.jar" | Select-Object -First 1).FullName
    # Start-Process with redirected streams: SLF4J's "No SLF4J providers" notice
    # goes to stderr and PowerShell would turn it into a fatal error record even
    # though the probe passed. The process exit code is the verdict.
    $rmCp = "$rmDir;$(Join-Path $OutDir 'classes');$slf4jJar"
    $rmP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', $rmCp, 'ReadmeLogSampleProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$rmDir\stdout.txt" -RedirectStandardError "$rmDir\stderr.txt"
    Get-Content "$rmDir\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    if ($rmP.ExitCode -ne 0) { throw 'README probe FAILED (README log samples drifted from the production output)' }
    Write-Host 'README probe OK' -ForegroundColor Green

    # GPU detection probe: the old code queried the display adapter CLASS key
    # for DriverDesc, but that value lives in the per-adapter subkeys, so the
    # query failed and the GPU line never reached the report.
    $gpuDir = Join-Path $OutDir 'gpu-probe'
    New-Item -ItemType Directory -Force -Path $gpuDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp (Join-Path $OutDir 'classes') -d $gpuDir (Join-Path $root 'src\test\java\GpuDetectProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'GPU probe compile failed' }
    $slf4jForGpu = (Get-ChildItem "$libs\slf4j-api*.jar" | Select-Object -First 1).FullName
    $gpuP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$gpuDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'GpuDetectProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$gpuDir\stdout.txt" -RedirectStandardError "$gpuDir\stderr.txt"
    Get-Content "$gpuDir\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    if ($gpuP.ExitCode -ne 0) { throw 'GPU probe FAILED (detectGpu returned nothing - the GPU line never reaches the report)' }
    Write-Host 'GPU probe OK' -ForegroundColor Green

    # Argument rewrite probe: the core of the fix is the argument rewriting
    # in JarToolMixin, and until now nothing actually EXECUTED it (Regression
    # is an independent mirror; the README probe only compares log strings).
    $mixinForAr = (Get-ChildItem "$libs\mixin-*.jar" | Select-Object -First 1).FullName
    if ($mixinForAr) {
        $arDir = Join-Path $OutDir 'arg-probe'
        New-Item -ItemType Directory -Force -Path $arDir | Out-Null
        & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$mixinForAr;$slf4jForGpu" -d $arDir (Join-Path $root 'src\test\java\ArgumentRewriteProbe.java')
        if ($LASTEXITCODE -ne 0) { throw 'Argument rewrite probe compile failed' }
        $arP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$arDir;$(Join-Path $OutDir 'classes');$mixinForAr;$slf4jForGpu", 'ArgumentRewriteProbe') `
                -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
                -RedirectStandardOutput "$arDir\stdout.txt" -RedirectStandardError "$arDir\stderr.txt"
        Get-Content "$arDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
        if ($arP.ExitCode -ne 0) { throw 'Argument rewrite probe FAILED (the hardening logic did not behave as required)' }
        Write-Host 'Argument rewrite probe OK' -ForegroundColor Green
    }

    # Forensics suppression probe: the startup self-check's suppression must be
    # thread-local, otherwise a real media playback on the media thread is
    # swallowed too and the forensic evidence is lost.
    $fsDir = Join-Path $OutDir 'forensics-probe'
    New-Item -ItemType Directory -Force -Path $fsDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $fsDir (Join-Path $root 'src\test\java\ForensicsSuppressionProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Forensics suppression probe compile failed' }
    $fsP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fsDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'ForensicsSuppressionProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fsDir\stdout.txt" -RedirectStandardError "$fsDir\stderr.txt"
    Get-Content "$fsDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fsP.ExitCode -ne 0) { throw 'Forensics suppression probe FAILED (the suppression leaks across threads)' }
    Write-Host 'Forensics suppression probe OK' -ForegroundColor Green

    # Config parse probe: a UTF-8 BOM must not make the parser drop the first
    # key, otherwise the user's hwDecoder setting is silently ignored.
    $cfgDir = Join-Path $OutDir 'cfgparse-probe'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $cfgDir (Join-Path $root 'src\test\java\ConfigParseProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Config parse probe compile failed' }
    $cfgP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$cfgDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'ConfigParseProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$cfgDir\stdout.txt" -RedirectStandardError "$cfgDir\stderr.txt"
    Get-Content "$cfgDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($cfgP.ExitCode -ne 0) { throw 'Config parse probe FAILED (the parser does not handle a UTF-8 BOM)' }
    Write-Host 'Config parse probe OK' -ForegroundColor Green

    # Mixin target guard probe: the guard that turns a silent mixin skip into
    # a visible warning must be verified against real stub classes.
    $gdDir = Join-Path $OutDir 'guard-probe'
    New-Item -ItemType Directory -Force -Path $gdDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $gdDir (Join-Path $root 'src\test\java\MixinTargetGuardProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Mixin target guard probe compile failed' }
    $gdP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$gdDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'MixinTargetGuardProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$gdDir\stdout.txt" -RedirectStandardError "$gdDir\stderr.txt"
    Get-Content "$gdDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($gdP.ExitCode -ne 0) { throw 'Mixin target guard probe FAILED (the guard does not detect the silent skip)' }
    Write-Host 'Mixin target guard probe OK' -ForegroundColor Green

    # Startup log truth probe: the startup line must show the value that is
    # actually in effect, not the raw string the user typed.
    $slDir = Join-Path $OutDir 'startuplog-probe'
    New-Item -ItemType Directory -Force -Path $slDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $slDir (Join-Path $root 'src\test\java\StartupLogTruthProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Startup log truth probe compile failed' }
    $slP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$slDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'StartupLogTruthProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$slDir\stdout.txt" -RedirectStandardError "$slDir\stderr.txt"
    Get-Content "$slDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($slP.ExitCode -ne 0) { throw 'Startup log truth probe FAILED (the startup line does not show the effective value)' }
    Write-Host 'Startup log truth probe OK' -ForegroundColor Green

    # Forensics vout probe: the diagnostics file must not say "vout=null"
    # when the user deliberately set vout=original.
    $fvDir = Join-Path $OutDir 'forensicsvout-probe'
    New-Item -ItemType Directory -Force -Path $fvDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $fvDir (Join-Path $root 'src\test\java\ForensicsVoutProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Forensics vout probe compile failed' }
    $fvP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fvDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'ForensicsVoutProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fvDir\stdout.txt" -RedirectStandardError "$fvDir\stderr.txt"
    Get-Content "$fvDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fvP.ExitCode -ne 0) { throw 'Forensics vout probe FAILED (the diagnostics file misreports the vout strategy)' }
    Write-Host 'Forensics vout probe OK' -ForegroundColor Green

    # Unknown config key probe: a mistyped config key must be VISIBLE, not silently dropped.
    # Needs the capturing slf4j provider on the test classpath: slf4j-api without a
    # provider degrades to a NOP logger, so the warning could not be observed at all.
    $ukDir = Join-Path $OutDir 'unknownkey-probe'
    New-Item -ItemType Directory -Force -Path $ukDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $ukDir (Join-Path $root 'src\test\stubs\slf4j\test\slf4j\CapturingServiceProvider.java')
    if ($LASTEXITCODE -ne 0) { throw 'Unknown key probe: capturing slf4j provider compile failed' }
    New-Item -ItemType Directory -Force -Path (Join-Path $ukDir 'META-INF\services') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ukDir 'META-INF\services\org.slf4j.spi.SLF4JServiceProvider'), "test.slf4j.CapturingServiceProvider`n", (New-Object System.Text.UTF8Encoding($false)))
    & $javac -encoding UTF-8 -proc:none -cp "$ukDir;$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $ukDir (Join-Path $root 'src\test\java\UnknownConfigKeyProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Unknown config key probe compile failed' }
    $ukP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$ukDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'UnknownConfigKeyProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$ukDir\stdout.txt" -RedirectStandardError "$ukDir\stderr.txt"
    Get-Content "$ukDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($ukP.ExitCode -ne 0) { throw 'Unknown config key probe FAILED (a mistyped config key is silently ignored)' }
    Write-Host 'Unknown config key probe OK' -ForegroundColor Green
    # Config default probe: the default values (none / gl,any / false) used to be
    # hard-coded in FOUR places - the field initialisers, the load() exception
    # reset, the file written to the user, and the unknown-value fallback. Any one
    # of them drifting means the user's config file says one thing while the
    # effective behaviour is another - and the log says "config loaded", so
    # nothing points at the cause.
    $cdDir = Join-Path $OutDir 'cfgdefault-probe'
    New-Item -ItemType Directory -Force -Path $cdDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $cdDir (Join-Path $root 'src\test\java\ConfigDefaultProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Config default probe compile failed' }
    $cdP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$cdDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'ConfigDefaultProbe', 'src/main/java/dev/polaris_fix/bilifix/config/BiliFixConfig.java') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$cdDir\stdout.txt" -RedirectStandardError "$cdDir\stderr.txt"
    Get-Content "$cdDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($cdP.ExitCode -ne 0) { throw 'Config default probe FAILED (the default values have more than one source of truth)' }
    Write-Host 'Config default probe OK' -ForegroundColor Green
    # Mirror parity probe: the Regression mirror is an INDEPENDENT
    # re-implementation of the production logic, so when production changes
    # on purpose the mirror has to be updated BY HAND. When it is not, the
    # mirror gives the opposite answer from production while every mirror
    # test still passes - the worst possible state for a safety net.
    # Three real divergences were measured this way (v1.4.8).
    $mpDir = Join-Path $OutDir 'mirrorparity-probe'
    New-Item -ItemType Directory -Force -Path $mpDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $mpDir (Join-Path $root 'src\test\java\Regression.java') (Join-Path $root 'src\test\java\MirrorParityProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Mirror parity probe compile failed' }
    $mpP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$mpDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'MirrorParityProbe', 'src/test/java/Regression.java') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$mpDir\stdout.txt" -RedirectStandardError "$mpDir\stderr.txt"
    Get-Content "$mpDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($mpP.ExitCode -ne 0) { throw 'Mirror parity probe FAILED (the regression mirror disagrees with production)' }
    Write-Host 'Mirror parity probe OK' -ForegroundColor Green
    # Fabric init probe: the Fabric loader is the ONLY one with its own
    # entry point (ModInitializer -> explicit directory injection), so the
    # injection order inside BiliFixMod.init() is semantic. Load the config
    # before the dirs are injected and the config file lands somewhere else
    # entirely - silently, with no error.
    $fiDir = Join-Path $OutDir 'fabricinit-probe'
    New-Item -ItemType Directory -Force -Path $fiDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $fiDir (Join-Path $root 'src\test\java\FabricInitProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Fabric init probe compile failed' }
    $fiP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fiDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'FabricInitProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fiDir\stdout.txt" -RedirectStandardError "$fiDir\stderr.txt"
    Get-Content "$fiDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fiP.ExitCode -ne 0) { throw 'Fabric init probe FAILED' }
    Write-Host 'Fabric init probe OK' -ForegroundColor Green
    # Normalized warning probe: the "config was normalized" line fires during
    # crash triage, and a noise warning is the worst kind - it points at a
    # problem that does not exist. An unset (null) field is NOT a change.
    $nwDir = Join-Path $OutDir 'normwarn-probe'
    New-Item -ItemType Directory -Force -Path $nwDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$slf4jForGpu" -d $nwDir (Join-Path $root 'src\test\java\NormalizedWarningProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Normalized warning probe compile failed' }
    $nwP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$nwDir;$(Join-Path $OutDir 'classes');$slf4jForGpu", 'NormalizedWarningProbe', 'src/main/java/dev/polaris_fix/bilifix/BiliFixMod.java') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$nwDir\stdout.txt" -RedirectStandardError "$nwDir\stderr.txt"
    Get-Content "$nwDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($nwP.ExitCode -ne 0) { throw 'Normalized warning probe FAILED' }
    Write-Host 'Normalized warning probe OK' -ForegroundColor Green
# Real arguments probe (v1.4.8). Every earlier check used HAND-WRITTEN
# parameter tables. This one uses the table watermedia actually ships
# (videolan/arguments.json, read out of the real jar) and runs the
# PRODUCTION rewrite on it. The real table carries
#   "--vout", "direct3d11,glwin32,gl,any"
#   "--avcodec-hw", "d3d11va,dxva2,any"
# which is exactly the D3D11VA copy-back path that kills the JVM.
# The real watermedia jar is optional: without it the jar-level checks
# are skipped, the table-level checks still run.
# Locate the real watermedia jar. The folder name contains non-ASCII
# characters, and this script may be read without a BOM (which would make
# a literal path unreadable), so the lookup must NOT depend on a
# hard-coded non-ASCII literal. Search by FILE NAME instead.
$wmJar = $null
$wmRoots = @('D:\PCL2\.minecraft\versions', 'D:\PCL2\.minecraft\mods')
foreach ($r in $wmRoots) {
    if (-not (Test-Path $r)) { continue }
    $hit = Get-ChildItem $r -Recurse -Filter 'watermedia-*.jar' -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
    if ($hit) { $wmJar = $hit.FullName; break }
}
if ((Test-Path "$root\src\test\java\RealArgumentsProbe.java") -and (Test-Path $mixinForAr)) {
    $raOut = Join-Path $OutDir 'realargs-probe'
    New-Item -ItemType Directory -Force -Path $raOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$mixinForAr;$slf4jForGpu" -d $raOut "$root\src\test\java\RealArgumentsProbe.java"
    if ($LASTEXITCODE -ne 0) { throw 'Real arguments probe compile failed' }
    $raArgs = @('-cp', "$raOut;$(Join-Path $OutDir 'classes');$mixinForAr;$slf4jForGpu", 'RealArgumentsProbe')
    if ($wmJar) { $raArgs += $wmJar }
    $raP = Start-Process -FilePath $javaExe -ArgumentList $raArgs `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$raOut\stdout.txt" -RedirectStandardError "$raOut\stderr.txt"
    Get-Content "$raOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|\[SKIP\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($raP.ExitCode -ne 0) { throw 'Real arguments probe FAILED (the production rewrite does not neutralise the REAL watermedia parameter table)' }
    Write-Host 'Real arguments probe OK' -ForegroundColor Green

# Doc structure probe. The CHANGELOG once had a "### 修复" heading split
# into "### 修" / "" / "复" by a String.Replace whose anchor crossed a
# newline. That damage is INVISIBLE to a build - the file is still valid
# Markdown, it just renders with an empty section and a stray paragraph.
# Release notes are how users learn what changed, so they get a probe too.
if (Test-Path "$root\src\test\java\DocStructureProbe.java") {
    $dsOut = Join-Path $OutDir 'docstruct-probe'
    New-Item -ItemType Directory -Force -Path $dsOut | Out-Null
    & $javac -encoding UTF-8 -proc:none -d $dsOut "$root\src\test\java\DocStructureProbe.java"
    if ($LASTEXITCODE -ne 0) { throw "Doc structure probe compile failed" }
    $dsP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', $dsOut, 'DocStructureProbe', 'CHANGELOG.md') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$dsOut\stdout.txt" -RedirectStandardError "$dsOut\stderr.txt"
    Get-Content "$dsOut\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($dsP.ExitCode -ne 0) { throw "Doc structure probe FAILED (the release notes are structurally broken)" }
    Write-Host "Doc structure probe OK" -ForegroundColor Green
}
}

    # Null element probe: a null entry in the argument array must not make the
    # hardening logic throw. JarTool.readArray is a GENERAL method - watermedia
    # may read other JSON with it, and a null entry would blow up switch (arg).
    $neDir = Join-Path $OutDir 'nullelem-probe'
    New-Item -ItemType Directory -Force -Path $neDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$(Join-Path $OutDir 'classes');$mixinForAr;$slf4jForGpu" -d $neDir (Join-Path $root 'src\test\java\NullElementProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Null element probe compile failed' }
    $neP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$neDir;$(Join-Path $OutDir 'classes');$mixinForAr;$slf4jForGpu", 'NullElementProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$neDir\stdout.txt" -RedirectStandardError "$neDir\stderr.txt"
    Get-Content "$neDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($neP.ExitCode -ne 0) { throw 'Null element probe FAILED (a null argument entry crashes the hardening logic)' }
    Write-Host 'Null element probe OK' -ForegroundColor Green

    # Negative tests: every probe must be able to FAIL. Each script breaks the
    # production code on purpose and asserts the matching probe fails. A probe
    # that cannot fail is decoration, not evidence.
    # NOTE: these scripts need .tools/jdk21 and the cached libs under
    # build/fabric/libs - both exist by the time this block runs.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'src\test\negative\run-all-negative-tests.ps1') 2>&1 |
        Select-String -Pattern '^\[neg-all\]|NEGATIVE_TESTS_' | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Negative tests FAILED (a probe cannot detect the regression it claims to cover)' }
    Write-Host 'Negative tests OK' -ForegroundColor Green

# Housekeeping: remove OLDER-VERSION jars from build/ (all published versions
# are recoverable from source).
# build.ps1 only ever cleaned the ROOT of build/, so the two 1.20.1
# variants accumulated stale jars in build/forge/ and build/fabric/.
# A leftover jar is a jar someone might think was published.
# This must run BEFORE the jar metadata probe, and it must cover every output
# directory - the probe scans build/ recursively, so a stale jar in
# build/fabric/ would be checked as if it were a current artefact.
#
# Only jars whose version differs from the one being built are removed: the
# three variants share the build/ tree, and deleting the OTHER variants'
# current jars would mean "build the forge variant" silently destroys the
# neoforge artefact.
$hkVersion = ($jarName -replace '^BiliFix-([^-]+)-.*$', '$1')
foreach ($hkDir in @((Join-Path $root 'build'), (Join-Path $root 'build\forge'), (Join-Path $root 'build\fabric'))) {
    if (-not (Test-Path $hkDir)) { continue }
    Get-ChildItem $hkDir -Filter 'BiliFix-*-mc*.jar' -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -replace '^BiliFix-([^-]+)-.*$', '$1') -ne $hkVersion } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
    # Jar metadata probe: check the PACKAGED artefact, not the source.
    # Which loader metadata file is inside, what the mixin
    # compatibilityLevel says and whether the mod classes are present are
    # all decided at packaging time - none of it is visible in the source
    # tree. The NeoForge jar once carried a dead META-INF/mods.toml that
    # no loader ever reads (FML loader 4.0.45's ModFileParser only knows
    # "META-INF/neoforge.mods.toml").
    if (Test-Path (Join-Path $root 'src\test\java\JarMetadataProbe.java')) {
        $jmOut = Join-Path $OutDir 'jarmeta-probe'
        New-Item -ItemType Directory -Force -Path $jmOut | Out-Null
        & $javac -encoding UTF-8 -proc:none -d $jmOut (Join-Path $root 'src\test\java\JarMetadataProbe.java')
        if ($LASTEXITCODE -ne 0) { throw 'Jar metadata probe compile failed' }
        # Check EVERY packaged jar, not just this script's own. The probe
        # infers the loader from the jar's own contents, so the order
        # does not matter. A jar that is not built yet is simply skipped -
        # running only build.ps1 on a fresh checkout must not fail here.
            # Find the packaged jars by glob, not by a hard-coded name: the
            # version variable is $version in one script and $ver in the other
            # two, and each has a different output directory. A probe that
            # silently finds nothing and skips is worse than no probe.
            $jmArgs = @('-cp', $jmOut, 'JarMetadataProbe')
            foreach ($jmJar in @(Get-ChildItem (Join-Path $root 'build') -Recurse -Filter 'BiliFix-*.jar' -ErrorAction SilentlyContinue)) {
                $jmArgs += $jmJar.FullName
            }
            if ($jmArgs.Count -le 3) {
                Write-Host 'Jar metadata probe SKIPPED: no packaged jar to check yet' -ForegroundColor Yellow
            } else {
                $jmP = Start-Process -FilePath $javaExe -ArgumentList $jmArgs `
                        -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
                        -RedirectStandardOutput (Join-Path $jmOut 'stdout.txt') -RedirectStandardError (Join-Path $jmOut 'stderr.txt')
                Get-Content (Join-Path $jmOut 'stdout.txt') -ErrorAction SilentlyContinue |
                    Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
                if ($jmP.ExitCode -ne 0) { throw 'Jar metadata probe FAILED (the packaged jar is wrong)' }
                Write-Host 'Jar metadata probe OK' -ForegroundColor Green
            }
    }
}
finally { Pop-Location }
