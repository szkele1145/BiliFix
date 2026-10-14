# Pending Modrinth uploads: v1.4.2 + v1.4.3 (blocked on an expired token).
# Run this ONCE after placing a fresh Modrinth PAT (with Create/Edit Version scopes)
# into ~\.dsh\mr.token - it uploads both pending versions and verifies.
#
# Usage: ./pending-modrinth.ps1

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$tokenFile = Join-Path $env:USERPROFILE '.dsh\mr.token'
$projectId = 'U6GLOyQ7'
$proxy = 'http://127.0.0.1:65532'

if (-not (Test-Path $tokenFile)) { throw "token file not found: $tokenFile - place a fresh Modrinth PAT there first" }
$mrToken = (Get-Content $tokenFile -Raw).Trim()

# ---- 0. token sanity check ----
try {
    $me = Invoke-RestMethod -Uri 'https://api.modrinth.com/v2/user' -Headers @{ Authorization = $mrToken } -Proxy $proxy
    Write-Host "token OK for: $($me.username)" -ForegroundColor Green
} catch {
    throw "token invalid (401?) - generate a fresh one at https://modrinth.com/settings/pats (needs Create + Edit Version scopes)"
}

# ---- pending versions: (number, changelog, featured) ----
$pending = @(
    @{ ver = '1.4.2'; changelog = "Diagnostics now report the full companion-chain versions: watermedia, bilibili_media, and waterframes - all read from the FML ModList runtime API (single source of truth, with a classpath-probe fallback)."; featured = $false },
    @{ ver = '1.4.3'; changelog = "CrashSentinel now captures the full hardened VLC arg sequence when verbose=true is set in the config - the diagnostic file becomes a complete record of what VLC actually received."; featured = $true }
)

foreach ($p in $pending) {
    $jarName = "BiliFix-$($p.ver)-mc1.21.1-neoforge.jar"
    $jarPath = Join-Path $root "build\$jarName"
    if (-not (Test-Path $jarPath)) { Write-Warning "$jarName not in build/ - skipping"; continue }

    # skip if already uploaded
    $v = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$projectId/version" -Headers @{ Authorization = $mrToken } -Proxy $proxy
    if ($v | Where-Object { $_.version_number -eq $p.ver }) { Write-Host "$($p.ver): already on Modrinth - skip" -ForegroundColor Yellow; continue }

    $boundary = "----BiliFixBoundary$([Guid]::NewGuid().ToString('N'))"
    $versionObj = [PSCustomObject]@{
        project_id = $projectId
        file_parts = @($jarName)
        version_title = "BiliFix $($p.ver)"
        version_number = $p.ver
        changelog = $p.changelog
        version_type = 'release'
        game_versions = @('1.21.1')
        loaders = @('neoforge')
        featured = $p.featured
        dependencies = @(
            [PSCustomObject]@{ project_id = 'vqvS4GPe'; dependency_type = 'optional' },
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
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $result = ($sr.ReadToEnd() | ConvertFrom-Json)
    Write-Host "$($p.ver): uploaded, id=$($result.id)" -ForegroundColor Green
}

# ---- verify ----
$v2 = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$projectId/version" -Headers @{ Authorization = $mrToken } -Proxy $proxy
Write-Host "`nModrinth now has $($v2.Count) versions:"
$v2 | ForEach-Object { Write-Host "  $($_.version_number): $($_.files[0].filename)" }
