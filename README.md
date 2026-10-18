<h1 align="center">gitmemo</h1>

<p align="center">
  <a href="https://github.com/Krow-zy/gitmemo/actions/workflows/ci.yml"><img src="https://github.com/Krow-zy/gitmemo/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey.svg" alt="Windows and Linux">
</p>

Durable project memory across Droid sessions and machines: notes at session start, redacted transcripts at session end.

`gitmemo` is a Droid plugin. A `SessionStart` hook prints the project's distilled
`notes.md` into the session context, and a `SessionEnd` hook captures the finished
transcript into a private git repository. The next session, on any machine, starts with
the decisions and traps of the previous ones instead of repeating them.

The store is a git repository you own. Nothing is sent anywhere else, and the plugin
never writes into the repository you are working on.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Development](#development)
- [Limits](#limits)
- [License](#license)

## Requirements

- Droid, with plugins enabled.
- PowerShell 7 (`pwsh`) on `PATH`.
- `git` 2.34 or newer.
- `gh`, authenticated (`gh auth login`), for cloning and pushing the private store.

## Install

Install the plugin from the marketplace:

```pwsh
droid plugin marketplace add Krow-zy/gitmemo
droid plugin install gitmemo@gitmemo --scope project
```

The default store remote is `Krow-zy/gitmemo-store`, a private repository owned by the
author. Point `GITMEMO_REMOTE` at your own private repository (for example
`your-name/gitmemo-store`) before the first session, or clone it to `GITMEMO_HOME`
yourself. `SessionStart` clones the store once when it is missing.

For a checkout without the plugin system, register the hooks manually:

```pwsh
pwsh -NoProfile -File ./plugin/hooks/install.ps1
```

The installer is idempotent, removes old `agent-memory` hook registrations, configures the
credential helper for the private remote, and enables sparse checkout. `-Full` keeps a
complete checkout instead.

## Quick start

```pwsh
git memo status
git memo search "why was the parser dropped"
git memo search "rc.exe" --project trafficdesk --sessions
git memo notes path
```

`git memo` is on `PATH` when the plugin exposes `plugin/bin`. If it is not, run the
scripts directly: `pwsh -NoProfile -File plugin/hooks/search.ps1 -Query "text"`.

## Commands

| Command | What it does |
|---|---|
| `git memo search <text>` | Searches `notes.md`, `index.md` and `manifest.jsonl` |
| `git memo search <text> --sessions` | Also searches raw transcripts (git objects in sparse mode) |
| `git memo search <text> --project <name>` | Limits the search to one project slug |
| `git memo search <text> --max <n>` | Caps the number of result lines (default 40) |
| `git memo notes` | Prints the current project's `notes.md` and its path |
| `git memo notes path` | Prints the absolute path only, creating the directory |
| `git memo status` | Store location, remote, branch, sparse mode and captured projects |

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `GITMEMO_HOME` | `~/.gitmemo` | Location of the store clone |
| `GITMEMO_REMOTE` | `Krow-zy/gitmemo-store` | Remote used when the store is cloned |
| Sparse mode | on | Working tree keeps notes, index and manifest; transcripts stay in git |

Set the environment variables in the shell that launches Droid. The store remote is read
at clone time; after that, `origin` in the store clone is authoritative.

## How it works

| What you see | Where it comes from |
|---|---|
| Project memory at session start | `hooks/session-start.ps1` prints `projects/<slug>/notes.md` and the index tail |
| `projects/<slug>/manifest.jsonl` | One row per capture: session, file, bytes, messages, sha256, redactions |
| `projects/<slug>/index.md` | Regenerated from the manifest by `session-end.ps1` |
| `projects/<slug>/sessions/*.jsonl` | Redacted transcript, stored in git |
| `hooks/hook.log` | Every skipped or failed hook path, with the reason |

The slug is the repository name from `git remote get-url origin`, lowercased. Dedup is by
session id, so a session that ends twice is captured once. A failed push keeps the commit
locally and is retried on the next capture.

Search, capture and storage are implemented in PowerShell and use only `git` and built-in
PowerShell cmdlets. `docs/DESIGN.md` covers the data flow, measurements and traps.

## Development

```pwsh
git clone https://github.com/Krow-zy/gitmemo
pwsh -NoProfile -File ./tests/run-tests.ps1
```

Nine tests run against temporary stores with no network and no real user data. CI runs
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
- Filenames use the first 8 characters of the session id; the manifest keeps the full id.
- The plugin does not capture attachments, images or binary payloads.

## License

MIT, see [LICENSE](LICENSE).
