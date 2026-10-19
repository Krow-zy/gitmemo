# gitmemo design

Durable project memory across Droid sessions and machines. Two lifecycle hooks move a
project's history into a private git repository; a skill and a CLI read it back.

## Data flow

```
session start
  └─ SessionStart hook
       ├─ clone the store on a first run (gh auth), enforce sparse checkout
       ├─ fast-forward the store (pull --rebase --autostash)
       └─ print projects/<slug>/notes.md + the index tail to stdout
            → Droid appends it to the session context

during the session
  └─ the agent writes notes.md when meaningful work ends (via the gitmemo skill)

session end
  └─ SessionEnd hook
       ├─ read the JSON payload from stdin (transcript_path, cwd, session_id)
       ├─ enforce sparse checkout before anything is written
       ├─ skip if this session id is already in manifest.jsonl (unless -Force)
       ├─ redact credential-shaped values, copy the transcript
       ├─ append a manifest row, regenerate index.md
       └─ git add --sparse -A, commit, push
            → a failed push keeps the commit locally and retries next run
```

Every failure path logs to `<GITMEMO_HOME>/hooks/hook.log` and exits 0. A hook must never
block a session.

## Components

| Path | Role |
|---|---|
| `plugin/hooks/hooks.json` | Registers the two hooks with `${DROID_PLUGIN_ROOT}` |
| `plugin/hooks/lib.ps1` | Store root, slug, redaction, index, commit/push |
| `plugin/hooks/session-start.ps1` | Clone/pull/print memory |
| `plugin/hooks/session-end.ps1` | Capture/redact/commit/push |
| `plugin/hooks/search.ps1` | Search notes and manifests; `-Sessions` for transcripts |
| `plugin/hooks/install.ps1` | Manual path: hooks registration, legacy retirement, sparse |
| `plugin/bin/git-memo*` | `git memo search`, `notes`, `status` |
| `plugin/skills/gitmemo/SKILL.md` | Routing skill for searching and writing memory |

## Project identity

The slug comes from `git remote get-url origin`: the last path segment, minus `.git`,
lowercased and sanitized to `[a-z0-9._-]`. It handles `https://`, `ssh://` and
`git@host:owner/repo` shapes, so no repository has to declare anything. Without a remote
the folder name is used.

## Store layout

```
<GITMEMO_HOME>/projects/<slug>/notes.md        distilled, written by the agent
                             /manifest.jsonl   one JSON row per captured session
                             /index.md         regenerated from the manifest
                             /sessions/<yyyy-MM-dd-HHmmss>-<sid8>.jsonl
<GITMEMO_HOME>/hooks/hook.log                  best-effort diagnostics
```

A manifest row carries `captured`, `session`, `file`, `bytes`, `messages`, `sha256`,
`redactions`, `project` and `cwd`. `index.md` is derived from the manifest and is never
hand-edited.

## Low-disk (sparse) mode

Sparse checkout is the default. The working tree holds notes, index, manifest and the
hook log; transcripts stay in the object database and on the remote. Local disk stays
flat no matter how many sessions accrue; only `.git` grows.

Measured on Windows with git 2.49, three synthetic sessions of 1.87 MB each (5.61 MB raw):

| Metric | Value |
|---|---|
| Working tree after 3 captures | 1.9 KB |
| Session files left on disk | 0 |
| `.git` after 3 captures | 481.5 KB |
| Growth per session | 160.5 KB |

That is about 11.6x smaller on disk than the raw transcripts, and the working tree does
not grow with the number of sessions. The prototype store measured 34 KB of working tree
with `.git` growing roughly 0.4 MB per real session.

Low-disk mode is self-healing. Sparse config lives in `.git/config`, which is not cloned,
and an existing store may predate sparse mode entirely, so `session-start.ps1` and
`session-end.ps1` each check `core.sparseCheckout` on every run and call the shared
`Initialize-StoreSparse` helper when it is missing. `install.ps1` also calls the helper, but no installer step is required: an existing or
hand-made store switches on its next hook run. `install.ps1 -Full` skips the install-time
step only; the next hook run re-applies sparse mode. A failure to enable sparse mode is
logged and the hook continues.

