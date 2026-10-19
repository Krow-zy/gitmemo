#requires -Version 7
<#
run-tests.ps1 - gitmemo test suite. No Pester, no network, no real user data.

    pwsh -NoProfile -File tests/run-tests.ps1 [-KeepTemp]

Every test prints PASS or FAIL with a reason. Exit code 1 when any test fails.
All stores live under the system temp directory.
#>
[CmdletBinding()]
param(
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Path $PSScriptRoot -Parent
$hooks = Join-Path (Join-Path $repo 'plugin') 'hooks'
$fixtures = Join-Path $PSScriptRoot 'fixtures'

$script:passes = 0
$script:failures = 0
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gitmemo-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passes++
        Write-Output ('PASS  {0}' -f $Name)
    } catch {
        $script:failures++
        Write-Output ('FAIL  {0}: {1}' -f $Name, $_.Exception.Message)
    }
}

function Invoke-Script {
    param(
        [string]$Script,
        [string[]]$Arguments = @(),
        [string]$Store,
        [AllowNull()][string]$Stdin = $null
    )
    $previous = $env:GITMEMO_HOME
    $env:GITMEMO_HOME = $Store
    try {
        # Always pipe (possibly nothing) so a hook can never block waiting on stdin.
        $output = $Stdin | & pwsh -NoProfile -File $Script @Arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = (@($output) | ForEach-Object { "$_" }) -join "`n"
        }
    } finally {
        $env:GITMEMO_HOME = $previous
    }
}

function New-TestStore {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    & git -C $Path init -q -b main 2>&1 | Out-Null
    & git -C $Path config user.name 'gitmemo tests' 2>&1 | Out-Null
    & git -C $Path config user.email 'tests@example.invalid' 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value '# test store' -Encoding utf8
    & git -C $Path add -A 2>&1 | Out-Null
    & git -C $Path commit -q -m 'init' 2>&1 | Out-Null
}

function New-TestProject {
    param([string]$Path, [string]$Remote)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    & git -C $Path init -q -b main 2>&1 | Out-Null
    & git -C $Path config user.name 'gitmemo tests' 2>&1 | Out-Null
    & git -C $Path config user.email 'tests@example.invalid' 2>&1 | Out-Null
    if ($Remote) { & git -C $Path remote add origin $Remote 2>&1 | Out-Null }
}

function Set-SparsePatterns {
    param([string]$Store)
    & git -C $Store sparse-checkout set --no-cone '/README.md' '/hooks/' '/projects/*/notes.md' '/projects/*/index.md' '/projects/*/manifest.jsonl' 2>&1 | Out-Null
}

