# /ticket:batch — process an explicit ticket queue (sequential / parallel)

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Process a user-specified key list. Without `--par`, run **sequentially** one at a time; with `--par`, spawn Phase 1 in parallel and run Phase 2 **sequentially in input order**. The source is an **explicit queue**, not JQL auto-selection.

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:batch TM-a,TM-b,...` | Comma-separated key list, sequential mode |
| `/ticket:batch --par TM-a,TM-b,...` | Same key list, parallel mode |
| `/ticket:batch 182,183` | Numbers-only input is normalized to `{projectKey}-<n>` |
| `/ticket:batch TM-a, TM-b` | Whitespace allowed (trim) |

At least 2 keys required. With 1 key, advise to use `/ticket:auto once` or `/ticket <{projectKey}-n>` and exit.

---

## Step 0: Load project config

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md

## Step 1: Parse arguments

Comma split → trim → normalize to `{projectKey}-<n>` → dedup (preserve input order).
On empty list / 1 key / invalid format, advise and exit.

## Step 2: Session state check

Run `bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/session-state.sh"` once.
- If `dirty: true`, **hard stop** (report `dirty_files` list).
- If cwd is not the main repo root or `branch != {baseBranch}`, **hard stop** — `/ticket:batch` only starts from the main repo root (`{baseBranch}`).
- Reuse the result JSON in each cycle's orchestrator prompt.

## Step 3: Pre-validation (one `getJiraIssue` per key)

For each key:
- Not found / permission error → add to skip list (reason: `not-found`).
- `statusCategory == Done` → skip (reason: `already-done`).
- `issuetype == "{epicIssueType}"` → skip (reason: `epic-excluded`).
- `status == "READY FOR QA"` → skip (reason: `ready-for-qa-manual`). QA-ready tickets risk transition conflicts — handle individually via `/ticket <{projectKey}-n>`.
- Otherwise, push into the **valid queue** in input order.

If the valid queue is empty, print skip summary and natural stop.

---

## Sequential mode (without `--par`)

For each key in the valid queue, in order:

**Step 4a** — If previous key == current key, skip.

**Step 4b — Orchestrator classification**

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md. Additional batch rules:
- `classification ∈ {blocked-by-current-work, conflict}` or `worktree_decision == stop` → **hard stop the entire queue** (report this key + remaining queue + classification grounds).
- `next_command` outside `/ticket*` → skip only this key (reason: `orchestrator-routed-elsewhere`), move to next.
- 5-field missing/non-conforming → **hard stop the entire queue**.

**Step 4c — Run cycle**

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md (Phase 1 → Phase 2 sequential). Each step's hard-stop conditions follow `_cycle.md` verbatim. After key N's worktree cleanup + `{baseBranch}` sync completes, proceed to key N+1.

On cycle success, record `{key, pr_url, merged_sha, regression_mode}` in the processed list.

---

## Parallel mode (`--par`)

### Step 5a — Orchestrator classification (per key, sequential)

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md. Additional batch rules:
- `classification ∈ {blocked-by-current-work, conflict}` or `worktree_decision == stop` → **exclude only this key** (do not stop the entire queue).
- `next_command` outside `/ticket*` → skip only this key (reason: `orchestrator-routed-elsewhere`).
- 5-field missing/non-conforming → **hard stop the entire queue**.

### Step 5b — Worktree batch creation (sequential)

For each classified key, in order, run § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md create procedure (once per key). On creation failure → exclude only this key, continue with the rest.

### Step 5c — Phase 1 parallel run

Spawn `_cycle.md` Phase 1 across `{maxConcurrent}` Agents simultaneously (default 3, max 5).
- If input keys > `{maxConcurrent}`, split into batches of `{maxConcurrent}`; next batch starts after the previous completes.
- Collect each agent result: `{key, status: "ready"|"blocked", head_sha, reason?}`.
- `blocked` → exclusion list. `ready` → Phase 2 queue.
- If the Phase 2 queue is empty (all blocked) → **hard stop**, exit 1.

### Step 5d — Phase 2 sequential run (preserve input order)

Run `_cycle.md` Phase 2 for `ready` keys in input order:
- Dev server lifecycle is managed by `_cycle.md` step 4a/12: previous key's step 12 stops it → current key's step 4a starts the worktree frontend. No port 3000 conflict (sequential guarantee).
- Merge conflict → exclude only this key, continue with the rest.
- After each key completes, run § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md cleanup + `{baseBranch}` sync.

