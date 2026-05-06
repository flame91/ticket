# Changelog

All notable changes to the flow plugin (renamed from `ticket` in v0.2.0) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2026-05-06

### Changed

- `/ticket:list` JQL switched from `ORDER BY priority DESC, updated DESC` to `ORDER BY Rank ASC`. List now mirrors the JIRA backlog UI exactly — the rank field (maintained by `/ticket:rerank` or manual drag-drop) is the single source of truth for backlog order. Rationale: a "show the backlog" command should show the backlog's *current state*, not impose its own sort. The `/ticket:list` step-2 "1–3 things to do right now" pick (status-weight heuristic) is unchanged; with a fresh rerank, it naturally aligns with the rank-top-3.

## [0.2.1] - 2026-05-06

### Changed

- `commands/ticket/_cycle.md` step 4a-2 now detects a mismatched external dev server (different worktree) before reuse — prevents false-positive chrome verification when a manual `npm run dev` is serving a different worktree's code. On cwd mismatch the cycle replaces the external server with a worktree-local one and emits user-facing notices both at replace time and on step 12 cleanup. Conservative reuse (with outstanding-risk row) is preserved when cwd resolution fails.

## [0.2.0] - 2026-05-06

### Changed (BREAKING — plugin rename)

- Plugin name: `ticket` → `flow`. Marketplace name: `ticket-marketplace` → `flow-marketplace`. Reason: plugin-mode invocation namespaces every command as `<plugin>:<path>`, so commands appeared as `/ticket:push`, `/ticket:ticket`, and `/ticket:ticket:list` — the doubled `ticket:` was avoidable noise. After the rename: `/flow:push`, `/flow:ticket`, `/flow:ticket:list`. The slash-command file structure (`commands/ticket.md`, `commands/ticket/list.md`, …) is unchanged; only the plugin namespace prefix moved.

### Migration

For plugin-install users:
```
/plugin uninstall ticket@ticket-marketplace
/plugin marketplace remove ticket-marketplace
/plugin marketplace add https://github.com/flame91/ticket
/plugin install flow@flow-marketplace
```

For symlink-mode (Mode B) users: no action needed — `~/.claude/commands/ticket.md` (and friends) keep working as bare `/ticket`, `/push`, etc.

The GitHub repository URL (`https://github.com/flame91/ticket`) is **unchanged** — only the plugin name inside the repo is.

## [0.1.3] - 2026-05-06

### Changed

- `/ticket:rerank` now writes ranks via `mcp__claude_ai_Atlassian_Rovo__editJiraIssue` instead of curl + JIRA Agile REST API. Lexorank values for non-anchor tickets are computed by appending a 2-character base-36 suffix to the proposed-position-0 ticket's current rank — no curl, no separate API token, no Lexorank library. Auth reuses the same MCP context already used by every other ticket-plugin command.

### Removed

- `jira.restApi.{enabled, userEmail, tokenFile}` config block (introduced in 0.1.2). No longer needed — the MCP path requires no separate REST credentials.
- `jira.site` config field (introduced in 0.1.2). No longer needed — `editJiraIssue` resolves the host via `cloudId`.

### Added

- `jira.rankFieldId` config field — the custom-field ID of the Lexorank "Rank" field. Default `customfield_10019` (standard JIRA Software company-managed). Override only if your instance reports a different ID.

### Notes

If you set up `jira.restApi` and `jira.site` for 0.1.2, you can remove both blocks — they are now ignored. `jira.attachmentApi` is unrelated and still in use by `/push` step 11b.

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

[0.2.2]: https://github.com/flame91/ticket/releases/tag/v0.2.2
[0.2.1]: https://github.com/flame91/ticket/releases/tag/v0.2.1
[0.2.0]: https://github.com/flame91/ticket/releases/tag/v0.2.0
[0.1.3]: https://github.com/flame91/ticket/releases/tag/v0.1.3
[0.1.2]: https://github.com/flame91/ticket/releases/tag/v0.1.2
[0.1.1]: https://github.com/flame91/ticket/releases/tag/v0.1.1
[0.1.0]: https://github.com/flame91/ticket/releases/tag/v0.1.0
