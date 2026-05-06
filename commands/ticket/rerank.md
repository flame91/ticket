# /ticket:rerank — propose and apply a JIRA backlog rerank

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Read-only proposal of a new ordering for the working backlog (status group + priority + age), then on user approval, write ranks back to JIRA via `editJiraIssue` on the rank custom field. Sibling to `/ticket:audit` — same propose → approve → apply shape.

The Atlassian Rovo MCP `editJiraIssue` accepts arbitrary `fields`, including the rank custom field (`customfield_10019` on standard JIRA Software projects, overridable via `jira.rankFieldId`). New rank values are computed by appending a unique base-36 suffix to the anchor ticket's current Lexorank — no curl, no separate REST credentials, no Lexorank arithmetic library needed.

## Step 0: Load project config

§ `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`. Bindings used here:

- `{cloudId}`, `{projectKey}`, `{epicIssueType}` (existing).
- `{rankFieldId}` — `jira.rankFieldId` if set, default `"customfield_10019"`. The custom-field ID of the Lexorank "Rank" field on the user's JIRA instance.

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
- fields: `["summary", "status", "issuetype", "priority", "labels", "created", "parent", "{rankFieldId}"]`
- maxResults: `50`

The current Lexorank string for each ticket is read from the `{rankFieldId}` field (e.g. `0|hzzzzz:`, `0|i0000v:`). It will be used as the anchor for new rank computation in step 5.

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

### 5. Compute new Lexorank values + apply via editJiraIssue

**Anchor strategy.** The first ticket in the proposed order (`seq[0]`) keeps its existing rank — call that string `R_anchor`. Every other ticket in the proposed order gets a new rank value formed by appending a 2-character base-36 suffix to `R_anchor`:

```
seq[0].new_rank = R_anchor                         (no write needed)
seq[i].new_rank = R_anchor + base36_2char(i)       for i = 1..N-1
```

Where `base36_2char(i)` is the 2-character left-zero-padded base-36 encoding of `i`:

| i | suffix | i | suffix | i | suffix |
|---|---|---|---|---|---|
| 1 | `01` | 10 | `0a` | 36 | `10` |
| 2 | `02` | 35 | `0z` | 49 | `1d` |
| … | … | … | … | … | … |

This is enough for any rerank up to 49 entries (and the JQL maxResults cap is 50 anyway).

**Why this works.** Lexorank strings are compared lexicographically. `R_anchor < R_anchor + "01" < R_anchor + "02" < ... < R_anchor + "0z" < R_anchor + "10" < ...` always holds, and these new strings are all strictly less than the next existing rank above `R_anchor` in the project (they share `R_anchor` as a prefix, but are longer — and any existing rank with a larger prefix character at the same position will sort higher).

**Writes.** For each `(ticket, new_rank)` pair where `ticket.current_rank != new_rank` (i.e. not a no-op), call:

```
mcp__claude_ai_Atlassian_Rovo__editJiraIssue(
  cloudId={cloudId},
  issueIdOrKey=ticket.key,
  fields={ "{rankFieldId}": new_rank }
)
```

Issue these calls sequentially (no parallel writes — keeps order of operations clean and avoids transient ordering races during the apply). Track each call's outcome (success / error) for the result table.

**Retry.** Retry once on transient errors (network blip, 5xx). On 4xx (e.g. field rejected, permission denied), abort the rest of the apply and report the partial result.

### 6. Print apply-result table

```
## /ticket:rerank apply result

| # | Key             | New rank suffix | Result   |
|---|---|---|---|
| 1 | {projectKey}-42 | (anchor)        | no-op    |
| 2 | {projectKey}-15 | 01              | OK       |
| 3 | {projectKey}-99 | 02              | OK       |
| 4 | {projectKey}-7  | 03              | FAIL: <reason> |
| …                                                  |

Applied: K of N. Failed: F. Anchor (no write): {projectKey}-42 → R_anchor unchanged.
```

On any 4xx mid-batch: stop, print the partial result, and warn the user that the JIRA backlog is now in an intermediate state — some new ranks applied, some old ranks remain. Suggest re-running `/ticket:rerank` to converge.

## Hard stop conditions

| Trigger | Action |
|---|---|
| `jira.enabled = false` | Standard "JIRA not configured" notice, exit 0 |
| `{rankFieldId}` value missing on any candidate (rank column comes back null) | Hard stop with: "Rank field `{rankFieldId}` returned no value for `<key>`. Override `jira.rankFieldId` in `.claude/project.json` if your instance uses a different field ID, then re-run." |
| MCP 401/403 on the JQL fetch | Re-check via `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources`; abort if still failing |
| MCP write returns 4xx (field rejected) | Abort the rest of the apply; partial result table; suggest re-run |
| Total candidates > 50 | Warn and operate on the first 50 only |
| `--explicit` keys mismatch the candidate set | Abort, list mismatches |

## Notes

- **Read-only by default through step 3.** No JIRA writes before user approval.
- **MCP-only writes.** Uses `editJiraIssue` exclusively — no curl, no separate API token, no `jira.restApi` config. Reuses the same MCP auth context already established for every other ticket-plugin command.
- **Anchor + suffix Lexorank.** No external Lexorank library. The first ticket in the proposed order keeps its current rank as anchor; subsequent tickets get ranks formed by suffix-appending. This works for ≤49 entries (the JQL cap is 50).
- **Sibling to `/ticket:audit`.** Same propose → approve → apply shape.
- **Does not consult or mutate `/ticket:auto` selection logic.** `/ticket:auto` uses its own status-and-label heuristic and does not read JIRA Rank.
- **Out of scope this version**: cross-project rerank, more than 50 in one invocation, recurring auto-rerank, reranking inside the Done pile, cleanup of accumulated suffixes (each rerank stacks one more suffix layer onto the anchor; after many reruns Lexorank rebalancing may be triggered server-side, which is fine).

## Related commands

- Single-ticket entry: `/ticket <{projectKey}-n>`
- Backlog summary: `/ticket:list`
- Stale-ticket audit: `/ticket:audit`
- Auto-implementation loop: `/ticket:auto`
