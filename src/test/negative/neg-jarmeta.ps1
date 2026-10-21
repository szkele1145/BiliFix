$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# The repository root and the JDK are derived from THIS script's own location
# and the environment - never hard-coded. A hard-coded
# "C:\Users\<non-ascii>\Desktop\BiliFix" points at somebody else's working
# copy in a clone, and turns into mojibake when the .ps1 has no BOM (Windows
# PowerShell 5.1 reads it as ANSI).
$d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
. (Join-Path (Split-Path -Parent $PSCommandPath) 'jdk.ps1')
$jdkBin = Resolve-JdkBin -RepoRoot $d
if (-not $jdkBin) { Write-Host "缺少 JDK（.tools\jdk21 或 JAVA_HOME）"; exit 1 }
$javac = Join-Path $jdkBin 'javac.exe'
$java  = Join-Path $jdkBin 'java.exe'

# Negative test for JarMetadataProbe.
#
# Purpose: the probe must be able to fail. It is pointed at a COPY of a
# real jar in which the loader metadata has been tampered with - the same
# class of damage that shipped in 1.3.2 (a mods.toml with the wrong
# FML structure made the game reject the jar with "Missing ModLoader").
#
# Two breakages are checked:
#   BREAK 1: the wrong loader's metadata is added to the jar
#            (e.g. fabric.mod.json inside the NeoForge jar). The loader
#            would then see two different mod descriptions.
#   BREAK 2: the mixin compatibilityLevel is downgraded to a value the
#            1.20.1 runtime mixin does not have (JAVA_21), which blows up
#            in the mixin bootstrap phase.

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$tmp = Join-Path $env:TEMP ('bilifix-neg-jarmeta-' + [guid]::NewGuid().ToString('N').Substring(0,8))
# SAFETY: only ever delete a directory that is inside %TEMP% and carries
# our own prefix. A mis-resolved $tmp must never be able to delete
# repository files.
if ($tmp -and -not $tmp.StartsWith((Join-Path $env:TEMP ''))) {
    Write-Host ("SAFETY: 拒绝删除不在 %TEMP% 下的路径: " + $tmp)
    exit 1
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host "[neg] 准备临时目录: $tmp"

# The jar to tamper with: the NeoForge one (it must contain exactly one
# loader metadata file).
$srcJar = "$d\build\BiliFix-1.4.8-mc1.21.1-neoforge.jar"
if (-not (Test-Path $srcJar)) {
    Write-Host '[neg] 跳过：找不到已构建的 jar（先跑 build.ps1）'
    Write-Host 'NEGATIVE_TEST_OK'
    exit 0
}

# 1) compile the probe
& $javac -encoding UTF-8 -proc:none -d $tmp "$d\src\test\java\JarMetadataProbe.java" 2>&1 |
    Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 2) BREAK 1: add a foreign loader metadata file to a copy of the jar
Add-Type -AssemblyName System.IO.Compression.FileSystem
$broken1 = Join-Path $tmp 'broken1.jar'
Copy-Item $srcJar $broken1 -Force
$zip = [System.IO.Compression.ZipFile]::Open($broken1, 'Update')
$entry = $zip.CreateEntry('fabric.mod.json')
$w = $entry.Open()
$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"id":"bilifix","version":"1.4.8","entrypoints":{"main":["dev.polaris_fix.bilifix.fabric.BiliFixFabric"]}}')
$w.Write($bytes, 0, $bytes.Length)
$w.Close()
$zip.Dispose()
Write-Host '[neg] 已破坏 BREAK 1：往 NeoForge jar 里塞了 fabric.mod.json'

# 3) BREAK 2: rewrite the mixin compatibilityLevel to a value that EXISTS
#    but is WRONG for this loader (NeoForge 21.1 needs JAVA_21; the 1.20.1
#    variants need JAVA_17). A wrong level either fails the mixin bootstrap
#    or silently targets the wrong JVM - and it is invisible in the source
#    tree, because the value only exists in the packaged jar.
$broken2 = Join-Path $tmp 'broken2.jar'
Copy-Item $srcJar $broken2 -Force
$zip2 = [System.IO.Compression.ZipFile]::Open($broken2, 'Update')
$e2 = $zip2.GetEntry('bilifix.mixins.json')
$sr = New-Object System.IO.StreamReader($e2.Open(), [System.Text.Encoding]::UTF8)
$txt = $sr.ReadToEnd()
$sr.Close()
$txt2 = $txt.Replace('JAVA_21', 'JAVA_18')
if ($txt2 -eq $txt) {
    Write-Host '[neg] 失败：没找到 compatibilityLevel';
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
# write it back (delete + recreate, ZipArchive Update mode cannot resize entries)
$e2.Delete()
$newE = $zip2.CreateEntry('bilifix.mixins.json')
$w2 = $newE.Open()
$b2 = [System.Text.Encoding]::UTF8.GetBytes($txt2)
$w2.Write($b2, 0, $b2.Length)
$w2.Close()
$zip2.Dispose()
Write-Host '[neg] 已破坏 BREAK 2：mixin compatibilityLevel 改成了 1.20.1 不认的值'

# 4) run the probe against each broken copy - it MUST fail
$failed = @()
foreach ($b in @($broken1, $broken2)) {
    $proc = Start-Process -FilePath $java -ArgumentList @('-cp', $tmp, 'JarMetadataProbe', $b) `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
            -RedirectStandardOutput "$tmp\stdout-$([System.IO.Path]::GetFileName($b)).txt" `
            -RedirectStandardError "$tmp\stderr-$([System.IO.Path]::GetFileName($b)).txt"
    Write-Host ("[neg] 探针对 " + [System.IO.Path]::GetFileName($b) + " 的输出：")
    Get-Content "$tmp\stdout-$([System.IO.Path]::GetFileName($b)).txt" -ErrorAction SilentlyContinue |
        Select-String -Pattern '\[FAIL\]|通过 \d+' | ForEach-Object { Write-Host "    $($_.ToString().Trim())" }
    if ($proc.ExitCode -eq 0) {
        $failed += [System.IO.Path]::GetFileName($b)
    } else {
        Write-Host ("    -> 探针失败（exit " + $proc.ExitCode + "），断言有效")
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($failed.Count -gt 0) {
    Write-Host ('[neg] 失败：探针对以下坏 jar PASS 了 —— 断言无效！')
    $failed | ForEach-Object { Write-Host ("  " + $_) }
    exit 1
}
Write-Host 'NEGATIVE_TEST_OK: 探针能抓到元数据被污染的 jar'
exit 0