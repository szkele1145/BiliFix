# 负向测试：还原 JarToolMixin 的 null 元素防御后，NullElementProbe 必须失败
#
# 原理：探针断言"参数数组里的 null 元素不能让加固逻辑抛 NPE"。
# 把两处防御都删掉（循环里的 null 跳过 + isValue 的 null 判断），
# 探针的行为断言必须失败（NPE 从 mixin 冒出去）。
#
# 关键：探针的源码级断言以**源码路径为参数**，读的是这份**副本**，
# 而不是工作副本——否则断言会检查没被还原的文件，对坏代码假 PASS。

$ErrorActionPreference = 'Stop'
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'
$tmp = Join-Path $env:TEMP ("bilifix-neg-nullelem-" + [guid]::NewGuid().ToString('N').Substring(0,8))
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
exit 1
}
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Write-Host "[neg] 准备临时副本: $tmp"

# 1) 复制被测源码
$srcDir = Join-Path $tmp 'src\dev\polaris_fix\bilifix\mixin'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
Copy-Item (Join-Path $repo 'src\main\java\dev\polaris_fix\bilifix\mixin\JarToolMixin.java') (Join-Path $srcDir 'JarToolMixin.java')

# 2) 还原：删掉两处 null 防御
$mix = Join-Path $srcDir 'JarToolMixin.java'
$text = [System.IO.File]::ReadAllText($mix, [System.Text.Encoding]::UTF8)

$nullGuard = @'
            if (arg == null) continue;
'@
$isValueGuard = '        return s != null && !s.startsWith("-");'

if (-not $text.Contains($nullGuard)) { Write-Host "[neg] 失败：没找到循环里的 null 防御"; exit 1 }
if (-not $text.Contains($isValueGuard)) { Write-Host "[neg] 失败：没找到 isValue 的 null 判断"; exit 1 }

$text = $text.Replace($nullGuard, '')
$text = $text.Replace($isValueGuard, '        return !s.startsWith("-");')
[System.IO.File]::WriteAllText($mix, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[neg] 已还原：移除两处 null 防御"

# 3) 编译还原后的生产源码 + 探针
$jdk = $jdkBin
$mixinJar = (Get-ChildItem (Join-Path $repo 'build\fabric\libs') -Filter 'mixin-*.jar' | Select-Object -First 1).FullName
$slf4jJar = (Get-ChildItem (Join-Path $repo 'build\fabric\libs') -Filter 'slf4j-api-*.jar' | Select-Object -First 1).FullName
$cpJars = "$mixinJar;$slf4jJar"
$classes = Join-Path $tmp 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null

$prodSources = @((Join-Path $tmp 'src\dev\polaris_fix\bilifix\mixin\JarToolMixin.java'))
$rest = Get-ChildItem (Join-Path $repo 'src\main\java') -Recurse -Filter '*.java' |
    Where-Object { $_.Name -ne 'JarToolMixin.java' } | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem (Join-Path $repo 'src\test\stubs\ci') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }

$args = @('-encoding','UTF-8','-proc:none','-cp',$cpJars,'-d',$classes) + $prodSources + $rest + $stubs
& (Join-Path $jdk 'javac.exe') @args 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "[neg] 失败：还原后源码编译不过"; exit 1 }

& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -proc:none -cp "$classes;$cpJars" -d $classes (Join-Path $repo 'src\test\java\NullElementProbe.java') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "[neg] 失败：探针编译不过"; exit 1 }

# 4) 跑探针 —— 必须失败
$o = Join-Path $tmp 'probe-out.txt'
$e = Join-Path $tmp 'probe-err.txt'
$proc = Start-Process -FilePath (Join-Path $jdk 'java.exe') `
    -ArgumentList @('-cp', "$classes;$cpJars", 'NullElementProbe', $mix) `
    -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
    -RedirectStandardOutput $o -RedirectStandardError $e

Write-Host "[neg] 探针输出："
Get-Content $o -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

if ($proc.ExitCode -eq 0) {
    Write-Host "[neg] 失败：探针对坏代码 PASS 了 —— 断言无效！"
    exit 1
}
Write-Host ("[neg] 探针在坏代码上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host "NEGATIVE_TEST_OK"
exit 0
