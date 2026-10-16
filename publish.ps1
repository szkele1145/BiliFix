<#
    publish.ps1 - one-command source publish (commit is assumed done).

    Why this exists: `git push` against the configured remote uses
    credential.helper=manager, which opens a GUI prompt. In a non-interactive
    shell that prompt is never answered, so the push hangs forever instead of
    failing - this silently stalled the v1.4.7 publish for ~40 minutes. This
    script pushes with an explicit token header and no credential helper, so it
    either succeeds or fails fast.

    Usage:
        .\publish.ps1                 # push main to origin
        .\publish.ps1 -Message "..."  # commit all changes first, then push
#>
param(
    [string]$Message,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

$tokenFile = Join-Path $env:USERPROFILE '.dsh\gh.token'
if (-not (Test-Path $tokenFile)) { Write-Error "token not found: $tokenFile"; exit 1 }
$token = (Get-Content $tokenFile -Raw).Trim()

if ($Message) {
    git add -A
    git -c core.quotepath=false commit -q -m $Message
    Write-Host "committed: $(git log --oneline -1)" -ForegroundColor Green
}

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$local  = (git rev-parse --short HEAD).Trim()

# Never let a GUI credential prompt hang the shell.
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE     = 'never'

$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))

if ($DryRun) {
    Write-Host "dry run: would push $branch ($local) with a token header" -ForegroundColor Yellow
    exit 0
}

Write-Host "pushing $branch ($local)..." -ForegroundColor Cyan
# Empty credential.helper disables the manager; the extraheader carries the token.
# NOTE: git writes progress ("To https://...", "   4bf9c18..b273823  main -> main")
# to stderr. With $ErrorActionPreference='Stop' PowerShell turns each of those
# lines into a terminating NativeCommandError, so the push would report exit 1
# even when it fully succeeded. Relax the preference around the call and judge
# success by $LASTEXITCODE alone.
$ErrorActionPreference = 'Continue'
git -c credential.helper= -c "http.https://github.com/.extraheader=Authorization: Basic $basic" push origin $branch 2>&1 |
    ForEach-Object { Write-Host "  $_" }
$pushExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($pushExit -ne 0) { Write-Error "push failed (exit $pushExit)"; exit $pushExit }

$remote = (git ls-remote origin "refs/heads/$branch" 2>$null | ForEach-Object { $_.Split()[0] })
if ($remote -and $remote.StartsWith($local)) {
    Write-Host "verified: origin/$branch is at $local" -ForegroundColor Green
} else {
    Write-Warning "pushed, but origin/$branch does not report $local yet (indexing lag)"
}
