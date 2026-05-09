# /flow:setup — bootstrap or edit `.claude/project.json`

> Single-command interactive wizard. Auto-detects mode: **bootstrap** (no `.claude/project.json`) vs **edit** (file exists; current values shown as defaults). Covers JIRA basics, repo basics, and the `skillIntegration.*` toggles. Every other config key (`jira.attachmentApi.*`, `jira.restApi.*`, `github.evidenceComment.*`, `parallel.maxConcurrent`, `codexReview.*`, `agents.*`, `scripts.regression`) stays a hand-edit per § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`. Out-of-scope keys already present in the file are preserved verbatim across the deep merge.
>
> Always asks for confirmation before writing. Idempotent — re-running with the same answers produces a zero-line diff.

## Step 0: Load existing config + detect mode

1. `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"`. If empty → **hard stop**: print `Not in a git repo. cd into the project root and re-run /flow:setup.` and exit.
2. `CONFIG_PATH="$REPO_ROOT/.claude/project.json"`.
3. If `CONFIG_PATH` exists:
   - Parse with `jq '.' "$CONFIG_PATH"`. On parse error → **hard stop**: print `.claude/project.json is not valid JSON. Fix manually before running /flow:setup.` plus the jq error verbatim. **Do not auto-overwrite.**
   - Bind `{currentConfig}` to the parsed object. `{mode} = "edit"`.
4. Else: `{currentConfig} = {}`. `{mode} = "bootstrap"`.

Print one line up front:
- bootstrap: `No .claude/project.json found — running first-time setup wizard.`
- edit: `Editing .claude/project.json (mode: edit). Each step pre-fills the current value.`

### Variable bindings (current → fallback)

| Variable | `{currentConfig}` key | Fallback when key missing |
|---|---|---|
| `{jiraEnabled}` | `jira.enabled` | `true` (auto-on once JIRA is configured) |
| `{cloudId}` | `jira.cloudId` | autodetect via Rovo (Step 1) |
| `{projectKey}` | `jira.projectKey` | autodetect via Rovo (Step 1) |
| `{epicIssueType}` | `jira.epicIssueType` | `"Epic"` |
| `{jiraSite}` | `jira.site` | host portion of the chosen Atlassian resource `url` |
| `{baseBranch}` | `git.baseBranch` | `git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \| sed 's@^origin/@@'` (fallback `main` → `master` → current branch) |
| `{repoSlug}` | `project.repoSlug` | `$(basename "$REPO_ROOT")` |
| `{skillKarpathy}` | `skillIntegration.karpathyGuidelinesInImpl` | `false` |
| `{skillDiagnose}` | `skillIntegration.diagnoseOnTestFail` | `false` |
| `{skillSimplify}` | `skillIntegration.simplifyBeforeCommit` | `false` |
| `{skillSlopClean}` | `skillIntegration.slopCleanBeforeCommit` | `false` |
| `{skillGrillDocs}` | `skillIntegration.grillWithDocsBeforeOrchestrator` | `false` |
| `{skillReleaseNotes}` | `skillIntegration.releaseNotesOnUserFacing` | `false` |

In **edit mode**, every prompt below labels the current value with `(current)`. In **bootstrap mode**, autodetected values use `(detected)`. Users can always pick `Other` to type a free-form override.

## Execution order

### 1. JIRA basics

Call `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources` once.

- HTTP 401/403 or empty response on auth failure → use `AskUserQuestion` to ask: `Atlassian Rovo MCP is not authenticated. Proceed with JIRA disabled (jira.enabled: false; cloudId/projectKey/site skipped)?` Options: `Yes, disable JIRA` / `No, exit and fix MCP auth`. On Yes → set `{jiraEnabled} = false`, skip 1a–1d, jump to step 2. On No → exit.
- `0` resources → **hard stop**: `No Atlassian sites accessible to the current Rovo account. Verify MCP scopes, then re-run.`

#### 1a. cloudId

