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
    Write-Warning 'bilifix.mixins.json: no "compatibilityLevel": "JAVA_21" found - source may have changed'
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
    $stubSrcs = Get-ChildItem (Join-Path $root 'src\test\stubs') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
    & $javac -encoding UTF-8 -proc:none -cp (Join-Path $OutDir 'classes') -d $fmlDir @stubSrcs (Join-Path $root 'src\test\java\FmlBridgeProbe.java')
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe compile failed' }
    & $javaExe -cp "$fmlDir;$(Join-Path $OutDir 'classes')" FmlBridgeProbe
    if ($LASTEXITCODE -ne 0) { throw 'FmlBridge probe FAILED (fmlDir chain or the no-throw contract broke)' }
    Write-Host 'FmlBridge probe OK' -ForegroundColor Green

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
}
finally { Pop-Location }
