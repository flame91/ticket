# /ticket:audit — audit whether stale open tickets have been invalidated by later changes + apply on approval

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Walk long-stale open tickets in `created ASC` order and produce a report classifying whether each ticket's premises/scope have been overridden by **tickets done or design-doc changes after its `created`**. The verdict is one of three buckets: `keep` / `revise` / `close(NO_NEEDED)`.

After printing the report, **ask the user "apply?"**. If approved (all / partial / specific keys), execute the changes directly. If declined, exit read-only. By default, no JIRA writes happen before user response.

## Step 0: Load project config

Read `.claude/project.json` from the repo root. If `jira.enabled` is `false` or the file is missing, print the notice above and exit.
- `{cloudId}` = `jira.cloudId`
- `{projectKey}` = `jira.projectKey`
- `{epicIssueType}` = `jira.epicIssueType` (default: `"Epic"`)

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:audit` | Default. Deeply audit the top **10** subjects by `created ASC`. |
| `/ticket:audit --top <N>` | Top N subjects (default 10). |
| `/ticket:audit --all` | Audit all open tickets. Per-ticket JQL fires N times — use deliberately. |
| `/ticket:audit {projectKey}-<n>` | Audit only that single open ticket (anchor set computed automatically). |
| `/ticket:audit --parent {projectKey}-<epic>` | Limit scope to children of an epic (still `created ASC`). |
| `/ticket:audit --doc <path>` | Add a design/policy/schema doc to every subject ticket's anchor set. |
| `/ticket:audit --dry-run` | Report only, skip the apply prompt (legacy read-only behavior). |

- Combinable (e.g. `--top 5 --parent {projectKey}-150`, `{projectKey}-187 --doc docs/DESIGN.md`, `--all --dry-run`).
- If `--doc <path>` is given and the path does not exist, abort.

## Run order

1. **Load subjects (open tickets)**
   - `mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`
   - cloudId: `{cloudId}`
   - jql: `project = {projectKey} AND statusCategory != Done AND issuetype != "{epicIssueType}" ORDER BY created ASC` (+ `AND parent = <{projectKey}-epic>` if specified, + `AND key = {projectKey}-<n>` for single-ticket mode)
   - fields: `["summary","status","issuetype","priority","labels","description","created","updated","parent"]` — `created` is required.
   - Unless `--all`, keep only the top `--top N` (default 10). Mention the rest as "audit excluded (oldest-first remaining M-N)" with count only.
   - Print `totalCount` and returned `nodes.length` at the top of the report.

2. **Per-ticket anchor set**
   - For each subject ticket, run an individual JQL:
     - `project = {projectKey} AND statusCategory = Done AND updated >= "<that open ticket's created date>"`
     - fields: `["summary","status","description","updated"]`, `maxResults`: 50.
   - If results exceed 50, only mention `nextPageToken` presence in the report; fetch more only on user request.
   - If `--doc <path>` is given, read locally (read-only) and add to every subject ticket's anchor set.
   - Reason for `updated >= …` instead of `created`: the Done transition is reflected in `updated`, which is accurate for finding "events that overrode it later".

3. **Scope comparison**
   - Compare each subject's `## Done Criteria` · `## Out of Scope` · summary · description against the same sections in anchors (or the `--doc` document).
   - Decide whether anchors change the subject's premises — input data shape · API contract · UX flow · schema · policy.
   - If a single ticket is affected by multiple anchors, take the strongest verdict (`close` > `revise` > `keep`) and list multiple grounds.

4. **Verdict (3 buckets)**
   - `keep` — no overlap or insufficient evidence. Omit from the report body (count only).
   - `revise` — partial overlap. Suggested items:
     - description patch (diff-style bullets: `- (remove)` / `+ (add)`)
     - items to add to `## Out of Scope`
     - optional label suggestion (e.g. `scope-reduced-by-{projectKey}-<x>`)
   - `close` — full overlap or premise collapsed. Suggested items:
     - CLOSED transition (match by `CLOSED` name in `getTransitionsForJiraIssue`)
     - add `NO_NEEDED` label
     - rationale comment (anchor `{projectKey}-<n>` or doc path + one-line reason)

5. **Print report**. No JIRA write calls allowed up to this point. End the report with an apply prompt:
   > "Apply the changes above? Options: `all` (revise + close) / `close only` / `revise only` / `TM-X, TM-Y` (specify keys) / `cancel`"
   - If `--dry-run` is given, skip the prompt and exit.
   - After the prompt, wait for user response. Do not attempt any write before receiving it.