function Get-WorkingTreeSize {
    param([string]$Store)
    $sum = (Get-ChildItem -LiteralPath $Store -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

function Get-ManifestRows {
    param([string]$ProjectDir)
    $manifest = Join-Path $ProjectDir 'manifest.jsonl'
    if (-not (Test-Path -LiteralPath $manifest)) { return @() }
    return @([System.IO.File]::ReadLines($manifest) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

# Byte-exact blob contents. `git cat-file` output is captured as a raw stream so CRLF
# bytes survive; PowerShell text pipelines would rewrite them.
function Get-GitBlobBytes {
    param([string]$Store, [string]$Rev)
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($arg in @('-C', $Store, 'cat-file', 'blob', $Rev)) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $buffer = [System.IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($buffer)
    [void]$process.WaitForExit()
    return $buffer.ToArray()
}

$transcriptPlain = Join-Path $fixtures 'session-plain.jsonl'

# --- 1 -----------------------------------------------------------------------
Test-Case '1 every .ps1 parses' {
    $files = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    Assert-True ($files.Count -ge 6) "expected at least 6 scripts, found $($files.Count)"
    $errors = @()
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($e in @($parseErrors)) {
            if ($e) { $errors += ("{0}:{1} {2}" -f $file.Name, $e.Extent.StartLineNumber, $e.Message) }
        }
    }
    Assert-True ($errors.Count -eq 0) ("parser errors: " + ($errors -join ' | '))
}

# --- 2 -----------------------------------------------------------------------
Test-Case '2 redaction' {
    $store = Join-Path $tempRoot 'store-2'
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $env:GITMEMO_HOME = $store
    . (Join-Path $hooks 'lib.ps1')

    $openai = 'sk-' + ('A' * 28)
    $github = 'ghp_' + ('b' * 30)
    $aws = 'AKIA' + ('C' * 16)
    $base64 = 'aGVsbG8gd29ybGQ='
    $sample = "key $openai token $github aws $aws base64 $base64 bare AKIA path C:\Users\someone\project"

    $result = Protect-Text -Text $sample
    Assert-True ($result.text.Contains('[REDACTED]')) 'no [REDACTED] marker in the output'
    Assert-True (-not $result.text.Contains($openai)) 'OpenAI-shaped value survived'
    Assert-True (-not $result.text.Contains($github)) 'GitHub-shaped value survived'
    Assert-True (-not $result.text.Contains($aws)) 'AWS-shaped value survived'
    Assert-True ($result.text.Contains($base64)) 'ordinary base64 was redacted'
    Assert-True ($result.text.Contains('bare AKIA')) 'bare AKIA prefix was redacted'
    Assert-True ($result.text.Contains('C:\Users\someone\project')) 'normal path was altered'

    $total = 0
    foreach ($v in $result.hits.Values) { $total += [int]$v }
    Assert-True ($total -eq 3) "expected 3 redactions, counted $total"
}

# --- 3 -----------------------------------------------------------------------
Test-Case '3 capture round-trip' {
    $store = Join-Path $tempRoot 'store-3'
    New-TestStore $store
    $project = Join-Path $tempRoot 'project-3'
    New-TestProject -Path $project -Remote 'https://github.com/example/My-App.git'

    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-three', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "exit $($run.ExitCode): $($run.Output)"

    $projectDir = Join-Path $store (Join-Path 'projects' 'my-app')
    $rows = @(Get-ManifestRows $projectDir)
    Assert-True ($rows.Count -eq 1) "expected 1 manifest row, found $($rows.Count)"

    $row = $rows[0]
    Assert-True ($row.session -eq 'session-three') "session id is '$($row.session)'"
    Assert-True ($row.file -like 'sessions/*.jsonl') "file is '$($row.file)'"
    # Sparse mode is on for every store now, so the working-tree copy is pruned after the
    # commit; the transcript still has to exist in HEAD.
    $blob = 'HEAD:projects/my-app/' + $row.file
    & git -C $store cat-file -e $blob 2>$null
    Assert-True ($LASTEXITCODE -eq 0) "stored transcript missing at $blob"

    $expectedBytes = (Get-Item -LiteralPath $transcriptPlain).Length
    Assert-True ($row.bytes -eq $expectedBytes) "bytes $($row.bytes), expected $expectedBytes"
    $committedBytes = [int](& git -C $store cat-file -s $blob 2>$null)
    Assert-True ($committedBytes -eq $expectedBytes) "committed blob is $committedBytes bytes, expected $expectedBytes"
    $expectedMessages = @([System.IO.File]::ReadLines($transcriptPlain)).Count
    Assert-True ($row.messages -eq $expectedMessages) "messages $($row.messages), expected $expectedMessages"
    # No redaction happened, so the stored copy is byte-identical to the fixture.
    $sha = (Get-FileHash -LiteralPath $transcriptPlain -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($row.sha256 -eq $sha) 'sha256 mismatch'
    Assert-True ($row.redactions -eq 0) "redactions $($row.redactions), expected 0"

    $index = Get-Content -LiteralPath (Join-Path $projectDir 'index.md') -Raw
    Assert-True ($index.Contains('session-three')) 'index.md does not list the session'
    Assert-True ($index.Contains('Total: 1 session(s).')) 'index.md total is wrong'
}

# --- 4 -----------------------------------------------------------------------
Test-Case '4 dedup' {
    $store = Join-Path $tempRoot 'store-4'
    New-TestStore $store
    $project = Join-Path $tempRoot 'project-4'
    New-TestProject -Path $project
    $projectDir = Join-Path $store (Join-Path 'projects' 'project-4')
    $common = @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-four', '-NoPush')

    $first = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store -Arguments $common
    Assert-True ($first.ExitCode -eq 0) "first run failed: $($first.Output)"
    Assert-True (@(Get-ManifestRows $projectDir).Count -eq 1) 'first capture did not add a manifest row'

    $second = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store -Arguments $common
    Assert-True ($second.ExitCode -eq 0) "second run exit $($second.ExitCode)"
    Assert-True ($second.Output -match 'already captured') "second run did not say 'already captured': $($second.Output)"
    Assert-True (@(Get-ManifestRows $projectDir).Count -eq 1) 'duplicate capture added a manifest row'

    $forced = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store -Arguments ($common + @('-Force'))
    Assert-True ($forced.ExitCode -eq 0) "force run failed: $($forced.Output)"
    Assert-True (@(Get-ManifestRows $projectDir).Count -eq 2) 'force run did not add a manifest row'
}

# --- 5 -----------------------------------------------------------------------
Test-Case '5 sparse staging' {
    $store = Join-Path $tempRoot 'store-5'
    New-TestStore $store
    Set-SparsePatterns $store
    $project = Join-Path $tempRoot 'project-5'
    New-TestProject -Path $project
    $projectDir = Join-Path $store (Join-Path 'projects' 'project-5')

    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-five', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "exit $($run.ExitCode): $($run.Output)"
    Assert-True ($run.Output -match 'committed locally') "unexpected result line: $($run.Output)"

    $row = @(Get-ManifestRows $projectDir)[0]
    $relative = 'projects/project-5/' + $row.file
    $tracked = @(& git -C $store ls-tree -r --name-only HEAD -- "projects/project-5/sessions")
    Assert-True ($tracked.Count -eq 1) "git ls-tree found $($tracked.Count) transcript(s)"
    Assert-True ($tracked[0] -eq $relative) "tracked path is '$($tracked[0])', expected '$relative'"

    $workingCopy = Join-Path $store $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-True (-not (Test-Path -LiteralPath $workingCopy)) 'working tree copy was not pruned'
    # hooks/hook.log is written after the commit by design, so untracked log files are
    # expected; no tracked file may be left dirty.
    $status = @(& git -C $store status --porcelain --untracked-files=no 2>&1)
    Assert-True ($status.Count -eq 0) ("tracked files are dirty after capture: " + ($status -join ' | '))
}

# --- 6 -----------------------------------------------------------------------
Test-Case '6 search from objects' {
    $store = Join-Path $tempRoot 'store-6'
    New-TestStore $store
    Set-SparsePatterns $store
    $project = Join-Path $tempRoot 'project-6'
    New-TestProject -Path $project

    $capture = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-six', '-NoPush')
    Assert-True ($capture.ExitCode -eq 0) "capture failed: $($capture.Output)"

    $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $store 'projects') -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '[\\/]sessions$' })
    Assert-True ($onDisk.Count -eq 0) "expected no transcripts on disk, found $($onDisk.Count)"

    $before = Get-WorkingTreeSize $store
    $search = Invoke-Script -Script (Join-Path $hooks 'search.ps1') -Store $store `
        -Arguments @('-Query', 'GITMEMO_TEST_TOKEN_7f3a', '-Sessions')
    $after = Get-WorkingTreeSize $store

    Assert-True ($search.ExitCode -eq 0) "search exit $($search.ExitCode): $($search.Output)"
    Assert-True ($search.Output -match 'from git objects') 'search did not read from git objects'
    Assert-True ($search.Output -match 'GITMEMO_TEST_TOKEN_7f3a') 'search did not find the token'
    Assert-True ($after -eq $before) "working tree size changed: $before -> $after"
}

# --- 7 -----------------------------------------------------------------------
Test-Case '7 SessionStart matrix' {
    $store = Join-Path $tempRoot 'store-7'
    New-TestStore $store
    $project = Join-Path $tempRoot 'matrix-repo'
    New-TestProject -Path $project
    $projectDir = Join-Path $store (Join-Path 'projects' 'matrix-repo')
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
    Set-Content -LiteralPath (Join-Path $projectDir 'notes.md') -Value 'MATRIX_MARKER notes body' -Encoding utf8
    $start = Join-Path $hooks 'session-start.ps1'
    $log = Join-Path $store 'hooks/hook.log'

    $startup = Invoke-Script -Script $start -Store $store `
        -Stdin (@{ cwd = $project; source = 'startup'; session_id = 's7' } | ConvertTo-Json -Compress)
    Assert-True ($startup.ExitCode -eq 0) "startup exit $($startup.ExitCode)"
    Assert-True ($startup.Output -match 'MATRIX_MARKER') "startup did not print memory: $($startup.Output)"

    $compact = Invoke-Script -Script $start -Store $store `
        -Stdin (@{ cwd = $project; source = 'compact'; session_id = 's7' } | ConvertTo-Json -Compress)
    Assert-True ($compact.ExitCode -eq 0) "compact exit $($compact.ExitCode)"
    Assert-True ($compact.Output.Trim() -eq '') "compact printed: $($compact.Output)"
    Assert-True ((Get-Content -LiteralPath $log -Raw) -match 'source=compact') 'compact skip was not logged'

    $unknown = Join-Path $tempRoot 'unknown-repo'
    New-TestProject -Path $unknown
    $none = Invoke-Script -Script $start -Store $store `
        -Stdin (@{ cwd = $unknown; source = 'startup'; session_id = 's7b' } | ConvertTo-Json -Compress)
    Assert-True ($none.ExitCode -eq 0) "unknown repo exit $($none.ExitCode)"
    Assert-True ($none.Output.Trim() -eq '') "unknown repo printed: $($none.Output)"

    $invalid = Invoke-Script -Script $start -Store $store -Stdin '{"cwd": "C:\broken\path", not json'
    Assert-True ($invalid.ExitCode -eq 0) "invalid payload exit $($invalid.ExitCode)"
    Assert-True ($invalid.Output.Trim() -eq '') "invalid payload printed: $($invalid.Output)"
    Assert-True ((Get-Content -LiteralPath $log -Raw) -match 'not valid JSON') 'invalid payload was not logged'
}

# --- 8 -----------------------------------------------------------------------
Test-Case '8 install idempotency' {
    $store = Join-Path $tempRoot 'store-8'
    New-TestStore $store
    $hooksDir = Join-Path $tempRoot 'factory-8'
    New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
    $hooksFile = Join-Path $hooksDir 'hooks.json'

    $legacyStart = 'pwsh -NoProfile -File "C:/opt/agent-memory/hooks/session-start.ps1"'
    $legacyEnd = 'pwsh -NoProfile -File "C:/opt/agent-memory/hooks/session-end.ps1"'
    $initial = @{
        SessionStart = @(
            @{ hooks = @(@{ type = 'command'; command = $legacyStart; timeout = 25 }) },
            @{ hooks = @(@{ type = 'command'; command = 'pwsh -NoProfile -File "C:/tools/keep-me.ps1"'; timeout = 10 }) }
        )
        SessionEnd   = @(@{ hooks = @(@{ type = 'command'; command = $legacyEnd; timeout = 90 }) })
        Stop         = @(@{ hooks = @(@{ type = 'command'; command = 'pwsh -NoProfile -File "C:/tools/stop.ps1"' }) })
    } | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $hooksFile -Value $initial -Encoding utf8

    $install = Join-Path $hooks 'install.ps1'
    $arguments = @('-StoreRoot', $store, '-HooksFile', $hooksFile, '-NoClone', '-SkipCredentials')

    $first = Invoke-Script -Script $install -Store $store -Arguments $arguments
    Assert-True ($first.ExitCode -eq 0) "first install exit $($first.ExitCode): $($first.Output)"

    $config = Get-Content -LiteralPath $hooksFile -Raw | ConvertFrom-Json
    $startCommands = @($config.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
    $endCommands = @($config.SessionEnd | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
    $legacy = @($startCommands + $endCommands | Where-Object { $_ -like '*agent-memory*' })
    Assert-True ($legacy.Count -eq 0) "legacy hooks survived: $($legacy -join ', ')"
    Assert-True (@($startCommands | Where-Object { $_ -like '*session-start.ps1*' }).Count -eq 1) 'expected exactly one gitmemo SessionStart hook'
    Assert-True (@($endCommands | Where-Object { $_ -like '*session-end.ps1*' }).Count -eq 1) 'expected exactly one gitmemo SessionEnd hook'
    Assert-True (@($startCommands | Where-Object { $_ -like '*keep-me.ps1*' }).Count -eq 1) 'unrelated hook was dropped'

    $backup = "$hooksFile.bak"
    Assert-True (Test-Path -LiteralPath $backup) 'no backup was written on a real change'
    Assert-True ((Get-Content -LiteralPath $backup -Raw) -match 'agent-memory') 'backup does not hold the pre-install file'
    Assert-True (@(Get-ChildItem -LiteralPath $hooksDir -Filter 'hooks.json.bak-*').Count -eq 0) 'timestamped backup litter was left behind'

    $backupHash = (Get-FileHash -LiteralPath $backup).Hash
    $afterFirstHash = (Get-FileHash -LiteralPath $hooksFile).Hash

    $second = Invoke-Script -Script $install -Store $store -Arguments $arguments
    Assert-True ($second.ExitCode -eq 0) "second install exit $($second.ExitCode): $($second.Output)"
    Assert-True ((Get-FileHash -LiteralPath $hooksFile).Hash -eq $afterFirstHash) 'second install changed hooks.json'
    Assert-True ((Get-FileHash -LiteralPath $backup).Hash -eq $backupHash) 'second install rewrote the backup'
    Assert-True (@(Get-ChildItem -LiteralPath $hooksDir -File).Count -eq 2) 'second install left extra files behind'

    $freshDir = Join-Path $tempRoot 'factory-8-fresh'
    New-Item -ItemType Directory -Force -Path $freshDir | Out-Null
    $freshFile = Join-Path $freshDir 'hooks.json'
    $fresh = Invoke-Script -Script $install -Store $store -Arguments @('-StoreRoot', $store, '-HooksFile', $freshFile, '-NoClone', '-SkipCredentials')
    Assert-True ($fresh.ExitCode -eq 0) "fresh install exit $($fresh.ExitCode): $($fresh.Output)"
    Assert-True (Test-Path -LiteralPath $freshFile) 'fresh install did not write hooks.json'
    Assert-True (-not (Test-Path -LiteralPath "$freshFile.bak")) 'fresh install created a backup when nothing existed'
}

# --- 9 -----------------------------------------------------------------------
Test-Case '9 no secret leakage' {
    $store = Join-Path $tempRoot 'store-9'
    New-TestStore $store
    $project = Join-Path $tempRoot 'project-9'
    New-TestProject -Path $project

    $openai = 'sk-' + ('D' * 28)
    $github = 'ghp_' + ('E' * 30)
    $aws = 'AKIA' + ('F' * 16)
    $template = Get-Content -LiteralPath (Join-Path $fixtures 'session-credentials.jsonl') -Raw
    $body = $template.Replace('{{OPENAI_KEY}}', $openai).Replace('{{GH_TOKEN}}', $github).Replace('{{AWS_KEY}}', $aws)
    $transcript = Join-Path $tempRoot 'session-credentials.jsonl'
    Set-Content -LiteralPath $transcript -Value $body -NoNewline -Encoding utf8

    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcript, '-SessionId', 'session-nine', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "capture exit $($run.ExitCode): $($run.Output)"

    $projectDir = Join-Path $store (Join-Path 'projects' 'project-9')
    $row = @(Get-ManifestRows $projectDir)[0]
    Assert-True ($row.redactions -ge 3) "manifest redactions is $($row.redactions), expected at least 3"
    # Sparse mode prunes the working-tree copy, so read the committed blob.
    $storedText = (@(& git -C $store show "HEAD:projects/project-9/$($row.file)" 2>$null) -join "`n")
    Assert-True ($storedText.Contains('[REDACTED]')) 'stored transcript has no redaction marker'
    Assert-True (-not $storedText.Contains($openai)) 'stored transcript contains the OpenAI-shaped value'
    Assert-True (-not $storedText.Contains($github)) 'stored transcript contains the GitHub-shaped value'
    Assert-True (-not $storedText.Contains($aws)) 'stored transcript contains the AWS-shaped value'
    & git -C $store grep -F -I -q -e '[REDACTED]' HEAD 2>$null
    Assert-True ($LASTEXITCODE -eq 0) 'the committed transcript has no redaction marker'

    $env:GITMEMO_HOME = $store
    . (Join-Path $hooks 'lib.ps1')
    $files = @(Get-ChildItem -LiteralPath $store -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    foreach ($file in $files) {
        $scan = Protect-Text -Text (Get-Content -LiteralPath $file.FullName -Raw)
        Assert-True ($scan.hits.Count -eq 0) "credential-shaped value in $($file.FullName)"
    }

    foreach ($secret in @($openai, $github, $aws)) {
        & git -C $store grep -F -I -q -e $secret HEAD 2>$null
        Assert-True ($LASTEXITCODE -ne 0) 'a credential survived in the committed tree'
    }
}

# --- 10 ----------------------------------------------------------------------
Test-Case '10 sparse self-heals on an existing store' {
    $store = Join-Path $tempRoot 'store-10'
    New-TestStore $store
    $initial = & git -C $store config --get core.sparseCheckout 2>$null
    Assert-True ($initial -ne 'true') "test store was already sparse ('$initial')"

    $project = Join-Path $tempRoot 'project-10'
    New-TestProject -Path $project

    # No install.ps1 and no successful SessionStart on this store: the capture hook
    # itself has to switch low-disk mode on before it writes.
    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-ten', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "capture exit $($run.ExitCode): $($run.Output)"

    $sparse = & git -C $store config --get core.sparseCheckout 2>$null
    Assert-True ($sparse -eq 'true') "core.sparseCheckout is '$sparse', expected 'true'"

    $tracked = @(& git -C $store ls-tree -r --name-only HEAD -- 'projects/project-10/sessions')
    Assert-True ($tracked.Count -eq 1) "git ls-tree found $($tracked.Count) transcript(s)"
    Assert-True ($tracked[0] -like 'projects/project-10/sessions/*.jsonl') "unexpected tracked path '$($tracked[0])'"

    $sessionsDir = Join-Path $store 'projects/project-10/sessions'
    Assert-True (-not (Test-Path -LiteralPath $sessionsDir)) "sessions directory materialized at $sessionsDir"

    # A store written by 0.1.0 can have sparse mode on with a pattern list that predates
    # .gitattributes, which also prunes the file itself. The next capture has to extend the
    # list and rewrite the file, or a later `sparse-checkout reapply` prunes it for good.
    Set-SparsePatterns $store
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $store '.gitattributes'))) 'old pattern list did not prune .gitattributes'

    $again = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-ten-b', '-NoPush')
    Assert-True ($again.ExitCode -eq 0) "second capture exit $($again.ExitCode): $($again.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $store '.gitattributes')) '.gitattributes was not rewritten'
    $patterns = Get-Content -LiteralPath (Join-Path $store '.git/info/sparse-checkout') -Raw
    Assert-True ($patterns.Contains('/.gitattributes')) 'the old sparse pattern list was not extended'
}

# --- 11 ----------------------------------------------------------------------
Test-Case '11 store is byte-faithful for CRLF transcripts' {
    $store = Join-Path $tempRoot 'store-11'
    New-TestStore $store
    $project = Join-Path $tempRoot 'project-11'
    New-TestProject -Path $project

    $body = '{"type":"user","message":{"role":"user","content":"crlf line one"}}' + "`r`n" +
            '{"type":"assistant","message":{"role":"assistant","content":"crlf line two"}}' + "`r`n"
    $transcript = Join-Path $tempRoot 'session-crlf.jsonl'
    [System.IO.File]::WriteAllText($transcript, $body, [System.Text.UTF8Encoding]::new($false))
    Assert-True ($body.Contains("`r`n")) 'test fixture is not CRLF'

    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcript, '-SessionId', 'session-eleven', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "capture exit $($run.ExitCode): $($run.Output)"

    $projectDir = Join-Path $store (Join-Path 'projects' 'project-11')
    $row = @(Get-ManifestRows $projectDir)[0]
    $attributes = Join-Path $store '.gitattributes'
    Assert-True (Test-Path -LiteralPath $attributes) '.gitattributes was not created'
    Assert-True ((Get-Content -LiteralPath $attributes -Raw).Contains('* -text')) '.gitattributes does not disable text normalisation'
    Assert-True (@(& git -C $store ls-tree -r --name-only HEAD -- '.gitattributes').Count -eq 1) '.gitattributes is not committed'

    $rev = "HEAD:projects/project-11/$($row.file)"
    $bytes = Get-GitBlobBytes -Store $store -Rev $rev
    Assert-True ($bytes.Length -eq $row.bytes) "committed blob is $($bytes.Length) bytes, manifest says $($row.bytes)"
    $sha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    Assert-True ($sha -eq $row.sha256) "committed sha256 is $sha, manifest says $($row.sha256)"
    Assert-True ($bytes.Length -eq (Get-Item -LiteralPath $transcript).Length) 'CRLF transcript was normalised in the commit'

    $patterns = Get-Content -LiteralPath (Join-Path $store '.git/info/sparse-checkout') -Raw
    Assert-True ($patterns.Contains('/.gitattributes')) '.gitattributes is outside the sparse pattern set'
}

# --- 12 ----------------------------------------------------------------------
Test-Case '12 install -InstallCli writes a working shim' {
    $store = Join-Path $tempRoot 'store-12'
    New-TestStore $store
    $hooksDir = Join-Path $tempRoot 'factory-12'
    $cliDir = Join-Path $tempRoot 'cli-12'
    New-Item -ItemType Directory -Force -Path $hooksDir, $cliDir | Out-Null

    $run = Invoke-Script -Script (Join-Path $hooks 'install.ps1') -Store $store `
        -Arguments @('-StoreRoot', $store, '-HooksFile', (Join-Path $hooksDir 'hooks.json'),
            '-NoClone', '-SkipCredentials', '-InstallCli', '-CliDir', $cliDir)
    Assert-True ($run.ExitCode -eq 0) "install exit $($run.ExitCode): $($run.Output)"

    $shim = Join-Path $cliDir 'git-memo'
    Assert-True (Test-Path -LiteralPath $shim) "shim missing at $shim"
    Assert-True ((Get-Content -LiteralPath $shim -Raw) -match 'git-memo\.ps1') 'shim does not point at the CLI script'

    $oldPath = $env:PATH
    $oldHome = $env:GITMEMO_HOME
    $env:PATH = "$cliDir$([System.IO.Path]::PathSeparator)$env:PATH"
    $env:GITMEMO_HOME = $store
    try {
        $out = & git memo 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "git memo exit $LASTEXITCODE"
        Assert-True ((@($out) -join "`n") -match 'git memo - search and inspect') 'the shim did not run the CLI'

        $status = & git memo status 2>&1
        Assert-True ((@($status) -join "`n") -match 'GITMEMO_REMOTE') 'status does not say how to configure a store remote'
    } finally {
        $env:PATH = $oldPath
        $env:GITMEMO_HOME = $oldHome
    }

    # No default remote: a machine with no store and no GITMEMO_REMOTE must stay silent
    # and leave a hint in the log instead of cloning somebody else's repository.
    $missing = Join-Path $tempRoot 'store-12-missing'
    $previousRemote = $env:GITMEMO_REMOTE
    $env:GITMEMO_REMOTE = ''
    try {
        $cold = Invoke-Script -Script (Join-Path $hooks 'session-start.ps1') -Store $missing `
            -Stdin (@{ cwd = $tempRoot; source = 'startup'; session_id = 's12' } | ConvertTo-Json -Compress)
    } finally { $env:GITMEMO_REMOTE = $previousRemote }
    Assert-True ($cold.ExitCode -eq 0) "no-remote start exit $($cold.ExitCode)"
    Assert-True ($cold.Output.Trim() -eq '') "no-remote start printed: $($cold.Output)"
    $log = Join-Path $missing 'hooks/hook.log'
    Assert-True (Test-Path -LiteralPath $log) 'no-remote start wrote no log'
    Assert-True ((Get-Content -LiteralPath $log -Raw) -match 'no store configured') 'no-remote start was not explained in the log'
}

# --- 13 ----------------------------------------------------------------------
Test-Case '13 -Sessions adds the transcripts to the text scope' {
    $store = Join-Path $tempRoot 'store-13'
    New-TestStore $store
    Set-SparsePatterns $store
    $project = Join-Path $tempRoot 'project-13'
    New-TestProject -Path $project
    $projectDir = Join-Path $store (Join-Path 'projects' 'project-13')

    $capture = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-thirteen', '-NoPush')
    Assert-True ($capture.ExitCode -eq 0) "capture failed: $($capture.Output)"
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
    Set-Content -LiteralPath (Join-Path $projectDir 'notes.md') -Value 'NOTES_ONLY_MARKER_9c1f' -Encoding utf8

    # One run has to answer both questions: the hit in notes.md and the hit that only
    # exists in the transcripts, which in low-disk mode live in the object database.
    $search = Invoke-Script -Script (Join-Path $hooks 'search.ps1') -Store $store `
        -Arguments @('-Query', 'NOTES_ONLY_MARKER_9c1f', '-Sessions')
    Assert-True ($search.ExitCode -eq 0) "search exit $($search.ExitCode): $($search.Output)"
    Assert-True ($search.Output -match 'notes\.md') "the notes hit disappeared with -Sessions: $($search.Output)"

    $transcripts = Invoke-Script -Script (Join-Path $hooks 'search.ps1') -Store $store `
        -Arguments @('-Query', 'GITMEMO_TEST_TOKEN_7f3a', '-Sessions')
    Assert-True ($transcripts.ExitCode -eq 0) "search exit $($transcripts.ExitCode)"
    Assert-True ($transcripts.Output -match 'from git objects') "the transcript hit is missing with -Sessions: $($transcripts.Output)"

    $plain = Invoke-Script -Script (Join-Path $hooks 'search.ps1') -Store $store `
        -Arguments @('-Query', 'NOTES_ONLY_MARKER_9c1f')
    Assert-True ($plain.Output -match 'notes\.md') "the notes hit is missing without -Sessions: $($plain.Output)"
    Assert-True ($plain.Output -notmatch 'from git objects') 'the default scope read the objects'
}

# --- 14 ----------------------------------------------------------------------
Test-Case '14 the hook log stays out of the store history' {
    $store = Join-Path $tempRoot 'store-14'
    New-TestStore $store
    $project = Join-Path $tempRoot 'project-14'
    New-TestProject -Path $project

    # A store written before .gitignore existed can already have the log committed.
    New-Item -ItemType Directory -Force -Path (Join-Path $store 'hooks') | Out-Null
    Set-Content -LiteralPath (Join-Path $store 'hooks/hook.log') -Value 'old log line' -Encoding utf8
    & git -C $store add -A 2>&1 | Out-Null
    & git -C $store commit -q -m 'log' 2>&1 | Out-Null
    Assert-True (@(& git -C $store ls-files 'hooks/hook.log').Count -eq 1) 'the test store did not commit the log'

    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-fourteen', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "capture exit $($run.ExitCode): $($run.Output)"

    $ignore = Join-Path $store '.gitignore'
    Assert-True (Test-Path -LiteralPath $ignore) '.gitignore was not written'
    Assert-True ((Get-Content -LiteralPath $ignore -Raw) -match 'hooks/hook\.log') '.gitignore does not cover the hook log'
    Assert-True (@(& git -C $store ls-files 'hooks/hook.log').Count -eq 0) 'the hook log is still tracked'
    Assert-True (@(& git -C $store ls-tree -r --name-only HEAD -- 'hooks/hook.log').Count -eq 0) 'the hook log is still committed'
    Assert-True (Test-Path -LiteralPath (Join-Path $store 'hooks/hook.log')) 'the local log was deleted instead of untracked'

    $patterns = Get-Content -LiteralPath (Join-Path $store '.git/info/sparse-checkout') -Raw
    Assert-True ($patterns.Contains('/.gitignore')) 'the sparse pattern list does not carry .gitignore'
    Assert-True ($patterns.Contains('/.gitattributes')) 'the sparse pattern list does not carry .gitattributes'
}

# --- 15 ----------------------------------------------------------------------
Test-Case '15 a tracked .gitignore is never overwritten' {
    $store = Join-Path $tempRoot 'store-15'
    New-TestStore $store
    $custom = "# rules the store owner wrote`ncustom.tmp`nhooks/hook.log`n"
    Set-Content -LiteralPath (Join-Path $store '.gitignore') -Value $custom -NoNewline -Encoding utf8
    & git -C $store add -A 2>&1 | Out-Null
    & git -C $store commit -q -m 'ignore' 2>&1 | Out-Null

    # Sparse mode from an older release prunes the file, so it is tracked but absent from
    # the working tree. That absence must not look like "no ignore file yet".
    Set-SparsePatterns $store
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $store '.gitignore'))) 'the old pattern list did not prune .gitignore'

    $project = Join-Path $tempRoot 'project-15'
    New-TestProject -Path $project
    $run = Invoke-Script -Script (Join-Path $hooks 'session-end.ps1') -Store $store `
        -Arguments @('-Cwd', $project, '-TranscriptPath', $transcriptPlain, '-SessionId', 'session-fifteen', '-NoPush')
    Assert-True ($run.ExitCode -eq 0) "capture exit $($run.ExitCode): $($run.Output)"

    $path = Join-Path $store '.gitignore'
    Assert-True (Test-Path -LiteralPath $path) '.gitignore was not restored by the sparse re-apply'
    $content = Get-Content -LiteralPath $path -Raw
    Assert-True ($content -match 'custom\.tmp') "the store's own rules were replaced: $content"
    $committed = @(& git -C $store show 'HEAD:.gitignore') -join "`n"
    Assert-True ($committed -match 'custom\.tmp') 'the commit dropped the custom rules'
    $status = @(& git -C $store status --porcelain --untracked-files=no)
    Assert-True ($status.Count -eq 0) ('tracked files are dirty: ' + ($status -join ' | '))
}

# --- summary -----------------------------------------------------------------
Write-Output ''
Write-Output ('{0} passed, {1} failed' -f $script:passes, $script:failures)
if ($script:failures -gt 0 -or $KeepTemp) {
    Write-Output "temp: $tempRoot"
} else {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit ([int]($script:failures -gt 0))
