# /ticket — enter a specific JIRA ticket

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Look up the ticket by the argument (`{projectKey}-<n>` or `<n>`) and route to the next action that matches its current state.

## Step 0: Load project config

§ `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`.

## Argument forms

- `/ticket {projectKey}-42`
- `/ticket 42`
- `/ticket {projectKey}-42` (case-insensitive)

## Run order

1. Parse argument:
   - Numbers-only input is normalized to `{projectKey}-<n>`.
   - The `{projectKey}-` prefix is uppercased.
   - On invalid input, print the correct format and abort.
2. Fetch ticket: use `mcp__claude_ai_Atlassian_Rovo__getJiraIssue` to inspect `summary / status / priority / issuetype / labels / assignee / description`.
3. Epic (`{epicIssueType}` type) handling: not directly implementable, so list children (`parent = {projectKey}-<n> AND statusCategory != Done`) in `/ticket:list` form, advise re-invocation as `/ticket <child-n>` for one of the children, and exit.
4. Determine worktree location — run in parallel: `git rev-parse --show-toplevel`, `git status --short`, `git branch --show-current`, `git worktree list --porcelain`, `git fetch origin --quiet`.
   - If cwd is inside this ticket's sibling worktree (`feat/{projectKey}-<n>-*` or `fix/{projectKey}-<n>-*`):
     - `git status --short` **clean** → reuse and proceed to step 5.
     - **dirty** → **hard stop**. Report changed files and tell the user to clean up via (a) committing in that worktree, (b) `git stash push -u -m "pre-ticket-{projectKey}-<n>"`, or (c) `git restore` / `git clean` (when clearly disposable), then re-run `/ticket`.
   - If cwd is inside another ticket / chore sibling worktree, **hard stop** — advise "move to main repo and re-run".
   - If cwd is the main repo root and branch is `{baseBranch}`, step 6-i-3 will create a fresh sibling worktree.
   - If cwd is the main repo root but branch is not `{baseBranch}`, **hard stop** — advise `git checkout {baseBranch}` and re-run.
5. **Orchestrator classification** — § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md`.

   **`next_command` handling (ticket.md only)**: if the return is a slash command other than `/ticket`, **abort** and tell the user "Orchestrator recommended `<next_command>` — restart with that command". Claude must not override the routing on its own.

   The main session pins the role-doc reference in step 6-i-4 to the returned `owner`.

6. Route based on current ticket state:
   - `To Do` / `In Progress` / `QA FAILED` → ready to implement:
     1. Prefix the session title with `[{projectKey}-<n>]`: use the `/rename` slash command to set the current session title to `[{projectKey}-<n>] <existing title or summary digest>`. If the `[{projectKey}-<n>]` prefix is already present, do not reset. (If a different `[{projectKey}-*]` prefix is present, replace it with the new ticket number.)
     2. If the body lacks `## Done Criteria` / `## Out of Scope` / `## Verification`, augment via `editJiraIssue`.
     2.5. **Pre-check key design decisions** (design-heavy tickets only):
        - If labels include one or more of `data-quality` / `data` / `data-pipeline` / `schema` / `api` / `backend` / `migration` / `llm` / `facet`, classify as a design-heavy ticket.
        - Inspect the `## Key design decisions` section in the description:
          - **Absent** → opus analyzes the description, extracts 1–3 missing items (multi-value column format, breaking-change policy, response serialization, idempotency, etc.) → ask the user via `AskUserQuestion`.
          - **Present but with empty items (`<TBD>` / `?` / blank lines)** → extract only the empty items and ask the user the same way.
          - **All items filled** → check passes, proceed to i-3.
        - After receiving the user's answer, update the description via `editJiraIssue` (create the section if absent, fill empty slots with the answer).
        - **If the user picks "not sure / impl-coder discretion"**: state it explicitly in the description (`Decision: impl-coder discretion, split codex findings to follow-ups`) — this justifies force-ack / follow-up split during later codex sprawl in the cycle. Treat the check as passed.
        - **Purpose**: prevent sprawl like the TM-231 case (codex 13 rounds, 1h 27m, 50%+ findings cascading from a single missing design decision). The point is to lock the decision before the cycle starts.
        - **i-2.5 in automated flows (`/ticket:auto` / `/ticket:batch`)**: the `AskUserQuestion` call pauses the auto flow — intended behavior. Changes to design-heavy handling in auto flows are tracked as separate follow-ups.
     3. § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md` "create/resume".
     4. If the ticket is `To Do`, run `getTransitionsForJiraIssue` → `Start work` → `transitionJiraIssue` to `In Progress`.
     5. § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` (run Phase 1 → Phase 2 sequentially).
   - `READY FOR QA` → print the ticket's `## Verification` section and the SKIP/outstanding-risk items in the most recent `verification summary` comment, then provide a manual QA checklist. (Per current policy, tickets where all three reviews are PASS / N/A transition straight to Done at `_cycle.md` step 10, so a ticket arriving at READY FOR QA almost always has env-dependent SKIPs or outstanding risk — focus checks there. Items marked N/A automatically passed and need not be re-verified.) On pass, run `getTransitionsForJiraIssue` → `Mark Done` → `transitionJiraIssue`. On fail, transition to `Fail QA` and request a root-cause comment.
   - `Done` / `CLOSED` → print summary only and note "ticket already complete". For rework, recommend creating a new ticket via `/ticket:create`.

## Notes

- `/ticket` is the single-ticket entry point. Distinct from `/ticket:create` (new), `/ticket:list` (backlog summary), and `/ticket:auto` (auto-loop).
- The main repo (repo-root) always stays on `{baseBranch}`. `/ticket` never checks out a feature/fix branch on the main repo; ticket work happens entirely inside the sibling worktree (`<repo-root>/../{repoSlug}-{projectKey}-<n>-<slug>`).
- On transition failure (permission / unmet transition condition), record the blocker as a comment and abort.
- Transition IDs change with project config, so match by name in the `getTransitionsForJiraIssue` response.
- Do not treat a PR merge as completion. Only run `Mark Done` after QA pass.
- Design-heavy tickets (data/api/schema/migration/llm/facet labels) must pass the step 6 i-2.5 pre-check. Bypass only on explicit user decision (e.g. "impl-coder discretion" answer).
