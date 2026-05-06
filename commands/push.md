# /push — branch split · commit · PR · merge

Analyze the current changes and run the sequence below automatically.

> **Review tool roles:** `/review` = pre-PR self-review (findings report). The Codex cross-review in Step 5 = pre-push cross-review gate (auto-runs only when `codexReview.enabled`). The two are independent.

## Step 0: load project config

Read `.claude/project.json` from the repo root. If absent, use the defaults:
- `project.repoSlug`: `$(basename "$(git rev-parse --show-toplevel)")`
- `git.baseBranch`: `"main"`
- `jira.enabled`: `false` (skip all of Step 11)
- `jira.projectKey`: `null`
- `codexReview.enabled`: `false` (skip all of Step 5)
- `codexReview.choreAllowList`: `["docs/", ".claude/", ".github/"]`

Below, `{baseBranch}`, `{projectKey}`, `{repoSlug}` refer to the values loaded above.

## Modes

- `/push` (default) — ticket-linked mode (when `jira.enabled`). With JIRA disabled, plain feature/fix PR mode.
- `/push chore` — for repo-meta cleanup (`.claude/`, `docs/`, `.github/workflows/`, `scripts/`, etc.) without a ticket.
  - Do not use chore mode for feature / bug changes. When in doubt, use the default mode.

## Execution order

### 1. Inspect current state
Run in parallel:
- `git status` — list changed files
- `git diff HEAD` — view changes
- `git log origin/{baseBranch}..HEAD --oneline` — local commits vs base
- `git branch --show-current` — current branch

### 2. Branch decision

Common rule: **the main repo (repo-root) always stays on `{baseBranch}`** — `/push` does not create feature / fix / chore branches inside the main repo. If `/push` is invoked without a sibling worktree, fall back to the "dirty recovery sequence" below.

**Default mode**
- Already on a `feat/*` or `fix/*` branch → use it as-is (sibling worktree cwd assumed).
- On `main` or `{baseBranch}` with changes → **hard stop**. Print the "dirty recovery sequence" verbatim. With no changes, natural stop.

**chore mode**
- Already on a `chore/*` branch → use it as-is.
- On `main` or `{baseBranch}` with changes → **hard stop**. Print the same "dirty recovery sequence" (chore variant). With no changes, natural stop.

**Dirty recovery sequence** (the user runs this manually; Claude does not automate it):

1. Split out only the relevant files in the main repo via a pathspec-scoped stash:
   ```
   git stash push -u -m "pre-push-<slug>" -- <paths to move…>
   ```
   An unscoped `-u` carries a high risk of mixed-scope contamination, so be explicit about the paths.
2. The main repo is now clean — create a sibling worktree via `/work <slug>`.
3. `cd <worktree-path>` into the new worktree, then restore the moved changes with `git stash pop`.
4. Re-run `/push` (or `/push chore`) inside that worktree.

### 3. Staging
- `git add` — stage individually after reviewing each changed file
- exclude `.env`, secret files, binaries

### 4. Commit

**Default mode (`jira.enabled`)**
- Title format: `<type>: <what> ({projectKey}-<n>)` — JIRA smart commit auto-recognizes
  - example: `fix: refresh nearby results after map move ({projectKey}-232)`

**Default mode (JIRA disabled)**
- Title format: `<type>: <what>` — no ticket suffix

**chore mode**
- Title format: `<type>: <what>` — no ticket suffix
  - `<type>` is usually one of `chore`, `docs`, `ci`

