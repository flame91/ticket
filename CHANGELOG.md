# Changelog

All notable changes to the ticket plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-05-06

### Added

- `/ticket:rerank` — propose backlog rerank (status group + priority + age) and apply via the JIRA Agile REST API on approval. Read-only by default; `--dry-run`, `--top N`, `--parent`, `--status`, and `--explicit` modes supported. Sibling to `/ticket:audit`.
- `jira.restApi.{enabled, userEmail, tokenFile}` config block — generalizes the existing `jira.attachmentApi` for any curl-based JIRA write. `jira.attachmentApi` continues to work as a legacy alias (existing setups need no changes).
- `jira.site` config field (host portion of the Atlassian Cloud URL, e.g. `flame91.atlassian.net`) — required by `/ticket:rerank --apply`.

## [0.1.1] - 2026-05-06

### Added

- `/ticket:release` slash command — pre-release verification (read-only)
- `AGENTS.md` at repo root — defines the `release-check` workflow (7 steps), ported from vocatrack/AGENTS.md §release-check
- `CHANGELOG.md` (this file)
- README: explicit version pin pointing at the changelog

### Changed

- `commands/test/chrome.md` diff→page mapping: rephrased the "home" example from `` `components/home/` `` to `` `home/*` under `components/` ``, so the rule-5 grep (`/home\|/Users\|~/\.claude`) no longer flags a benign relative-path reference

### Notes

The `v0.1.0` git tag was issued on 2026-05-06 for commit `a5ae50b`. That commit contains the same content as this `0.1.1` release; the version is bumped here purely to invalidate version-pinned plugin caches so devices that fetched `0.1.0` before this date pick up the changes. There is no functional difference between `v0.1.0` (as tagged on 2026-05-06) and `v0.1.1`.

## [0.1.0] - 2026-05-05

### Initial release

- **Slash commands**: `/ticket`, `/ticket:list`, `/ticket:create`, `/ticket:auto`, `/ticket:batch`, `/ticket:batch:append`, `/ticket:batch:plan`, `/ticket:audit`, `/work`, `/push`, `/test`, `/test chrome`, `/review`
- **Subagents**: `impl-coder` (sonnet), `qa-verifier` (opus), `executive-orchestrator` (sonnet)
- **Skills**: `diagnose`, `grill-with-docs`
- **Scripts**: `session-state.sh`, `install-symlinks-home.sh`

[0.1.2]: https://github.com/flame91/ticket/releases/tag/v0.1.2
[0.1.1]: https://github.com/flame91/ticket/releases/tag/v0.1.1
[0.1.0]: https://github.com/flame91/ticket/releases/tag/v0.1.0
