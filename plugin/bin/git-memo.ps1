#requires -Version 7
<#
git-memo.ps1 - the `git memo` CLI.

    git memo search "why was the parser dropped" [-Sessions] [-Project name] [-Max 40]
    git memo notes [path]
    git memo status

The launchers next to this file are named `git-memo` and `git-memo.cmd`, which is what
git resolves for `git memo`.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Continue'
$hookDir = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'hooks'
. (Join-Path $hookDir 'lib.ps1')

function Show-Usage {
    @'
git memo - search and inspect durable project memory

usage:
  git memo search <text> [--sessions] [--project <name>] [--max <n>]
  git memo notes [path]
  git memo status

  search        notes, index and manifest by default; add --sessions for transcripts
  notes         print the project's notes.md (or only its path with `notes path`)
  status        store location, remote, branch, sparse mode and captured projects
'@ | Write-Output
}

switch ($Command) {
    'search' {
        $search = @{}
        $words = @()
        for ($i = 0; $i -lt $Rest.Count; $i++) {
            switch -Regex ($Rest[$i]) {
                '^-{1,2}(sessions?)$' { $search.Sessions = $true }
                '^-{1,2}project$' { $i++; $search.Project = $Rest[$i] }
                '^-{1,2}max$' { $i++; $search.Max = [int]$Rest[$i] }
                default { $words += $Rest[$i] }
            }
        }
        if ($words.Count -eq 0) { Write-Output 'usage: git memo search <text> [--sessions] [--project <name>] [--max <n>]'; exit 1 }
        $search.Query = $words -join ' '
        $argsList = @('-NoProfile', '-File', (Join-Path $hookDir 'search.ps1'))
        foreach ($key in $search.Keys) {
            # A switch must be passed alone; "True" would bind to the next positional arg.
            if ($search[$key] -is [bool]) { if ($search[$key]) { $argsList += "-$key" } }
            else { $argsList += @("-$key", "$($search[$key])") }
        }
        & pwsh @argsList
        exit $LASTEXITCODE
    }
    'notes' {
        $slug = Get-ProjectSlug -Directory (Get-Location).Path
        $notes = Join-Path (Get-StoreRoot) (Join-Path 'projects' (Join-Path $slug 'notes.md'))
        if ($Rest -contains 'path') {
            if (-not (Test-Path -LiteralPath (Split-Path -Path $notes -Parent))) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Path $notes -Parent) | Out-Null
            }
            Write-Output $notes
            exit 0
        }
        Write-Output "# $slug"
        Write-Output "path: $notes"
        Write-Output ''
        if (Test-Path -LiteralPath $notes) { Write-Output (Get-Content -LiteralPath $notes -Raw) }
        else { Write-Output 'no notes yet - write them before the next session, not after it' }
        exit 0
    }
    'status' {
        $store = Get-StoreRoot
        Write-Output "store:   $store"
        if (Test-Path -LiteralPath (Join-Path $store '.git')) {
            $remote = & git -C $store remote get-url origin 2>$null
            $branch = & git -C $store rev-parse --abbrev-ref HEAD 2>$null
            $sparse = ((& git -C $store config --get core.sparseCheckout 2>$null) -eq 'true')
            $pending = @(& git -C $store status --porcelain 2>$null).Count
            Write-Output "remote:  $remote"
            Write-Output "branch:  $branch"
            Write-Output "sparse:  $sparse"
            Write-Output "pending: $pending change(s)"
        } else {
            Write-Output 'store not initialized - run plugin/hooks/install.ps1'
        }
        Write-Output ''
        & pwsh -NoProfile -File (Join-Path $hookDir 'search.ps1') -List
        exit $LASTEXITCODE
    }
    { $_ -in @('', 'help', '-h', '--help') } {
        Show-Usage
        exit 0
    }
    default {
        Write-Output "unknown command: $Command"
        Write-Output ''
        Show-Usage
        exit 1
    }
}