- 1 resource → autopick. Print `Atlassian site: <url> (cloudId=<id>) — auto-selected.`
- ≥2 resources → `AskUserQuestion` single-select. Options: each resource as `<url>` (label) / `Atlassian site` (header). Add a final `Other (type cloudId manually)` option. In edit mode, label the option matching `{currentConfig}.jira.cloudId` with `(current)`.

Bind `{cloudId}` to the chosen resource id, and capture its `url` for derived defaults below.

#### 1b. projectKey

Call `mcp__claude_ai_Atlassian_Rovo__getVisibleJiraProjects` with the chosen `cloudId`.

- 0 projects → **hard stop**: `No JIRA projects visible on cloudId=<id>. Verify scopes or invite the Rovo account, then re-run.`
- 1 project → autopick.
- ≥2 → `AskUserQuestion` single-select. Options: `<KEY> — <name>` per project + `Other (type a project key)`. Edit mode: current value labeled `(current)`.

Bind `{projectKey}`.

#### 1c. epicIssueType

`AskUserQuestion` single-select. Options: `Epic` (default unless edit-mode current differs), `Initiative`, `Other (type a value)`. Edit mode: pre-check `{currentConfig}.jira.epicIssueType`.

Bind `{epicIssueType}`.

#### 1d. jira.site

Default = host of the chosen resource `url` (strip `https://`, e.g. `flame91.atlassian.net`).

`AskUserQuestion` single-select. Options: `<derived> (use this)`, `Type a different host`. Edit mode: if `{currentConfig}.jira.site` differs from derived, list both and label the current one.

Bind `{jiraSite}`.

### 2. Repo basics

#### 2a. baseBranch

Autodetect via shell:

```bash
git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'
```

If empty: try `git show-ref --verify --quiet refs/heads/main` then `refs/heads/master`. Otherwise fall back to `git branch --show-current`.

`AskUserQuestion` single-select. Options: `<detected> (use this)`, `main`, `master`, `develop`, `Type another`. Suppress duplicates; edit mode highlights `{currentConfig}.git.baseBranch`.

Bind `{baseBranch}`.

#### 2b. repoSlug

Default: `$(basename "$REPO_ROOT")`.

`AskUserQuestion` single-select. Options: `<detected> (use this)`, `Type a different slug`. Edit mode highlights current.

Bind `{repoSlug}`.

### 3. skillIntegration toggles

Run all six companion-availability probes (read-only) before asking, in parallel where possible:

| Flag | Probe | Recommendation |
|---|---|---|
| `karpathyGuidelinesInImpl` | `find ~/.claude/plugins -type d -name 'andrej-karpathy-skills' 2>/dev/null \| head -1` | ON if installed (lightweight, no time cost) |
| `diagnoseOnTestFail` | bundled with `flow` (skill `flow:diagnose`) — always present | ON recommended (only triggers on test failure) |
| `simplifyBeforeCommit` | builtin `simplify` — always present | OFF recommended (high time cost on every commit) |
| `slopCleanBeforeCommit` | bundled with `flow` (command `/flow:slop-clean`, agent `slop-cleaner`, skill `flow:slop-clean`) — always present | OFF recommended (high time cost on every commit — parallel sonnet agents per staged file) |
| `grillWithDocsBeforeOrchestrator` | bundled with `flow` (skill `flow:grill-with-docs`) — always present; **plus** check `test -f "$REPO_ROOT/CONTEXT.md" -o -d "$REPO_ROOT/docs/adr"` | ON if `CONTEXT.md` or `docs/adr/` exists in repo |
| `releaseNotesOnUserFacing` | `find ~/.claude/plugins -type d -name 'pm-execution' 2>/dev/null \| head -1` | ON if installed |

Then make a single `AskUserQuestion` call with **6 questions** (one per flag), each `single-select` with options `On` / `Off`. Question text format:

