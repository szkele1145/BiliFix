# 负向测试：还原 BiliFixConfig.load() 的未识别键警告后，UnknownConfigKeyProbe 必须失败
#
# 原理：探针断言的是"写错的配置键必须发出可见警告"。把 load() 里的警告代码
# 删掉（回到修复前的行为——未知键被静默忽略），探针的 5 条警告断言必须失败。
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
$tmp = Join-Path $env:TEMP ("bilifix-neg-unknownkey-" + [guid]::NewGuid().ToString('N').Substring(0,8))
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
$srcDir = Join-Path $tmp 'src\dev\polaris_fix\bilifix\config'
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
Copy-Item (Join-Path $repo 'src\main\java\dev\polaris_fix\bilifix\config\BiliFixConfig.java') (Join-Path $srcDir 'BiliFixConfig.java')

# 2) 还原：删掉未识别键的警告代码
$cfg = Join-Path $srcDir 'BiliFixConfig.java'
$text = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8)

$before = @'
                // 未识别的 key 警告：写错的配置必须可见，否则就是又一条静默失效路径
                // （与 UTF-8 BOM 同族——用户写了配置、文件也"加载成功"、但设置没生效，
                // 且日志里没有任何指向原因的线索）。
                for (String k : kv.keySet()) {
                    if (k.equals("hwDecoder") || k.equals("vout") || k.equals("verbose")) continue;
                    // 忽略大小写后能对上已知键 → 多半是大小写写错，给出可直接照做的提示
                    String lower = k.toLowerCase();
                    if (lower.equals("hwdecoder") || lower.equals("vout") || lower.equals("verbose")) {
                        String correct = lower.equals("hwdecoder") ? "hwDecoder"
                                       : lower.equals("vout") ? "vout" : "verbose";
                        BiliFixMod.LOGGER.warn("[BiliFix] 配置键 '{}' 拼写不对（键名区分大小写），"
                                + "应为 '{}'——本次该设置未生效", k, correct);
                    } else {
                        BiliFixMod.LOGGER.warn("[BiliFix] 配置里有未识别的键 '{}'"
                                + "（已知键: hwDecoder / vout / verbose，区分大小写），该设置被忽略", k);
                    }
                }
'@

if (-not $text.Contains($before)) {
    Write-Host "[neg] 失败：没找到要还原的警告代码块（源码已变？）"
    exit 1
}
$text = $text.Replace($before, '')
[System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[neg] 已还原：移除未识别键警告"

# 3) 编译还原后的生产源码 + 探针
$jdk = $jdkBin
$cpJars = @(
    (Join-Path $repo 'build\fabric\libs\slf4j-api-2.0.7.jar'),
    (Join-Path $repo 'build\fabric\libs\mixin-0.8.5.jar')
) -join ';'
$classes = Join-Path $tmp 'classes'
New-Item -ItemType Directory -Force -Path $classes | Out-Null

$prodSources = @(
    (Join-Path $tmp 'src\dev\polaris_fix\bilifix\config\BiliFixConfig.java')
)
# 还原的 BiliFixConfig 依赖 BiliFixMod / FmlBridge —— 直接用工作副本的其余源码
$rest = Get-ChildItem (Join-Path $repo 'src\main\java') -Recurse -Filter '*.java' |
    Where-Object { $_.Name -ne 'BiliFixConfig.java' } | ForEach-Object { $_.FullName }
$stubs = Get-ChildItem (Join-Path $repo 'src\test\stubs\ci') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
$slfStub = Join-Path $repo 'src\test\stubs\slf4j\test\slf4j\CapturingServiceProvider.java'

$args = @('-encoding','UTF-8','-proc:none','-cp',$cpJars,'-d',$classes) + $prodSources + $rest + $stubs + @($slfStub)
& (Join-Path $jdk 'javac.exe') @args 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "[neg] 失败：还原后源码编译不过"; exit 1 }

# 注册 slf4j provider
New-Item -ItemType Directory -Force -Path (Join-Path $classes 'META-INF\services') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $classes 'META-INF\services\org.slf4j.spi.SLF4JServiceProvider'),
    "test.slf4j.CapturingServiceProvider`n", (New-Object System.Text.UTF8Encoding($false)))

& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -proc:none -cp "$classes;$cpJars" -d $classes (Join-Path $repo 'src\test\java\UnknownConfigKeyProbe.java') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "[neg] 失败：探针编译不过"; exit 1 }

# 4) 跑探针 —— 必须失败
$o = Join-Path $tmp 'probe-out.txt'
$e = Join-Path $tmp 'probe-err.txt'
$proc = Start-Process -FilePath (Join-Path $jdk 'java.exe') `
    -ArgumentList @('-cp', "$classes;$cpJars", 'UnknownConfigKeyProbe', $cfg) `
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
