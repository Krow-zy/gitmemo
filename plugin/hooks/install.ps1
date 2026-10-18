#requires -Version 7
<#
install.ps1 - connect a machine to the private gitmemo store and register the hooks.

This is the manual install path. It shadows nothing in the plugin: plugin installs get
hooks/hooks.json instead.

    pwsh -File install.ps1 -Sparse

It clones the store when missing, fixes the credential helper for the private remote,
switches on sparse checkout (low-disk mode, the default), and registers SessionStart and
SessionEnd in ~/.factory/hooks.json. It also removes legacy hooks whose command mentions
`agent-memory`, so a session is never captured twice. Pass -Full for a complete checkout.

Idempotent: a second run writes nothing. An existing hooks.json is backed up once to
hooks.json.bak, and only when the file actually changes.
#>
[CmdletBinding()]
param(
    [string]$StoreRoot = $(if ($env:GITMEMO_HOME) { $env:GITMEMO_HOME } else { Join-Path $HOME '.gitmemo' }),
    [string]$Remote = '',
    [string]$HooksFile = (Join-Path $HOME (Join-Path '.factory' 'hooks.json')),
    [switch]$NoClone,
    [switch]$SkipHooks,
    [switch]$SkipCredentials,
    [switch]$Full
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:StoreRoot = $StoreRoot
if (-not $Remote) { $Remote = Get-StoreRemote }

$report = [ordered]@{}

if (-not (Test-Path -LiteralPath (Join-Path $StoreRoot '.git'))) {
    if ($NoClone) { $report.store = 'missing (clone skipped)' }
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

# Storage mode: transcripts stay in git and on GitHub, the working tree keeps only the
# files a session needs, so local disk stays flat no matter how many sessions pile up.
if ($storeIsRepo -and -not $Full) {
    if (Enable-StoreSparse -Store $StoreRoot -Source 'install') {
        $tree = (Get-ChildItem -LiteralPath $StoreRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | Measure-Object Length -Sum).Sum
        $report.storage = "sparse: working tree $([math]::Round($tree / 1KB, 1)) KB, transcripts kept in the cloud"
    } else { $report.storage = 'sparse checkout failed, store stays full' }
} elseif ($storeIsRepo) { $report.storage = 'full working tree' }

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

Write-Output 'gitmemo install'
Write-Output '==============='
foreach ($k in $report.Keys) { Write-Output ("{0,-17}: {1}" -f $k, $report[$k]) }
Write-Output ''
Write-Output 'Check it:'
Write-Output ('  pwsh -File "' + (Join-Path $PSScriptRoot 'search.ps1') + '" -List')
Write-Output ('  pwsh -File "' + (Join-Path $PSScriptRoot 'search.ps1') + '" -Query "why" -Sessions')
exit 0
