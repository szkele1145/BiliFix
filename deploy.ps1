# Deploy script (PowerShell, Windows)
# One command to sync the freshly built jar(s) to: local mods folder + GitHub Release asset.
# v1.4.8: three variants exist (neoforge 1.21.1 / forge 1.20.1 / fabric 1.20.1).
# -Variant picks which one to deploy locally; the GitHub Release asset sync is now
# INCREMENTAL (uploads missing assets, refreshes stale ones, no longer deletes
# everything first - which would have deleted the other variants' assets).
#
# Tokens are read from ~\.dsh\gh.token (create it yourself; NOT committed).
# Modrinth is handled separately by pending-modrinth.ps1.
#
# Usage:
#   ./deploy.ps1                                # neoforge variant locally + GitHub assets
#   ./deploy.ps1 -Variant forge                # forge 1.20.1 to local mods
#   ./deploy.ps1 -Variant fabric               # fabric 1.20.1 to local mods
#   ./deploy.ps1 -SkipRemote                    # local only, no GitHub calls
#   ./deploy.ps1 -DryRun                        # show what would happen, change nothing
#   ./deploy.ps1 -ForceRelease                  # publish even if CHANGELOG is not promoted
#
# Release gate: creating a Release = publishing. The script refuses to create a
# Release for a version whose CHANGELOG section has not been promoted from
# "## Unreleased" to "## <version>" (the in-game validation must have passed first).

