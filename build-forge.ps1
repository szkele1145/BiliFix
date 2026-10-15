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
    # MC runtime is a trimmed JRE (no javac) - probe local JDKs instead
    foreach ($probe in @("$env:USERPROFILE\.jdks\ms-17.0.19\bin\javac.exe", 'C:\jdk17\bin\javac.exe')) {
        if (Test-Path $probe) { $javac = $probe; break }
    }
}
if (-not $javac) { throw 'no JDK found: set BILIFIX_JAVAC or install one (.jdks/ms-17.0.19 expected for --release 17)' }
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
Copy-Item (Join-Path $root 'src\main\resources\bilifix.mixins.json') "$stage\" -Force
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
