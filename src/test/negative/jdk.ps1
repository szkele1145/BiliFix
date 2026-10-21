# Resolve the JDK: the project's own toolchain first, then JAVA_HOME.
#
# The GitHub runner has a complete JDK in JAVA_HOME (actions/setup-java) and
# no .tools/jdk21 - the project toolchain is git-ignored. Copying just
# java.exe + javac.exe into .tools/jdk21 does NOT work: JDK 21 is modular,
# so javac.exe needs the jdk.compiler module from lib/ and fails with
# "Module jdk.compiler not found".
#
# Returns $null when neither is usable.
function Resolve-JdkBin {
    $candidates = @()
    $projectJdk = Join-Path (Get-Location) '.tools\jdk21\bin'
    if (Test-Path (Join-Path $projectJdk 'javac.exe')) { $candidates += $projectJdk }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
        $candidates += (Join-Path $env:JAVA_HOME 'bin')
    }
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'javac.exe')) { return $c }
    }
    return $null
}
