#requires -Version 7
<#
lib.ps1 - shared helpers for the gitmemo hooks. Dot-source from every script in this folder.
Nothing here writes to the repository being worked on; the store is the only target.
#>

$script:StoreRoot = if ($env:GITMEMO_HOME) { $env:GITMEMO_HOME } else { Join-Path $HOME '.gitmemo' }
# No default remote: the store belongs to the user. An unset value is a configuration
# error the hooks log, not a clone attempt against someone else's private repository.
$script:StoreRemote = [string]$env:GITMEMO_REMOTE

function Get-StoreRoot { return $script:StoreRoot }

function Get-StoreRemote { return $script:StoreRemote }

# Low-disk mode keeps the working tree flat: notes, index and manifest are checked out,
# transcripts stay in the object database and on the remote.
function Get-SparsePatterns {
    return @('/README.md', '/.gitattributes', '/hooks/', '/projects/*/notes.md', '/projects/*/index.md', '/projects/*/manifest.jsonl')
}

# Byte-faithful storage: without this, git normalises line endings on `git add`, so the
# committed blob would no longer match the manifest's bytes/sha256. `* -text` disables
# normalisation for the whole store. Never overwrite an existing file.
function Initialize-StoreAttributes {
    param([string]$Store = $script:StoreRoot, [string]$Source = 'store')
    $path = Join-Path $Store '.gitattributes'
    if (Test-Path -LiteralPath $path) { return $false }
    try {
        Set-Content -LiteralPath $path -Value "* -text`n" -NoNewline -Encoding utf8
        return $true
    } catch {
        Write-HookLog $Source "could not write .gitattributes: $($_.Exception.Message)"
        return $false
    }
}

function Enable-StoreSparse {
    param([string]$Store = $script:StoreRoot, [string]$Source = 'store')
    $patterns = Get-SparsePatterns
    & git -C $Store sparse-checkout set --no-cone @patterns 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-HookLog $Source 'sparse checkout failed, store stays full'
        return $false
    }
    return $true
}

# Low-disk mode is enforced by the hooks, not by the installer. Sparse config is
# repo-local and is not cloned, and a store may predate sparse mode entirely, so every
# hook run checks it and re-applies the patterns when they are missing.
function Initialize-StoreSparse {
    param([string]$Store = $script:StoreRoot, [string]$Source = 'store')
    if (-not (Test-Path -LiteralPath (Join-Path $Store '.git'))) { return $false }
    if ((& git -C $Store config --get core.sparseCheckout 2>$null) -eq 'true') { return $true }
    return (Enable-StoreSparse -Store $Store -Source $Source)
}

# Everything a hook needs before touching the store: byte-faithful attributes and
# low-disk mode. Safe to call on every run.
function Initialize-Store {
    param([string]$Store = $script:StoreRoot, [string]$Source = 'store')
    if (-not (Test-Path -LiteralPath (Join-Path $Store '.git'))) { return $false }
    $attributesCreated = Initialize-StoreAttributes -Store $Store -Source $Source
    # A new .gitattributes needs the current pattern list, which carries it.
    if ($attributesCreated) { return (Enable-StoreSparse -Store $Store -Source $Source) }
    if ((& git -C $Store config --get core.sparseCheckout 2>$null) -ne 'true') {
        return (Enable-StoreSparse -Store $Store -Source $Source)
    }
    # Sparse mode can be on with a pattern list from an older release that predates
    # .gitattributes; re-apply so `sparse-checkout reapply` does not prune it.
    $file = Join-Path $Store '.git/info/sparse-checkout'
    $current = if (Test-Path -LiteralPath $file) { @(Get-Content -LiteralPath $file | Where-Object { $_.Trim() }) } else { @() }
    if (@(Compare-Object -ReferenceObject @(Get-SparsePatterns) -DifferenceObject $current).Count -gt 0) {
        Write-HookLog $Source 'sparse pattern list is out of date, re-applying'
        return (Enable-StoreSparse -Store $Store -Source $Source)
    }
    return $true
}

