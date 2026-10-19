#requires -Version 7
<#
install.ps1 - connect a machine to the private gitmemo store and register the hooks.

This is the manual install path. It shadows nothing in the plugin: plugin installs get
hooks/hooks.json instead.

    pwsh -File install.ps1 -Remote <owner/repo>

There is no default remote. It clones the store when missing, fixes the credential helper
for the private remote, writes the store's byte-faithful .gitattributes and .gitignore, switches on sparse
checkout (low-disk mode, the default), and registers SessionStart and SessionEnd in
~/.factory/hooks.json. It also removes legacy hooks whose command mentions `agent-memory`,
so a session is never captured twice. Pass -Full to skip the sparse step.

-InstallCli writes a `git-memo` shim into a per-user directory that is already on PATH and
prints the path. Droid does not add a plugin's bin directory to PATH by itself.

Idempotent: a second run writes nothing. An existing hooks.json is backed up once to
hooks.json.bak, and only when the file actually changes.
#>
[CmdletBinding()]
param(
    [string]$StoreRoot = $(if ($env:GITMEMO_HOME) { $env:GITMEMO_HOME } else { Join-Path $HOME '.gitmemo' }),
    [string]$Remote = '',
    [string]$HooksFile = (Join-Path $HOME (Join-Path '.factory' 'hooks.json')),
    [string]$CliDir = '',
    [switch]$NoClone,
    [switch]$SkipHooks,
    [switch]$SkipCredentials,
    [switch]$InstallCli,
    [switch]$Full
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:StoreRoot = $StoreRoot
if (-not $Remote) { $Remote = Get-StoreRemote }
$remoteConfigured = [bool]$Remote

# Prefer a per-user directory that is already on PATH; fall back to ~/.local/bin.
function Resolve-CliDir {
    param([string]$Explicit)
    if ($Explicit) {
        New-Item -ItemType Directory -Force -Path $Explicit | Out-Null
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $sep = [string][System.IO.Path]::PathSeparator
    $entries = @($env:PATH -split [regex]::Escape($sep) | Where-Object { $_ } |
        ForEach-Object { $_.Trim('"') } | Select-Object -Unique)
    $userDirs = @($entries |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container -ErrorAction SilentlyContinue } |
        Where-Object { $_.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase) })
    foreach ($preferred in @((Join-Path $HOME '.local/bin'), (Join-Path $HOME 'bin'))) {
        if ($userDirs -contains $preferred) { return $preferred }
    }
    if ($userDirs.Count -gt 0) { return $userDirs[0] }
    $fallback = Join-Path $HOME '.local/bin'
    New-Item -ItemType Directory -Force -Path $fallback | Out-Null
    return $fallback
}

$report = [ordered]@{}

if (-not (Test-Path -LiteralPath (Join-Path $StoreRoot '.git'))) {
    if ($NoClone) { $report.store = 'missing (clone skipped)' }
    elseif (-not $Remote) { $report.store = 'missing, no remote configured (pass -Remote <owner/repo> or set GITMEMO_REMOTE)' }
    elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $report.store = 'missing, and gh is not installed' }
    else {
        $out = & gh repo clone $Remote $StoreRoot -- --quiet 2>&1
        $report.store = if (Test-Path -LiteralPath (Join-Path $StoreRoot '.git')) { "cloned to $StoreRoot" } else { "clone failed: $out" }
    }
} else { $report.store = "present at $StoreRoot" }

$storeIsRepo = Test-Path -LiteralPath (Join-Path $StoreRoot '.git')
if ($storeIsRepo -and -not $SkipCredentials) {
    # A private repo cloned with gh needs the helper on the repo itself, otherwise pull
    # and push fail with "Repository not found" on the next machine.
    $helper = & git -C $StoreRoot config --local --get 'credential.https://github.com.helper' 2>$null
    if (-not $helper -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        & git -C $StoreRoot config --local --replace-all credential.helper '' 2>&1 | Out-Null
        & git -C $StoreRoot config --local --replace-all 'credential.https://github.com.helper' '!gh auth git-credential' 2>&1 | Out-Null
        $report.credentials = 'configured (gh auth git-credential)'
    } elseif ($helper) { $report.credentials = "already set ($helper)" }
    else { $report.credentials = 'gh not installed, pull/push over https needs a token' }
}

# .gitattributes is written for every store: git must never normalise a transcript, or
# the committed blob stops matching the manifest's bytes/sha256. .gitignore keeps the
# local hook log out of the store history.
if ($storeIsRepo) { [void](Initialize-StoreAttributes -Store $StoreRoot -Source 'install') }
if ($storeIsRepo) { [void](Initialize-StoreIgnore -Store $StoreRoot -Source 'install') }

