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
    Write-Warning 'bilifix.mixins.json: no "compatibilityLevel": "JAVA_21" found - source may have changed'
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
    $stubSrcs = Get-ChildItem (Join-Path $root 'src\test\stubs') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp $outClasses -d $fmlDir @stubSrcs (Join-Path $root 'src\test\java\FmlBridgeProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe compile failed' }
    & $javaExe -cp "$fmlDir;$outClasses" FmlBridgeProbe
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe FAILED (fmlDir chain or the no-throw contract broke)' }
    Write-Host 'FmlBridge probe OK' -ForegroundColor Green

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
}
finally { Pop-Location }
