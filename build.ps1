# Build script (PowerShell, Windows)
# Requires: local Minecraft runtime JDK (javac/jar), NeoForge 21.1 libs, mixin 0.8.5, watermedia jar
# Usage: ./build.ps1 [-WatermediaJar <path>] [-OutDir <dir>]

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
    # Probe common Minecraft runtime JDK locations (PCL / vanilla launcher layouts)
    $home2 = $env:USERPROFILE
    $candidates = @(
        "$env:APPDATA\.minecraft\runtime\java-runtime-delta\bin\javac.exe",
        "$home2\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\javac.exe",
        "C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\javac.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $javac = $c; break } }
}
if (-not $javac) { throw "javac not found. Set BILIFIX_JAVAC=<path to javac.exe> or add a JDK 21 to PATH" }
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

# Version (read from mods.toml)
$toml = Get-Content "$root\src\main\resources\META-INF\neoforge.mods.toml" -Raw -Encoding UTF8
if ($toml -match 'version="([^"]+)"') { $version = $Matches[1] } else { throw "cannot read version from mods.toml" }
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

# Package
# NOTE: no timestamp post-processing - patching entry times via ZipArchive Update mode
# corrupted the jar (DOS timestamp epoch boundary at 1980-01-01 produced an invalid
# central directory: "invalid entry size (expected 0 but got 154 bytes)" at game load).
# The jar tool's META-INF timestamps being "now" is harmless; correctness > reproducibility.
$stage = "$OutDir\jar"
Copy-Item "$OutDir\classes\dev" "$stage\dev" -Recurse -Force
Copy-Item "$root\src\main\resources\bilifix.mixins.json" "$stage\" -Force
Copy-Item "$root\src\main\resources\META-INF\neoforge.mods.toml" "$stage\META-INF\" -Force
@"
Manifest-Version: 1.0
Implementation-Title: BiliFix
Implementation-Version: $version
MixinConfigs: bilifix.mixins.json
"@ | Out-File "$OutDir\MANIFEST.MF" -Encoding ascii
Push-Location $stage
& $jar cfm "$OutDir\BiliFix-$version.jar" "$OutDir\MANIFEST.MF" dev bilifix.mixins.json META-INF/neoforge.mods.toml
Pop-Location
Write-Host "Packaged: $OutDir\BiliFix-$version.jar ($((Get-Item "$OutDir\BiliFix-$version.jar").Length) bytes)" -ForegroundColor Green
