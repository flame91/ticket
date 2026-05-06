# ticket

> Current version: **v0.1.2** — see [CHANGELOG.md](CHANGELOG.md).

JIRA-driven solo-dev cycle: **ticket → worktree → impl → tri-review → PR → merge → done**.

A bundle of slash commands and subagents that takes a JIRA ticket key and drives it
through implementation, code-level regression, browser-level regression, an optional
Codex cross-review gate, PR creation, merge, and JIRA state transition — all inside
isolated sibling worktrees so the main repo always stays on the base branch.

Built around `.claude/project.json` for per-project configuration. Designed for
Anthropic's Claude Code CLI.

## What's inside

**Slash commands**

- `/ticket <KEY-n>` — single-ticket entry point (status-aware routing)
- `/ticket:list` — JIRA backlog summary
- `/ticket:create` — new ticket, optionally seeded from `pm-execution` skills
- `/ticket:auto` — auto-loop: pick → implement → review → merge → repeat
- `/ticket:batch <KEY-a,KEY-b,...>` — explicit queue, sequential or `--par` parallel
- `/ticket:batch:append <KEY>` — append to an in-flight batch queue
- `/ticket:batch:plan <KEY-a,KEY-b,...>` — read-only split suggestion (parallel groups / sequential chains) before invoking `/ticket:batch`
- `/ticket:audit` — find stale open tickets invalidated by later work + apply
- `/ticket:rerank` — propose + (on approval) apply a backlog rerank by status / priority / age
- `/ticket:release` — pre-release verification checklist for the plugin itself (read-only)
- `/work <slug>` — sibling worktree for non-ticket / chore work
- `/push` (+ `/push chore`) — branch · commit · PR · merge · base sync · JIRA transition
- `/test` — change-scoped regression tests
- `/test chrome` — Chrome DevTools MCP browser verification
- `/review` — pre-PR self-review (read-only findings)

**Subagents**

- `impl-coder` — implements ticket Done Criteria, reflects review findings (sonnet)
- `qa-verifier` — findings-first read-only review (opus)
- `executive-orchestrator` — 5-field routing classification (sonnet)

**Bundled skills (own)**

- `diagnose` — disciplined debugging loop (HITL template included)
- `grill-with-docs` — challenge a plan against CONTEXT.md / ADRs

**Bundled scripts**

- `scripts/session-state.sh` — emit current branch / dirty / worktrees as JSON

## Prerequisites

| Requirement | Why |
|---|---|
| Claude Code CLI | obviously |
| Atlassian Rovo MCP server (`mcp__claude_ai_Atlassian_Rovo__*`) | every JIRA call goes through it |
| `gh` CLI authenticated | PR create / merge / comment |
| `git` ≥ 2.30 | sibling worktree management |
| `jq`, `python3` | session-state.sh JSON shaping |
| `curl` | optional — JIRA attachment upload (`jira.attachmentApi`) |

## Recommended companions (soft deps — `.claude/project.json` flags)

Each is optional. Install via marketplace if you want the corresponding feature.

| Plugin / skill | What it adds | Config flag |
|---|---|---|
| `codex` plugin (OpenAI) | Codex cross-review gate (`/push` step 5, `_cycle.md` step 6) | `codexReview.enabled: true` |
| `andrej-karpathy-skills` | Surgical-changes guidelines injected into impl-coder | `skillIntegration.karpathyGuidelinesInImpl: true` |
| `pm-execution` (pm-skills) | WWA stories / AC scenarios in `/ticket:create`; release-notes in cycle step 11 | `skillIntegration.releaseNotesOnUserFacing: true` |
| `simplify` (Claude Code builtin) | Pre-commit code reuse / dead-code review | `skillIntegration.simplifyBeforeCommit: true` |
| Chrome DevTools MCP | Enables `/test chrome` browser verification | (none — auto-detected) |

Without any of these the workflow degrades silently — flags default to `false`, gates
treat the missing component as N/A (no Mark Done blocker).

## Installation

### Mode A — Plugin install (other machines)

```
/plugin marketplace add https://github.com/flame91/ticket
/plugin install ticket@ticket-marketplace
```

That registers the marketplace in `~/.claude/settings.json` and pulls the plugin to
`~/.claude/plugins/cache/`. Slash commands and subagents become available immediately.

### Mode B — Hybrid (this repo's home machine, edit-in-place)

The repo doubles as the source of truth for user-scope `~/.claude/`. Symlinks let
edits in the repo flow into both `~/.claude/` (immediate use) and the plugin source
(other machines pull via git).

```bash
git clone https://github.com/flame91/ticket ~/coding/plugins/ticket
cd ~/coding/plugins/ticket
bash scripts/install-symlinks-home.sh           # preview first: --dry-run
```

The script backs up any existing real files (`~/.claude/commands/ticket.md` etc.) to
`*.bak.<timestamp>` before symlinking. Rollback: `bash scripts/install-symlinks-home.sh --rollback <timestamp>`.

After install, `~/.claude/commands/ticket.md` is a symlink to `repo/commands/ticket.md`,
so editing either path edits the same file.

## Per-project setup — `.claude/project.json`

Drop this in any project root that uses the workflow. Minimum:

```jsonc
{
  "jira": {
    "enabled": true,
    "cloudId": "<your atlassian cloudId>",
    "projectKey": "<your project key>",
    "epicIssueType": "Epic"
  },
  "git": { "baseBranch": "main" },
  "codexReview": { "enabled": false }
}
```

Full schema: see `commands/ticket/_config.md`. Highlights:

- `skillIntegration.*` — opt-in flags for soft-dep skills
- `jira.attachmentApi.*` — REST-API token setup for evidence screenshots
- `github.evidenceComment.enabled` — orphan-branch-based PR evidence comments
- `parallel.maxConcurrent` — `/ticket:batch --par` concurrency (default 3, max 5)

## Path resolution — how `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}` works

Slash command bodies reference each other through fully-qualified paths:

```
§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md
```

- **Plugin install**: Claude Code expands `${CLAUDE_PLUGIN_ROOT}` to the install dir
  → resolves to `~/.claude/plugins/cache/.../commands/ticket/_config.md`.
- **User-scope (symlink mode)**: `${CLAUDE_PLUGIN_ROOT}` is unset → fallback to
  `$HOME/.claude` → resolves to `~/.claude/commands/ticket/_config.md` (symlink to
  the same repo file).

One body, two install modes, one source of truth.

## Cross-references

- Most commands route through `commands/ticket/_cycle.md` (the implementation +
  verification + commit + push + merge + transition state machine). Read that file
  to understand what `/ticket` actually does end-to-end.
- `_orchestrator.md` describes the 5-field classification contract. `_worktree.md`
  describes worktree lifecycle. `_config.md` is the project.json schema.
- The `_*.md` files are model-readable cross-references, not user-facing slash
  commands — Claude Code does expose them as `/ticket:_config` etc., but invoking
  them directly is meaningless without the surrounding context.

## License

MIT — see LICENSE.
