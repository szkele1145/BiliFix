# Modrinth upload sync: auto-discovers every BiliFix-<ver>-mc<mc>-<loader>.jar in
# build\ that is not yet on Modrinth and uploads it, using the GitHub Release body
# as the changelog. Reads a Modrinth PAT (Create + Edit Version scopes) from
# ~\.dsh\mr.token - it is never committed.
#
# v1.4.8: previously hardcoded to "-mc1.21.1-neoforge.jar" with game_versions
# [1.21.1] and loaders [neoforge] - so the 1.20.1 Forge/Fabric variants could never
# be published at all. Now every variant is discovered and each is uploaded with the
# game version and loader parsed from its own filename. Modrinth's loader tags
# were verified against /v2/tag/loader: "neoforge", "forge" and "fabric" all exist.
# Following JEI's precedent, the same version_number is reused across a version's
# per-loader entries (Modrinth allows it); the skip check is therefore keyed on
# version_number + loader rather than version_number alone.
#
# Usage: ./pending-modrinth.ps1

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$tokenFile = Join-Path $env:USERPROFILE '.dsh\mr.token'
$projectId = 'U6GLOyQ7'
$proxy = 'http://127.0.0.1:65532'
# Bypass the release gate (CHANGELOG promotion) - deliberate overrides only.
$ForceRelease = $args -contains '-ForceRelease'

if (-not (Test-Path $tokenFile)) { throw "token file not found: $tokenFile - place a fresh Modrinth PAT there first" }
$mrToken = (Get-Content $tokenFile -Raw).Trim()

# ---- 0. token sanity check ----
try {
    $me = Invoke-RestMethod -Uri 'https://api.modrinth.com/v2/user' -Headers @{ Authorization = $mrToken } -Proxy $proxy
    Write-Host "token OK for: $($me.username)" -ForegroundColor Green
} catch {
    throw "token invalid (401?) - generate a fresh one at https://modrinth.com/settings/pats (needs Create + Edit Version scopes)"
}

# ---- pending versions ----
# MANUAL LIST below is used when present; otherwise the script AUTO-DISCOVERS
# jars in build\ that are not yet on Modrinth (changelog defaults to the GH Release body).
# A manual entry must carry ver + mcver + loader, matching the BiliFix-<ver>-mc<mcver>-<loader>.jar
# filename - otherwise the upload would look for a jar name that cannot exist.
$manualPending = @(
    @{ ver = ''; mcver = ''; loader = ''; changelog = ''; featured = $false }
) | Where-Object { $_.ver -and $_.mcver -and $_.loader }

# Fetch existing Modrinth versions once. Keyed on version_number+loader because the
# same version_number legitimately appears once per loader (JEI does exactly this).
$existing = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$projectId/version" -Headers @{ Authorization = $mrToken } -Proxy $proxy
$existingKeys = $existing | ForEach-Object { "$($_.version_number)|$(($_.loaders) -join '+')" }

if ($manualPending) {
    $pending = $manualPending
} else {
    # auto-discover every variant jar in build\ that is missing from Modrinth.
    # Filename is the source of truth: BiliFix-<ver>-mc<mcver>-<loader>.jar
    #
    # v1.4.8 fix: the scan used to look at build\ TOP LEVEL only, while the Forge
    # and Fabric variants live in build\forge\ and build\fabric\. Measured:
    # 1 jar visible at top level vs 4 actually built -> the Forge/Fabric variants
    # could still never be published, even after the hardcoded-loader fix.
    # Now the whole build tree is scanned recursively.
    $ghTokenFile = Join-Path $env:USERPROFILE '.dsh\gh.token'
    $ghToken = if (Test-Path $ghTokenFile) { (Get-Content $ghTokenFile -Raw).Trim() }
    $ghRels = if ($ghToken) { Invoke-RestMethod -Uri 'https://api.github.com/repos/szkele1145/BiliFix/releases' -Headers @{ Authorization = "Bearer $ghToken"; 'User-Agent' = 'BiliFix' } -Proxy $proxy }
    $buildDir = Join-Path $root 'build'
    $pending = Get-ChildItem $buildDir -Filter 'BiliFix-*.jar' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.BaseName -notmatch '^BiliFix-(.+)-mc(\d+\.\d+(?:\.\d+)?)-(neoforge|forge|fabric)$') {
            Write-Warning "$($_.Name): filename does not match BiliFix-<ver>-mc<mcver>-<loader>.jar - skipping"
            return
        }
        $ver = $Matches[1]; $mcver = $Matches[2]; $loader = $Matches[3]
        $key = "$ver|$loader"
        if ($existingKeys -contains $key) { return }
        $rel = $ghRels | Where-Object { $_.tag_name -eq "v$ver" }
        $body = if ($rel) { ($rel.body -split "`n" | Where-Object { $_ -notmatch '^#' -and $_.Trim() }) -join ' ' } else { "See the GitHub release notes for v$ver." }
        # keep the resolved path so the upload reads the very jar that was discovered
        @{ ver = $ver; mcver = $mcver; loader = $loader; changelog = $body; featured = $false; path = $_.FullName }
    }
}

if (-not $pending) { Write-Host 'Nothing pending - Modrinth is up to date with build\.' -ForegroundColor Green; return }

$vers = ($pending | ForEach-Object { "$($_.ver)/$($_.loader)" }) -join ', '
Write-Host "Discovered pending versions: $vers" -ForegroundColor Cyan