Common
- Summary ≤ 50 chars + body if needed (follow the existing commit style; either Korean or English is fine)
- Trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`

### 5. Codex cross-review (only when `codexReview.enabled`)

> If `codexReview.enabled` is `false`, skip this step entirely → go to Step 6.

Before pushing, Claude runs the Codex cross-review script and records the ack / cycle state to `<git-dir>/codex-review-ledger.json`. The PreToolUse hook blocks `git push` whenever ack SHA ≠ HEAD.

Script path: `$HOME/.claude/scripts/codex-auto-review.sh` (global) or the project-local `scripts/claude/codex-auto-review.sh` — use whichever exists.

Per exit code:

- **0** — approve → ack recorded automatically. Proceed to the next step (push).
- **1** — normal rejection (streak=0). **Delegate the reflection to the `impl-coder` subagent** — `Agent(subagent_type="impl-coder", prompt=<input contract>)`, `mode: "reflect-exit1"`. The subagent creates a new commit reflecting critical / high findings and reports back. Main re-runs the script against the new HEAD.
- **5** — cycle detected (streak ≥ 1). **The main (opus) plans the strategy directly**, then delegates re-implementation only to `impl-coder`. Strategy ladder: `opus_remodel` → `opus_scope_cut` → `opus_essence_review` → stop-and-ask.
- **4** — cycle MAX exceeded (default streak ≥ 4). **User decision required.** Outside Claude's autonomous scope.
- **2/3** — infrastructure error. Pass stderr through verbatim, stop.

Other behaviors:
- medium / low severity passes autonomously, summary only.
- On a chore branch, when all changed paths are inside `codexReview.choreAllowList`, auto-pass.

### 6. Push
- `git push -u origin <branch>`

### 7. Create PR
- `gh pr create --base {baseBranch} --title "<commit title>" --body "<body>"`

**Default mode (`jira.enabled`)**
- Default body link: `Refs: {projectKey}-<n>` (when verification is incomplete)
- Use `Closes: {projectKey}-<n>` only when verification is already complete and the user explicitly asked for immediate Done

**Default mode (JIRA disabled) / chore mode**
- Omit the JIRA link in the body. Add a one-line summary if needed.

### 8. Merge
- `gh pr merge --squash --delete-branch`

### 9. Worktree cleanup (both modes)

If the current cwd is a sibling worktree created by `/work` or `/ticket`, remove it automatically here.

- Use `git worktree list --porcelain` to detect whether the current cwd is the main repo root or a sibling worktree.
- cwd == main repo root → skip cleanup, move on.
- cwd == sibling worktree →
  - if uncommitted changes remain, **stop**. Do not auto-remove.
  - if clean: move to main repo root → `git worktree remove <sibling-path>` → `git worktree prune` → `git fetch origin --prune`.
  - on remove failure, pass stderr through verbatim and stop.

### 10. Sync base branch
- From the main repo root: `git checkout {baseBranch} && git pull`.
- If another worktree currently has `{baseBranch}` checked out, do not check it out — report the blocker.

### 11. JIRA transition (only when `jira.enabled`)

> If `jira.enabled` is `false`, skip this step entirely.

**Default mode**
- After a successful merge, list available transitions via `getTransitionsForJiraIssue`.
- Branching rules:
  - The previous cycle (`/ticket:auto` / `/ticket <TM-n>`) produced the step 8a verification summary (`/test`, `/test chrome`, `codex review`, `outstanding risk` — 4 rows), and **all three reviews PASS / N/A + outstanding-risk row is empty** → `Mark Done` → `Done`. In a solo workflow, when automated verification has all passed (or is N/A as not applicable), an extra manual QA gate adds little, so bypass it.
  - 8a summary exists but **any one is SKIP / outstanding risk is explicit** (e.g. chrome SKIP, outstanding risk on a Codex auto-passed finding) → `Submit for QA` → `READY FOR QA`. This signals the user must reinforce with manual QA.
  - **Difference between N/A and SKIP**: when `/test chrome` is auto-N/A because there is no UI mapping in the changed scope, treat it as PASS-equivalent → Mark Done route. When `/test chrome` is SKIP because of environment dependencies (dev server / Chrome MCP) being unavailable, take the READY FOR QA route. Same for Codex — chore allowlist auto-pass + **`codexReview.enabled=false` (= N/A by config) counts as PASS**, not as outstanding risk.
  - **When `/push` is invoked without cycle context (= 8a summary missing)**: default to `Submit for QA` → `READY FOR QA` for safety. The Mark Done route is only entered when (a) the user is explicit (`"skip QA"`) or (b) there is evidence the tri-review was actually performed in the same session.
  - If the user is explicit ("skip QA, go straight to Done", or conversely "keep the QA gate"), that explicit instruction wins.
- After the transition, record via `addCommentToJiraIssue` the PR URL + merged commit sha + branching result (`Status transition: Mark Done (reason: <PASS or N/A reason>)` or `Status transition: Submit for QA (reason: <skip items or "no-cycle-evidence">)`). When N/A is involved, the reason must be explicit (e.g. `Mark Done (reason: /test chrome N/A — docs+slash-spec only)`).

**chore mode**
- Skip this step entirely (no linked ticket).

## Notes
- Do not push directly to `{baseBranch}` / `main` (both modes)
- When invoked from the main repo root with changes, `/push` does not create a branch — it hard stops.
- If a PR has merge conflicts, notify the user and stop
- Never use `--force` push
- Do not treat a PR merge as ticket completion — `Done` transition only after QA passes or the user is explicit
- chore mode is limited to repo-meta cleanup. Changes that touch app code / DB schema / API contracts must use the default mode.
- In the worktree-cleanup step, do not auto-delete or overwrite uncommitted changes.
