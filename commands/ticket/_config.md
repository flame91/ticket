# § config — project config loader (internal reference only)

Read `.claude/project.json` from the repo root. If `jira.enabled` is `false` or the file is missing, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

## Variable bindings

| Variable | Source | Default |
|------|------|--------|
| `{cloudId}` | `jira.cloudId` | (required) |
| `{projectKey}` | `jira.projectKey` | (required) |
| `{epicIssueType}` | `jira.epicIssueType` | `"Epic"` |
| `{baseBranch}` | `git.baseBranch` | `"main"` |
| `{repoSlug}` | `project.repoSlug` | `$(basename "$(git rev-parse --show-toplevel)")` |
| `{roleDocDir}` | `agents.roleDocDir` | `".claude/agents"` |
| `{roleMapping}` | `agents.roleMapping` | `{}` |
| `{regression}` | `scripts.regression` | `null` (auto-detect test framework) — see "scripts.regression recommended pattern" |
| `{codexReviewEnabled}` | `codexReview.enabled` | `false` |
| `{choreAllowList}` | `codexReview.choreAllowList` | `["docs/", ".claude/", ".github/"]` |
| `{maxConcurrent}` | `parallel.maxConcurrent` | `3` (max 5) |
| `{skillKarpathy}` | `skillIntegration.karpathyGuidelinesInImpl` | `false` |
| `{skillDiagnose}` | `skillIntegration.diagnoseOnTestFail` | `false` |
| `{skillSimplify}` | `skillIntegration.simplifyBeforeCommit` | `false` |
| `{skillGrillDocs}` | `skillIntegration.grillWithDocsBeforeOrchestrator` | `false` |
| `{skillReleaseNotes}` | `skillIntegration.releaseNotesOnUserFacing` | `false` |
| `{jiraAttachmentEnabled}` | `jira.attachmentApi.enabled` | `false` |
| `{jiraAttachmentEmail}` | `jira.attachmentApi.userEmail` | (required if enabled) |
| `{jiraAttachmentTokenFile}` | `jira.attachmentApi.tokenFile` | (required if enabled) |
| `{rankFieldId}` | `jira.rankFieldId` | `"customfield_10019"` |
| `{githubEvidenceEnabled}` | `github.evidenceComment.enabled` | `false` |

## scripts.regression recommended pattern

The default value of `scripts.regression` should auto-detect the changed area when **invoked without arguments** and run only the relevant regressions (e.g. `bash scripts/regression.sh` internally picks frontend / backend / compose impact areas based on `git diff` and runs only those, auto-including pytest/ruff if backend is hit). Step 3 of § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md runs `{regression}` as-is with no arguments, so:

- If the script determines zero regression mappings in the changed area → exit 0 + empty output. The `/test` row in step 8a is recorded as `N/A (reason)` and is included in the `Mark Done` track in step 10 (e.g. docs-only · `.claude/`-only changes).
- For when you want to force-run all regressions, the script should accept a separate argument (e.g. `all` / `full`), but **do not put any argument in the `scripts.regression` default itself** — argument-less invocation is the cycle's auto-detection path.

If you currently have something like `bash scripts/regression.sh default` registered with an explicit argument, remove the argument and have the script treat argument-less invocation as auto mode.

## skillIntegration section

The `skillIntegration` object in `.claude/project.json` opt-ins auxiliary skills auto-invoked inside the `/ticket` chain. All keys fall back to false when missing — introducing a new key has no impact on existing project behavior. Effect of each flag:

| Flag | Trigger location | Effect |
|---|---|---|
| `karpathyGuidelinesInImpl` | impl-coder delegation (`§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 2) | Inject an `andrej-karpathy-skills:karpathy-guidelines` reference line into the system prompt. Lightweight. Recommended ON by default. |
| `diagnoseOnTestFail` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 3 (test failure) | After the first retry fails, call `/diagnose` right before the second retry to produce a root-cause hypothesis → attach to impl-coder reflect input. |
| `simplifyBeforeCommit` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 5 (commit), just before | Call `/simplify` against the staged diff → auto-fix on missed reuse / over-abstraction. High time cost, OFF by default. |
| `grillWithDocsBeforeOrchestrator` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md` step 1 (classification) | Call `/grill-with-docs` only when `invoking_command == "/ticket"` (manual entry); use the result as supplementary context for `reason`. Ignored under `/ticket:auto` · `/ticket:batch`. |
| `releaseNotesOnUserFacing` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 11 (post-merge JIRA comment) | If the ticket labels include `user-facing` or `release-impacting`, attach a one-paragraph output from `pm-execution:release-notes` to the comment. |

## jira.rankFieldId

Used by `/ticket:rerank`. The custom-field ID of JIRA's Lexorank "Rank" field. On standard JIRA Software (company-managed) projects this is `customfield_10019` — the default. Override only if your instance reports a different field ID.

To discover yours: run `mcp__claude_ai_Atlassian_Rovo__getJiraIssue` on any ticket with `fields=["*all"]` and look for the field whose value matches the Lexorank format (`<bucket>|<base36>:<optional>`, e.g. `0|hzzzzz:`).

`/ticket:rerank` writes new rank values via `editJiraIssue` (no curl, no extra credentials — uses the same MCP auth as every other ticket command). The Lexorank string for each non-anchor ticket is computed by appending a 2-character base-36 suffix to the proposed-position-0 ticket's current rank.

## jira.attachmentApi section

Required for the evidence-screenshot attachment in `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 11b. The Atlassian Rovo MCP does not expose an attachment tool, so we call the REST API directly (`curl`). Requires a separate token setup.

| Key | Meaning |
|---|---|
| `enabled` | true/false. false (default) skips all of step 11b and excludes the screenshots section from the comment body. |
| `userEmail` | Atlassian account email (REST auth username). |
| `tokenFile` | Path to a file containing the API token (e.g. `~/.config/jira/api-token`). Do not put the token directly in settings/project.json (commit risk). 600 file permission recommended. |

**One-time setup:**
```bash
# 1. Issue token: https://id.atlassian.com/manage-profile/security/api-tokens
# 2. Save to file
mkdir -p ~/.config/jira && echo '<token>' > ~/.config/jira/api-token && chmod 600 ~/.config/jira/api-token
# 3. Add jira.attachmentApi to .claude/project.json:
#    { "jira": { ..., "attachmentApi": { "enabled": true, "userEmail": "you@example.com", "tokenFile": "~/.config/jira/api-token" } } }
```

## github.evidenceComment section

`§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 11c — show evidence screenshots inline in the GitHub PR comment. Independent of the JIRA attachment; both can be enabled together.

| Key | Meaning |
|---|---|
| `enabled` | true/false. false (default) skips all of step 11c. |

How it works: PNG/HTML files are pushed to a separate orphan branch `evidence/{key}-{short_sha}` and embedded as markdown images in the PR comment via raw.githubusercontent.com URLs. Binaries never enter the develop merge target branch, so there is no main-history pollution. Requires only existing git remote auth (gh CLI) — no extra setup.

**No extra setup** — just add one line `github.evidenceComment.enabled: true` to `.claude/project.json`:
```jsonc
{ "github": { "evidenceComment": { "enabled": true } } }
```

**Periodic cleanup** (optional): evidence branches accumulate, so a quarterly cleanup is recommended.
```bash
git ls-remote --heads origin 'evidence/*' | awk '{print $2}' | sed 's|refs/heads/||' \
  | xargs -I {} git push origin --delete {}
```
