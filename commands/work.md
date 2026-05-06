# /work — create a sibling worktree for new work

When starting new work, create a separate worktree so the main repo stays untouched. Use it for plain work requests / chore cleanups / experimental branches. Feature / bug work tied to a JIRA ticket usually goes through `/ticket <KEY-n>` instead, which wraps this command.

## Step 0: load project config

Read `.claude/project.json` from the repo root. If absent, use the defaults:
- `project.repoSlug`: `$(basename "$(git rev-parse --show-toplevel)")`
- `git.baseBranch`: `"main"`
- `jira.enabled`: `false`
- `jira.projectKey`: `null`

Below, `{repoSlug}`, `{baseBranch}`, `{projectKey}` refer to the values loaded above.

## Arguments

- `/work <slug>` — for general work without a ticket number. Default branch name: `chore/<slug>`. If Claude judges that `feat/{projectKey}-<n>-<slug>` / `fix/{projectKey}-<n>-<slug>` is more appropriate, confirm with the user once and use that convention.
- slug rules: ASCII kebab-case, ≤ 5 words. Examples: `remove-discord-bot`, `tune-nearby-cache`, `audit-oauth-flow`.

## Execution order

### 1. Validate input
- If slug is empty, non-ASCII, or ≥ 6 words → abort and print the rules.
- If `jira.enabled` and the slug contains only `{projectKey}-<n>` → redirect to "use `/ticket <{projectKey}-n>` instead".

### 2. Inspect current state (parallel)
- `git rev-parse --show-toplevel` — main repo root.
- `git status --short` — dirty?
- `git branch --show-current` — current branch.
- `git worktree list --porcelain` — existing worktrees.
- `git fetch origin --quiet` — refresh `{baseBranch}` reference.

### 3. Pick branch name
- Default: `chore/<slug>`.
- If `jira.enabled` and the conversation context already has a confirmed ticket, ask the user once whether to switch to `feat/{projectKey}-<n>-<slug>` or `fix/{projectKey}-<n>-<slug>`.
- Reject `main` / `{baseBranch}` / reserved prefixes (e.g. just `{projectKey}-<n>` without `feat/`).

### 4. Pick worktree path
- Normalize to `<repo-root>/../{repoSlug}-<slug>`.
- If the path already exists:
  - If it is already registered as a worktree → print "move into the existing worktree" and abort.
  - If it is an orphan directory only → print "run `git worktree prune`, then retry" and abort. Do not auto-delete.

### 5. Handle a dirty working tree
- If the main repo has uncommitted changes, **hard stop**. The new worktree is created from `origin/{baseBranch}`, so changes in the main repo will not follow automatically. Silently proceeding leaves changes in the main repo while branching off in the new worktree — a dangerous state.
  - Tell the user to do one of the following first, then re-run `/work <slug>`:
    - (a) To move the changes into the new worktree, **pathspec-scoped stash**: `git stash push -u -m "pre-work-<slug>" -- <paths to move…>` → `/work <slug>` → `cd` to the cwd reported on completion, then `git stash pop` to restore. **Warning**: `git stash push -u` without `-- <pathspec>` saves repo-wide, and `stash pop` then drags unrelated changes into the new branch. With mixed scope, always narrow with a pathspec.
    - (b) To move the changes onto an unrelated branch instead: `cd` into that branch's worktree, commit there, then re-run (the safest path).
    - (c) If the changes are clearly disposable: clean up via `git restore` / `git clean`, then re-run.
  - Claude must not auto-run stash / restore / clean without user consent. Unscoped `stash -u` in particular is too risky to recommend without confirmation due to mixed-scope contamination.

### 6. Create the worktree
- If the branch already exists locally / remotely → report the blocker and abort (reuse risk).
- Run: `git worktree add -b <branch> <path> origin/{baseBranch}` (options before the positional `<path>`).
- On failure, pass stderr through verbatim.

### 7. Completion report
- Print the following as one block:
  - absolute path of the new worktree
  - branch name
  - cwd to use from the next turn (`cd <path>`)
  - if step 5 was bridged via stash, a note: "in the new cwd, run `git stash pop` to restore"
- This command itself does not change cwd. From the next task, Claude uses the new worktree via `cd <path> && ...` in Bash.

## Notes

- This command is **only run from the current main repo root**, both reads and writes. If already inside another worktree, abort with "move to the main repo, then re-run".
- Path conflicts / branch conflicts / dirty state are never auto-overwritten — every case is reported as a blocker that requires user confirmation.
- Right after creating a new worktree, do not touch the main repo until you move on to `/push`.
- Worktree removal is handled automatically by the merge step of `/push`. This command only creates.
