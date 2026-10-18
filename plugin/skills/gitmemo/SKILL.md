---
name: gitmemo
description: Search and maintain durable project memory in a private gitmemo store. Use when the user asks what happened before, references an earlier decision or trap, asks you to remember something, or edits the store itself. Not for code search in the working tree.
---

# gitmemo

Durable memory for this machine and every other machine that shares the store. It holds
distilled `notes.md` plus raw session transcripts, one directory per project.

## Search before re-deciding

Search when the user references earlier work, when you are about to repeat a decision,
or before asking a question the store may already answer.

```pwsh
git memo search "why was the parser dropped"
git memo search "rc.exe" --project trafficdesk --sessions
git memo status
```

Default scope is `notes.md`, `index.md` and `manifest.jsonl`. `--sessions` searches the
raw transcripts. In sparse mode those transcripts are read from git objects, so the
search writes nothing to disk.

## Write notes before you finish

Notes are the distilled memory; the transcripts are the raw record. Update the notes when
meaningful work ends, not after every tool call.

```pwsh
git memo notes path     # prints the absolute path, creating the directory
git memo notes          # prints the current notes
```

Append a short section under the existing headings: **what changed**, **why**, **what is
still open**, and any **trap that cost time**. Keep it readable. A future session reads
this before it knows anything else about the repository. Do not paste transcripts or code
dumps into it.

## Store conventions

```
<GITMEMO_HOME>/projects/<slug>/notes.md        distilled, written by the agent
                             /manifest.jsonl   one line per captured session
                             /index.md         regenerated from the manifest
                             /sessions/<stamp>-<sid8>.jsonl
```

`<slug>` comes from `git remote get-url origin` (repository name, lowercased), falling
back to the folder name. `GITMEMO_HOME` defaults to `~/.gitmemo`. `manifest.jsonl` and
`index.md` are derived state: never edit `index.md` by hand, and never edit a manifest row
to hide a capture.

SessionEnd redacts credential-shaped values before storing them and records the count in
the manifest. Redaction is case-sensitive on purpose.

## Sparse mode

Low-disk mode is the default. The working tree contains notes, index, manifest and hooks;
transcripts live in the object database and on the remote, so local disk stays flat no
matter how many sessions accrue. Only `.git` grows. Searching sessions reads committed
blobs with `git grep HEAD`.

## Traps, one line each

- `git add -A` silently skips new files outside the sparse patterns; capture uses `git add --sparse -A`.
- `git sparse-checkout add <path>` edits the stored pattern list permanently; never use it for a temporary fetch.
- `manifest.jsonl` must stay inside the sparse pattern set, or regenerating `index.md` loses every session.
- PowerShell `-match` is case-insensitive; credential patterns use `[regex]::Matches(..., None)`.
- Variable names and switch parameters share one namespace: a local `$sessions` collides with `-Sessions`.
- Every hook failure path must log to `<GITMEMO_HOME>/hooks/hook.log` and exit 0, including invalid JSON on stdin.

## Verifying a change to the store itself

```pwsh
pwsh -NoProfile -File tests/run-tests.ps1
git memo status
git -C "$env:GITMEMO_HOME" log --oneline -5
git -C "$env:GITMEMO_HOME" ls-tree -r --name-only HEAD -- projects
```

Run the tests before claiming a hook change works. For a capture change, confirm the
transcript appears in `git ls-tree` even when it is not in the working tree, and that the
manifest row's `bytes`, `messages` and `sha256` match the stored file.

Full design, measurements and open items: `docs/DESIGN.md` in
https://github.com/Krow-zy/gitmemo
