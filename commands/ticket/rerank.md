# /ticket:rerank — propose and apply a JIRA backlog rerank

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Read-only proposal of a new ordering for the working backlog, then on user approval, write ranks back to JIRA via `curl PUT /rest/agile/1.0/issue/rank` (the Agile REST API). Sibling to `/ticket:audit` — same propose → approve → apply shape.

**Default mode is LLM judgement** — the agent reads each ticket's description, labels, and dependency hints, then proposes an ordering with per-ticket rationale. The previous rule-based heuristic (status group + priority + age) is preserved behind `--heuristic` for cheaper / deterministic runs.

**Why curl, not the MCP.** The Atlassian Rovo MCP cannot set rank: `editJiraIssue` wraps JIRA's platform edit endpoint, which **silently rejects Lexorank field updates** (a documented JIRA Cloud constraint), and `fetch` is ARI-only so it cannot reach the Agile REST endpoint. The only working path is `PUT /rest/agile/1.0/issue/rank` with `rankBeforeIssue` / `rankAfterIssue` (relative — never compute Lexorank strings yourself), max 50 issues per call, scope `write:issue:jira-software`. Auth uses the same Cloud API token pattern as `jira.attachmentApi`.

## Step 0: Load project config

§ `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`. Bindings used here:

- `{cloudId}`, `{projectKey}`, `{epicIssueType}` (existing).
- `{jiraSite}` — `jira.site`, e.g. `flame91.atlassian.net`. Required for `--apply`. If absent, **hard stop** with a setup pointer.
- `{jiraRestApiEnabled}` — `jira.restApi.enabled` (falls back to `jira.attachmentApi.enabled`). False blocks `--apply` (dry-run still works).
- `{jiraRestApiEmail}`, `{jiraRestApiTokenFile}` — same fallback chain. Used as `curl -u "${email}:${token}"`.

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:rerank` | Default. **LLM-judgement mode** over the four working statuses, print the report with rationale, ask for approval, apply on yes. |
| `/ticket:rerank --heuristic` | Use the rule-based heuristic (status group + priority DESC + created ASC). Cheaper, deterministic, no per-ticket rationale. |
| `/ticket:rerank --top N` | Slice the candidate set to the first N rows by current rank. |
| `/ticket:rerank --parent {projectKey}-<epic>` | Restrict to children of an Epic. |
| `/ticket:rerank --status "A,B,C"` | Override the default status filter (comma-separated). |
| `/ticket:rerank --dry-run` | Skip the apply prompt; print proposed order only. Read-only. |
| `/ticket:rerank --explicit KEY1,KEY2,...` | Skip the heuristic and the LLM judgement; use the user-supplied order directly. Still gated on approval before any write. |

Combinable (`--heuristic --parent {projectKey}-150`, `--explicit KEY1,KEY2 --dry-run`).

## Run order

### 1. Load candidates

`mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`:
- cloudId: `{cloudId}`
- jql: `project = {projectKey} AND status IN ("To Do", "In Progress", "QA FAILED", "READY FOR QA") AND issuetype != "{epicIssueType}" ORDER BY Rank ASC`
  - Override the status list via `--status "..."`.
  - Append `AND parent = "<{projectKey}-epic>"` for `--parent`.
- fields: `["summary", "status", "issuetype", "priority", "labels", "created", "parent"]`
- maxResults: `50`

The relative-rank API (step 5) does not need to know the existing Lexorank strings — it expresses ordering as `rankBeforeIssue` / `rankAfterIssue` (key-relative). We only use the JQL result to capture the **current order** (for the proposal table's "Old #" column) and the candidate set.

If the JQL returns more than 50 entries, **warn** that only the first 50 (by current rank) will be considered this run, and the user can re-invoke after applying to operate on the next page.

**Token budget guard.** When the JQL response exceeds the per-tool token cap, the tool returns an error pointing at a saved file. Delegate the parse to a subagent with an explicit instruction: read the file in chunks, return a compact JSON array (key, summary≤100 chars, status, priority, created, parent, labels) preserving file order. This avoids polluting the main context with raw JIRA payload.

### 2. Compute proposed order

#### 2a. LLM-judgement mode (default)

Fetch each candidate's full **description** via `getJiraIssue` (`responseContentFormat: "markdown"`, `fields: ["summary", "description", "status", "priority", "labels"]`). Read each, then rank with the four axes below — applied lexicographically (axis 1 outranks axis 2, etc.) within the status weight bucket from §2c.

1. **Dependency graph** — search descriptions for explicit blocker/precedence patterns:
   - `블로커:` / `선행:` / `depends on` / `blocked by` / `after` followed by a `{projectKey}-N` key
   - JIRA Issue links of type `is blocked by` (visible in `getJiraIssue` with `expand=issuelinks` if needed)
   - Within each status weight bucket, topologically sort: blockers strictly precede their blockees.
   - **Cross-bucket conflict.** If a blocker sits in a lower-priority status bucket than its blockee (e.g. a To Do prerequisite blocks an In Progress ticket), §2c forbids reordering across buckets — so the dependency invariant cannot be satisfied by reranking alone. Treat this as a workflow-state inconsistency: **abort the rerank** and report the conflicting pair with the suggested remediation (move the blockee back to a lower status, or move the blocker up). Listed as a hard-stop condition below. Never silently produce a sequence that violates the dependency invariant.

2. **User-visible defect priority** — push tickets up if they meet ≥1 of:
   - `bug` or `regression` label
   - Description contains "user report" / "사용자 보고" / equivalent locale-specific phrasing with a date
   - Affects the **primary locale** if `jira.primaryLocale` is set in `.claude/project.json` (otherwise this sub-axis is skipped)
   - Hotfix / production-impacting

3. **Dependency cluster grouping** — keep contiguous a chain that shares a parent epic AND has internal blockers (e.g. `backend migration → backend backfill → API exposure → frontend usage`). Don't interleave unrelated tickets between members of a tight chain even if isolated priority signals would split them.

4. **Backlog noise demotion** — push down if any of:
   - `nit`, `rolling-backlog`, `design-heavy`, `size-l` labels
   - Description signals **blocked on external setup** ("Anthropic 키 설정 후", "after vendor account", etc.) without an action this sprint
   - Stale: created > N days ago (default 21) with no recent updates AND no urgency signal from axis 2

Output: a per-ticket **rationale** string (one short clause: `"bug: ja locale broken — primary-locale regression"`, `"depends on TM-241/242/243"`, `"blocked on external Anthropic key"`, etc.) — used in the proposal report.

#### 2b. `--heuristic` mode (rule-based fallback)

Within each status weight bucket (see §2c), sort by:
1. **Priority DESC** — `Highest` > `High` > `Medium` > `Low` > `Lowest`. Treat unset/`None` as `Medium`.
2. **`created` ASC** — older first.

Stable sort. Ties retain the JQL order from step 1 (i.e. current Rank). No description fetch, no rationale column.

#### 2c. Status weight (both modes)

Matches `/ticket:auto` candidate priority — see `commands/ticket/auto.md` step 2:

| Status | Weight |
|---|---|
| `QA FAILED` | 0 (top) |
| `READY FOR QA` | 1 |
| `In Progress` | 2 |
| `To Do` | 3 |

LLM judgement may **not** override the status weight — In Progress always precedes To Do, etc. Within a bucket, the four axes apply. If §2a axis 1 (dependency) requires a cross-bucket move (lower-status blocker, higher-status blockee), abort per the hard-stop table — the conflict signals a workflow-state inconsistency that reranking cannot fix.

#### 2d. `--explicit` mode

Parse the comma-separated keys, validate that every key is present in the candidate set (and that no candidate is missing from the supplied list). On mismatch, **abort** and list the discrepancies. No status weight check, no rationale.

### 3. Print proposal report

```
## /ticket:rerank proposal
Scope: status IN (...) | parent={projectKey}-<epic|none> | total=N (max 50)
Mode: llm-judgement | heuristic | explicit