Searching in sparse mode uses `git grep HEAD`, which reads committed blobs and writes
nothing. It must never check transcripts back out.

## Redaction

Credential-shaped values are replaced with `[REDACTED]` before the transcript is copied;
the count is recorded in the manifest. Patterns cover common provider prefixes, private
key headers and JWT shapes. Matching is case-sensitive
(`[regex]::Matches(..., RegexOptions::None)`) because PowerShell's `-match` ignores case
and previously flagged ordinary base64 as an AWS key.

Redaction is a safety net, not a guarantee. A credential with an unrecognised shape still
reaches the store; the store is private for that reason.

## Deduplication

A session can end more than once (clear, then exit). `session-end.ps1` scans the manifest
for the session id and skips with `already captured` when it finds one. `-Force`
recaptures and appends a second row.

## Install paths

| Path | What it does |
|---|---|
| Plugin install | Hooks come from `plugin/hooks/hooks.json`; the marketplace handles updates |
| `install.ps1` | Manual registration in `~/.factory/hooks.json`, legacy `agent-memory` hooks removed, credential helper configured |

`install.ps1` is idempotent. It computes the new configuration, compares it with the file,
and only writes when something changed. The first real change backs the original up to
`hooks.json.bak`; a no-op run writes no backup. It also removes legacy hooks whose command
contains `agent-memory`, so a session is never captured twice.

## Traps

These cost time, in rough order:

- `git add -A` silently skips new files outside the sparse patterns. A transcript is
  exactly that, so the commit would carry a manifest row pointing at nothing. Capture
  uses `git add --sparse -A`, with a fallback for git older than 2.34.
- `git sparse-checkout add <path>` edits the stored pattern list permanently, so
  `reapply` will not prune that path later. Never use it for a temporary fetch; read from
  objects or reset the patterns.
- `manifest.jsonl` must stay inside the sparse pattern set, or regenerating `index.md`
  loses every session.
- PowerShell `-match` is case-insensitive; the redaction patterns use
  `[regex]::Matches(..., None)`.
- Variable names and switch parameters share one namespace: a local `$sessions` collides
  with the `-Sessions` switch.
- `[Console]::In.ReadToEnd()` is the only reliable stdin read, and invalid JSON must be
  logged rather than silently ignored.
- A private store cloned with `gh` needs a repo-local credential helper
  (`credential.helper ''` plus `credential.https://github.com.helper` set to
  `!gh auth git-credential`), or pull and push fail with "Repository not found".
- Sparse configuration is not cloned, so every fresh clone has to opt back in.
- Hooks live in `~/.factory/hooks.json` and `settings.json`; both are merged. A legacy
  registration next to the plugin one captures every session twice.

## Open items

- **Retention**: nothing prunes old sessions. Add a policy when `.git` growth becomes
  annoying; the manifest makes a prune auditable.
- **Compression**: gzip would cut the stored copy further (the prototype measured about
  2.9x) at the cost of reading raw transcripts with plain search tools. Not worth it while
  `git grep` handles the sparse path.
- **macOS**: out of scope for 0.1.0. The code is OS-neutral (`$HOME`, `Join-Path`, `pwsh`)
  but is only tested on Windows and Linux.
- **Session id collisions**: filenames use the first 8 characters of the session id. The
  manifest keeps the full id if a collision ever needs resolving.

## Tests

`tests/run-tests.ps1` runs ten checks without Pester, Pester modules or the network, all
against temporary stores:

1. Every `.ps1` parses.
2. Redaction replaces secrets but leaves base64, a bare `AKIA` prefix and normal paths alone.
3. Capture round-trip: file, manifest fields, hash and regenerated index.
4. Dedup skips a second run and `-Force` recaptures.
5. Sparse staging: the transcript is in the commit but pruned from the working tree.
6. Object search finds a token with no transcript on disk and does not grow the tree.
7. SessionStart matrix: startup, compact, unknown repo, invalid JSON.
8. Install idempotency, legacy removal, one backup, none for a no-op or a fresh file.
9. No credential-shaped value survives in the store, the log or the committed tree.
10. An existing store with no installer run turns sparse mode on during capture: the
    transcript is committed, and the sessions directory never appears in the working tree.
