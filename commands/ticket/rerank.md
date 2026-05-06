# /ticket:rerank — propose and apply a JIRA backlog rerank

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Read-only proposal of a new ordering for the working backlog (status group + priority + age), then on user approval, write ranks back to JIRA via `curl PUT /rest/agile/1.0/issue/rank` (the Agile REST API). Sibling to `/ticket:audit` — same propose → approve → apply shape.

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
| `/ticket:rerank` | Default. Compute proposed order over the four working statuses, print the report, ask for approval, apply on yes. |
| `/ticket:rerank --top N` | Slice the candidate set to the first N rows by current rank. |
| `/ticket:rerank --parent {projectKey}-<epic>` | Restrict to children of an Epic. |
| `/ticket:rerank --status "A,B,C"` | Override the default status filter (comma-separated). |
| `/ticket:rerank --dry-run` | Skip the apply prompt; print proposed order only. Read-only. |
| `/ticket:rerank --explicit KEY1,KEY2,...` | Skip the heuristic; use the user-supplied order directly. Still gated on approval before any write. |

Combinable (`--parent {projectKey}-150 --top 10`, `--explicit KEY1,KEY2 --dry-run`).

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

### 2. Compute proposed order

Status weight (matches `/ticket:auto` candidate priority — see `commands/ticket/auto.md` step 2):

| Status | Weight |
|---|---|
| `QA FAILED` | 0 (top) |
| `READY FOR QA` | 1 |
| `In Progress` | 2 |
| `To Do` | 3 |

Within each weight bucket, sort by:
1. **Priority DESC** — `Highest` > `High` > `Medium` > `Low` > `Lowest`. Treat unset/`None` as `Medium`.
2. **`created` ASC** — older first.

Stable sort. Ties retain the JQL order from step 1 (i.e. current Rank).

For `--explicit`: parse the comma-separated keys, validate that every key is present in the candidate set (and that no candidate is missing from the supplied list). On mismatch, **abort** and list the discrepancies.

### 3. Print proposal report

```
## /ticket:rerank proposal
Scope: status IN (...) | parent={projectKey}-<epic|none> | total=N (max 50)
Source rule: status group + priority + age | --explicit | etc.

| New # | Old # | Δ    | Key      | Status        | Pri     | Age  | Summary |
|---|---|---|---|---|---|---|---|
| 1     | 7     | ↑6   | {projectKey}-42 | QA FAILED     | High    | 12d  | … |
| 2     | 1     | ↓1   | {projectKey}-15 | READY FOR QA  | Highest | 3d   | … |
| 3     | 3     | =    | {projectKey}-7  | In Progress   | High    | 5d   | … |
| …                                                                    |

Movers: K of N tickets shift position.
No-ops: M tickets already correctly ranked.
```

**Hard rule** (mirrors `commands/ticket/audit.md` "steps up to 5 are read-only"): no JIRA writes by the end of step 3.

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

**Why per-pair, not a single batched call.** The Agile API's batch mode (multiple `issues` with one `rankAfterIssue`) places **all** listed issues immediately after the same anchor — fine for "move N tickets to one spot" but **wrong** for enforcing a total order over N tickets. Per-pair iteration is the correct primitive for "make seq[i] come right after seq[i-1] for every i".

**No-op detection.** Skip the curl call when the proposed pair already matches the current order (`prev` was already immediately before `curr` in the JQL `ORDER BY Rank ASC` result). Track these as "no-op" in the result table.

**Retry.** Retry once on transient errors (network blip, HTTP 5xx). On HTTP 4xx (401/403 stale token, 400 invalid issue key, etc.), abort the rest of the apply and report the partial result. Sequential issue order is critical — a parallel apply would race on rank assignment.

### 6. Print apply-result table

```
## /ticket:rerank apply result

| # | Issue            | rankAfterIssue   | HTTP | Result |
|---|---|---|---|---|
| 1 | {projectKey}-15  | {projectKey}-42  | 204  | OK     |
| 2 | {projectKey}-99  | {projectKey}-15  | —    | no-op (already in order) |
| 3 | {projectKey}-7   | {projectKey}-99  | 204  | OK     |
| 4 | {projectKey}-3   | {projectKey}-7   | 401  | FAIL: token rejected |
| …                                                                |

Applied: K of N. Failed: F. No-ops: M.
```

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

## Notes

- **Read-only by default through step 3.** No JIRA writes before user approval.
- **Curl + Agile REST.** Uses `PUT /rest/agile/1.0/issue/rank` (relative `rankAfterIssue`). The MCP path is unavailable: `editJiraIssue` silently rejects Lexorank field updates, and `fetch` is ARI-only (no arbitrary REST). Token reuses `jira.restApi` (with `jira.attachmentApi` fallback) — typically nothing new to set up if attachments are already configured.
- **Lexorank strings are never computed locally.** All ordering is expressed via `rankAfterIssue` (relative). The Agile API allocates new Lexoranks on the server side.
- **Per-pair, never batched.** N-1 sequential PUT calls for N tickets. Batched mode (multiple issues sharing one anchor) would only place all of them after the same anchor — wrong for total-order enforcement.
- **Sibling to `/ticket:audit`.** Same propose → approve → apply shape.
- **Does not consult or mutate `/ticket:auto` selection logic.** `/ticket:auto` uses its own status-and-label heuristic and does not read JIRA Rank.
- **Out of scope this version**: cross-project rerank, more than 50 in one invocation, recurring auto-rerank, reranking inside the Done pile.

## Related commands

- Single-ticket entry: `/ticket <{projectKey}-n>`
- Backlog summary: `/ticket:list`
- Stale-ticket audit: `/ticket:audit`
- Auto-implementation loop: `/ticket:auto`