```
{flag name} — {one-line effect from _config.md skillIntegration table}.
Companion: {detected: yes|no — name} • Recommended: {On|Off}
```

In edit mode, the current value is the first option (so `(current)` shows). Bootstrap defaults to the recommendation.

If a companion is missing but the user picks ON: **allow it** and print a one-line note (`Note: {companion} not detected — flag is recorded but stays a no-op until installed.`). The runtime contract in `_config.md` already degrades silently.

Bind `{skillKarpathy}`, `{skillDiagnose}`, `{skillSimplify}`, `{skillSlopClean}`, `{skillGrillDocs}`, `{skillReleaseNotes}` to the chosen booleans.

### 4. Diff preview + confirm

1. Build `{patchConfig}` (only the keys this wizard manages):

```jsonc
{
  "jira": {
    "enabled": {jiraEnabled},
    "cloudId": "{cloudId}",
    "projectKey": "{projectKey}",
    "epicIssueType": "{epicIssueType}",
    "site": "{jiraSite}"
  },
  "git": { "baseBranch": "{baseBranch}" },
  "project": { "repoSlug": "{repoSlug}" },
  "skillIntegration": {
    "karpathyGuidelinesInImpl": {skillKarpathy},
    "diagnoseOnTestFail": {skillDiagnose},
    "simplifyBeforeCommit": {skillSimplify},
    "slopCleanBeforeCommit": {skillSlopClean},
    "grillWithDocsBeforeOrchestrator": {skillGrillDocs},
    "releaseNotesOnUserFacing": {skillReleaseNotes}
  }
}
```

If `{jiraEnabled} = false` (Rovo-disabled path), drop `jira.cloudId`, `jira.projectKey`, `jira.epicIssueType`, `jira.site` from the patch — keep only `jira.enabled = false`. Likewise drop unanswered fields from the patch entirely (do not write `null`).

2. Compute `{newConfig}` as a recursive merge of `{currentConfig}` with `{patchConfig}` using jq's `*` operator. Persist via temp files to handle quoting safely:

```bash
CURRENT_FILE=$(mktemp); echo "$CURRENT_JSON" > "$CURRENT_FILE"
PATCH_FILE=$(mktemp);   echo "$PATCH_JSON"   > "$PATCH_FILE"
NEW_JSON=$(jq -s '.[0] * .[1]' "$CURRENT_FILE" "$PATCH_FILE")
rm -f "$CURRENT_FILE" "$PATCH_FILE"
```

The `*` operator on objects is a recursive deep merge — leaf values are replaced, untouched subtrees (`jira.attachmentApi`, `jira.restApi`, `github.evidenceComment`, `codexReview`, `agents`, `parallel`, `scripts`, plus any extra keys inside `skillIntegration` not in the table above) are preserved verbatim.

3. Print a unified diff (sorted-keys for stability):

```bash
diff -u <(echo "$CURRENT_JSON" | jq -S '.') <(echo "$NEW_JSON" | jq -S '.') | sed 's/^/    /'
```

In bootstrap mode the "before" side is `{}` so the diff shows the entire config as additions. If the diff is empty, print `No changes — current config already matches the answered values.` and skip step 5.

