# Deploy script (PowerShell, Windows)
# One command to sync the freshly built jar to: local mods folder, GitHub Release asset,
# and (optionally) Modrinth. Eliminates manual drift between the three channels.
#
# Usage:
#   ./deploy.ps1                    # deploy to local mods + refresh GitHub asset
#   ./deploy.ps1 -IncludeModrinth   # also replace the Modrinth version (deletes + re-uploads)
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

# ---- Read version + jar ----
$toml = Get-Content "$root\src\main\resources\META-INF\neoforge.mods.toml" -Raw -Encoding UTF8
if (-not ($toml -match '(?s)\[\[mods\]\].*?version\s*=\s*"([^"]+)"')) { throw "cannot read version" }
$version = $Matches[1]
$jarPath = Join-Path $root "build\BiliFix-$version.jar"
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
$modsJar = Join-Path $mcDir "versions\航空学这一块\mods\BiliFix-$version.jar"
Copy-Item $jarPath $modsJar -Force
Write-Host "mods folder: deployed -> $modsJar" -ForegroundColor Green

# ---- 2. GitHub Release asset refresh ----
if (Test-Path $ghTokenFile) {
    $ghToken = (Get-Content $ghTokenFile -Raw).Trim()
    $proxy = $env:HTTPS_PROXY
    $h = @{ Authorization = "Bearer $ghToken"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'BiliFix-Deploy' }
    $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/szkele1145/BiliFix/releases' -Headers $h -Proxy $proxy
    $rel = $rels | Where-Object { $_.tag_name -eq "v$version" }
    if ($rel) {
        foreach ($a in $rel.assets) { Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/szkele1145/BiliFix/releases/assets/$($a.id)" -Headers $h -Proxy $proxy | Out-Null }
        $jar = [System.IO.File]::ReadAllBytes($jarPath)
        $req = [System.Net.HttpWebRequest]::Create("https://uploads.github.com/repos/szkele1145/BiliFix/releases/$($rel.id)/assets?name=BiliFix-$version.jar")
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

# ---- 3. Modrinth version replace (opt-in; deletes + re-uploads) ----
if ($IncludeModrinth) {
    if (-not (Test-Path $mrTokenFile)) { Write-Warning "$mrTokenFile not found - Modrinth sync skipped"; return }
    $mrToken = (Get-Content $mrTokenFile -Raw).Trim()
    Write-Warning "Modrinth replacement requires interactive confirmation (delete+upload may affect review queue)."
    Write-Host "Run the Modrinth steps manually when needed; this path is intentionally not automated yet."
}

Write-Host "Deploy complete." -ForegroundColor Green
