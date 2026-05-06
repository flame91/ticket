# § worktree — worktree create/resume/cleanup (internal reference only)

The main repo (repo-root) always stays on `{baseBranch}`. All ticket work is isolated in sibling worktrees. Match by ticket number (`{projectKey}-<n>`) — slug is not the matching key.

## Create / resume

### Pre-scan

```bash
git worktree list --porcelain
git branch --list 'feat/{projectKey}-<n>-*' 'fix/{projectKey}-<n>-*'
git ls-remote --heads origin 'feat/{projectKey}-<n>-*' 'fix/{projectKey}-<n>-*'
```

**local set** = worktree + local branch. **remote-only set** = exists only on origin. If the same name exists on both sides, count as local.

### Branching

**distinct branch ≥ 2 (local + remote-only)** → **hard stop** (split state, user check required). Record the branch list in a ticket comment.

**local set of 1** (normal resume):
- Worktree registered → check `git status --short`.
  - clean → reuse the path.
  - dirty → **hard stop** (no auto-delete/commit). User must clean up via one of (a) commit, (b) `git stash push -u -m "pre-ticket-{projectKey}-<n>" -- <paths…>`, (c) `git restore`/`git clean`, then re-run.
- Orphan local branch → re-attach via `git worktree add <repo-root>/../{repoSlug}-<existing-branch-without-prefix> <existing-branch>` + clean check.

**local 0 + remote-only 1** → **hard stop** (possibly another machine/person). Guide the user to verify provenance via `git fetch origin <branch> && git log origin/<branch> --pretty=oneline -5`. The user manually runs `git worktree add --track -b <branch> <path> origin/<branch>` and re-runs. Do not auto-adopt.

**local 0 + remote-only 0** (entirely new):
- Path: `<repo-root>/../{repoSlug}-{projectKey}-<n>-<slug>` (slug ASCII kebab, ≤5 words).
- If the path exists as an orphan directory not registered as a worktree → **hard stop** (advise `git worktree prune`, no auto-delete).
- `git worktree add -b feat/{projectKey}-<n>-<slug> <path> origin/{baseBranch}` (use `fix/` for bug tickets). Options come before the positional `<path>`.

### Dirty recovery sequence (when main repo is dirty)

If the main repo is dirty, **hard stop**. The user manually runs:
1. `git stash push -u -m "pre-ticket-{projectKey}-<n>" -- <file paths…>` (pathspec-scoped)
2. Create the worktree and move into it
3. `git stash pop`
4. Re-run

## Cleanup

1. If the sibling worktree has uncommitted changes / leftover stash → **hard stop** (no auto-delete).
2. Move to the main repo root.
3. `git worktree remove <sibling-path>` → `git worktree prune` → `git fetch origin --prune`.
4. `git pull` (assumes `{baseBranch}` is checked out).