6. **Apply (after user response)**
   - If user says `cancel` / `no` / negative, exit.
   - If user approves, determine the apply target list (all / close only / revise only / explicit keys).
   - For each target ticket:
     - `close` verdict: pre-fetch CLOSED transition ID via `getTransitionsForJiraIssue` (workflow may differ per ticket, so query once on the first close target and cache).
     - Add labels: query current labels via `getJiraIssue` → union existing + suggested labels, then `editJiraIssue` (avoid overwriting). If no labels exist, just set the single item.
     - Comment: `addCommentToJiraIssue` (`contentFormat=markdown`) — verbatim from the report's "suggested comment".
     - Transition: for `close`, apply CLOSED via `transitionJiraIssue`.
   - If a same-intent batch op is partially rejected by the permission system, retry once immediately. Mark items that still fail in the result table.
   - Report apply results as a table: `ticket key | label | comment | transition` with checkmark / cross / dash in each cell.

## Output format

```
## /ticket:audit summary
Audit mode: top-10 (created ASC) | --all | single={projectKey}-<n>
Scope: <all open | parent={projectKey}-<epic>>
Subjects: oldest N audited out of M open (the remaining M-N are not in this report)
Anchor calc: Done tickets after each subject's created
Extra anchor doc: <--doc path | none>
Result: of N audited, keep=a, revise=b, close=c
Pagination: <nextPageToken present/absent>

## revise (b)
- {projectKey}-<n> <summary>   (created: 2025-10-14, age: 191d)
  Anchor evidence: {projectKey}-<x>:Done Criteria #3 (Done 2026-04-18) | docs/xxx.md:section
  Suggested description patch:
    - (remove) <existing line>
    + (add)    <replacement line>
  Add to Out of Scope: <one line>
  Suggested label: scope-reduced-by-{projectKey}-<x>  (optional)

## close (c)
- {projectKey}-<n> <summary>   (created: 2025-09-02, age: 234d)
  Anchor evidence: {projectKey}-<x> (Done 2026-04-18) | docs/xxx.md
  Suggested transition: CLOSED
  Suggested label: NO_NEEDED
  Suggested comment: "Premise (<reason>) of this ticket dissolved by {projectKey}-<x> merge. Closing."

---
Apply the changes above?
- `all` — apply revise + close
- `close only` / `revise only` — apply one bucket
- `{projectKey}-X, {projectKey}-Y` — explicit keys
- `cancel` — do not apply
```

After user approval, the apply result report (after Step 6):

```
## Apply result

| Ticket | Label | Comment | Transition |
|---|---|---|---|
| {projectKey}-<n> | OK NO_NEEDED | OK | OK CLOSED |
| {projectKey}-<m> | FAIL (reason) | OK | — (revise, no transition) |
```

## Notes

- **Steps up to 5 are read-only.** `editJiraIssue` / `addCommentToJiraIssue` / `transitionJiraIssue` are only called in Step 6 after user approval. Never attempt them before user response.
- If `--dry-run` is given, exit at Step 5 (preserve legacy read-only behavior).
- When applying labels, **always preserve existing labels** — query current labels via `getJiraIssue` and union. A plain set overwrite loses existing labels.
- Transition IDs differ per workflow, so pre-fetch via `getTransitionsForJiraIssue`. Recommend caching the result from the first close target within the same project.
- `revise` / `close` verdicts must have **explicit anchor evidence**. Without evidence, `keep` is the default.
- Write evidence specifically down to the section/line of a ticket (e.g. `{projectKey}-200:Done Criteria #3`).
- On MCP 401/403 → re-check via `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources` and note that fact in the report.
- Per-subject anchor JQLs cause up to N+1 calls. With `--all` this can reach hundreds — invoke deliberately.
- If anchor results exceed 50, only mention `nextPageToken` presence; fetch more only on user request.
- The `NO_NEEDED` label is a convention introduced by this command. Applying it outside this command is not recommended.
- When invoked without arguments, state the default `--top 10` on the `Audit mode:` line at the top of the report.

## Related commands

- Single-ticket: `/ticket <{projectKey}-n>`
- New ticket: `/ticket:create`
- Auto-implementation loop: `/ticket:auto`
- Backlog summary: `/ticket:list`

`/ticket:audit` fills the gap left by the four commands above — "have stale open tickets been invalidated by later changes?" — and nothing more. It runs audit → user approval → apply in one flow, so there is no need to enter each ticket via `/ticket <{projectKey}-n>`. For single-ticket edits/comments only, keep using `/ticket <{projectKey}-n>`.