function Write-HookLog {
    param([string]$Source, [string]$Message)
    try {
        $logDir = Join-Path $script:StoreRoot 'hooks'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -LiteralPath (Join-Path $logDir 'hook.log') -Value ('{0} {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Source, $Message)
    } catch { }
}

# Hook payload arrives as JSON on stdin. The parameters exist so the scripts can be
# tested by hand; when -Cwd is given, stdin is not read at all.
function Get-HookPayload {
    param([string]$Cwd, [string]$TranscriptPath, [string]$SessionId)
    if ($Cwd) {
        return [pscustomobject]@{ cwd = $Cwd; transcript_path = $TranscriptPath; session_id = $SessionId }
    }
    $raw = ''
    try { $raw = [Console]::In.ReadToEnd() } catch { }
    if (-not $raw.Trim()) { return $null }
    try { $json = $raw | ConvertFrom-Json } catch {
        # Doing nothing is the right behaviour for a hook, but not silently failing to
        # do anything at all: leave a trail for the next debug session.
        Write-HookLog 'payload' "stdin was not valid JSON ($($_.Exception.Message)), $($raw.Length) bytes ignored"
        return $null
    }
    if (-not $json.cwd) { $json | Add-Member -NotePropertyName cwd -NotePropertyValue (Get-Location).Path }
    return $json
}

# Project identity comes from the git remote, so no repository has to declare anything.
# Fallback: folder name. Both are lowercased and sanitized for use as a path segment.
function Get-ProjectSlug {
    param([string]$Directory)
    $dir = $Directory
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = (Get-Location).Path }
    $name = $null
    try {
        $url = (& git -C $dir remote get-url origin 2>$null | Select-Object -First 1)
        if ($url) {
            # Last path segment of any remote shape: https, ssh://, git@host:owner/repo.
            $name = (("$url".Trim() -replace '[\\/]+$', '') -split '[:/\\]' |
                Where-Object { $_ } | Select-Object -Last 1) -replace '\.git$', ''
        }
    } catch { }
    if (-not $name) {
        $leaf = Split-Path -Path ($dir.TrimEnd([char[]]@('/', '\'))) -Leaf
        $name = if ($leaf) { $leaf } else { 'unknown' }
    }
    return ($name.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
}

$script:SecretPatterns = @(
    'hskey-[A-Za-z0-9]{8,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'sk-[A-Za-z0-9]{20,}'
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'AKIA[0-9A-Z]{16}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}'
)

# Replaces anything that looks like a credential and reports what was replaced.
# Case-sensitive on purpose: PowerShell's -match ignores case, which turns a prefix like
# AKIA into ordinary base64 noise and would flag innocent transcripts.
function Protect-Text {
    param([string]$Text)
    $hits = [ordered]@{}
    if (-not $Text) { return [pscustomobject]@{ text = $Text; hits = $hits } }
    foreach ($p in $script:SecretPatterns) {
        $count = [regex]::Matches($Text, $p, [System.Text.RegularExpressions.RegexOptions]::None).Count
        if ($count -gt 0) {
            $Text = [regex]::Replace($Text, $p, '[REDACTED]', [System.Text.RegularExpressions.RegexOptions]::None)
            $hits[$p] = $count
        }
    }
    return [pscustomobject]@{ text = $Text; hits = $hits }
}

# Regenerates index.md from manifest.jsonl. Derived, never hand-edited.
function Update-ProjectIndex {
    param([string]$ProjectDir)
    $manifest = Join-Path $ProjectDir 'manifest.jsonl'
    if (-not (Test-Path -LiteralPath $manifest)) { return }
    $rows = @()
    foreach ($line in [System.IO.File]::ReadLines($manifest)) {
        if (-not $line.Trim()) { continue }
        try { $rows += ($line | ConvertFrom-Json) } catch { }
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Session index')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Derived from `manifest.jsonl` by `hooks/session-end.ps1`. Do not edit by hand.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Captured | Session | Messages | Size | SHA256 |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    foreach ($r in ($rows | Sort-Object captured -Descending)) {
        $kb = [math]::Round(($r.bytes / 1KB), 0)
        $sha = "$($r.sha256)"
        if ($sha.Length -gt 12) { $sha = $sha.Substring(0, 12) }
        [void]$sb.AppendLine(('| {0} | `{1}` | {2} | {3} KB | `{4}` |' -f $r.captured, $r.session, $r.messages, $kb, $sha))
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(('Total: {0} session(s).' -f $rows.Count))
    Set-Content -LiteralPath (Join-Path $ProjectDir 'index.md') -Value $sb.ToString() -Encoding utf8
}

# Commits and pushes the store. A failed push keeps the commit locally and is retried on
# the next run, because a hook must never break the session.
function Save-Store {
    param([string]$Message, [switch]$NoPush, [string]$Source = 'store')
    $store = $script:StoreRoot
    # --sparse is required in low-disk mode: plain `add -A` skips new files that live
    # outside the sparse patterns (a transcript is exactly that), and would commit an
    # index entry pointing at nothing. Old git without --sparse falls back.
    & git -C $store add --sparse -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { & git -C $store add -A 2>&1 | Out-Null }
    $staged = & git -C $store diff --cached --name-only 2>&1
    if (-not $staged) {
        # A previous push may have failed; retry it even when this run has nothing new.
        if ($NoPush) { return 'nothing to commit' }
        $unpushed = @(& git -C $store log --branches --not --remotes --oneline 2>$null).Count
        if ($unpushed -eq 0) { return 'nothing to commit' }
        $out = & git -C $store -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 push -q 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-HookLog $Source "push retry failed, kept locally: $out"
            return 'nothing to commit (push retry failed)'
        }
        return 'nothing to commit (previous commit pushed)'
    }
    & git -C $store commit -q -m $Message 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-HookLog $Source 'commit failed'; return 'commit failed' }
    if ((& git -C $store config --get core.sparseCheckout 2>$null) -eq 'true') {
        # The commit holds the transcript now, so drop the working-tree copy again.
        & git -C $store sparse-checkout reapply 2>&1 | Out-Null
        Write-HookLog $Source 'low-disk mode: transcript committed, working tree copy pruned'
    }
    if ($NoPush) { return 'committed locally (push skipped)' }
    $out = & git -C $store -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 push -q 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-HookLog $Source "push failed, kept locally: $out"
        return 'committed locally (push failed, retried next run)'
    }
    return 'committed and pushed'
}