| New # | Old # | Δ    | Key      | Status        | Pri     | Age  | Rationale (LLM mode) | Summary |
|---|---|---|---|---|---|---|---|---|
| 1     | 7     | ↑6   | {projectKey}-42 | QA FAILED     | High    | 12d  | qa-failed retest urgent | … |
| 2     | 1     | ↓1   | {projectKey}-15 | READY FOR QA  | Highest | 3d   | blocks {projectKey}-99  | … |
| …                                                                    |

Movers: K of N tickets shift position.
```

The `Rationale` column is omitted in `--heuristic` and `--explicit` modes. **Hard rule** (mirrors `commands/ticket/audit.md` "steps up to 5 are read-only"): no JIRA writes by the end of step 3.

If `--dry-run`: print the report and exit 0.

### 4. Ask for approval

```
Apply this rerank?
- `yes` / `apply`  — apply the full proposed order
- `top-N`          — apply only the first N rows (e.g. `top-10`)
- `cancel`         — exit without writing
```

Wait for the user's response. On any unrecognized input or empty answer, **default to cancel** and exit.

### 5. Apply via Agile REST `PUT /rest/agile/1.0/issue/rank`

**Per-pair iteration, never batched.** For each pair `(prev, curr)` in the approved sequence (starting from index 1, where `prev = seq[i-1]` and `curr = seq[i]`), issue one PUT call with `rankAfterIssue = prev.key` and `issues = [curr.key]`:

```bash
TOKEN=$(cat "${jiraRestApiTokenFile/#~/$HOME}")
curl -sS -u "${jiraRestApiEmail}:${TOKEN}" \
  -X PUT "https://{jiraSite}/rest/agile/1.0/issue/rank" \
  -H 'Content-Type: application/json' \
  -d "{\"issues\": [\"${curr.key}\"], \"rankAfterIssue\": \"${prev.key}\"}" \
  -w '%{http_code}\n' -o /tmp/rerank-resp-$$.json
