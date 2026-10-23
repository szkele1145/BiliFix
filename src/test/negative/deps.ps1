# Make sure the two dependency jars the negative tests need on the compile
# classpath are in place, and tell the caller where they are.
#
# Why this exists: every negative test compiles a COPY of the production
# sources, and the production sources import org.slf4j / org.spongepowered.
# The classpath was hard-coded to "<repo>\build\fabric\libs\*.jar" - a
# BUILD ARTIFACT. A fresh clone has no build\ directory, so ALL 22
# negative tests failed to compile with "package org.slf4j does not exist"
# before a single assertion ran. The CI hid it (ci-faithful.ps1 downloads
# the jars itself) and the local build hid it (the jars were left over
# from an earlier run). Only a fresh clone exposed it.
#
# So: fetch the jars if they are missing, from whatever is available:
#   1. an explicit directory (BILIFIX_DEPS_DIR)
#   2. out\ci-libs and build\fabric\libs (what the build/CI already fetched)
#   3. a Minecraft library directory (PCL / vanilla launcher) - the game
#      ships both jars
#   4. download from Maven
# The jars are placed in build\fabric\libs, which is where the negative
# tests already look, so the existing classpath lines keep working.
#
# Returns the resolved classpath string (';'-joined) or $null. The caller
# must FAIL LOUDLY on $null: compiling against an empty classpath produces
# a confusing "package org.slf4j does not exist" instead of "the
# dependency is missing".
function Initialize-DepJars {
    param([string]$RepoRoot)

    $deps = @(
        @{ name = 'slf4j-api-2.0.7.jar'; url = 'https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.7/slf4j-api-2.0.7.jar' },
        @{ name = 'mixin-0.8.5.jar';     url = 'https://repo.spongepowered.org/repository/maven-public/org/spongepowered/mixin/0.8.5/mixin-0.8.5.jar' }
    )

    $cacheDir = Join-Path $RepoRoot 'build\fabric\libs'
    $searchDirs = @()
    if ($env:BILIFIX_DEPS_DIR) { $searchDirs += $env:BILIFIX_DEPS_DIR }
    $searchDirs += (Join-Path $RepoRoot 'out\ci-libs')
    $searchDirs += $cacheDir
    # Minecraft library directories: the game ships both jars.
    $searchDirs += 'D:\PCL2\.minecraft\libraries'
    $searchDirs += (Join-Path $env:APPDATA '.minecraft\libraries')

    $paths = @()
    foreach ($dep in $deps) {
        $cached = Join-Path $cacheDir $dep.name
        if (-not (Test-Path $cached)) {
            $hit = $null
            foreach ($dir in $searchDirs) {
                if (-not $dir -or -not (Test-Path $dir)) { continue }
                $cand = Get-ChildItem $dir -Recurse -Filter $dep.name -ErrorAction SilentlyContinue -Depth 4 |
                        Select-Object -First 1
                if ($cand) { $hit = $cand.FullName; break }
            }
            if ($hit) {
                New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
                Copy-Item $hit $cached -Force
            } else {
                try {
                    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
                    Invoke-WebRequest -Uri $dep.url -OutFile $cached -UseBasicParsing
                } catch {
                    Write-Host ("  依赖获取失败: " + $dep.name + " (" + $_.Exception.Message + ")")
                }
            }
        }
        if (Test-Path $cached) { $paths += $cached }
        else { return $null }
    }
    return ($paths -join ';')
}
