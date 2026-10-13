# 构建脚本（PowerShell，Windows）
# 依赖：本地 Minecraft 运行时 JDK（javac/jar），NeoForge 21.1 + mixin 0.8.5 + watermedia jar
# 用法：./build.ps1 [-WatermediaJar <path>] [-OutDir <dir>]

param(
    [string]$WatermediaJar = "C:\Users\一只屑\AppData\Local\Temp\bm_analysis\water.jar",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
# 定位脚本目录（$PSScriptRoot 在某些调用方式下为空）
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'build' }
$javac = 'C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\javac.exe'
$jar = 'C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\jar.exe'
$javaExe = 'C:\Users\一只屑\AppData\Roaming\.minecraft\runtime\java-runtime-delta\bin\java.exe'
$lib = 'D:\PCL2\.minecraft\libraries'

if (-not (Test-Path $javac)) { throw "javac 未找到: $javac（需要 Minecraft 运行时 JDK）" }
if (-not (Test-Path $WatermediaJar)) { Write-Warning "watermedia jar 未找到（$WatermediaJar）—— 编译仍可进行（@Pseudo 目标缺失仅告警）" }

# 版本号（从 mods.toml 读取）
$toml = Get-Content "$root\src\main\resources\META-INF\neoforge.mods.toml" -Raw -Encoding UTF8
if ($toml -match 'version="([^"]+)"') { $version = $Matches[1] } else { throw "无法从 mods.toml 读取版本号" }
Write-Host "构建 BiliFix v$version"

# classpath
$cp = @(
    "$lib\org\spongepowered\mixin\0.8.5\mixin-0.8.5.jar",
"$lib\net\neoforged\fancymodloader\loader\4.0.45\loader-4.0.45.jar",
    "$lib\net\neoforged\mergetool\2.0.0\mergetool-2.0.0-api.jar",
    "$lib\net\neoforged\neoforge\21.1.248\neoforge-21.1.248-universal.jar",
    "$lib\org\slf4j\slf4j-api\2.0.7\slf4j-api-2.0.7.jar",
    "D:\PCL2\.minecraft\versions\航空学这一块\航空学这一块.jar",
    $WatermediaJar
) -join ';'

# 清理 + 编译
Remove-Item "$OutDir\classes","$OutDir\jar" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$OutDir\classes","$OutDir\jar\META-INF" | Out-Null
$srcs = Get-ChildItem "$root\src\main\java" -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
# 2>$null 静默 javac 对引用注解的枚举校验警告（非致命）
$jargs = @("--release","21","-encoding","UTF-8","-proc:none","-cp",$cp,"-d","$OutDir\classes") + $srcs
$p = Start-Process -FilePath $javac -ArgumentList $jargs -NoNewWindow -Wait -PassThru -RedirectStandardError "$OutDir\javac-stderr.txt" -RedirectStandardOutput "$OutDir\javac-stdout.txt"
if ($p.ExitCode -ne 0) { Get-Content "$OutDir\javac-stderr.txt" -ErrorAction SilentlyContinue; throw "编译失败" }
Write-Host "编译完成" -ForegroundColor Green

# 回归测试
if (Test-Path "$root\src\test\java\Regression.java") {
    New-Item -ItemType Directory -Force -Path "$OutDir\test" | Out-Null
    & $javac -encoding UTF-8 -d "$OutDir\test" "$root\src\test\java\Regression.java"
    & $javaExe -cp "$OutDir\test" Regression
    if ($LASTEXITCODE -ne 0) { throw "回归测试失败" }
    Write-Host "回归测试通过" -ForegroundColor Green
}

# 打包
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
Write-Host "打包完成: $OutDir\BiliFix-$version.jar ($((Get-Item "$OutDir\BiliFix-$version.jar").Length) bytes)" -ForegroundColor Green