---

## Hard stop table

| Type | Trigger | Mode | Action |
|---|---|---|---|
| Argument | 0 / 1 keys or parse failure | both | exit 1, usage notice |
| Dirty workspace | working tree dirty at step 2 | both | exit 1, list of changed files |
| Pre-check empty | valid queue 0 after pre-validation | both | exit 0, skip summary |
| Orchestrator malformed | 5-field missing/non-conforming | both | exit 1, raw return value |
| Orchestrator block | `blocked-by-current-work` / `conflict` / `stop` | sequential | exit 1, this key + remaining queue + grounds |
| Ticket description | `editJiraIssue` failed | sequential | exit 1, current key + remaining queue |
| Regression fail | regression abnormal exit | sequential | exit 1, current key + remaining queue |
| Merge conflict | `gh pr merge` failed | sequential | exit 1, PR link + remaining queue |
| MCP auth | Atlassian Rovo 401/403 | both | re-check via `getAccessibleAtlassianResources`; if still failing, exit 1 |
| Phase 1 all blocked | all keys blocked | parallel | exit 1 |
| Worktree create fail | `git worktree add` error | parallel | exclude this key, continue |
| Phase 2 merge conflict | `gh pr merge` failed | parallel | exclude this key, continue |

## Skips (skip this key only, continue)

| Type | Trigger |
|---|---|
| Not found | `getJiraIssue` not found |
| Already done | `statusCategory == Done` |
| Epic excluded | `issuetype == "{epicIssueType}"` |
| Ready for QA manual | `status == "READY FOR QA"` — handle via manual `/ticket <{projectKey}-n>` |
| Orchestrator routed elsewhere | `next_command` outside `/ticket*` |

---

## Safeguards

- Inherits all safeguards from `_cycle.md`: no direct push to `{baseBranch}` / `main`, no `--force` / `--no-verify` / `--no-gpg-sign`, fresh sibling worktree + fresh branch per cycle.
- **Sibling worktree per ticket.** Path: `<repo-root>/../{repoSlug}-{projectKey}-<n>-<slug>`.
- **Phase 2 merge order preserves input order (race prevention). No file conflicts between parallel impls (each worktree isolated).**
- **JQL bypass.** Batch processes only the explicit input keys. Does not use JQL auto-selection logic.
- The queue is session-local. Do not create queue files inside the repo.

---

## Result report format

### Sequential mode

```
/ticket:batch exit (<natural|hard-stop>)
Input queue: N
  - TM-182, TM-183, TM-184, ...
Processed: K
  - TM-182: <summary> → <merged-sha> (PR #nnn, regression: frontend)
Skipped: M
  - TM-<n>: <not-found|already-done|epic-excluded|orchestrator-block>
Unprocessed (on hard stop): L
  - TM-<n>, TM-<m>, ...
Blocker: <hard-stop reason or "none">
```

### Parallel mode (`--par`)

```
/ticket:batch --par exit (<natural|hard-stop>)
Input queue: N
Phase 1 parallel: K complete, M blocked
  - TM-214: ready (impl 3m12s, test 45s)
  - TM-215: blocked — "vitest assertion failure"
Phase 2 sequential: L merged, P failed
  - TM-214: merged → abc1234 (PR #291, chrome: PASS)
Unprocessed: Q
  - TM-215: Phase 1 blocked
Blocker: "none" or reason
```

---

## Notes

- `/ticket:batch` runs all the way through merge automatically. Only use it in unsupervised environments.
- For manual one-by-one ticket review/implementation, use `/ticket <{projectKey}-n>`. For JQL auto-selection loop, use `/ticket:auto`. This command is **explicit-queue only**.
- If new tickets appear during a batch, you can append to the remaining queue via `/ticket:batch:append <KEY>` (only during sequential mode or while parallel Phase 1 is still running). Mid-queue insertion or priority changes are not supported and are explicitly refused due to race risk.
- If unsure how to split a large key list (`--par` group / sequential chain), call `/ticket:batch:plan TM-a,TM-b,...` first to get a recommendation. `plan` is read-only — it only prints the split invocation commands without executing.