```

Bash invocation: when running on macOS via the Bash tool (zsh-default shell), arrays are 1-indexed and the script will misindex. **Always wrap the loop in `bash <<'BASH' ... BASH`** to force bash semantics (0-indexed arrays, C-style `for ((i=1; i<N; i++))`).

**Why per-pair, not a single batched call.** The Agile API's batch mode (multiple `issues` with one `rankAfterIssue`) places **all** listed issues immediately after the same anchor — fine for "move N tickets to one spot" but **wrong** for enforcing a total order over N tickets. Per-pair iteration is the correct primitive for "make seq[i] come right after seq[i-1] for every i".

**Issue all N-1 PUTs — do NOT skip pairs.** A previous version of this command tried to skip pairs that were already adjacent in the JQL source order. **This is wrong.** Each PUT physically moves an issue, which can break an adjacency that held in the source. Concretely: if seq is `[A, B, C, D]` and source is `[A, X, C, B, ..., D]`, and you do PUT (B after A) but skip (C after B) because in source `B → C` was adjacent, the final state is wrong: B was just moved, C is still where it was — they are no longer adjacent. The Agile API call is idempotent and returns 204 even when the issues are already in the requested order, so issuing all N-1 PUTs is cheap and always correct.

**Retry.** Retry once on transient errors (network blip, HTTP 5xx). On HTTP 4xx (401/403 stale token, 400 invalid issue key, etc.), abort the rest of the apply and report the partial result. Sequential issue order is critical — a parallel apply would race on rank assignment.

### 6. Print apply-result table

```
## /ticket:rerank apply result

| # | Issue            | rankAfterIssue   | HTTP | Result |
|---|---|---|---|---|
| 1 | {projectKey}-15  | {projectKey}-42  | 204  | OK     |
| 2 | {projectKey}-99  | {projectKey}-15  | 204  | OK     |
| 3 | {projectKey}-3   | {projectKey}-7   | 401  | FAIL: token rejected |
| …                                                                |