# ---- release gate (v1.4.8) ----
# Publishing to Modrinth is shipping. The project rule: CHANGELOG "## Unreleased"
# may only be promoted to "## <version>" after the in-game launch validation
# passed on BOTH loaders. Uploading an unvalidated build would put it in front
# of users. Every pending version must therefore be promoted in CHANGELOG.md.
# -ForceRelease bypasses this deliberately.
$unpromoted = @()
$clPath = Join-Path $root 'CHANGELOG.md'
$cl = [System.IO.File]::ReadAllText($clPath, [System.Text.Encoding]::UTF8)
foreach ($p in $pending) {
    $esc = [regex]::Escape($p.ver)
    if (-not [regex]::IsMatch($cl, "(?m)^##\s+$esc\b")) { $unpromoted += "$($p.ver)/$($p.loader)" }
}
if ($unpromoted.Count -gt 0 -and -not $ForceRelease) {
    throw ("these versions are not promoted in CHANGELOG.md: " + ($unpromoted -join ', ') +
           "`n  Publishing to Modrinth means shipping; a version may only be released" +
           "`n  after the in-game launch validation passed (see docs/verification-checklist.md)." +
           "`n  Promote CHANGELOG '## Unreleased' -> '## <version>' first," +
           "`n  or pass -ForceRelease if you really mean to publish now.")
}
if ($unpromoted.Count -gt 0) {
    Write-Warning "publishing unpromoted versions due to -ForceRelease: $($unpromoted -join ', ')" -ForegroundColor Red
}

foreach ($p in $pending) {
    $jarName = "BiliFix-$($p.ver)-mc$($p.mcver)-$($p.loader).jar"
    # Use the path that discovery actually resolved. The old code rebuilt
    # "build\<jarName>", which only exists for the neoforge variant - the Forge
    # and Fabric jars live in build\forge\ and build\fabric\.
    $jarPath = if ($p.path -and (Test-Path $p.path)) { $p.path } else { Join-Path $root "build\$jarName" }
    if (-not (Test-Path $jarPath)) {
        # fall back: search the whole build tree for this exact jar name
        $found = Get-ChildItem (Join-Path $root 'build') -Filter $jarName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $jarPath = $found.FullName }
        else { Write-Warning "$jarName not found under build\ - skipping"; continue }
    }

    # skip if this exact (version, loader) pair is already on Modrinth
    if ($existingKeys -contains "$($p.ver)|$($p.loader)") { Write-Host "$($p.ver)/$($p.loader): already on Modrinth - skip" -ForegroundColor Yellow; continue }

    $boundary = "----BiliFixBoundary$([Guid]::NewGuid().ToString('N'))"
    $versionObj = [PSCustomObject]@{
        project_id = $projectId
        file_parts = @($jarName)
        version_title = "BiliFix $($p.ver) ($($p.loader) $($p.mcver))"
        version_number = $p.ver
        changelog = $p.changelog
        version_type = 'release'
        game_versions = @($p.mcver)
        loaders = @($p.loader)
        featured = $p.featured
        dependencies = @(
            # BiliBiliMedia is genuinely required (the fix only matters alongside it);
            # WATERMEDIA stays optional. Keep this in sync with the Modrinth project page.
            [PSCustomObject]@{ project_id = 'vqvS4GPe'; dependency_type = 'required' },
            [PSCustomObject]@{ project_id = 'G922NeHS'; dependency_type = 'optional' }
        )
    }
    $versionJson = $versionObj | ConvertTo-Json -Depth 5
    $enc = [System.Text.Encoding]::UTF8
    $ms = New-Object System.IO.MemoryStream
    $d = $enc.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"data`"`r`nContent-Type: application/json`r`n`r`n$versionJson`r`n")
    $ms.Write($d, 0, $d.Length)
    $d = $enc.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"$jarName`"; filename=`"$jarName`"`r`nContent-Type: application/java-archive`r`n`r`n")
    $ms.Write($d, 0, $d.Length)
    $jb = [System.IO.File]::ReadAllBytes($jarPath)
    $ms.Write($jb, 0, $jb.Length)
    $d = $enc.GetBytes("`r`n--$boundary--`r`n")
    $ms.Write($d, 0, $d.Length)
    $payload = $ms.ToArray()

    $req = [System.Net.HttpWebRequest]::Create('https://api.modrinth.com/v2/version')
    $req.Method = 'POST'; $req.Proxy = New-Object System.Net.WebProxy($proxy)
    $req.ContentType = "multipart/form-data; boundary=$boundary"
    $req.Headers.Add('Authorization', $mrToken)
    $req.UserAgent = 'BiliFix-pending'
    $req.ContentLength = $payload.Length
    $s = $req.GetRequestStream(); $s.Write($payload, 0, $payload.Length); $s.Close()
    try {
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $result = ($sr.ReadToEnd() | ConvertFrom-Json)
        Write-Host "$($p.ver): uploaded, id=$($result.id)" -ForegroundColor Green
    } catch [System.Net.WebException] {
        $esr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        Write-Warning "$($p.ver): upload FAILED - $($esr.ReadToEnd())"
        continue
    }
}

# ---- verify ----
$v2 = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$projectId/version" -Headers @{ Authorization = $mrToken } -Proxy $proxy
Write-Host "`nModrinth now has $($v2.Count) versions:"
$v2 | ForEach-Object { Write-Host "  $($_.version_number): $($_.files[0].filename)" }
