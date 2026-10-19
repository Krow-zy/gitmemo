#requires -Version 7
<#
session-end.ps1 - Droid SessionEnd hook.

Copies the finished session transcript into the private gitmemo store, appends a
manifest line, regenerates index.md, then commits and pushes. Designed to be safe:
every problem path logs and exits 0, because a SessionEnd hook cannot block a session.

Manual test:
    pwsh -File session-end.ps1 -Cwd "/path/to/repo" -TranscriptPath "/tmp/session.jsonl" -SessionId test-1

Layout written:
    projects/<slug>/sessions/<yyyy-MM-dd-HHmmss>-<sid8>.jsonl
    projects/<slug>/manifest.jsonl
    projects/<slug>/index.md
#>
[CmdletBinding()]
param(
    [string]$Cwd,
    [string]$TranscriptPath,
    [string]$SessionId,
    [int]$MaxMegabytes = 50,
    [switch]$NoPush,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'lib.ps1')
$ErrorActionPreference = 'Continue'

function Stop-Capture([string]$Reason) {
    Write-HookLog 'session-end' $Reason
    Write-Output "gitmemo: $Reason"
    exit 0
}

$payload = Get-HookPayload -Cwd $Cwd -TranscriptPath $TranscriptPath -SessionId $SessionId
if (-not $payload) { exit 0 }

$store = Get-StoreRoot
if (-not (Test-Path -LiteralPath (Join-Path $store '.git'))) { Stop-Capture "store not found at $store" }

# Self-healing store setup: byte-faithful attributes and low-disk mode must not depend
# on install.ps1 ever running on this machine.
[void](Initialize-Store -Store $store -Source 'session-end')

$transcript = $payload.transcript_path
if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { Stop-Capture "no transcript to capture at '$transcript'" }

$file = Get-Item -LiteralPath $transcript
$megabytes = $file.Length / 1MB
if ($megabytes -gt $MaxMegabytes) { Stop-Capture ("skip: transcript is {0:N1} MB, over the {1} MB cap" -f $megabytes, $MaxMegabytes) }
if ($file.Length -eq 0) { Stop-Capture 'skip: empty transcript' }

$session = if ($payload.session_id) { [string]$payload.session_id } else { [guid]::NewGuid().ToString() }
$sessionShort = $session.Substring(0, [Math]::Min(8, $session.Length))
$slug = Get-ProjectSlug -Directory $payload.cwd

$projectDir = Join-Path $store (Join-Path 'projects' $slug)

# One session can end more than once (clear then exit), so the manifest decides whether
# this session is new. -Force overrides when a transcript really must be recaptured.
$manifest = Join-Path $projectDir 'manifest.jsonl'
if (-not $Force -and (Test-Path -LiteralPath $manifest)) {
    foreach ($line in [System.IO.File]::ReadLines($manifest)) {
        if (-not $line.Trim()) { continue }
        $row = $null
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.session -and ([string]$row.session) -eq $session) {
            Stop-Capture "skip: session $sessionShort is already captured ($($row.file))"
        }
    }
}

$sessionDir = Join-Path $projectDir 'sessions'
if (-not (Test-Path -LiteralPath $sessionDir)) { New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null }

# Redaction gate: what looks like a credential is replaced before the copy is stored,
# so the session is kept and the value never reaches the store or GitHub.
$text = [System.IO.File]::ReadAllText($transcript)
$protected = Protect-Text -Text $text
$redactions = 0
foreach ($key in $protected.hits.Keys) { $redactions += $protected.hits[$key] }

$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$name = "$stamp-$sessionShort.jsonl"
$dest = Join-Path $sessionDir $name
if ($redactions -gt 0) {
    [System.IO.File]::WriteAllText($dest, $protected.text)
    Write-HookLog 'session-end' "redacted $redactions value(s) in $slug/$sessionShort ($($protected.hits.Keys -join ', '))"
} else {
    Copy-Item -LiteralPath $transcript -Destination $dest -Force
}

$messages = 0
foreach ($null in [System.IO.File]::ReadLines($dest)) { $messages++ }
$sha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()

$entry = [ordered]@{
    captured   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    session    = $session
    file       = "sessions/$name"
    bytes      = (Get-Item -LiteralPath $dest).Length
    messages   = $messages
    sha256     = $sha
    redactions = $redactions
    project    = $slug
    cwd        = [string]$payload.cwd
}
($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Join-Path $projectDir 'manifest.jsonl') -Encoding utf8
Update-ProjectIndex -ProjectDir $projectDir

$result = Save-Store -Message "capture: $slug $sessionShort ($([math]::Round($megabytes, 1)) MB, $messages messages)" -NoPush:$NoPush -Source 'session-end'
Write-HookLog 'session-end' "$slug $sessionShort -> $result"
Write-Output "gitmemo: $slug $sessionShort captured ($messages messages) - $result"
exit 0
