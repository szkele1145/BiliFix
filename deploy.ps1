# Deploy script (PowerShell, Windows)
# One command to sync the freshly built jar to: local mods folder + GitHub Release asset.
# Eliminates channel drift. Tokens are read from ~\.dsh\gh.token (create it yourself;
# NOT committed). Modrinth is handled separately by pending-modrinth.ps1.
#
# Usage:
#   ./deploy.ps1                    # deploy to local mods + refresh GitHub asset
#   ./deploy.ps1 -IncludeModrinth   # prints a pointer to pending-modrinth.ps1 (intentionally manual)
#   ./deploy.ps1 -DryRun            # show what would happen, change nothing

param(
    [switch]$IncludeModrinth,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- Locate game install (mirror build.ps1 logic) ----
$lib = $env:BILIFIX_LIBS
if (-not $lib) { $lib = 'D:\PCL2\.minecraft\libraries' }
if (-not (Test-Path $lib)) { $lib = "$env:APPDATA\.minecraft\libraries" }
if (-not (Test-Path $lib)) { throw "game libraries dir not found. Set BILIFIX_LIBS" }
$mcDir = Split-Path -Parent $lib

# ---- Constants (these two are public knowledge; tokens come from files) ----
$ghTokenFile = Join-Path $env:USERPROFILE '.dsh\gh.token'
$mrTokenFile = Join-Path $env:USERPROFILE '.dsh\mr.token'

# ---- Read version + jar (naming: <mod>-<version>-mc<game>-<loader>.jar) ----
$toml = Get-Content "$root\src\main\resources\META-INF\neoforge.mods.toml" -Raw -Encoding UTF8
if (-not ($toml -match '(?s)\[\[mods\]\].*?version\s*=\s*"([^"]+)"')) { throw "cannot read version" }
$version = $Matches[1]
$jarName = "BiliFix-$version-mc1.21.1-neoforge.jar"
$jarPath = Join-Path $root "build\$jarName"
if (-not (Test-Path $jarPath)) { throw "jar not built: $jarPath (run build.ps1 first)" }
Write-Host "Deploying BiliFix v$version  ($([Math]::Round((Get-Item $jarPath).Length/1KB,1)) KB)"

# ---- Integrity gate (same strict check as build.ps1) ----
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zc = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
$fail = 0
foreach ($e in $zc.Entries) { try { $ms = New-Object System.IO.MemoryStream; $e.Open().CopyTo($ms) } catch { $fail++ } }
$zc.Dispose()
if ($fail -gt 0) { throw "jar integrity check FAILED ($fail entries) - refusing to deploy" }
Write-Host "Jar integrity OK - proceeding" -ForegroundColor Green

if ($DryRun) { Write-Host "DRY RUN - would deploy to: mods folder, GitHub Release v$version$(if ($IncludeModrinth) { ', Modrinth' }); stopping."; return }

# ---- 1. Local mods folder ----
# Instance dir override: BILIFIX_INSTANCE=<full path to the version instance dir>; default the known pack
$instanceDir = $env:BILIFIX_INSTANCE
if (-not $instanceDir) { $instanceDir = Join-Path $mcDir 'versions\航空学这一块' }
$modsDir = Join-Path $instanceDir 'mods'
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null
# remove ALL previous BiliFix jars (any version / naming convention) to keep the mods dir clean
Remove-Item (Join-Path $modsDir 'BiliFix-*.jar') -Force -ErrorAction SilentlyContinue
# leftover check: if the game is running and locked a jar, old ones may survive removal -
# that would cause a duplicate-modid warning in FML. Warn loudly instead of failing silently.
$leftovers = Get-ChildItem $modsDir -Filter 'BiliFix-*.jar' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $jarName }
if ($leftovers) { Write-Warning "game may be running - could not remove: $($leftovers.Name -join ', ')" }
$modsJar = Join-Path $modsDir $jarName
Copy-Item $jarPath $modsJar -Force
Write-Host "mods folder: deployed -> $modsJar (older BiliFix jars removed)" -ForegroundColor Green

# ---- 2. GitHub Release asset refresh ----
if (Test-Path $ghTokenFile) {
    $ghToken = (Get-Content $ghTokenFile -Raw).Trim()
    $proxy = $env:HTTPS_PROXY
    $h = @{ Authorization = "Bearer $ghToken"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'BiliFix-Deploy' }
    # Retry loop: a Release created seconds ago may not be in the list API yet (seen twice in practice)
    $rel = $null
    foreach ($attempt in 1..5) {
        $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/szkele1145/BiliFix/releases' -Headers $h -Proxy $proxy
        $rel = $rels | Where-Object { $_.tag_name -eq "v$version" }
        if ($rel) { break }
        Write-Host "  Release v$version not visible yet (attempt $attempt), waiting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
    if (-not $rel) {
        # A tag/Release is NOT created by git push - it has to be made explicitly.
        # Missing this step is what silently stalled the v1.4.7 publish, so create it here.
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
        try {
            $rel = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/repos/szkele1145/BiliFix/releases' `
                -Headers $h -Proxy $proxy -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
            Write-Host "  created Release v$version (id=$($rel.id))" -ForegroundColor Green
        } catch {
            Write-Warning "could not create Release v$version: $($_.Exception.Message)"
            if ($_.ErrorDetails) { Write-Warning $_.ErrorDetails.Message }
        }
    }
    if ($rel) {
        foreach ($a in $rel.assets) { Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/szkele1145/BiliFix/releases/assets/$($a.id)" -Headers $h -Proxy $proxy | Out-Null }
        $jar = [System.IO.File]::ReadAllBytes($jarPath)
        $req = [System.Net.HttpWebRequest]::Create("https://uploads.github.com/repos/szkele1145/BiliFix/releases/$($rel.id)/assets?name=$jarName")
        $req.Method = 'POST'
        if ($proxy) { $req.Proxy = New-Object System.Net.WebProxy($proxy) }
        $req.ContentType = 'application/java-archive'
        $req.Headers.Add('Authorization', "Bearer $ghToken")
        $req.UserAgent = 'BiliFix-Deploy'
        $req.ContentLength = $jar.Length
        $s = $req.GetRequestStream(); $s.Write($jar, 0, $jar.Length); $s.Close()
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $url = ($sr.ReadToEnd() | ConvertFrom-Json).browser_download_url
        Write-Host "GitHub Release v$version asset refreshed: $url" -ForegroundColor Green
    } else { Write-Warning "no GitHub Release tag v$version found - skipped" }
} else { Write-Warning "$ghTokenFile not found - GitHub sync skipped" }

# ---- 3. Modrinth ----
# NOTE: Modrinth uploads are handled by pending-modrinth.ps1 (token-gated batch uploader).
# -IncludeModrinth is intentionally NOT implemented here: deleting/re-uploading versions
# affects the review queue (see docs/postmortem-1.3.2.md) and stays an explicit, separate step.
if ($IncludeModrinth) {
    Write-Host "Modrinth is handled by pending-modrinth.ps1 (run it separately after placing a fresh token)." -ForegroundColor Yellow
}

Write-Host "Deploy complete." -ForegroundColor Green
