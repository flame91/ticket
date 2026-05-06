# /ticket:batch:plan — Input queue split suggestion (read-only)

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

Analyzes a given key list and **suggests splitting into multiple `/ticket:batch` invocations** based on dependencies, progress state, and labels. Read-only mode that does not actually execute — the user copies and runs the printed commands themselves.

`/ticket:batch`'s `--par` mode takes the input queue as-is and runs concurrently (no auto-grouping). This skill pre-computes a "how to group" recommendation before invoking batch directly.

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:batch:plan TM-a,TM-b,...` | Comma-separated key list |
| `/ticket:batch:plan 182,183` | Numbers only are auto-normalized to `{projectKey}-<n>` |
| `/ticket:batch:plan TM-a, TM-b` | Whitespace allowed (trim) |

At least 2 keys required. If 1 key, print `/ticket <{projectKey}-n>` guidance and exit.

---

## Step 0: Load project config

See § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md.

## Step 1: Parse arguments

Comma split → trim → normalize to `{projectKey}-<n>` → dedupe (preserving input order).
If list is empty / single / invalid format, print guidance and exit.

## Step 2: Collect metadata (one `getJiraIssue` per key)

For each key, query only these fields (lightweight):
`summary, status, issuetype, parent, issuelinks, labels, priority`

## Step 3: Classify

Classify each key into a category:

| Category | Condition | Handling |
|---|---|---|
| `runnable` | status ∈ {To Do, READY FOR DEV} and issuetype != `{epicIssueType}` | Add to runnable queue |
| `in-progress` | status == In Progress | Skip (reason: current worktree active, handle separately) |
| `ready-for-qa` | status == "READY FOR QA" | Skip (reason: manual `/ticket <{projectKey}-n>` recommended) |
| `already-done` | statusCategory == Done | Skip |
| `epic-excluded` | issuetype == `{epicIssueType}` | Skip |
| `not-found` | API missing / permission error | Skip |

## Step 4: Build dependency graph

For the `runnable` queue only:
- Extract from `issuelinks` items where `type.name ∈ {"Blocks", "Depends", "is blocked by"}`
- Use as edge only if the linked key is also inside the same runnable queue (external key dependencies are shown as info)
- On cycle detection → report "Dependency cycle detected: TM-x ↔ TM-y" and exit

## Step 5: Topological sort + level split

DAG topological sort → group by level. Keys at level N are mutually independent → `--par` candidates; across levels is sequential.

## Step 6: Further split within group (5-key chunks)

For K keys at each level:

| K | Recommended call |
|---|---|
| 1 | `/ticket <key>` (single-key batch is meaningless) |
| 2-5 | `/ticket:batch --par <key1>,<key2>,...` |
| 6+ | Chunk into 5 by input order, each chunk an independent `--par` |

## Step 7: Heuristic warnings (no forced split, display only)

The following patterns are reported with ⚠️ but do not force a split:

- **Multiple size-l running concurrently**: 2+ size-l labels in the same group → "Concurrent merges of large changes burden regression validation. Recommend separating"
- **Same EPIC + same area-***: 2+ keys with the same parent and matching area-* label → "Possible same-file-region conflict"
- **Lone Highest priority**: a single Highest bundled with other keys → "Recommend running alone to minimize failure impact"
- **External dependency**: linked key outside the queue + status != Done → "Risk of blocking if started while TM-x is incomplete"

## Step 8: Output format

```
=== /ticket:batch split suggestion ===

Input: N keys
runnable: K
skipped: M

Split plan (P calls total):

[1/P] sequential — <reason summary>
  /ticket:batch <key1>,<key2>
  reason: <key1> blocks <key2>

[2/P] parallel — <reason summary>
  /ticket:batch --par <key3>,<key4>,<key5>
  reason: same EPIC <parent>, no dependency links, all size-m

[3/P] sequential — <reason summary>
  /ticket:batch <key6>,<key7>
  reason: both size-l, sequential to isolate regressions

Skipped:
  TM-x: in-progress (current worktree active)
  TM-y: epic-excluded
  TM-z: already-done

⚠️ Caveats:
  TM-c, TM-d both have frontend area-* labels + same EPIC <parent> — possible same-file-region overlap
  TM-f external dependency: TM-200 (To Do) — risk of blocking if started while incomplete

Copy & run:
  /ticket:batch <key1>,<key2>
  /ticket:batch --par <key3>,<key4>,<key5>
  /ticket:batch <key6>,<key7>
```

---

## Safeguards / limits

- **read-only**. Must not invoke orchestrator / worktree / cycle. Uses only JIRA `getJiraIssue`.
- Actual execution is the user's responsibility. Plan output is not auto-run.
- Dependencies missing from `issuelinks` are not detected — user should fill the field and re-run.
- File-region conflict estimation is a label-based heuristic, not exact. Real conflicts are determined at merge time.
- Worktree / merge race / port 3000 collision and other in-flight batch safeguards are handled by `_cycle.md` Phase 2 sequential guarantees, so they are not validated at the plan stage.
- The group chunk size (5) is independent of `parallel.maxConcurrent`'s ceiling (default 3, max 5). Plan only recommends; actual execution applies `{maxConcurrent}` as defined in batch.md.
