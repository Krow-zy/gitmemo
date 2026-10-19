#requires -Version 7
<#
search.ps1 - search the private gitmemo store.

    pwsh -File search.ps1 -Query "why was the parser dropped"
    pwsh -File search.ps1 -Query "rc.exe" -Project trafficdesk -Sessions
    pwsh -File search.ps1 -List

Default scope is notes.md + index.md + manifest.jsonl. Add -Sessions to search the raw
transcripts too (that is where the full conversation lives).

Search uses git and built-in PowerShell only; ripgrep is not required.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Query,
    [string]$Project,
    [int]$Max = 40,
    [switch]$Sessions,
    [switch]$List
)

. (Join-Path $PSScriptRoot 'lib.ps1')
$ErrorActionPreference = 'Continue'

$store = Get-StoreRoot
if (-not (Test-Path -LiteralPath $store)) { Write-Output "store not found at $store"; exit 1 }

if ($List) {
    $projectsDir = Join-Path $store 'projects'
    if (-not (Test-Path -LiteralPath $projectsDir)) { Write-Output 'no projects captured yet'; exit 0 }
    # Careful: a local named $sessions would collide with the -Sessions switch parameter,
    # because PowerShell variable names are case-insensitive.
    $rows = Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $hasNotes = Test-Path -LiteralPath (Join-Path $_.FullName 'notes.md')
        # Counted from the manifest, not from the files on disk: in low-disk mode the
        # transcripts are not checked out and would otherwise read as zero.
        $manifest = Join-Path $_.FullName 'manifest.jsonl'
        $captured = if (Test-Path -LiteralPath $manifest) {
            @([System.IO.File]::ReadLines($manifest) | Where-Object { $_.Trim() }).Count
        } else { 0 }
        [pscustomobject]@{ project = $_.Name; notes = $hasNotes; sessions = $captured }
    }
    $rows | Sort-Object project | Format-Table -AutoSize | Out-String -Width 120
    exit 0
}

if (-not $Query) { Write-Output 'usage: search.ps1 -Query "<text>" [-Project name] [-Sessions] [-List]'; exit 1 }

$root = if ($Project) { Join-Path $store (Join-Path 'projects' $Project) } else { Join-Path $store 'projects' }
if (-not (Test-Path -LiteralPath $root)) { Write-Output "no such project: $Project"; exit 1 }

# Low-disk mode keeps the transcripts out of the working tree. They are still in the
# object database, so read them from there instead of checking 12 MB back out. A plain
# `git grep` reads committed blobs and writes nothing.
$sparse = ((& git -C $store config --get core.sparseCheckout 2>$null) -eq 'true')

# -Sessions adds the transcripts to the text scope instead of replacing it: a query that
# is answered in notes.md has to be found in the same run that also wants transcripts.
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    if ($_.Name -in @('notes.md', 'index.md', 'manifest.jsonl')) { $true }
    elseif ($Sessions -and $_.Extension -eq '.jsonl') { $true }
    else { $false }
})

$hits = @()
foreach ($file in $files) {
    $found = @(Select-String -LiteralPath $file.FullName -Pattern $Query -SimpleMatch -CaseSensitive -ErrorAction SilentlyContinue |
        Select-Object -First 6)
    foreach ($m in $found) {
        $rel = $file.FullName
        if ($rel.StartsWith($store, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($store.Length).TrimStart([char[]]@('\', '/'))
        }
        $text = "$($m.Line)"
        if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + ' ...' }
        $hits += ('{0}:{1}:{2}' -f $rel, $m.LineNumber, $text)
    }
}

$sessionHits = @()
if ($Sessions -and $sparse) {
    $spec = if ($Project) { "projects/$Project/sessions/*.jsonl" } else { 'projects/*/sessions/*.jsonl' }
    $raw = & git -C $store grep --no-color -n -I -m 6 -e $Query HEAD -- $spec 2>&1
    if ($LASTEXITCODE -gt 1) { Write-Output "search failed: $raw"; exit 1 }
    foreach ($hit in @($raw)) {
        $line = "$hit" -replace '^HEAD:', ''
        if ($line.Length -gt 300) { $line = $line.Substring(0, 300) + ' ...' }
        $sessionHits += $line
    }
}

$total = $hits.Count + $sessionHits.Count
if ($total -eq 0) { Write-Output "no matches for '$Query'"; exit 0 }

$shown = 0
foreach ($hit in $hits) { if ($shown -ge $Max) { break }; Write-Output $hit; $shown++ }
if ($sessionHits.Count -gt 0) {
    Write-Output '(transcripts read from git objects, nothing written to disk)'
    foreach ($hit in $sessionHits) { if ($shown -ge $Max) { break }; Write-Output $hit; $shown++ }
}
if ($total -gt $shown) { Write-Output "... ($($total - $shown) more lines, raise -Max)" }
exit 0
