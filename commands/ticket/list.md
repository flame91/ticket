# /ticket:list — JIRA backlog summary

> If `jira.enabled` is `false`, print "JIRA not configured. Add a `jira` section to `.claude/project.json`" and exit.

## Step 0: Load project config

Read `.claude/project.json` from the repo root. If `jira.enabled` is `false` or the file is missing, print the message above and exit.
- `{cloudId}` = `jira.cloudId`
- `{projectKey}` = `jira.projectKey`
- `{epicIssueType}` = `jira.epicIssueType` (default: `"Epic"`)

## Execution order

1. Call `mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`:
   - cloudId: `{cloudId}`
   - jql: `project = {projectKey} AND statusCategory != Done ORDER BY priority DESC, updated DESC`
   - fields: `["summary","status","issuetype","priority","labels","assignee","parent"]`
   - maxResults: 30
2. Analyze results and summarize three things:
   - Current progress (count by status + count by type)
   - Remaining child ticket count per top-level Epic (`{epicIssueType}`) (additional JQL: `parent = {projectKey}-<n> AND statusCategory != Done`)
   - 1–3 things to do right now — selected by priority `QA FAILED` > `READY FOR QA` > `In Progress` > `To Do`

## Notes

- If MCP connection fails, re-verify auth via `getAccessibleAtlassianResources` and state that explicitly
- Prefer interpretation of progress over a raw list dump
- Show `{epicIssueType}` types together with their child tickets (don't mix into a flat list)
- If results exceed 30, only mention the next page token (`nextPageToken`); do an actual additional fetch only on user request
