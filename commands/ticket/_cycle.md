# § cycle — single-ticket implementation→merge cycle (internal reference only)

## Input contract

| Field | Content |
|------|------|
| `ticket_snapshot` | `{key, summary, done_criteria, out_of_scope, verification}` |
| `worktree` | `{cwd, branch, head_sha}` — sibling worktree absolute path |
| `role_hint` | role doc path (optional, derived from owner in § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md) |
| `config` | full config loaded from § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md |

## Cycle state variables (in-memory — initialized at cycle start)

| Variable | Initial | Purpose |
|------|------|------|
| `_cycle_corrections` | `[]` | Accumulated corrections during the cycle. Each entry `{step, attempt, what, why}`. Merged into a single paragraph attached to the step 11 comment. |
| `_cycle_evidence_dir` | `null` | Created once on Phase 2 entry via `mktemp -d -t "techo-evidence-{key}-XXXXXX"`. All `/test chrome` screenshots and Lighthouse reports accumulate under this path. PNGs are bulk-uploaded in step 11, then cleaned up in step 12. |
| `_cycle_dev_pid` | `null` | (existing) Phase 2 dev server PID. |

---

## Phase 1 — implementation + code-level validation (parallelizable)

The section that can run N tickets concurrently in parallel mode (`--par`). Each agent works only inside its own worktree.

### 1. Start work transition

If the ticket is `To Do`: `getTransitionsForJiraIssue` → `transitionJiraIssue` (name="Start work") → `In Progress`. Skip if already `In Progress`.

### 2. Delegate to impl-coder subagent

`Task(subagent_type="impl-coder", prompt=<input contract>)`:
- Ticket snapshot: `ticket_snapshot` as-is (subagent must not re-fetch)
- Worktree state: `worktree`
- `mode: "initial"`
- Role doc hint: `role_hint` (pass the path if the file exists)
- If `{skillKarpathy}` is `true`, add `apply_skill_guidelines: "karpathy"` to the prompt — impl-coder applies `andrej-karpathy-skills:karpathy-guidelines` (surgical changes, no overcomplication, explicit verifiable success criteria).

On blocker report → end Phase 1 with `{status: "blocked", reason: <blocker>}`.

### 3. /test — code-level regression

- If `{regression}` is set, run that script.
- Otherwise auto-detect the project test framework (pytest, jest, vitest).
- **On failure**: delegate fix to impl-coder (`mode: "reflect-test-failure"`) and retry. Right after receiving the delegation result, `_cycle_corrections.append({step: "test", attempt: N, what: "<one-line summary of impl-coder notes>", why: "<failing test case / symptom>"})`.
- **On first retry failure (= second fail)**: if `{skillDiagnose}` is `true` and the final retry (2nd) is still pending, call `Skill(name="diagnose")` or `/diagnose` right before the 2nd retry to produce a root-cause hypothesis. Attach the hypothesis body as a `diagnostic_hypothesis` field in the next reflect-test-failure delegation input → impl-coder makes the final fix attempt based on the hypothesis. Also record `diagnose: <one-line hypothesis>` in the correction entry's `why`.
- **After 2 failed retries**: end with `{status: "blocked", reason: <regression log> + (diagnose summary if available)}`.

### Phase 1 output

```json
{
  "status": "ready" | "blocked",
  "reason": null | "<blocker detail>",
  "files_changed": ["path/a.ts", "path/b.py"],
  "head_sha": "abc1234"
}
```

---

## Phase 2 — browser validation + ship (sequential only)

Only tickets with Phase 1 `"ready"` enter. Even in parallel mode, this section runs one ticket at a time.

**Phase 2 invariant — dev server cleanup:** if the dev server was started in this section, `kill $_cycle_dev_pid && wait` must run on exit (both normal and hard-stop paths). Performed in step 12, including the hard-stop path.

**Create evidence directory on Phase 2 entry:** run `_cycle_evidence_dir = $(mktemp -d -t "techo-evidence-{ticket_snapshot.key}-XXXXXX")` once, immediately before the first substep (4a) of Phase 2. Expose this path as the `EVIDENCE_DIR` env var to `/test chrome` (`export EVIDENCE_DIR="$_cycle_evidence_dir"`) so chrome.md step 0 reuses this path instead of its own mktemp. PNGs are bulk-uploaded in step 11, cleaned up in step 12.