# Storage mode: transcripts stay in git and on GitHub, the working tree keeps only the
# files a session needs, so local disk stays flat no matter how many sessions pile up.
if ($storeIsRepo -and -not $Full) {
    if (Initialize-StoreSparse -Store $StoreRoot -Source 'install') {
        $tree = (Get-ChildItem -LiteralPath $StoreRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | Measure-Object Length -Sum).Sum
        $report.storage = "sparse: working tree $([math]::Round($tree / 1KB, 1)) KB, transcripts kept in the cloud"
    } else { $report.storage = 'sparse checkout failed, store stays full' }
} elseif ($storeIsRepo) { $report.storage = 'full working tree (hooks re-enable sparse on their next run)' }

if (-not $SkipHooks -and $storeIsRepo) {
    $parseFailed = $false
    $existingRaw = $null
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $HooksFile) {
        $existingRaw = Get-Content -LiteralPath $HooksFile -Raw
        try {
            $existing = $existingRaw | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $config[$p.Name] = @($p.Value) }
        } catch { $parseFailed = $true }
    }

    # Retire the prototype's hooks: two capture paths would store every session twice.
    $legacyRemoved = 0
    foreach ($event in @($config.Keys)) {
        $groups = @()
        foreach ($g in @($config[$event])) {
            $hooks = @()
            foreach ($h in @($g.hooks)) {
                if ($h.command -and "$($h.command)" -like '*agent-memory*') { $legacyRemoved++; continue }
                $hooks += $h
            }
            if ($hooks.Count -gt 0) {
                if ($g.PSObject.Properties['hooks']) { $g.hooks = $hooks }
                $groups += $g
            }
        }
        $config[$event] = $groups
    }

    $definitions = @(
        [pscustomobject]@{ event = 'SessionStart'; script = 'session-start.ps1'; timeout = 25 },
        [pscustomobject]@{ event = 'SessionEnd';   script = 'session-end.ps1';   timeout = 90 }
    )
    $added = @()
    foreach ($d in $definitions) {
        $scriptPath = Join-Path $PSScriptRoot $d.script
        $command = 'pwsh -NoProfile -File "' + $scriptPath + '"'
        $groups = @()
        if ($config.Contains($d.event)) { $groups = @($config[$d.event]) }
        $already = $false
        foreach ($g in $groups) { foreach ($h in @($g.hooks)) { if ($h.command -and $h.command -like "*$($d.script)*") { $already = $true } } }
        if (-not $already) {
            $groups += [pscustomobject]@{
                hooks = @([pscustomobject]@{ type = 'command'; command = $command; timeout = $d.timeout })
            }
            $added += $d.event
        }
        $config[$d.event] = $groups
    }

    $newRaw = $config | ConvertTo-Json -Depth 12
    $changed = $parseFailed -or ($newRaw.Trim() -ne ([string]$existingRaw).Trim())
    if ($changed) {
        $dir = Split-Path -Path $HooksFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Back up once: a later change must not overwrite the pre-install original.
        if ($existingRaw -and -not (Test-Path -LiteralPath "$HooksFile.bak")) {
            Copy-Item -LiteralPath $HooksFile -Destination "$HooksFile.bak" -Force
            $report.backup = "$HooksFile.bak"
        }
        Set-Content -LiteralPath $HooksFile -Value $newRaw -Encoding utf8
        $report.hooksFile = $HooksFile
        $report.hooksRegistered = if ($added.Count) { $added -join ', ' } else { 'updated (legacy hooks removed)' }
    } else {
        $report.hooksFile = $HooksFile
        $report.hooksRegistered = 'already present (no change)'
    }
    if ($legacyRemoved -gt 0) { $report.legacyRemoved = "$legacyRemoved hook(s)" }
}

if ($InstallCli) {
    $dir = Resolve-CliDir -Explicit $CliDir
    $launcher = Join-Path (Split-Path -Path $PSScriptRoot -Parent) (Join-Path 'bin' 'git-memo.ps1')
    $shim = Join-Path $dir 'git-memo'
    $content = "#!/bin/sh`nexec pwsh -NoProfile -File `"$launcher`" `"`$@`"`n"
    Set-Content -LiteralPath $shim -Value $content -NoNewline -Encoding utf8
    if (-not $IsWindows) { & chmod +x $shim 2>&1 | Out-Null }
    $sep = [string][System.IO.Path]::PathSeparator
    $onPath = @($env:PATH -split [regex]::Escape($sep)) -contains $dir
    $report.cli = if ($onPath) { $shim } else { "$shim (directory is not on PATH - add $dir)" }
}

Write-Output 'gitmemo install'
Write-Output '==============='
foreach ($k in $report.Keys) { Write-Output ("{0,-17}: {1}" -f $k, $report[$k]) }
Write-Output ''
if (-not $remoteConfigured) {
    Write-Output 'No store remote configured. Set one and re-run:'
    Write-Output '  $env:GITMEMO_REMOTE = ''<owner/repo>'''
    Write-Output '  pwsh -File install.ps1 -Remote <owner/repo>'
    Write-Output ''
}
Write-Output 'Check it:'
Write-Output ('  pwsh -File "' + (Join-Path $PSScriptRoot 'search.ps1') + '" -List')
Write-Output ('  pwsh -File "' + (Join-Path $PSScriptRoot 'search.ps1') + '" -Query "why" -Sessions')
exit 0
