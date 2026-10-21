$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Negative test for DocStructureProbe.
#
# Purpose: a probe that cannot fail proves nothing. This breaks the
# CHANGELOG in a COPY - splitting a "### 修复" heading into
#   "### 修"  /  ""  /  "复"
# which is the exact damage this project already produced once (a
# String.Replace with an anchor that crossed a newline pushed the last
# character of the heading onto the next line).
#
# The damage is INVISIBLE to a build: the file is still valid Markdown,
# it just renders with an empty section and a stray paragraph. So
# without this probe the release notes could silently rot.

$d = 'C:\Users\一只屑\Desktop\BiliFix'
$javac = "$d\.tools\jdk21\bin\javac.exe"
$java  = "$d\.tools\jdk21\bin\java.exe"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$tmp = Join-Path $env:TEMP ('bilifix-neg-docstruct-' + [guid]::NewGuid().ToString('N').Substring(0,8))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host "[neg] 准备临时目录: $tmp"

# 1) copy CHANGELOG.md and break a heading
$src = "$d\CHANGELOG.md"
if (-not (Test-Path $src)) { Write-Host '[neg] 失败：找不到 CHANGELOG.md'; exit 1 }
$text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)

$idx = $text.IndexOf('### 修复')
if ($idx -lt 0) { Write-Host 'ANCHOR_HEADING_NOT_FOUND'; exit 1 }
# split the heading: keep "### 修" on its own line, then a blank line, then "复"
$broken = $text.Substring(0, $idx + 5) + "`r`n`r`n复" + $text.Substring($idx + 7)
$brokenPath = Join-Path $tmp 'CHANGELOG.md'
[System.IO.File]::WriteAllText($brokenPath, $broken, $utf8NoBom)
Write-Host '[neg] 已破坏：把一个 "### 修复" 标题拆成 "### 修" / "" / "复"'

# 2) compile the probe
& $javac -encoding UTF-8 -proc:none -d $tmp "$d\src\test\java\DocStructureProbe.java" 2>&1 |
    Select-Object -First 5 | ForEach-Object { "  $($_.ToString())" }
if ($LASTEXITCODE -ne 0) { Write-Host '[neg] 失败：探针编译不过'; exit 1 }

# 3) run against the BROKEN copy - it MUST fail
$proc = Start-Process -FilePath $java -ArgumentList @('-cp', $tmp, 'DocStructureProbe', $brokenPath) `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $tmp `
        -RedirectStandardOutput "$tmp\stdout.txt" -RedirectStandardError "$tmp\stderr.txt"

Write-Host '[neg] 探针输出：'
Get-Content "$tmp\stdout.txt" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Write-Host '[neg] 失败：探针对坏掉的 CHANGELOG PASS 了 —— 断言无效！'
    exit 1
}
Write-Host ("[neg] 探针在坏掉的 CHANGELOG 上失败（exit {0}）—— 断言有效" -f $proc.ExitCode)
Write-Host 'NEGATIVE_TEST_OK'
exit 0
