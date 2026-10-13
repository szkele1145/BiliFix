# Build script (PowerShell, Windows)
# Requires: local Minecraft runtime JDK (javac/jar), NeoForge 21.1 libs, mixin 0.8.5, watermedia jar
# Usage: ./build.ps1 [-WatermediaJar <path>] [-OutDir <dir>]

param(
    [string]$WatermediaJar = "C:\Users\一只屑\AppData\Local\Temp\bm_analysis\water.jar",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
# Locate script dir ($PSScriptRoot can be empty in some invocation styles)
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'build' }
$javac = 'C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\javac.exe'
$jar = 'C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\jar.exe'
$javaExe = 'C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\java.exe'
$lib = 'D:\PCL2\.minecraft\libraries'

if (-not (Test-Path $javac)) { throw "javac not found: $javac (Minecraft runtime JDK required)" }
if (-not (Test-Path $WatermediaJar)) { Write-Warning "watermedia jar not found ($WatermediaJar) - compile continues (@Pseudo target missing is only a warning)" }

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

# Package (reproducible: pin file timestamps to 1980-01-01, eliminating build-time hash drift)
$stage = "$OutDir\jar"
Copy-Item "$OutDir\classes\dev" "$stage\dev" -Recurse -Force
Copy-Item "$root\src\main\resources\bilifix.mixins.json" "$stage\" -Force
Copy-Item "$root\src\main\resources\META-INF\neoforge.mods.toml" "$stage\META-INF\" -Force
# Normalize mtimes of all files AND directories to be packaged (jar entry times come from mtime)
$fixedTime = Get-Date '1980-01-01 00:00:00'
Get-ChildItem $stage -Recurse | ForEach-Object { $_.LastWriteTime = $fixedTime }
@"
Manifest-Version: 1.0
Implementation-Title: BiliFix
Implementation-Version: $version
MixinConfigs: bilifix.mixins.json
"@ | Out-File "$OutDir\MANIFEST.MF" -Encoding ascii
(Get-Item "$OutDir\MANIFEST.MF").LastWriteTime = $fixedTime
Push-Location $stage
& $jar cfm "$OutDir\BiliFix-$version.jar" "$OutDir\MANIFEST.MF" dev bilifix.mixins.json META-INF/neoforge.mods.toml
Pop-Location
# Post-process: patch META-INF entry timestamps written by the jar tool with "now"
# (jar cfm stamps META-INF and MANIFEST.MF entries at creation time regardless of source mtime)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = "$OutDir\BiliFix-$version.jar"
$epoch = New-Object System.DateTime(1980, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
$zs = [System.IO.File]::Open($zipPath, 'Open', 'ReadWrite', 'None')
try {
    $za = New-Object System.IO.Compression.ZipArchive($zs, 'Update')
    foreach ($e in $za.Entries) {
        if ($e.FullName -eq 'META-INF/' -or $e.FullName -eq 'META-INF/MANIFEST.MF') {
            $e.LastWriteTime = $epoch
        }
    }
    $za.Dispose()
} finally { $zs.Dispose() }
Write-Host "Packaged: $OutDir\BiliFix-$version.jar ($((Get-Item "$OutDir\BiliFix-$version.jar").Length) bytes)" -ForegroundColor Green
