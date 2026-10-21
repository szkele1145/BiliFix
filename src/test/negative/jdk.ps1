# Resolve the JDK: the project's own toolchain first, then JAVA_HOME.
#
# The GitHub runner has a complete JDK in JAVA_HOME (actions/setup-java) and
# no .tools/jdk21 - the project toolchain is git-ignored. Copying just
# java.exe + javac.exe into .tools/jdk21 does NOT work: JDK 21 is modular,
# so javac.exe needs the jdk.compiler module from lib/ and fails with
# "Module jdk.compiler not found".
#
# The repository root is a PARAMETER, not something guessed from the current
# directory: the negative tests are started from whatever directory the
# caller happens to be in, and a helper that reads Get-Location silently
# depends on that. Returns $null when neither JDK is usable.
function Resolve-JdkBin {
    param([string]$RepoRoot)
    $candidates = @()
    if ($RepoRoot) {
        $projectJdk = Join-Path $RepoRoot '.tools\jdk21\bin'
        if (Test-Path (Join-Path $projectJdk 'javac.exe')) { $candidates += $projectJdk }
    }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
        $candidates += (Join-Path $env:JAVA_HOME 'bin')
    }
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'javac.exe')) { return $c }
    }
    return $null
}
