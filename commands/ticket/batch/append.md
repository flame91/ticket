# /ticket:batch:append — Append keys to the end of an in-flight batch queue

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Append keys to the **end** of the remaining queue of an in-flight `/ticket:batch` in the current session. Not a standalone command — only meaningful in a session where `/ticket:batch` is running. Mid-queue insertion, priority changes, and reordering of existing keys are not supported (only simple append, due to race risk).

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:batch:append TM-a` | Append a single key |
| `/ticket:batch:append TM-a,TM-b` | Append multiple keys (comma-separated, preserving input order) |
| `/ticket:batch:append 228` | Numbers only are auto-normalized to `{projectKey}-<n>` |

## Step 0: Load project config

See § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`.

## Step 1: Verify in-flight batch

- If no `/ticket:batch` is in flight in the current session — print "No `/ticket:batch` in flight. Start a new queue with `/ticket:batch <KEY,...>`" and exit.
- If the in-flight batch is **parallel mode + after Phase 1 (entered Phase 2)** — print "Parallel batch is in Phase 2. Handle new keys via a separate `/ticket:batch` or `/ticket:auto`" and exit. (Phase 2 processes the pre-merged ready set in input order, so inserting new keys would require re-running Phase 1, which is outside the scope of simple append.)
- Otherwise (sequential mode in flight / parallel mode Phase 1 in flight), proceed.

## Step 2: Parse arguments

Comma split → trim → normalize to `{projectKey}-<n>` → dedupe (preserving input order).
If a key duplicates the in-flight batch's queue (completed/in-flight/skipped/remaining), report to the user and exclude.

## Step 3: Pre-validation (same as `/ticket:batch` Step 3)

Run `getJiraIssue` once per key:
- Missing / permission error → skip (reason: `not-found`).
- `statusCategory == Done` → skip (reason: `already-done`).
- `issuetype == "{epicIssueType}"` → skip (reason: `epic-excluded`).
- `status == "READY FOR QA"` → skip (reason: `ready-for-qa-manual`).

Append valid keys to the **end** of the remaining queue. Preserve input order.

## Step 4: Report + return to flow

```
/ticket:batch:append done
Added: K
  - TM-228 (remaining queue position: M)
Skipped: P
  - TM-227: already-done
Current batch state:
  - Mode: sequential / parallel-Phase1
  - Completed: x, remaining: y (queue: TM-..., TM-..., TM-228, ...)
```

The in-flight batch picks up newly appended keys naturally as it advances (no separate phase trigger).

## Notes

- **Append-only.** Mid-queue insertion, priority swap, removing existing keys, etc., are not supported. For more complex queue manipulation, wait for the current batch to finish and then bundle in a separate `/ticket:batch`.
- **Parallel/sequential mode follows the in-flight batch's mode.** No per-key mode override. Parallel pairing, file-conflict analysis, etc., are delegated to LLM heuristics (orchestrator classification + judgment during cycle progress).
- **Session-local.** No queue-file persistence. If the session dies, appended keys are lost too — restart `/ticket:batch` in a new session.
- Safeguards are inherited as-is from `/ticket:batch` (no direct push to `{baseBranch}` / `main`, sibling worktree isolation, JQL bypass, etc.).