Applied: K of N. Failed: F.
```

After all PUTs complete, **re-fetch the candidate set** (same JQL as step 1, only `summary` field) to verify the final order matches the approved sequence. Print a one-line `verify: OK` (or list any mismatches) at the bottom of the result table.

On any 4xx mid-batch: stop, print the partial result, and warn the user that the JIRA backlog is now in an intermediate state — some new ranks applied, some old ranks remain. Suggest re-running `/ticket:rerank` to converge.

## Hard stop conditions

| Trigger | Action |
|---|---|
| `jira.enabled = false` | Standard "JIRA not configured" notice, exit 0 |
| `--apply` requested but `{jiraRestApiEnabled}` is false (and `attachmentApi.enabled` is also false / unset) | Hard stop with: "Set up `jira.restApi` per `_config.md` to apply ranks. Use `--dry-run` to preview only." |
| `{jiraSite}` unset and `--apply` requested | Hard stop with: "Set `jira.site` (e.g. `flame91.atlassian.net`) in `.claude/project.json`, then re-run." |
| Token file unreadable | Hard stop pointing at the `_config.md` `jira.restApi` setup steps |
| MCP 401/403 on the JQL fetch | Re-check via `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources`; abort if still failing |
| Curl HTTP 401/403 | Token likely stale; print "regenerate at https://id.atlassian.com/manage-profile/security/api-tokens" and abort the apply |
| Curl HTTP 4xx (other) | Abort the rest of the apply; partial result table; suggest re-run |
| Total candidates > 50 | Warn and operate on the first 50 only (per-call API cap) |
| `--explicit` keys mismatch the candidate set | Abort, list mismatches |
| LLM-judgement mode hits dep cycle (A blocks B blocks A) | Abort, list the cycle, suggest fixing the description text or running `--heuristic` |
| LLM-judgement mode hits cross-bucket dep conflict (lower-status blocker, higher-status blockee) | Abort, name the conflicting pair, suggest moving the blockee back to a lower status or promoting the blocker. Reranking cannot resolve it; only a status transition can. |

## Notes

- **Read-only by default through step 3.** No JIRA writes before user approval.
- **LLM-judgement is the default.** It buys discrimination in the common case where many tickets share the same status+priority bucket and the rule-based mode collapses to "older first" (which is rarely the right answer). When you don't want LLM cost / variance, pass `--heuristic`.
- **Curl + Agile REST.** Uses `PUT /rest/agile/1.0/issue/rank` (relative `rankAfterIssue`). The MCP path is unavailable: `editJiraIssue` silently rejects Lexorank field updates, and `fetch` is ARI-only (no arbitrary REST). Token reuses `jira.restApi` (with `jira.attachmentApi` fallback) — typically nothing new to set up if attachments are already configured.
- **Lexorank strings are never computed locally.** All ordering is expressed via `rankAfterIssue` (relative). The Agile API allocates new Lexoranks on the server side.
- **Per-pair, never batched.** N-1 sequential PUT calls for N tickets. Batched mode (multiple issues sharing one anchor) would only place all of them after the same anchor — wrong for total-order enforcement.
- **No skip optimization.** Always issue all N-1 PUTs. Skipping based on source-order adjacency is incorrect because intermediate PUTs invalidate the adjacency premise. The Agile API is idempotent (204 even when no actual move occurs), so the cost is tolerable.
- **bash, not zsh.** Wrap the apply loop in `bash <<'BASH' ... BASH` to force 0-indexed arrays. zsh on macOS will silently misindex `${SEQ[$((i-1))]}` and put empty strings into the curl payload, which JIRA rejects with HTTP 400.
- **Sibling to `/ticket:audit`.** Same propose → approve → apply shape.
- **Does not consult or mutate `/ticket:auto` selection logic.** `/ticket:auto` uses its own status-and-label heuristic and does not read JIRA Rank.
- **Out of scope this version**: cross-project rerank, more than 50 in one invocation, recurring auto-rerank, reranking inside the Done pile.

## Related commands

- Single-ticket entry: `/ticket <{projectKey}-n>`
- Backlog summary: `/ticket:list`
- Stale-ticket audit: `/ticket:audit`
- Auto-implementation loop: `/ticket:auto`
