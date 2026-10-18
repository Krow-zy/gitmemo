# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
