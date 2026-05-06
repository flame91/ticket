# /ticket:create — Create a new JIRA ticket

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

> **Tip:** During planning, write a PRD first with `/write-prd` to produce more precise Done Criteria.

## Step 0: Load project config

Read `.claude/project.json` from the repo root. If `jira.enabled` is `false` or the file is missing, print the message above and exit.
- `{cloudId}` = `jira.cloudId`
- `{projectKey}` = `jira.projectKey`
- `{epicIssueType}` = `jira.epicIssueType` (default: `"Epic"`)

## Arguments

| Form | Meaning |
|---|---|
| `/ticket:create` | Default. If user intent is classified as "user feature", auto-generate description / AC drafts via helper skills. |
| `/ticket:create --bare` | Use user input as-is, no helper skills. For chore / ops meta / quick bug reports. |
| `/ticket:create --feature` | Force "user feature" classification. Bypass auto-classification when summary is ambiguous. |

## Execution order

1. Confirm user input:
   - Title (required)
   - Description (required — recommend including `## Done Criteria`, `## Out of Scope`, `## Verification` sections. Data/API tickets must add `## Core Design Decisions` — see §design-decisions section below)
   - Issue type (default `Task`; one of `Bug`, `Story`, `{epicIssueType}`)
   - Priority (default `Medium`; can be `Highest` / `High` / `Low` / `Lowest`)
   - Labels (optional)
   - Parent Epic (`parent`, optional)
2. **Design-heavy detection (independent of `--bare`, auto-checks labels/description):**
   - Classify as design-heavy ticket if any of the following match:
     - Labels include one or more of `data-quality` / `data` / `data-pipeline` / `schema` / `api` / `backend` / `migration` / `llm` / `facet`
     - Description contains keywords: `migration`, `Alembic`, `schema`, `column`, `table`, `endpoint`, `API`
   - If design-heavy, auto-insert a `## Core Design Decisions` section into the description (use the template from §design-decisions verbatim). Tell the user: "Filling in the empty fields now avoids cycle sprawl. If left blank, you'll be asked again at `/ticket` entry." If user fills them in, use as-is; if left blank, include the placeholder in the description as `<TBD>`.
3. **Feature intent classification + helper skill invocation (when `--bare` is not set):**
   - If `--feature` is explicit, or if the summary starts with a verb + noun pattern ("add", "show", "enable", etc.), classify as "user feature".
   - When classified as "user feature":
     - Call `Skill(name="pm-execution:write-stories")` or `/pm-execution:write-stories` → generate a WWA (Why-What-Acceptance) format description draft. If user-provided description is empty or short, adopt this draft; if user input is sufficient, use as supporting context only.
     - Call `Skill(name="pm-execution:test-scenarios")` or `/pm-execution:test-scenarios` → generate AC (acceptance criteria) test scenarios. Augment the description's `## Verification` section with this output.
   - If classification is ambiguous or looks like "chore" / "bug", skip helper skill invocation.
4. **Bug reproduction (required when issue type is `Bug`, regardless of `--bare`):**
   - For frontend / web UI defects, **reproduce directly via chrome-devtools MCP** before creating the ticket. Do not write speculative bug reports based on guesses or screenshots alone.
   - Items to capture during reproduction (include verbatim in description):
     - Exact URL · locale · prior state (localStorage / cookies / login etc. setup script).
     - Click/input sequence (natural-language steps a human can follow, not snapshot uids; include a console-pasteable script if possible).
     - Observed result (expected vs actual) — at least one objective evidence among DOM / localStorage / network / console logs.
   - If reproduction narrows the root cause, list the relevant files/lines in the description's "Root Cause" section.
   - For defects not reproducible in a browser (backend / scrapers / data pipeline / CLI etc.), skip with a one-line reason and, where possible, include alternative reproduction means (curl / pytest / log excerpt) in the description.
5. Duplicate check: run `searchJiraIssuesUsingJql` with the title's core keyword (e.g., `project = {projectKey} AND summary ~ "keyword" AND statusCategory != Done`). If similar open tickets exist, notify the user and stop.
6. If no duplicate or the user confirms, run `mcp__claude_ai_Atlassian_Rovo__createJiraIssue`.
   - cloudId: `{cloudId}`
   - `project.key`: `{projectKey}`
7. Return the created ticket key and URL. If helper skills were invoked, report in one line which skill contributed to description / Verification. If Bug reproduction was performed, also report which reproduction evidence (script · console output etc.) was included in the description.

## Notes

- Don't create tickets by guessing — if title/description is ambiguous, ask first
- If duplicates are possible, stop first and explain
- When creating a `{epicIssueType}` type, list the parent-child ticket structure in the description
- Don't invent new labels; pick from existing project labels

## §design-decisions — Core Design Decisions guide

Add the following format to data/API ticket descriptions. Pre-locks against impl-coder making arbitrary decisions that cascade. **The main cause of codex round sprawl when missing** (TM-231 case: 13 rounds, over 50% of findings cascaded from a single missing design decision).

### Template

```markdown
## Core Design Decisions

### Data model
- Multi-value column form: <string (comma-joined) | ARRAY[] | junction table | enum>. Reason: <one line>
- NOT NULL / NULL policy: <per column>
- Indexes: <per field or N/A>

### API contract
- Breaking change allowed: <yes / no — whether frontend compatibility mapping is needed>
- Response serialization: <raw value / split token list / both>
- New query params: <enum whitelist / free form>

### Pipeline (LLM/script)
- Output format: <canonical code / raw label / both>
- Failed row state: <retry / quarantine / mark-done>
- Idempotency: <re-run safety, --force semantics>

### Other (per-ticket)
- <add as needed>
```

### Empty-field handling

If fields are blank at `/ticket:create` time, mark as `<TBD>`. At `/ticket <KEY>` entry, step 6-i-2.5 re-checks → asks the user to fill via `AskUserQuestion`. If the user says "not sure / impl-coder discretion", record that fact in the description (`Decision: impl-coder discretion, split codex findings into follow-ups`) — this justifies force-ack / follow-up split during later cycle codex round sprawl.

### Trigger condition (which tickets apply)

Design-heavy if any of the following match:

- Labels: `data-quality` / `data` / `data-pipeline` / `schema` / `api` / `backend` / `migration` / `llm` / `facet`
- Description keywords: `migration`, `Alembic`, `schema`, `column`, `table`, `endpoint`, `API`

Pure frontend tickets (`area-frontend` only, no backend/data keywords) do not apply.
