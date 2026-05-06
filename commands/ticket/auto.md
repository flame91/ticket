# /ticket:auto — automatic ticket loop

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Automatically pick the next ticket from the JIRA backlog and run **implement → regression → merge → state transition**. The state transition follows the branch rule in `_cycle.md` step 10 — if all three reviews pass with no outstanding risk, `Mark Done`; otherwise `Submit for QA`. Use this when handing off continuous coding while the user is away.

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:auto` | Loop mode (default). Repeats until no more tickets to process. |
| `/ticket:auto once` | Single-shot mode. Finishes one ticket and exits. |
| `/ticket:auto loop` | Explicit loop (same as default). |

## One cycle

### Step 0: Load project config

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md

### Step 1: Session state check

Run `bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/session-state.sh"` once. Reuse the result JSON (`branch`, `dirty`, `dirty_files`, `upstream`, `ahead`, `behind`, `worktrees`, `cwd`) in the step 3 prompt.

- If `dirty: true`, **hard stop** (report the `dirty_files` list).
- If cwd is not the main repo root or `branch != {baseBranch}`, **hard stop** — `/ticket:auto` only starts from the main repo root (with `{baseBranch}` checked out). If running inside a sibling worktree, `cd <main-repo-root>` and re-run.

### Step 2: Pick the next ticket

`mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`:
- cloudId: `{cloudId}`
- jql: `project = {projectKey} AND statusCategory != Done AND status != "READY FOR QA" AND issuetype != "{epicIssueType}" ORDER BY priority DESC, updated DESC`
- fields: `["summary","status","issuetype","priority","labels","assignee","parent"]`
- Candidate filtering (required before selection):
  1. `QA FAILED` — always a candidate.
  2. `In Progress` — **only leftover work on this machine is a candidate**. Run `git worktree list --porcelain` and `git branch --list 'feat/{projectKey}-<n>-*' 'fix/{projectKey}-<n>-*'`; only treat as a candidate when a local worktree/branch matches the key. Branches that exist only on the remote belong to other sessions/people and are excluded.
  3. `To Do` — high priority, slight preference for `size-s`.
- Priority order: `QA FAILED` > `In Progress` with local trace > `To Do`.
- `READY FOR QA` is excluded from auto-selection.
- **empty-candidate verdict**: if the JQL returns 0 or filtering leaves 0 candidates, treat as "no auto-implementation target". Include the keys of `In Progress` tickets dropped during filtering in the session summary.
- When "no auto-implementation target", run a secondary JQL `project = {projectKey} AND status = "READY FOR QA" AND issuetype != "{epicIssueType}"` to count K READY-FOR-QA tickets:
  - K = 0 → pure natural stop, print session summary, exit 0.
  - K ≥ 1 → "Auto-impl queue empty but K READY FOR QA tickets remain (key list). Run manual QA via `/ticket <{projectKey}-n>`" then exit 0. Do not exit silently.

### Step 3: Orchestrator classification

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md

**auto-specific**: if `next_command` is not `/ticket:auto`, **skip only that ticket** and continue the loop — log "Orchestrator recommended `<next_command>` ({projectKey}-<n>), out of auto-loop scope, skipping" in the cycle log.

### Step 4: Augment ticket body

Use `getJiraIssue` to inspect the description. If `## Done Criteria` / `## Out of Scope` / `## Verification` are missing, augment via `editJiraIssue`. On failure, **hard stop** + ticket comment.

### Step 5: Create/resume sibling worktree

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md "create/resume"

### Step 6: Start work transition

`getTransitionsForJiraIssue` → `transitionJiraIssue` (name="Start work") → `In Progress`.

### Steps 7–18: Implement → merge cycle

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md (run Phase 1 → Phase 2 sequentially). On hard stop, break the loop and report to the user.

### Step 18: Branch

After § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md completes, return to step 2 in loop mode. Exit in single-shot mode.

## Hard stop conditions

Cycle-level hard stops are in § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md + § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md. auto-specific stops:

| Type | Trigger | Action |
|---|---|---|
| Natural | Backlog empty (step 2 returned 0) | exit 0, summary report |
| Dirty workspace | Working tree dirty at cycle start | exit 1, list of changed files |
| MCP auth | Atlassian Rovo 401/403 | re-check via `getAccessibleAtlassianResources`; if still failing, exit 1 |
| Repeat | Same ticket selected twice in a row (previous cycle unresolved) | exit 1 |

## Safeguards

Inherits safeguards from § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md + _worktree.md. auto-specific additions:

- No direct push to `{baseBranch}` / `main`.
- The main repo (repo-root) always stays on `{baseBranch}` — never check out a feature/fix branch there.
- Epics (`{epicIssueType}` type) are excluded from auto-selection (JQL filter). Child tickets are included.
- Do not treat a PR merge as Done — follow the branch rule in `_cycle.md` step 10. If all three reviews (`/test` + `/test chrome` + Codex) pass and there is no outstanding risk, `Mark Done` → `Done`. If any was skipped or any outstanding risk remains, `Submit for QA` → `READY FOR QA`.

## Result report format

Final summary at session end:

```
/ticket:auto exit (<natural|hard-stop>)
Tickets processed: N
  - {projectKey}-<n>: <summary> → <merged-sha|blocked reason> (PR #nnn)
  - ...
Blocker: <hard-stop reason or "none">
Selectable tickets remaining: M
```

## Notes

- `/ticket:auto` runs all the way through merge automatically, so **only use it in unsupervised environments**.
- For manual one-by-one ticket review/implementation, use `/ticket <{projectKey}-n>`.
- For a single run, use `/ticket:auto once`.
- If MCP auth drops, re-check with `getAccessibleAtlassianResources`.
