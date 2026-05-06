# /ticket:rerank — propose and apply a JIRA backlog rerank

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Read-only proposal of a new ordering for the working backlog (status group + priority + age), then on user approval, write ranks back to JIRA via the Agile REST API. Sibling to `/ticket:audit` — same propose → approve → apply shape, different decision.

The Atlassian Rovo MCP cannot set rank (the Lexorank field is rejected by `editIssue`), so this command shells out to `curl` against `PUT /rest/agile/1.0/issue/rank` using the same Cloud Basic-auth pattern (`userEmail` + API token in a file) already used by `jira.attachmentApi`.

## Step 0: Load project config

§ `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`. Bindings used here:

- `{cloudId}`, `{projectKey}`, `{epicIssueType}` (existing).
- `{jiraSite}` — `jira.site` (e.g. `flame91.atlassian.net`). Required for `--apply`. If absent, derive from any Atlassian URL the user has on hand and prompt them to add it to `project.json`.
- `{jiraRestApiEnabled}` — `jira.restApi.enabled` if present, else `jira.attachmentApi.enabled`. False blocks `--apply`.
- `{jiraRestApiEmail}` — `jira.restApi.userEmail` if present, else `jira.attachmentApi.userEmail`.
- `{jiraRestApiTokenFile}` — `jira.restApi.tokenFile` if present, else `jira.attachmentApi.tokenFile`.

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
- maxResults: `50` — matches the Agile rank API per-call cap.

If the JQL returns more than 50 entries, **warn** that only the first 50 (by current rank) will be considered this run, and the user can re-invoke after applying to operate on the next page. Do not paginate transparently.

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
2. **`created` ASC** — older first (oldest debt cleared sooner).

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

**Hard rule (mirrors `commands/ticket/audit.md` "steps up to 5 are read-only"):** no JIRA writes — neither MCP nor curl — have happened by the end of step 3.

If `--dry-run`: print the report and exit 0. Do not proceed to step 4.

### 4. Ask for approval

```
Apply this rerank?
- `yes` / `apply`  — apply the full proposed order
- `top-N`          — apply only the first N rows (e.g. `top-10`)
- `cancel`         — exit without writing
```

Wait for the user's response. On any unrecognized input or empty answer, **default to cancel** and exit. Do not attempt any write before receiving an explicit approval.

If approval is given but `{jiraRestApiEnabled}` is false (i.e. neither `jira.restApi.enabled` nor `jira.attachmentApi.enabled` is true), **hard stop** with: "Set up `jira.restApi` per `_config.md` to apply ranks. Re-run with `--dry-run` to preview only." Do not silently downgrade.

If approval is given but `{jiraSite}` is unset, prompt the user once for the host (e.g. `flame91.atlassian.net`) and instruct them to persist it as `jira.site` in `project.json`. Continue if they supply it interactively.

### 5. Apply via curl

For each pair `(prev, curr)` in the approved sequence — that is, `(seq[0], seq[1])`, `(seq[1], seq[2])`, …, `(seq[n-2], seq[n-1])` — issue:

```bash
TOKEN=$(cat "${jiraRestApiTokenFile/#~/$HOME}")
curl -sS -u "${jiraRestApiEmail}:${TOKEN}" \
  -X PUT "https://{jiraSite}/rest/agile/1.0/issue/rank" \
  -H 'Content-Type: application/json' \
  -d "{\"issues\": [\"${curr}\"], \"rankAfterIssue\": \"${prev}\"}" \
  -w '\nHTTP %{http_code}\n'
```

Why one PUT per pair (and not a single batched PUT with all 50 keys): the Agile API places every issue in `issues[]` after the same anchor, which expresses "move all of these after X" — fine for "move 50 things to the top," wrong for "enforce a total order over 50 things." Per-pair iteration is the correct primitive when each ticket needs its own anchor.

**Lexorank strings are never computed locally.** All ordering is expressed via `rankAfterIssue` (relative to a key already in the backlog).

**Retry:** retry once on transient HTTP 5xx. On 4xx (or repeat 5xx), abort the rest of the apply.

### 6. Print apply-result table

```
## /ticket:rerank apply result

| Pair | Issue           | Anchor (after) | HTTP | Note    |
|---|---|---|---|---|
| 1    | {projectKey}-15 | {projectKey}-42| 204  | OK      |
| 2    | {projectKey}-99 | {projectKey}-15| 204  | OK      |
| 3    | {projectKey}-7  | {projectKey}-99| 401  | Auth    |
| …                                                  |

Applied: K of N. Failed: F.
```

On any 4xx mid-batch: stop, print the partial result, and warn the user that the JIRA backlog is now in an intermediate state — some new ranks applied, some old ranks remain. Suggest re-running `/ticket:rerank` to converge.

## Hard stop conditions

| Trigger | Action |
|---|---|
| `jira.enabled = false` | Standard "JIRA not configured" notice, exit 0 |
| Approval given but `{jiraRestApiEnabled}` is false | Hard stop with config pointer (see step 4) |
| Approval given but `{jiraSite}` unset and the user does not supply one | Hard stop with instructions to set `jira.site` |
| Token file unreadable | Hard stop, point at `_config.md` setup steps |
| MCP 401/403 on the JQL fetch | Re-check via `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources`; abort if still failing |
| Curl 401/403 on apply | Token likely stale — print "regenerate at https://id.atlassian.com/manage-profile/security/api-tokens" and abort |
| Total candidates > 50 | Warn and operate on the first 50 only |
| `--explicit` keys mismatch the candidate set | Abort, list mismatches |

## Notes

- **Read-only by default through step 3.** No JIRA writes — MCP or curl — before user approval.
- **Sibling to `/ticket:audit`.** Same propose → approve → apply shape, but the verdict is "new rank order" rather than "keep / revise / close."
- **Does not consult or mutate `/ticket:auto` selection logic.** `/ticket:auto` uses its own status-and-label heuristic to pick the next ticket and does not read JIRA Rank. After running `/ticket:rerank` the JIRA UI reflects the new order; the auto-loop continues to behave the same.
- **Per-pair PUTs are intentional.** Batched calls cannot enforce a total order — see step 5 rationale.
- **Out of scope this version**: cross-project rerank, more than 50 in one invocation, recurring auto-rerank, reranking inside the Done pile.

## Related commands

- Single-ticket entry: `/ticket <{projectKey}-n>`
- Backlog summary: `/ticket:list`
- Stale-ticket audit: `/ticket:audit`
- Auto-implementation loop: `/ticket:auto`
