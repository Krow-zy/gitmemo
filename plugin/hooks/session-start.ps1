#requires -Version 7
<#
session-start.ps1 - Droid SessionStart hook.

Brings the private memory of the current project into the new session:
  * clones the store on a fresh machine when it is missing (one time, needs gh auth)
  * fast-forwards the store, failing fast on a slow network instead of hanging
  * prints projects/<slug>/notes.md and the tail of index.md to stdout, which Droid
    appends to the session context

Nothing is printed when the project has no memory yet, so unrelated repos stay clean.

Manual test:
    pwsh -File session-start.ps1 -Cwd "/path/to/repo"
#>
[CmdletBinding()]
param(
    [string]$Cwd,
    [int]$MaxNotesCharacters = 6000,
    [string]$Remote
)

. (Join-Path $PSScriptRoot 'lib.ps1')
$ErrorActionPreference = 'Continue'

if (-not $Remote) { $Remote = Get-StoreRemote }

$payload = Get-HookPayload -Cwd $Cwd
if (-not $payload) { exit 0 }

# After a mid-session compaction the memory printed at startup is already in context,
# so printing it again would only burn tokens.
if ("$($payload.source)" -eq 'compact') {
    Write-HookLog 'session-start' 'skipped: source=compact, memory already in context'
    exit 0
}

$store = Get-StoreRoot
if (-not (Test-Path -LiteralPath (Join-Path $store '.git'))) {
    # First run on a machine: fetch the store itself, silently give up if that fails.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-HookLog 'session-start' 'store missing and gh not installed'
        exit 0
    }
    $clone = & gh repo clone $Remote $store -- --quiet 2>&1
    if (-not (Test-Path -LiteralPath (Join-Path $store '.git'))) {
        Write-HookLog 'session-start' "auto-clone failed: $clone"
        exit 0
    }
    # Sparse checkout is repo-local config, so a fresh clone must opt back in.
    [void](Enable-StoreSparse -Store $store -Source 'session-start')
    Write-HookLog 'session-start' "store cloned to $store"
}

$pull = & git -C $store -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 pull --rebase --autostash -q 2>&1
if ($LASTEXITCODE -ne 0) { Write-HookLog 'session-start' "pull skipped: $pull" }

$slug = Get-ProjectSlug -Directory $payload.cwd
$projectDir = Join-Path $store (Join-Path 'projects' $slug)
$notes = Join-Path $projectDir 'notes.md'
$index = Join-Path $projectDir 'index.md'
if (-not (Test-Path -LiteralPath $notes) -and -not (Test-Path -LiteralPath $index)) { exit 0 }

$parts = @()
if (Test-Path -LiteralPath $notes) {
    $body = Get-Content -LiteralPath $notes -Raw
    if ($body -and $body.Length -gt $MaxNotesCharacters) {
        $body = $body.Substring(0, $MaxNotesCharacters) + "`n`n(truncated)"
    }
    $parts += "## Project memory: $slug`n`n$body"
}
if (Test-Path -LiteralPath $index) {
    $tail = Get-Content -LiteralPath $index | Select-Object -Last 12
    $parts += "## Captured sessions`n`n" + ($tail -join "`n")
}
$parts += "Search the full history with: git memo search '<text>'"

Write-Output ('# gitmemo (private)' + "`n`n" + ($parts -join "`n`n"))
exit 0
