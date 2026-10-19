# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-19

### Changed

- No default store remote. `GITMEMO_REMOTE` starts unset, so a fresh machine cannot clone
  a repository it does not own. With no store and no remote the hooks stay silent and log
  `no store configured`; `git memo status` and `install.ps1` print what to set. Point the
  machine at your own store with `GITMEMO_REMOTE=<owner>/<repo>` or
  `install.ps1 -Remote <owner>/<repo>`.
- The documented primary command is
  `pwsh -NoProfile -File "${DROID_PLUGIN_ROOT}/hooks/search.ps1" -Query "text" -Sessions`.
  `git memo` is the short form and needs `install.ps1 -InstallCli` or `plugin/bin` on
  `PATH`, because a plugin install never adds it.
- `install.ps1 -InstallCli` writes a `git-memo` launcher into a per-user directory that is
  already on `PATH`, and prints the path.

### Added

- Store `.gitattributes` with `* -text`, written when the store is initialised and kept
  inside the sparse pattern set, so a transcript commits byte-for-byte and keeps matching
  the `bytes` and `sha256` in its manifest row.
- Hook-enforced self-healing: an existing store picks up `.gitattributes` and low-disk mode
  on its next SessionStart or SessionEnd, with no installer run.
- Tests 10 to 12: sparse self-heal, CRLF byte-faithfulness against the manifest, and the
  `-InstallCli` shim with the no-remote log line. Twelve tests in total.
- README section on enabling the plugin (`enabledPlugins`, `/plugins`), and a note that
  installing is not enabling.

### Fixed

- Low-disk mode never turned on for a store that already existed.

## [0.1.0] - 2026-10-19

### Added

- Droid plugin `gitmemo`: a `SessionStart` hook injects `notes.md` and the session index,
  a `SessionEnd` hook captures the transcript into a private git store.
- `git memo` CLI with `search`, `notes` and `status`.
- Credential redaction before storage, with the redaction count recorded per session.
- Session deduplication by session id, with `-Force` to recapture.
- Low-disk sparse mode: transcripts stay in the object database and on the remote.
- `install.ps1` for the manual path: idempotent hook registration, legacy
  `agent-memory` hook retirement, and the private-remote credential helper.
- Nine tests covering parsing, redaction, capture, dedup, sparse staging, object search,
  the SessionStart matrix, install idempotency and secret leakage.
- CI on Windows and Linux, and a tagged release workflow that attaches a plugin zip.