4. `AskUserQuestion` single-select: `Apply — write to .claude/project.json` / `Cancel — exit without writing`. (Single-field re-edit loops are intentionally omitted — re-run `/flow:setup` to change one more thing; it's idempotent.)

### 5. Atomic write

Apply only:

1. `mkdir -p "$REPO_ROOT/.claude"` — handles missing directory in bootstrap.
2. **Edit mode only**: `cp "$CONFIG_PATH" "$CONFIG_PATH.bak.$(date +%s)"` — backup snapshot for rollback.
3. `echo "$NEW_JSON" | jq -S '.' > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"` — atomic rename.
4. Re-read `jq '.' "$CONFIG_PATH"` to verify the on-disk file parses cleanly. On any parse failure (defensive — should be impossible), restore from `.bak` (edit mode) or `rm "$CONFIG_PATH"` (bootstrap), then hard stop with the jq error.

### 6. Validation + summary

1. If `{jiraEnabled}` is true, call `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources` once more and confirm `{cloudId}` is present in the response. On miss, print a warning (do **not** roll back the write): `Warning: cloudId={cloudId} not in the current Rovo session — credentials may have changed since step 1.`
2. Print the summary block:

```
## /flow:setup — applied
- mode:           {bootstrap | edit}
- file:           <REPO_ROOT>/.claude/project.json
- jira:           enabled={jiraEnabled} cloudId={cloudId} projectKey={projectKey} epicIssueType={epicIssueType} site={jiraSite}
- git.baseBranch: {baseBranch}
- project.repoSlug: {repoSlug}
- skillIntegration:
    karpathyGuidelinesInImpl       = {skillKarpathy}
    diagnoseOnTestFail             = {skillDiagnose}
    simplifyBeforeCommit           = {skillSimplify}
    slopCleanBeforeCommit          = {skillSlopClean}
    grillWithDocsBeforeOrchestrator= {skillGrillDocs}
    releaseNotesOnUserFacing       = {skillReleaseNotes}

Still hand-edit (see § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md):
- jira.attachmentApi    — evidence screenshot upload (one-time API token setup)
- jira.restApi          — /ticket:rerank --apply (falls back to attachmentApi if unset)
- github.evidenceComment — orphan-branch PR evidence comments
- codexReview           — Codex pre-push gate
- parallel.maxConcurrent — /ticket:batch --par concurrency
- agents.*              — role mapping / role-doc dir
- scripts.regression    — regression script wrapper
```

Edit mode also prints the backup path: `Backup: <REPO_ROOT>/.claude/project.json.bak.<epoch> (rollback: mv .claude/project.json.bak.<epoch> .claude/project.json)`.

## Hard stop conditions

| Trigger | Action |
|---|---|
| Not in a git repo | `Not in a git repo. cd into the project root and re-run.` |
| `.claude/project.json` exists but is invalid JSON | Print jq error, do not overwrite |
| Rovo MCP unauthenticated | Offer JIRA-disabled path; otherwise exit |
| 0 accessible Atlassian sites | Hard stop |
| 0 visible JIRA projects on chosen cloudId | Hard stop |
| User picks `Cancel` at step 4 | No write, no `.tmp` left over, exit 0 with `Cancelled — no changes.` |
| Post-write parse failure | Restore from `.bak` (edit) or remove file (bootstrap), print jq error, exit non-zero |

## Notes

- **Narrow scope by design.** This wizard intentionally covers only the keys a first-time user needs to get the cycle running. Token-bearing config (`jira.attachmentApi`, `jira.restApi`), GitHub evidence wiring, Codex review, parallel concurrency, role mapping, and regression-script wiring all stay hand-edits per § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md` — those keys depend on credentials, file paths, or repo-specific scripts the wizard cannot reliably introspect.
- **Out-of-scope key preservation.** The jq `*` deep merge is the contract: any key under `jira.attachmentApi`, `jira.restApi`, `github`, `codexReview`, `agents`, `parallel`, `scripts`, or extra keys inside `skillIntegration`, survives a `/flow:setup` run untouched.
- **Idempotent.** Re-running `/flow:setup` and accepting every `(current)` default produces an empty diff at step 4 and exits without writing.
- **Tokens stay outside `project.json`.** API tokens belong in a separate file (e.g. `~/.config/jira/api-token` with `chmod 600`) — see `_config.md`. The wizard never prompts for or stores secrets.
- **Edit-mode backup.** `.claude/project.json.bak.<epoch>` is left next to the config on every overwrite — quick rollback via `mv`.

## Related commands

- Backlog summary: `/ticket:list`
- New ticket: `/ticket:create`
- Single-ticket entry: `/ticket <KEY-n>`
- Full config schema reference: § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md`
