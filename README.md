<p align="center"><img src="assets/logo.svg" alt="gitmemo logo: a git branch next to a stack of notes" width="112"></p>

<h1 align="center">gitmemo</h1>

<p align="center">
  Durable project memory across Droid sessions and machines: notes at session start, redacted transcripts at session end.
</p>

<p align="center">
  <a href="https://github.com/Krow-zy/gitmemo/actions/workflows/ci.yml"><img src="https://github.com/Krow-zy/gitmemo/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/Krow-zy/gitmemo/releases"><img src="https://img.shields.io/github/v/release/Krow-zy/gitmemo" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey.svg" alt="Windows and Linux">
  <img src="https://img.shields.io/badge/Droid-plugin-6f42c1.svg" alt="Droid plugin">
</p>

`gitmemo` is a Droid plugin. A `SessionStart` hook prints the project's distilled
`notes.md` into the session context, and a `SessionEnd` hook captures the finished
transcript into a private git repository. The next session, on any machine, starts with
the decisions and traps of the previous ones instead of repeating them.

The store is a git repository you own. Nothing is sent anywhere else, and the plugin
never writes into the repository you are working on.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Enable the plugin](#enable-the-plugin)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Limits](#limits)
- [License](#license)

## Requirements

- Droid, with plugins enabled.
- PowerShell 7 (`pwsh`) on `PATH`.
- `git` 2.34 or newer.
- `gh`, authenticated (`gh auth login`), for cloning and pushing the private store.

## Install

Add the marketplace and install the plugin:

```pwsh
droid plugin marketplace add Krow-zy/gitmemo
droid plugin install gitmemo@gitmemo --scope project
```

Install into a private store you own. There is no default remote, so set one in the shell
that launches Droid:

```pwsh
$env:GITMEMO_REMOTE = 'your-name/gitmemo-store'
```

`SessionStart` clones that repository to `GITMEMO_HOME` the first time it is missing and
`gh` is authenticated. Without a configured remote the hooks stay silent and log
`no store configured` to `~/.gitmemo/hooks/hook.log`. Cloning the store to `GITMEMO_HOME`
by hand works too.

For a checkout without the plugin system, register the hooks manually:

```pwsh
pwsh -NoProfile -File ./plugin/hooks/install.ps1 -Remote your-name/gitmemo-store
```

The installer is idempotent, removes old `agent-memory` hook registrations, configures the
credential helper for the private remote, writes the store's `.gitattributes`, and enables
sparse checkout. `-InstallCli` also writes a `git-memo` shim to the first per-user
directory on `PATH` (or `~/.local/bin` when there is none) and prints the path. `-Full`
skips the sparse step, but the hooks re-apply sparse
mode on their next run: they own low-disk mode, so an existing store reaches it without
the installer.

Pick up a later version with `droid plugin update gitmemo`, or reinstall as above. The
plugin installs nothing else: no global config, no shell profile changes.

To remove it: `droid plugin uninstall gitmemo@gitmemo`, then delete the `gitmemo`
entry from `enabledPlugins`. The store is a separate git repository; deleting it is your
decision, not the plugin's, and nothing else on the machine refers to it.

## Enable the plugin

Installing is not enabling. Droid shows the plugin but leaves it off until settings say
otherwise, and it stays off in every new session. Run `/plugins` and turn it on, or set it
in the user scope, `~/.factory/settings.json`:

```json
{
  "enabledPlugins": {
    "gitmemo@gitmemo": true
  }
}
```

Project scope works the same way in `.factory/settings.json` inside the repository, which
is what a team should commit. Restart the session after the change: hooks load at session
start.

## Quick start

The hooks do the work; these commands read what they stored. The direct script path works
everywhere, because Droid does not add a plugin's `bin` directory to `PATH`:

```pwsh
pwsh -NoProfile -File ./plugin/hooks/search.ps1 -List
pwsh -NoProfile -File ./plugin/hooks/search.ps1 -Query "why was the parser dropped"
pwsh -NoProfile -File ./plugin/hooks/search.ps1 -Query "backoff" -Project demo -Sessions
```

Example output, from a store holding one project called `demo`. The transcript filename is
shortened to `<date>-abc12345.jsonl` and long transcript lines are trimmed with `...`:

```text
gitmemo: demo abc12345 captured (4 messages) - committed locally (push skipped)

pwsh -NoProfile -File ./plugin/hooks/search.ps1 -Query "generator"
projects/demo/notes.md:4: - Parser is hand-written; the generator needed 40 MB and compiled for 90 s.

pwsh -NoProfile -File ./plugin/hooks/search.ps1 -Query "backoff" -Sessions
(from git objects, nothing written to disk)
projects/demo/sessions/<date>-abc12345.jsonl:2: {"type":"assistant","message":{... "Added retries with exponential backoff in upload.ps1"}}

pwsh -NoProfile -File ./plugin/hooks/search.ps1 -List
project notes sessions
------- ----- --------
demo     True        1
```

Inside a Droid session the plugin's skill expands `${DROID_PLUGIN_ROOT}`, so the same
search is `pwsh -NoProfile -File "${DROID_PLUGIN_ROOT}/hooks/search.ps1" -Query "text"`.

`git memo` is the short form and needs the shim on `PATH`:

```pwsh
pwsh -NoProfile -File ./plugin/hooks/install.ps1 -InstallCli   # writes it and prints the path
```

To keep the launcher out of `PATH`, run the CLI script directly:
`pwsh -NoProfile -File ./plugin/bin/git-memo.ps1 search "text"`. To add the launcher by
hand:

```pwsh
# Windows, current shell
$env:PATH = "$PWD\plugin\bin;$env:PATH"
# Linux
export PATH="$PWD/plugin/bin:$PATH"
```

## Commands

Every search below also runs as `pwsh -NoProfile -File ./plugin/hooks/search.ps1` with the
matching switches (`-Query`, `-Sessions`, `-Project`, `-Max`, `-List`). `notes` and `status`
live in the CLI only: `pwsh -NoProfile -File ./plugin/bin/git-memo.ps1 notes`.

| Command | What it does |
|---|---|
| `git memo search <text>` | Searches `notes.md`, `index.md` and `manifest.jsonl` |
| `git memo search <text> --sessions` | Adds the raw transcripts to the search; in low-disk mode from the git objects |
| `git memo search <text> --project <name>` | Limits the search to one project slug |
| `git memo search <text> --max <n>` | Caps the number of result lines (default 40) |
| `git memo notes` | Prints the current project's `notes.md` and its path |
| `git memo notes path` | Prints the absolute path only, creating the directory |
| `git memo status` | Store location, remote, branch, sparse mode and captured projects |

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `GITMEMO_HOME` | `~/.gitmemo` | Location of the store clone |
| `GITMEMO_REMOTE` | unset | `owner/repo` cloned into `GITMEMO_HOME` when the store is missing |
| Sparse mode | on | Working tree keeps notes, index and manifest; transcripts stay in git |
| `-MaxMegabytes` (`session-end.ps1`) | `50` | Transcripts above the cap are skipped and logged, not truncated |
| `-NoPush` (`session-end.ps1`) | off | Commit locally and skip the push, for offline or air-gapped runs |
| `-Force` (`session-end.ps1`) | off | Re-capture a session id that is already in the manifest |
| Redaction patterns | 9 | Credential shapes replaced with `[REDACTED]` before the transcript is stored |
| Low-disk patterns | 7 paths | `/README.md`, `/.gitattributes`, `/.gitignore`, `/hooks/`, `/projects/*/notes.md`, `/projects/*/index.md`, `/projects/*/manifest.jsonl` |
| Hook timeouts | `25` s start, `90` s end | Set in `plugin/hooks/hooks.json`; a slower hook is killed by Droid |

Raising the capture cap: pass `-MaxMegabytes <n>` when running `session-end.ps1` by hand.
The hook itself always uses the default, so a session above 50 MB is skipped by the plugin
rather than captured.

Set the environment variables in the shell that launches Droid. The store remote is read
at clone time; after that, `origin` in the store clone is authoritative. An unset
`GITMEMO_REMOTE` is not an error: the hooks skip the session and log the reason.

Sparse mode is enforced by the hooks on every run: `SessionStart` and `SessionEnd` check
`core.sparseCheckout` and re-apply the patterns when they are missing, so an existing
store switches to low-disk mode without an installer step.

## How it works

| What you see | Where it comes from |
|---|---|
| Project memory at session start | `hooks/session-start.ps1` prints `projects/<slug>/notes.md` and the index tail |
| `projects/<slug>/manifest.jsonl` | One row per capture: session, file, bytes, messages, sha256, redactions |
| `projects/<slug>/index.md` | Regenerated from the manifest by `session-end.ps1` |
| `projects/<slug>/sessions/*.jsonl` | Redacted transcript, stored in git |
| `.gitattributes` in the store | `* -text`, written on store init so a transcript commits byte-for-byte |
| `.gitignore` in the store | `hooks/hook.log`, created only when the store has no ignore file of its own |
| `hooks/hook.log` | Every skipped or failed hook path, with the reason |

The slug is the repository name from `git remote get-url origin`, lowercased. Dedup is by
session id, so a session that ends twice is captured once. A failed push keeps the commit
locally and is retried on the next capture. Each manifest row records the byte count and
sha256 of the committed blob, and a test captures a CRLF transcript to prove the committed
bytes still match.

Search, capture and storage are implemented in PowerShell and use only `git` and built-in
PowerShell cmdlets. [docs/DESIGN.md](docs/DESIGN.md) covers the data flow, measurements
and traps.

## Troubleshooting

Every skipped or failed hook path is written to `hooks/hook.log` inside the store, with
the reason. Start there.

| Symptom | Cause | Fix |
|---|---|---|
| `git memo` is not found | Droid never adds a plugin's `bin` directory to `PATH` | run `install.ps1 -InstallCli`, or call `plugin/hooks/search.ps1` directly |
| The plugin is listed but no hook ever runs | installing is not enabling | set `"gitmemo@gitmemo": true` in settings and restart the session |
| `skip: no store configured` in the hook log | `GITMEMO_REMOTE` is unset and the store is missing | set `GITMEMO_REMOTE`, or clone the store into `GITMEMO_HOME` by hand |
| `push failed`, or a `403` on a private store | no credential helper for the store remote | `gh auth login`, then re-run `install.ps1 -Remote <owner/repo>` |
| One session captured twice | two capture paths are registered: the plugin plus leftover hand-written hooks | keep one, and remove the old registrations from `~/.factory/hooks.json` |
| `sessions` reads `0` although transcripts exist on the remote | the store's sparse patterns are missing `manifest.jsonl` | re-run any hook or `install.ps1`: both re-apply the patterns |

## Development

```pwsh
git clone https://github.com/Krow-zy/gitmemo
pwsh -NoProfile -File ./tests/run-tests.ps1
```

Fifteen tests run against temporary stores with no network and no real user data. CI runs
the same suite plus PSScriptAnalyzer (error severity fails) on `windows-latest` and
`ubuntu-latest`. The skill that teaches an agent to search and maintain the store is at
`plugin/skills/gitmemo/SKILL.md`.

Tagging `v*` runs the release workflow, which reruns the tests and attaches
`gitmemo-plugin.zip` to the GitHub Release.

## Limits

- `.git` grows with history: about 160 KB per 1.87 MB session in the measured sample.
  The working tree stays flat, but the object database does not shrink.
- A transcript larger than 50 MB is skipped by default (`-MaxMegabytes`).
- Windows and Linux are supported. macOS is not tested.
- Redaction is pattern-based. A credential with an unusual shape can survive; the store
  is private for that reason.
- Nothing prunes old sessions yet. There is no retention policy.
- Search is case-sensitive substring matching, not semantic search.
- `--sessions` adds the transcripts to the text scope. A transcript hit is a raw JSONL
  line, trimmed at 300 characters, not a summary.
- Filenames use the first 8 characters of the session id; the manifest keeps the full id.
- The plugin does not capture attachments, images or binary payloads.

## License

MIT, see [LICENSE](LICENSE).
