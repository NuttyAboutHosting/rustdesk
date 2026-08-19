#requires -Version 7.0
<#
.SYNOPSIS
    Pull a newer upstream RustDesk release into the NAH fork by replaying our
    patch series onto the new tag. Stops for you to resolve / build / test.

.DESCRIPTION
    The fork = upstream RustDesk + a small series of NAH commits on
    nah/custom-client. This script:
      1. fetches upstream (rustdesk/rustdesk) tags,
      2. auto-detects the tag our work currently sits on,
      3. archives the pre-update state (local branch + best-effort private push),
      4. rebases our commits onto the target tag.

    It deliberately does NOT republish - build and TEST first, then run the
    republish block it prints (full history -> private, single squash -> public).
    Never use GitHub's "Sync fork" button; this is the correct path.

.PARAMETER ToTag
    Upstream tag to move onto (e.g. 1.4.10). Omit to just list recent tags.

.PARAMETER Base
    The tag/commit our work currently sits on. Auto-detected via
    merge-base(upstream/master, nah/custom-client) if omitted.

.PARAMETER SkipArchive
    Skip pushing the pre-update archive branch to the private remote (a local
    archive branch is always created regardless).

.EXAMPLE
    pwsh .\update-from-upstream.ps1                 # show what's available upstream
    pwsh .\update-from-upstream.ps1 -ToTag 1.4.10   # do the update
#>
[CmdletBinding()]
param(
    [string]$ToTag,
    [string]$Base,
    [switch]$SkipArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Branch = 'nah/custom-client'

function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Step([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Fail 'Not inside a git repository.' }
Set-Location $repoRoot

# Ensure the upstream remote exists.
if (-not ((git remote) -contains 'upstream')) {
    Write-Host 'Adding upstream remote (rustdesk/rustdesk)...'
    git remote add upstream https://github.com/rustdesk/rustdesk.git
}

Step 'Fetching upstream tags'
git fetch upstream --tags --prune 2>&1 | Write-Host

# Detect the base our patch series sits on.
if (-not $Base) {
    $baseSha = (git merge-base upstream/master $Branch 2>$null)
    if (-not $baseSha) { Fail 'Could not detect base (merge-base upstream/master). Pass -Base explicitly.' }
    $tag = (git describe --tags --exact-match $baseSha 2>$null)
    $Base = if ($tag) { $tag } else { $baseSha }
}
Write-Host "Current base: $Base"

if (-not $ToTag) {
    Step 'Recent upstream tags (pick one with -ToTag)'
    git tag -l '1.*' --sort=-version:refname | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
    Write-Host "`nRe-run with:  pwsh .\update-from-upstream.ps1 -ToTag <tag>"
    exit 0
}

git rev-parse --verify "refs/tags/$ToTag" *> $null
if ($LASTEXITCODE -ne 0) { Fail "Tag '$ToTag' not found after fetch - check the name." }
if (git status --porcelain) { Fail 'Working tree is not clean - commit or stash first.' }

git switch $Branch 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Fail "Could not switch to $Branch." }

# Archive the pre-update state so nothing can be lost.
$stamp   = (Get-Date -Format 'yyyyMMdd-HHmmss')
$archive = "archive/pre-$ToTag-$stamp"
git branch $archive $Branch
Write-Host "Local archive branch: $archive"
if (-not $SkipArchive -and ((git remote) -contains 'private')) {
    Write-Host 'Pushing archive to private (best-effort)...'
    git push private "${archive}:refs/heads/$archive" 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "WARN: private archive push failed - local branch $archive still holds it." -ForegroundColor Yellow }
}

Step "Rebasing our commits from $Base onto $ToTag"
git rebase --onto $ToTag $Base $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nCONFLICTS - resolve each file, then:" -ForegroundColor Yellow
    Write-Host '  git add <files> ; git rebase --continue     (repeat until finished)'
    Write-Host "  ...or  git rebase --abort  to bail out (your work is safe on $archive)"
    Write-Host "`nExpected conflict spots: hooks in common.rs/core_main.rs/lib.rs, the Flutter"
    Write-Host 'branding files, lang/en.rs, and the version-info in Cargo.toml / Runner.rc.'
    Write-Host 'Once the rebase finishes, BUILD + TEST, then republish (below).'
}
else {
    Write-Host "`nRebase clean. BUILD + TEST before publishing." -ForegroundColor Green
}

Step 'Republish (only after a build + test passes)'
Write-Host @'
  # full history -> private
  git push --force private nah/custom-client

  # single squashed commit -> public (public push URL is disabled; use an explicit token URL)
  $T    = gh auth token -u nahosting
  $TREE = git rev-parse nah/custom-client^{tree}
  $NEW  = git commit-tree $TREE -m "NAH Support - modified RustDesk (AGPL-3.0). See LICENCE / README.NAH.md"
  git push --force "https://x-access-token:$T@github.com/NuttyAboutHosting/rustdesk.git" "${NEW}:refs/heads/nah/custom-client"

  # signed release when ready (approve the release-signing environment as nahosting):
  gh workflow run "NAH build" -f sign=true --ref nah/custom-client
'@ -ForegroundColor Gray
