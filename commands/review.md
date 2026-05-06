# /review — pre-commit review

Review the current diff, branch, or specified change from a code-review perspective. The actual review is performed by the `qa-verifier` subagent.

> **Role split:** `/review` is pre-PR self-review (findings report). `codex:review` is the pre-push cross-review gate (auto-invoked by the `/push` workflow). When invoking standalone: "check my code → `/review`" / "push gate → auto-invoked by `/push`".

## Step 0: load project config

Read `.claude/project.json` from the repo root. If absent, use the defaults:
- `jira.enabled`: `false` (skip JIRA-related steps)
- `jira.projectKey`: `null`
- `scripts.qaSummary`: `null` (skip regression script)

## Execution order

1. **Identify change scope** — get the impacted file set via `git diff --stat` or `git diff <base>...HEAD --stat`. If `jira.enabled`, also collect related JIRA ticket keys (`{projectKey}-<n>`) when present.
2. **Spawn `qa-verifier`** — call `Agent(subagent_type="qa-verifier", prompt=...)`. Include in the prompt:
   - diff range (base..HEAD or specific commits)
   - impacted file list
   - JIRA ticket key + Done Criteria (when present and `jira.enabled`)
   - review focus (if the user specified a particular area)
   - `scripts.qaSummary` path (when present in project.json)
3. **Relay** — pass the subagent's findings (severity-ordered) through to the user verbatim. Do not add extra praise / overview from the main session.

## Output format (returned by qa-verifier)

- findings ordered by severity (title / severity / steps / expected / actual / suspected area)
- when no findings, `findings: none` + outstanding test gap
- short change summary (at the end)

## Notes

- `/review` is a read-only review pass — it does not modify code.
- For findings that need deeper investigation, recommend `/diagnose`.
- If a ticket scope appears mis-routed, `qa-verifier` recommends escalating to `executive-orchestrator`.