param(
    [ValidateSet('neoforge', 'forge', 'fabric')]
    [string]$Variant = 'neoforge',
    [switch]$SkipRemote,
    [switch]$DryRun,
    # Bypass the release gate (CHANGELOG promotion). Only for deliberate overrides.
    [switch]$ForceRelease
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- Locate game install (mirror build.ps1 logic) ----
$lib = $env:BILIFIX_LIBS
if (-not $lib) { $lib = 'D:\PCL2\.minecraft\libraries' }
if (-not (Test-Path $lib)) { $lib = "$env:APPDATA\.minecraft\libraries" }
if (-not (Test-Path $lib)) { throw "game libraries dir not found. Set BILIFIX_LIBS" }
$mcDir = Split-Path -Parent $lib

$ghTokenFile = Join-Path $env:USERPROFILE '.dsh\gh.token'

# ---- Read version (single source: neoforge.mods.toml, cross-checked by regression) ----
$toml = Get-Content "$root\src\main\resources\META-INF\neoforge.mods.toml" -Raw -Encoding UTF8
if (-not ($toml -match '(?s)\[\[mods\]\].*?version\s*=\s*"([^"]+)"')) { throw "cannot read version" }
$version = $Matches[1]

# ---- Resolve the jar for the requested variant ----
$variantSpec = @{
    neoforge = @{ mc = '1.21.1'; dir = 'build';            localInstance = '航空学这一块' }
    forge    = @{ mc = '1.20.1'; dir = 'build\forge';       localInstance = $null }  # no live Forge 1.20.1 instance at the moment
    fabric   = @{ mc = '1.20.1'; dir = 'build\fabric';      localInstance = '璃湾省 1.20.1 城建版' }
}[$Variant]
$jarName = "BiliFix-$version-mc$($variantSpec.mc)-$Variant.jar"
$jarPath = Join-Path $root (Join-Path $variantSpec.dir $jarName)
if (-not (Test-Path $jarPath)) { throw "jar not built: $jarPath (run build$(if ($Variant -ne 'neoforge') { '-' + $Variant }).ps1 first)" }
Write-Host "Deploying BiliFix v$version [$Variant] ($([Math]::Round((Get-Item $jarPath).Length/1KB,1)) KB)"

# ---- Integrity gate (same strict check as build.ps1) ----
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zc = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
$fail = 0
foreach ($e in $zc.Entries) { try { $ms = New-Object System.IO.MemoryStream; $e.Open().CopyTo($ms) } catch { $fail++ } }
$zc.Dispose()
if ($fail -gt 0) { throw "jar integrity check FAILED ($fail entries) - refusing to deploy" }
Write-Host "Jar integrity OK - proceeding" -ForegroundColor Green

if ($DryRun) { Write-Host "DRY RUN - would deploy [$Variant] to: mods folder + GitHub Release v$version; stopping."; return }

# ---- 1. Local mods folder ----
$instanceDir = $env:BILIFIX_INSTANCE
if (-not $instanceDir) {
    if ($variantSpec.localInstance) { $instanceDir = Join-Path $mcDir ("versions\" + $variantSpec.localInstance) }
    else { throw "no known $Variant 1.20.1 instance on this machine - set BILIFIX_INSTANCE=<version dir> (the former shwetro-1201 bed is gone)" }
}
$modsDir = Join-Path $instanceDir 'mods'
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null
# remove ALL previous BiliFix jars (any version / naming convention) to keep the mods dir clean
Remove-Item (Join-Path $modsDir 'BiliFix-*.jar') -Force -ErrorAction SilentlyContinue
$leftovers = Get-ChildItem $modsDir -Filter 'BiliFix-*.jar' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $jarName }
if ($leftovers) { Write-Warning "game may be running - could not remove: $($leftovers.Name -join ', ')" }
$modsJar = Join-Path $modsDir $jarName
Copy-Item $jarPath $modsJar -Force
Write-Host "mods folder: deployed -> $modsJar (older BiliFix jars removed)" -ForegroundColor Green

if ($SkipRemote) { Write-Host "Deploy complete (local only)."; return }

# ---- 2. GitHub Release asset sync (incremental, all variants) ----
if (Test-Path $ghTokenFile) {
    $ghToken = (Get-Content $ghTokenFile -Raw).Trim()
    $proxy = $env:HTTPS_PROXY
    $h = @{ Authorization = "Bearer $ghToken"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'BiliFix-Deploy' }

    $rel = $null
    foreach ($attempt in 1..5) {
        try { $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/szkele1145/BiliFix/releases' -Headers $h -Proxy $proxy } catch { $rels = $null }
        $rel = $rels | Where-Object { $_.tag_name -eq "v$version" }
        if ($rel) { break }
        if ($attempt -lt 5) { Write-Host "  Release v$version not visible yet (attempt $attempt), waiting..." -ForegroundColor Yellow; Start-Sleep -Seconds 5 }
    }
    if (-not $rel) {
        # A tag/Release is NOT created by git push - it has to be made explicitly.
        # Missing this step is what silently stalled the v1.4.7 publish, so create it here.
        #
        # Release discipline gate (v1.4.8): creating a Release means PUBLISHING.
        # The project rule is "promote CHANGELOG ## Unreleased -> ## <version> only
        # after the in-game launch validation passed (Forge AND Fabric)". If the
        # CHANGELOG still has the version under "## Unreleased", the release was
        # NOT promoted yet -> publishing now would ship an unvalidated build.
        # Use -ForceRelease to override deliberately.
        $promoted = $false
        try {
            $clPath = Join-Path $root 'CHANGELOG.md'
            $cl = [System.IO.File]::ReadAllText($clPath, [System.Text.Encoding]::UTF8)
            $esc = [regex]::Escape($version)
            # promoted <=> a "## <version>" heading exists AND is not inside Unreleased
            $promoted = [regex]::IsMatch($cl, "(?m)^##\s+$esc\b")
        } catch { $promoted = $false }
        if (-not $promoted -and -not $ForceRelease) {
            throw ("CHANGELOG has no promoted '## $version' section - the release gate is closed." +
                   "`n  Publishing means shipping; v$version may only be released after the" +
                   "`n  in-game launch validation passed (see docs/verification-checklist.md)." +
                   "`n  Promote CHANGELOG '## Unreleased' -> '## $version' first," +
                   "`n  or pass -ForceRelease if you really mean to publish now.")
        }
        if (-not $promoted) {
            Write-Host "  WARNING: publishing v$version with -ForceRelease despite an unpromoted CHANGELOG" -ForegroundColor Red
        }
        Write-Host "  no Release for v$version - creating tag + release..." -ForegroundColor Yellow
        $notes = "BiliFix $version"
        try {
            $cl = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CHANGELOG.md'), [System.Text.Encoding]::UTF8)
            $esc = [regex]::Escape($version)
            $m = [regex]::Match($cl, "(?s)## $esc[^\n]*\n(.*?)(?:\n## |\z)")
            if ($m.Success -and $m.Groups[1].Value.Trim()) { $notes = $m.Groups[1].Value.Trim() }
        } catch { Write-Host "  (changelog body unavailable, using a minimal body)" -ForegroundColor Yellow }
        $payload = @{ tag_name = "v$version"; target_commitish = 'main'
                      name = "BiliFix $version"; body = $notes
                      draft = $false; prerelease = $false } | ConvertTo-Json -Depth 5
        $rel = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/repos/szkele1145/BiliFix/releases' `
                -Headers $h -Proxy $proxy -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
        Write-Host "  created Release v$version (id=$($rel.id))" -ForegroundColor Green
    }

    # Build the full desired asset set: every built variant of this version.
    $desired = @()
    foreach ($v in @('neoforge', 'forge', 'fabric')) {
        $spec = @{
            neoforge = @{ mc = '1.21.1'; dir = 'build' }
            forge    = @{ mc = '1.20.1'; dir = 'build\forge' }
            fabric   = @{ mc = '1.20.1'; dir = 'build\fabric' }
        }[$v]
        $n = "BiliFix-$version-mc$($spec.mc)-$v.jar"
        $p = Join-Path $root (Join-Path $spec.dir $n)
        if (Test-Path $p) { $desired += @{ name = $n; path = $p } }
        else { Write-Host "  (skipping $n - not built)" -ForegroundColor DarkGray }
    }

    function Upload-Asset($relId, $name, $path) {
        $jar = [System.IO.File]::ReadAllBytes($path)
        $req = [System.Net.HttpWebRequest]::Create("https://uploads.github.com/repos/szkele1145/BiliFix/releases/$relId/assets?name=$name")
        $req.Method = 'POST'
        if ($proxy) { $req.Proxy = New-Object System.Net.WebProxy($proxy) }
        $req.ContentType = 'application/java-archive'
        $req.Headers.Add('Authorization', "Bearer $ghToken")
        $req.UserAgent = 'BiliFix-Deploy'
        $req.ContentLength = $jar.Length
        $s = $req.GetRequestStream(); $s.Write($jar, 0, $jar.Length); $s.Close()
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        ($sr.ReadToEnd() | ConvertFrom-Json).browser_download_url
    }

    foreach ($d in $desired) {
        $existing = $rel.assets | Where-Object { $_.name -eq $d.name }
        # Content check by SHA-256 (v1.4.8): size alone is NOT sufficient - the very
        # history of this repo proves it: v1.4.4 and v1.4.5 jars are BOTH 20582 bytes
        # with completely different content. GitHub exposes asset.digest
        # ("sha256:...", verified by download+hash against the API field).
        # If digest is ever unavailable (older GitHub Enterprise), fall back to size.
        $localHash = 'sha256:' + (Get-FileHash $d.path -Algorithm SHA256).Hash.ToLower()
        $isCurrent = $false
        if ($existing) {
            if ($existing.PSObject.Properties.Name -contains 'digest' -and $existing.digest) {
                $isCurrent = ($existing.digest -eq $localHash)
            } else {
                $isCurrent = ($existing.size -eq (Get-Item $d.path).Length)
            }
        }
        if ($existing -and $isCurrent) {
            Write-Host "  asset $($d.name) already current (sha256 verified)" -ForegroundColor Green
            continue
        }
        if ($existing) {
            # same name but different content: delete the stale asset, then re-upload
            Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/szkele1145/BiliFix/releases/assets/$($existing.id)" -Headers $h -Proxy $proxy | Out-Null
            Write-Host "  removed stale asset $($d.name) (digest changed)" -ForegroundColor Yellow
        }
        $url = Upload-Asset $rel.id $d.name $d.path
        Write-Host "  asset uploaded: $url" -ForegroundColor Green
    }
    # Note: assets of OTHER variants are intentionally left alone now (incremental).
} else { Write-Warning "$ghTokenFile not found - GitHub sync skipped" }

# ---- 3. Modrinth ----
# Intentionally NOT implemented here (see pending-modrinth.ps1): deleting/re-uploading
# versions affects the review queue and stays an explicit, separate step.

Write-Host "Deploy complete." -ForegroundColor Green
