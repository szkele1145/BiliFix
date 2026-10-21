# build-fabric.ps1 - build the Fabric 1.20.1 variant of BiliFix
#
# Why this variant needs a staging step at all:
#   src/main/java/* is compiled against NeoForge by build.ps1, and the class
#   dev.polaris_fix.bilifix.BiliFixMod carries @Mod + a (ModContainer) constructor.
#   Neither fabric-loader nor the Minecraft runtime provides net.neoforged.fml.*,
#   so javac would fail on the missing symbols. We therefore compile a *staged copy*
#   of src/main/java with the two FML imports + the @Mod annotation + the ModContainer
#   constructor parameter stripped, plus the real Fabric entrypoint from src/fabric/java.
#   src/fabric/* is never visible to the Forge/NeoForge scripts, so the reverse
#   contamination cannot happen either (bytecode-verified).
#
# v1.4.8: mixins.json is staged with compatibilityLevel JAVA_17 (see note below).

param(
    [string]$OutDir = "",
    [string]$Proxy  = ""
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'build\fabric' }
$Proxy = if ($Proxy) { $Proxy } else { $env:HTTPS_PROXY }

Write-Host "BiliFix Fabric build -> $OutDir" -ForegroundColor Cyan

function Get-Javac {
    foreach ($probe in @(
        $env:BILIFIX_JAVAC,
        (Get-Command javac -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        "$root\.tools\jdk21\bin\javac.exe",
        "$env:USERPROFILE\.jdks\ms-17.0.19\bin\javac.exe",
        'C:\jdk17\bin\javac.exe',
        "$env:APPDATA\.minecraft\runtime\java-runtime-delta\bin\javac.exe"
    )) {
        if ($probe -and (Test-Path $probe)) { return $probe }
    }
    throw 'no JDK found: set BILIFIX_JAVAC or install one (--release 17 needs JDK >= 17)'
}
$javac   = Get-Javac
$javaExe = $javac -replace 'javac\.exe$', 'java.exe'
$jarExe  = $javac -replace 'javac\.exe$', 'jar.exe'
Write-Host "javac: $javac"

# ---- libs ----
# Fabric compile classpath. fabric-loader + sponge-mixin are only needed as symbols;
# slf4j-api is a real runtime dependency of the mod. Prefer jars already fetched by a
# previous run (offline reproducibility), then fall back to downloading.
$libs = Join-Path $OutDir 'libs'
New-Item -ItemType Directory -Force -Path $libs | Out-Null

$deps = @(
    @{ name = 'slf4j-api-2.0.7.jar';    url = 'https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.7/slf4j-api-2.0.7.jar' },
    @{ name = 'fabric-loader.jar';      url = 'https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.15.11/fabric-loader-0.15.11.jar' },
    @{ name = 'sponge-mixin.jar';       url = 'https://repo.spongepowered.org/repository/maven-public/org/spongepowered/mixin/0.8.5/mixin-0.8.5.jar' }
)
foreach ($dep in $deps) {
    $target = Join-Path $libs $dep.name
    if (Test-Path $target) { Write-Host "  [libs] cached $($dep.name)"; continue }
    # reuse a jar fetched for another variant before hitting the network
    foreach ($alt in @("$root\build\forge\libs\$($dep.name)", "$root\build\neoforge\libs\$($dep.name)")) {
        if (Test-Path $alt) { Copy-Item $alt $target -Force; break }
    }
    if (Test-Path $target) { Write-Host "  [libs] reused $($dep.name)"; continue }
    Write-Host "  [libs] download $($dep.name)" -ForegroundColor Yellow
    try {
        if ($Proxy) {
            Invoke-WebRequest -Uri $dep.url -OutFile $target -Proxy $Proxy -UseBasicParsing
        } else {
            Invoke-WebRequest -Uri $dep.url -OutFile $target -UseBasicParsing
        }
    } catch {
        throw "failed to fetch $($dep.name): $($_.Exception.Message) - place it in $libs manually"
    }
}

# ---- stage sources ----
$stage = Join-Path $OutDir 'src'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$mainSrc = Join-Path $root 'src\main\java'
$fabSrc  = Join-Path $root 'src\fabric\java'

foreach ($f in Get-ChildItem $mainSrc -Recurse -Filter '*.java') {
    $rel  = $f.FullName.Substring($mainSrc.Length).TrimStart('\')
    $dest = Join-Path $stage $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($f.Name -eq 'BiliFixMod.java') {
        # strip the FML-only surface: imports, @Mod annotation, ModContainer ctor param
        $txt = $txt -replace '(?m)^import\s+net\.(neoforged|minecraftforge)\.fml[^\r\n]*\r?\n', ''
        $txt = $txt -replace '(?m)^@Mod\([^\)]*\)\s*\r?\n', ''
        $txt = $txt -replace 'public BiliFixMod\(ModContainer container\)', 'public BiliFixMod()'
        if ($txt -match 'ModContainer|@Mod\(|neoforged\.fml') {
            throw 'fabric staging failed: FML reference left in BiliFixMod.java'
        }
    }
    [System.IO.File]::WriteAllText($dest, $txt, $utf8NoBom)
}
# the real Fabric entrypoint, copied verbatim (it only uses fabric-loader API)
foreach ($f in Get-ChildItem $fabSrc -Recurse -Filter '*.java') {
    $rel  = $f.FullName.Substring($fabSrc.Length).TrimStart('\')
    $dest = Join-Path $stage $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    [System.IO.File]::WriteAllText($dest,
            [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8), $utf8NoBom)
}

# ---- compile ----
$outClasses = Join-Path $OutDir 'classes'
Remove-Item $outClasses -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $outClasses | Out-Null
$cp = (Get-ChildItem $libs -Filter '*.jar' | ForEach-Object { $_.FullName }) -join ';'
$srcs = Get-ChildItem $stage -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$jargs = @('--release', '17', '-encoding', 'UTF-8', '-proc:none', '-cp', $cp, '-d', $outClasses) + $srcs
$p = Start-Process -FilePath $javac -ArgumentList $jargs -NoNewWindow -Wait -PassThru `
        -RedirectStandardError (Join-Path $OutDir 'javac-stderr.txt') `
        -RedirectStandardOutput (Join-Path $OutDir 'javac-stdout.txt')
if ($p.ExitCode -ne 0) {
    Get-Content (Join-Path $OutDir 'javac-stderr.txt') -Encoding UTF8 | Select-Object -First 12
    throw 'fabric compile failed'
}
Write-Host 'Compile OK (Fabric, --release 17)' -ForegroundColor Green

# ---- package ----
$ver = $null
$fmj = Join-Path $root 'src\fabric\resources\fabric.mod.json'
if (Test-Path $fmj) {
    $m = [regex]::Match([System.IO.File]::ReadAllText($fmj, [System.Text.Encoding]::UTF8),
                        '"version"\s*:\s*"([^"]+)"')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}
if (-not $ver) { throw 'cannot determine version from fabric.mod.json' }
$jarName = "BiliFix-$ver-mc1.20.1-fabric.jar"

$pkg = Join-Path $OutDir 'jar'
Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
Copy-Item (Join-Path $outClasses 'dev') $pkg -Recurse -Force

# ---- mixins.json: JAVA_21 -> JAVA_17 (v1.4.8) ----
# PROVEN against the real mixin-0.8.5.jar (MixinProbe): its CompatibilityLevel enum
# has ONLY JAVA_16/JAVA_17/JAVA_18, so "JAVA_21" throws
#   IllegalArgumentException: No enum constant ...CompatibilityLevel.JAVA_21
# at mixin bootstrap. The shared resource keeps JAVA_21 for the NeoForge 1.21.1 main
# line, so the 1.20.1 variants must downgrade it at staging time.
$mixinsTxt = [System.IO.File]::ReadAllText((Join-Path $root 'src\main\resources\bilifix.mixins.json'),
                                           [System.Text.Encoding]::UTF8)
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
[System.IO.File]::WriteAllText((Join-Path $pkg 'bilifix.mixins.json'), $mixinsTxt, $utf8NoBom)
Copy-Item (Join-Path $root 'src\fabric\resources\fabric.mod.json') $pkg -Force
Copy-Item (Join-Path $root 'src\main\resources\bilifix_logo.png')  $pkg -Force
Write-Host 'mixins.json staged with compatibilityLevel=JAVA_17' -ForegroundColor Green

$manifestPath = Join-Path $OutDir 'MANIFEST.MF'
$manifest = "Manifest-Version: 1.0`r`nImplementation-Title: BiliFix`r`nImplementation-Version: $ver`r`n`r`n"
[System.IO.File]::WriteAllText($manifestPath, $manifest, $utf8NoBom)

$jarOut = Join-Path $OutDir $jarName
Remove-Item $jarOut -Force -ErrorAction SilentlyContinue
Push-Location $pkg
try {
    & $jarExe cfm $jarOut (Join-Path $OutDir 'MANIFEST.MF') `
        dev bilifix.mixins.json fabric.mod.json bilifix_logo.png
    if ($LASTEXITCODE -ne 0) { throw "jar packaging failed ($LASTEXITCODE)" }
} finally { Pop-Location }

# ---- integrity gate ----
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fail = 0; $total = 0
$zip = [System.IO.Compression.ZipFile]::OpenRead($jarOut)
try {
    foreach ($e in $zip.Entries) {
        $total++
        try {
            if ($e.Length -gt 0) {
                $s = $e.Open(); $buf = New-Object byte[] 8192
                while ($s.Read($buf, 0, $buf.Length) -gt 0) { }
                $s.Close()
            }
        } catch { $fail++; Write-Warning "UNREADABLE entry: $($e.FullName)" }
    }
} finally { $zip.Dispose() }
if ($fail -gt 0) { throw "fabric jar integrity check FAILED ($fail of $total)" }
Write-Host "Jar integrity: $total/$total entries OK" -ForegroundColor Green
Write-Host "Fabric jar: $jarOut ($((Get-Item $jarOut).Length) bytes, $total entries)" -ForegroundColor Green

# ---- tests (v1.4.8) ----
# Mirrors build.ps1 / build-forge.ps1: previously only build.ps1 ran tests, so
# running ONLY build-fabric.ps1 gave zero coverage. Both steps run after
# packaging so the §9.6b jar structure assertions cover this variant's output.
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
    & $javac -encoding UTF-8 -proc:none -cp $outClasses -d $probeDir (Join-Path $root 'src\test\java\ConcurrentRecordProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'concurrency probe compile failed' }
    & $javaExe -cp "$probeDir;$outClasses" ConcurrentRecordProbe
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
    & $javac -encoding UTF-8 -proc:none -cp $outClasses -d $fmlDir @stubSrcs (Join-Path $root 'src\test\java\FmlBridgeProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe compile failed' }
    & $javaExe -cp "$fmlDir;$outClasses" FmlBridgeProbe
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
    & $javac -encoding UTF-8 -proc:none -cp $outClasses -d $fmvDir @mvStubs (Join-Path $root 'src\test\java\FmlModVersionProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'FmlModVersion probe compile failed' }
    $fmvP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fmvDir;$outClasses", 'FmlModVersionProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fmvDir\stdout.txt" -RedirectStandardError "$fmvDir\stderr.txt"
    Get-Content "$fmvDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fmvP.ExitCode -ne 0) { throw 'FmlModVersion probe FAILED (modVersion success path or the no-throw contract broke)' }
    Write-Host 'FmlModVersion probe OK' -ForegroundColor Green

    # README drift probe: the READMEs quote the exact log lines users look for.
    $rmDir = Join-Path $OutDir 'readme-probe'
    New-Item -ItemType Directory -Force -Path $rmDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp $outClasses -d $rmDir (Join-Path $root 'src\test\java\ReadmeLogSampleProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'README probe compile failed' }
    $slf4jJar = (Get-ChildItem "$libs\slf4j-api*.jar" | Select-Object -First 1).FullName
    # Start-Process with redirected streams: SLF4J's "No SLF4J providers" notice
    # goes to stderr and PowerShell would turn it into a fatal error record even
    # though the probe passed. The process exit code is the verdict.
    $rmCp = "$rmDir;$outClasses;$slf4jJar"
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
    & $javac -encoding UTF-8 -proc:none -cp $outClasses -d $gpuDir (Join-Path $root 'src\test\java\GpuDetectProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'GPU probe compile failed' }
    $slf4jForGpu = (Get-ChildItem "$libs\slf4j-api*.jar" | Select-Object -First 1).FullName
    $gpuP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$gpuDir;$outClasses;$slf4jForGpu", 'GpuDetectProbe') `
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
        & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$mixinForAr;$slf4jForGpu" -d $arDir (Join-Path $root 'src\test\java\ArgumentRewriteProbe.java')
        if ($LASTEXITCODE -ne 0) { throw 'Argument rewrite probe compile failed' }
        $arP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$arDir;$outClasses;$mixinForAr;$slf4jForGpu", 'ArgumentRewriteProbe') `
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
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$slf4jForGpu" -d $fsDir (Join-Path $root 'src\test\java\ForensicsSuppressionProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Forensics suppression probe compile failed' }
    $fsP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fsDir;$outClasses;$slf4jForGpu", 'ForensicsSuppressionProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$fsDir\stdout.txt" -RedirectStandardError "$fsDir\stderr.txt"
    Get-Content "$fsDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($fsP.ExitCode -ne 0) { throw 'Forensics suppression probe FAILED (the suppression leaks across threads)' }
    Write-Host 'Forensics suppression probe OK' -ForegroundColor Green

    # Config parse probe: a UTF-8 BOM must not make the parser drop the first
    # key, otherwise the user's hwDecoder setting is silently ignored.
    $cfgDir = Join-Path $OutDir 'cfgparse-probe'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$slf4jForGpu" -d $cfgDir (Join-Path $root 'src\test\java\ConfigParseProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Config parse probe compile failed' }
    $cfgP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$cfgDir;$outClasses;$slf4jForGpu", 'ConfigParseProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$cfgDir\stdout.txt" -RedirectStandardError "$cfgDir\stderr.txt"
    Get-Content "$cfgDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($cfgP.ExitCode -ne 0) { throw 'Config parse probe FAILED (the parser does not handle a UTF-8 BOM)' }
    Write-Host 'Config parse probe OK' -ForegroundColor Green

    # Mixin target guard probe: the guard that turns a silent mixin skip into
    # a visible warning must be verified against real stub classes.
    $gdDir = Join-Path $OutDir 'guard-probe'
    New-Item -ItemType Directory -Force -Path $gdDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$slf4jForGpu" -d $gdDir (Join-Path $root 'src\test\java\MixinTargetGuardProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Mixin target guard probe compile failed' }
    $gdP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$gdDir;$outClasses;$slf4jForGpu", 'MixinTargetGuardProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$gdDir\stdout.txt" -RedirectStandardError "$gdDir\stderr.txt"
    Get-Content "$gdDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($gdP.ExitCode -ne 0) { throw 'Mixin target guard probe FAILED (the guard does not detect the silent skip)' }
    Write-Host 'Mixin target guard probe OK' -ForegroundColor Green

    # Startup log truth probe: the startup line must show the value that is
    # actually in effect, not the raw string the user typed.
    $slDir = Join-Path $OutDir 'startuplog-probe'
    New-Item -ItemType Directory -Force -Path $slDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$slf4jForGpu" -d $slDir (Join-Path $root 'src\test\java\StartupLogTruthProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Startup log truth probe compile failed' }
    $slP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$slDir;$outClasses;$slf4jForGpu", 'StartupLogTruthProbe') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput "$slDir\stdout.txt" -RedirectStandardError "$slDir\stderr.txt"
    Get-Content "$slDir\stdout.txt" -ErrorAction SilentlyContinue | Select-String -Pattern '\[FAIL\]|通过 \d+|RESULT' | ForEach-Object { Write-Host $_ }
    if ($slP.ExitCode -ne 0) { throw 'Startup log truth probe FAILED (the startup line does not show the effective value)' }
    Write-Host 'Startup log truth probe OK' -ForegroundColor Green

    # Forensics vout probe: the diagnostics file must not say "vout=null"
    # when the user deliberately set vout=original.
    $fvDir = Join-Path $OutDir 'forensicsvout-probe'
    New-Item -ItemType Directory -Force -Path $fvDir | Out-Null
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$slf4jForGpu" -d $fvDir (Join-Path $root 'src\test\java\ForensicsVoutProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Forensics vout probe compile failed' }
    $fvP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$fvDir;$outClasses;$slf4jForGpu", 'ForensicsVoutProbe') `
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
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$slf4jForGpu" -d $ukDir (Join-Path $root 'src\test\stubs\slf4j\test\slf4j\CapturingServiceProvider.java')
    if ($LASTEXITCODE -ne 0) { throw 'Unknown key probe: capturing slf4j provider compile failed' }
    New-Item -ItemType Directory -Force -Path (Join-Path $ukDir 'META-INF\services') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ukDir 'META-INF\services\org.slf4j.spi.SLF4JServiceProvider'), "test.slf4j.CapturingServiceProvider`n", (New-Object System.Text.UTF8Encoding($false)))
    & $javac -encoding UTF-8 -proc:none -cp "$ukDir;$outClasses;$slf4jForGpu" -d $ukDir (Join-Path $root 'src\test\java\UnknownConfigKeyProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Unknown config key probe compile failed' }
    $ukP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$ukDir;$outClasses;$slf4jForGpu", 'UnknownConfigKeyProbe') `
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
    & $javac -encoding UTF-8 -proc:none -cp "$outClasses;$mixinForAr;$slf4jForGpu" -d $neDir (Join-Path $root 'src\test\java\NullElementProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'Null element probe compile failed' }
    $neP = Start-Process -FilePath $javaExe -ArgumentList @('-cp', "$neDir;$outClasses;$mixinForAr;$slf4jForGpu", 'NullElementProbe') `
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
}
finally { Pop-Location }