### 4a. Start dev server (auto workflow only)

> Run only when the caller is `/ticket*`. If the user invoked `/test chrome` directly, this substep does not exist (chrome.md's hard-stop rule applies).

1. **Chrome DevTools MCP check** — call `mcp__chrome-devtools__list_pages`. On failure → skip all of 4a (reason: "Chrome DevTools MCP not connected").
2. **Existing server check** — `curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ja`. 200 → `_cycle_dev_pid = null` (externally started), **proceed to 4b.**
3. **Port conflict check** — `lsof -ti :3000`. If a PID exists → skip 4a (reason: "port 3000 occupied (PID N) — no 200 response. Manual check required").
4. **Dependency check** — `[ -x "{worktree.cwd}/frontend/node_modules/.bin/next" ]`. If missing, `( cd "{worktree.cwd}/frontend" && npm ci )`. On failure → skip 4a (reason: "npm ci failed").
5. **Start** — `cd "{worktree.cwd}/frontend" && NEXT_PUBLIC_API_URL=/api NEXT_PUBLIC_BACKEND_URL=http://localhost:8000 API_INTERNAL_URL=http://localhost:8000 npm run dev &`. Record the PID in `_cycle_dev_pid`.
6. **Ready poll** — every 5s, up to 60s. On 200 → **proceed to 4b.** After 60s → `kill $_cycle_dev_pid; wait`. `_cycle_dev_pid = null`. Skip 4a (reason: "dev server did not respond within 60s").

### 4b. /test chrome — browser validation (required step, conditional N/A · SKIP)

**This step is a required component of Phase 2. The agent must not autonomously omit it.** Branch in the order: diff analysis → 4a result.

**Auto N/A determination (takes precedence over 4a, both conditions AND):** N/A applies only when **both** of the following are met. If even one is unmet, it is not N/A — proceed with the normal availability check.

1. **Inside chore allowlist**: **every** file in `git diff --name-only origin/{baseBranch}..HEAD` matches a path inside `{choreAllowList}` (default `["docs/", ".claude/", ".github/"]`, extensible via project config). If even one file lies outside the allowlist, it is not N/A.
2. **Zero UI mappings**: zero matches against the UI paths in chrome.md "diff → page mapping" (`app/[locale]/`, `components/`, `messages/`, `lib/api.ts`, `globals.css`).

Both conditions met (AND) → **treat as N/A** — do not run `/test chrome`, skip 4a, do not even attempt to start the dev server. Record in the Phase 2 log: "`/test chrome` N/A: change is inside chore allowlist + zero UI mappings (changed files: <1-2 representative paths>)". **N/A is different from SKIP — it is an intended state where the validation target is absent, and is not classified as outstanding risk.**

**Conservative determination**: if backend routers, DB schema, auth/session, runtime config, or API contracts changed but only UI mappings are 0, it is not N/A — falls out at the first condition because it is outside the chore allowlist. This conservatism prevents codex's "absence-of-evidence shipping" risk.

**If not N/A, availability check**: dev server (http://localhost:3000/ja == 200) + Chrome DevTools MCP (list_pages) both respond.

- **Available**: run `/test chrome` (expose `EVIDENCE_DIR=$_cycle_evidence_dir` — use this path instead of chrome.md step 0's mktemp). Scope is auto-determined from diff. On FAIL, delegate fix to impl-coder → retry from step 3. Right after receiving the delegation result, `_cycle_corrections.append({step: "test-chrome", attempt: N, what: "<one-line fix summary>", why: "<page · symptom: e.g. 'home/console Failed to fetch'>"})`. On retry failure → **hard stop** + ticket comment. Clean up `_cycle_dev_pid` before the hard stop.
- **Unavailable** (4a skipped): always record "⚠ /test chrome SKIP: <4a reason>" in the Phase 2 log. Also include in the final report as outstanding risk.

**Evidence screenshots:** chrome.md step 5's "if there are failure evidence screenshots, save them to temp via take_screenshot" lands in `$EVIDENCE_DIR`, so no extra work needed. Additionally, to save a final-state screenshot per page (one each) on PASS as well, either pass a hint like `--evidence=always` when invoking chrome.md, or after `/test chrome` returns, the cycle directly calls `mcp__chrome-devtools__take_screenshot` to save `${EVIDENCE_DIR}/<page>-final.png`. Attachment selection rule: on PASS, 1 final per page; on FAIL, both the fail-time and post-fix final.

**On FAIL retry:** when impl-coder fix → re-run step 3 → re-enter 4b, keep the server alive if `_cycle_dev_pid` is still up. If dead, re-run from 4a.

### 5. Commit

Stage only relevant changes (exclude `.env`, secrets, unrelated generated files).

If `{skillSimplify}` is `true`, immediately after `git add` and before `git commit` call `Skill(name="simplify")` or `/simplify` against the staged diff → auto-fix on missed reuse / over-abstraction / dead code. If a fix occurred, re-stage and proceed. If no fix, commit as-is. Time cost is high, so OFF by default.

- Title: `<type>: <what> ({projectKey}-<n>)`
- Trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`

### 6. Codex cross-review

> If `{codexReviewEnabled}` is `false`, skip → step 7.

`push.md` section 5 is the canonical reference. Per-exit-code handling:
- **0**: next step.
- **1**: delegate reflection to impl-coder (`mode: "reflect-exit1"`). After a new commit, re-run. Right after receiving the delegation result, `_cycle_corrections.append({step: "codex-review", attempt: N, what: "<one-line summary of reflected finding — e.g. 'critical: added SQL injection defense'>", why: "codex exit 1 (streak=0)"})`.
- **5**: main (opus) directly devises a strategy → delegate re-implementation to impl-coder. `_cycle_corrections.append({step: "codex-review", attempt: N, what: "<one-line opus strategy — e.g. 'opus_remodel: split out permission-check layer'>", why: "codex exit 5 (streak≥1)"})`.
- **4**: user decision required, **hard stop**.
- **2/3**: infra error, **hard stop**.

### 7. Push

`git push -u origin <branch>`

### 8. Create PR

`gh pr create --base {baseBranch} --title "<commit title>" --body "Refs: {projectKey}-<n>..."`

### 8a. Validation summary report (user-facing)

Right after PR creation, before merge, emit a single block of validation results from this cycle **so the user can read it**. Do not omit this even in auto loops (`/ticket:auto`, `/ticket:batch`) — this is the first thing a returning user checks.

```
── {projectKey}-<n> validation summary ──
/test:        PASS (86/86) | FAIL (2 failures, PASS after retry) | N/A (changes unrelated to regression mapping — e.g. docs-only / `.claude/`-only) | ⚠ SKIP: <reason>
/test chrome: PASS (home, detail) | FAIL → fix → PASS | N/A (zero UI mappings in changed area) | ⚠ SKIP: dev server not running
codex review: PASS (exit 0) | reflected once (exit 1 → reflect) | PASS (chore allowlist auto) | N/A (codexReview.enabled=false)
PR:           #<n> (<PR URL>)
Outstanding risk: none | /test chrome SKIP — manual browser check recommended
───────────────────────────────
```

Fill each row with the actual outcome. Status vocabulary: `PASS` (ran, passed), `FAIL → fix → PASS` (passed after retry), `N/A (reason)` (intended out-of-scope — `/test chrome` via 4b auto-determination, `/test` when the project's regression script in auto mode determines zero regression mappings in the changed area — e.g. docs-only / `.claude/`-only), `⚠ SKIP: <reason>` (env-dependent, not run). N/A and SKIP differ — N/A is not outstanding risk, SKIP is. If outstanding risk exists, summarize it on the last row.

### 9. Merge

`gh pr merge --squash --delete-branch`. On conflict, **hard stop** (report PR link, no `--force`).

### 10. JIRA state transition

Branch on the 8a validation summary. In a solo workflow, when `/test` + `/test chrome` + Codex cross-review have all passed (or are out-of-scope N/A), having the same person re-look at the same code through a READY FOR QA gate adds little value, so it is bypassed. However, if any step was SKIPped due to env dependency or any outstanding risk is recorded, leave the ticket at READY FOR QA as a manual-QA signal for the user.

- **All PASS / N/A + no outstanding risk** → `Mark Done` → `Done`.
  - Conditions: `/test` **PASS or N/A** (including PASS-after-retry, or regression script in auto mode determining zero regression mappings in the changed area — e.g. docs-only / `.claude/`-only), `/test chrome` **PASS or N/A** (= 4b auto-determined zero UI mappings in changed area), Codex review **exit 0 / chore allowlist auto-pass / `{codexReviewEnabled}=false` (= N/A by config)**, the "Outstanding risk" row in 8a is "none" or empty.
- **Any SKIP / outstanding risk recorded** → `Submit for QA` → `READY FOR QA`.
  - Example triggers: `/test chrome` SKIP (dev server not running / WSL WebGL unsupported, etc. — env-dependent, not run), Codex auto-pass finding recorded as outstanding risk, user-facing change without a11y audit, etc. **`{codexReviewEnabled}=false` is treated as N/A, not SKIP** (intended out-of-scope, not outstanding risk).
- **N/A vs SKIP (key)**: N/A means the validation target is 0 in the changed area or intentionally turned off via config — auto/config determined, same Mark Done track as PASS. SKIP means it could not run because environment/tools were unavailable — operator manual-QA signal, READY FOR QA track. This distinction determines release-gate trustworthiness, so always record the N/A reason in both the 8a summary and the step 11 comment (e.g. `codex review: N/A (codexReview.enabled=false)`).

In the `getTransitionsForJiraIssue` response, match transition id by name. On transition failure, record the blocker as a comment and stop. Also state the branch decision in one line in the step 11 `validation summary` comment body (`Transition: Mark Done` / `Transition: Submit for QA (reason: <skip item>)`).

### 11. Evidence comment + screenshot attachment

**11a. Compose JIRA comment body:** combine the following sections in order and post once via `addCommentToJiraIssue`:

1. **Validation summary** (required): PR URL, merge commit sha, regression mode and result, browser validation result (PASS/FAIL/skip).
2. **Corrections during cycle** (conditional): if `_cycle_corrections` is non-empty, add a `## Corrections during cycle` section. Render each entry as one line — `- [<step>] attempt N: <what> (reason: <why>)`. Step categories: `test` / `test-chrome` / `codex-review`. If empty, omit the section entirely (case where it passed without any retries).
3. **Attached screenshots** (conditional): if step 11b uploaded any files successfully, add a `## Attached screenshots` section listing the filenames (to view alongside the JIRA UI attachment panel). For inline preview in the body, use `!<filename>|thumbnail!` (JIRA wiki markup) or `[^<filename>]` (ADF reference).
4. **release-notes** (conditional): if `{skillReleaseNotes}` is `true` and the ticket labels include `user-facing` or `release-impacting`, add a `## User-facing change summary` section and attach a one-paragraph output from `Skill(name="pm-execution:release-notes")`.

**11b. Screenshot attachment (conditional — when `{jiraAttachmentEnabled}` is `true`):**

Upload the `*.png` files (and `*.html` Lighthouse reports if any) from `_cycle_evidence_dir` via the JIRA REST API. Rovo MCP does not expose an attachment tool, so call `curl` directly.

```bash
TOKEN=$(cat "${jiraAttachmentTokenFile/#\~/$HOME}")  # ~ expansion
[ -z "$TOKEN" ] && echo "⚠ JIRA token missing — skip attach" && return
shopt -s nullglob
for f in "$_cycle_evidence_dir"/*.png "$_cycle_evidence_dir"/*.html; do
  [ -f "$f" ] || continue
  curl -sS -X POST \
    -u "${jiraAttachmentEmail}:${TOKEN}" \
    -H "X-Atlassian-Token: no-check" \
    -H "Accept: application/json" \
    -F "file=@${f}" \
    "https://${cloudId}/rest/api/3/issue/${ticket_snapshot.key}/attachments" \
    > /tmp/jira-attach-$$.log 2>&1 \
    && echo "uploaded: $(basename "$f")" \
    || { echo "⚠ upload failed: $(basename "$f") — $(tail -1 /tmp/jira-attach-$$.log)"; }
done
rm -f /tmp/jira-attach-$$.log
```

The list of successfully uploaded files feeds into the `## Attached screenshots` section in step 11a. If the token is unset, `{jiraAttachmentEnabled}` is false, or the directory is empty, silently skip and omit that section from the comment body.

> **Token setup (one-time)**: user generates a token at https://id.atlassian.com/manage-profile/security/api-tokens → `mkdir -p ~/.config/jira && echo '<token>' > ~/.config/jira/api-token && chmod 600 ~/.config/jira/api-token` → configure `jira.attachmentApi` in `.claude/project.json` (`enabled:true`, `userEmail`, `tokenFile`). See the `jira.attachmentApi` section in § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md.

**11c. GitHub PR evidence comment (conditional — when `{githubEvidenceEnabled}` is `true`):**

Also post the same evidence-dir files as a GitHub PR comment. Committing binaries directly to the PR branch (= the merge target develop) would mix binaries into develop on squash merge, so push them to a **separate orphan branch `evidence/{key}-{short_sha}`** and reference them via raw URL. On merge, `--delete-branch` only deletes the PR's own branch, so the evidence branch is preserved.

```bash
[ -d "$_cycle_evidence_dir" ] || return
shopt -s nullglob
files=("$_cycle_evidence_dir"/*.png "$_cycle_evidence_dir"/*.html)
[ ${#files[@]} -eq 0 ] && return

REMOTE_URL=$(git -C "{worktree.cwd}" remote get-url origin)
OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
SHORT_SHA="${head_sha:0:7}"
EV_BRANCH="evidence/${ticket_snapshot.key}-${SHORT_SHA}"

# Orphan branch push — touches neither the main repo nor the PR branch
EV_PUSH_TMP=$(mktemp -d -t "evidence-push-${ticket_snapshot.key}-XXXXXX")
(
  cd "$EV_PUSH_TMP"
  git init -q -b "$EV_BRANCH"
  git config user.email "${jiraAttachmentEmail:-noreply@anthropic.com}"
  git config user.name "Cycle evidence"
  cp "${files[@]}" .
  git add .
  git commit -q -m "evidence: ${ticket_snapshot.key} (${SHORT_SHA})"
  git push -q "$REMOTE_URL" "HEAD:refs/heads/$EV_BRANCH"
)
rm -rf "$EV_PUSH_TMP"

# Compose PR comment body (PNG inline only, HTML as link)
BODY="## Verification Evidence ($SHORT_SHA)"$'\n\n'
for f in "$_cycle_evidence_dir"/*.png; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  BODY+="![${name%.png}](https://raw.githubusercontent.com/${OWNER_REPO}/${EV_BRANCH}/${name})"$'\n'
done
for f in "$_cycle_evidence_dir"/*.html; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  BODY+="- [${name}](https://raw.githubusercontent.com/${OWNER_REPO}/${EV_BRANCH}/${name})"$'\n'
done
BODY+=$'\n'"JIRA: https://${cloudId}/browse/${ticket_snapshot.key}"

gh pr comment "$PR_NUMBER" --body "$BODY"
```

The branch naming convention `evidence/{key}-{short_sha}` accumulates without collision across retries on the same ticket. Periodic cleanup is the user's responsibility — bulk-clean via `git push origin --delete $(git ls-remote --heads origin 'evidence/*' | awk '{print $2}' | sed 's|refs/heads/||')`.

If `{githubEvidenceEnabled}` is false, the directory is empty, or the gh CLI is unauthenticated, silently skip. Independent of 11b (JIRA) — either-only or both-on are both fine.

### 12. Worktree cleanup

**Dev server cleanup (first):** if `_cycle_dev_pid` is non-null and the process is alive, run `kill $_cycle_dev_pid; wait $_cycle_dev_pid 2>/dev/null`. Always perform on both normal and hard-stop paths.

**Evidence directory cleanup:** if `_cycle_evidence_dir` is non-null, after step 11 finishes (both normal and hard-stop) run `rm -rf "$_cycle_evidence_dir"`. If any uploads failed, report the path to the user in one line right before cleanup so they have a chance to recover manually.

See the "Cleanup" section of § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md. uncommitted check → `worktree remove` → `prune` → `fetch` → `pull`.
