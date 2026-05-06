# § orchestrator — orchestrator 5-field classification (internal reference only)

## Spawn contract

Spawn via `Task(subagent_type="executive-orchestrator", prompt=...)`. Include the following context in the prompt:

- **session-state**: caller-collected worktree/cwd/branch/dirty JSON
- **ticket**: `{key, summary, status, issuetype, priority, labels, parent}`
- **invoking_command**: the calling command name (`/ticket`, `/ticket:auto`, `/ticket:batch`)
- **docs_grill_summary** (conditional): included only when `{skillGrillDocs}` is `true` and `invoking_command == "/ticket"` (manual entry). Just before spawning, call `Skill(name="grill-with-docs")` or `/grill-with-docs` to get a summary of the ticket summary + done_criteria checked against ADR / CONTEXT.md. The orchestrator uses this context to enrich `reason`. Not invoked under `/ticket:auto` · `/ticket:batch` (preserve loop speed).

The subagent returns a 5-field classification result, read-only.

## 5-field validation

| Field | Allowed values |
|------|---------|
| `classification` | `continue`, `not-related`, `related-but-separate`, `blocked-by-current-work`, `conflict` |
| `owner` | role string |
| `next_command` | slash-command string |
| `worktree_decision` | `stop`, `reuse-current`, `create-issue-worktree` |
| `reason` | free text |

**Hard stop if any value is out-of-spec or missing** (unexpected output, user check).

## Behavior per classification

| classification | Behavior |
|---|---|
| `continue` | Proceed reusing the existing worktree |
| `not-related` | Separate scope — new sibling worktree |
| `related-but-separate` | Separate done criteria — new sibling worktree, report `reason` |
| `blocked-by-current-work` / `conflict` | **Hard stop** |

## worktree_decision override (takes precedence over classification)

| Value | Behavior |
|---|---|
| `stop` | **Hard stop** (regardless of classification) |
| `reuse-current` | Reuse existing worktree |
| `create-issue-worktree` | Create new sibling worktree |

## next_command handling

Handled differently per caller:

| Caller | next_command ≠ self | Behavior |
|--------|---------------------|------|
| `/ticket` | e.g. `/migrate` | **Stop** — message "orchestrator recommends `<next_command>`" |
| `/ticket:auto` | e.g. `/migrate` | **Skip this ticket only**, continue the loop |
| `/ticket:batch` | outside `/ticket*` | **Skip this key only**, continue the queue |

## owner usage

Use the returned `owner` to look up the role doc in `{roleDocDir}` + `{roleMapping}` and pass it as a hint when delegating to impl-coder.
