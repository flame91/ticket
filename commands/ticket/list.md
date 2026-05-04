# /ticket:list — JIRA 백로그 요약

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

## Step 0: 프로젝트 설정 로드

Read `.claude/project.json` from the repo root. `jira.enabled` 가 `false` 이거나 파일이 없으면 위 안내 후 종료.
- `{cloudId}` = `jira.cloudId`
- `{projectKey}` = `jira.projectKey`
- `{epicIssueType}` = `jira.epicIssueType` (기본: `"Epic"`)

## 실행 순서

1. `mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql` 호출:
   - cloudId: `{cloudId}`
   - jql: `project = {projectKey} AND statusCategory != Done ORDER BY priority DESC, updated DESC`
   - fields: `["summary","status","issuetype","priority","labels","assignee","parent"]`
   - maxResults: 30
2. 결과 분석 후 아래 3가지 요약:
   - 현재 진행 상황 (상태별 카운트 + 타입별 카운트)
   - 상위 Epic(`{epicIssueType}`) 별 잔여 자식 티켓 수 (추가 JQL: `parent = {projectKey}-<n> AND statusCategory != Done`)
   - 지금 당장 해야 할 일 1~3개 — `QA FAILED` > `READY FOR QA` > `In Progress` > `To Do` 우선순위로 선별

## 주의사항

- MCP 연결 실패 시 `getAccessibleAtlassianResources` 로 인증 재확인하고 그 사실을 명시
- 단순 목록 나열보다 진행 상황 해석 우선
- `{epicIssueType}` 타입은 자식 티켓과 함께 표시 (단독 리스트에 섞어두지 않음)
- 결과가 30개를 초과하면 다음 페이지 토큰(`nextPageToken`)을 언급만 하고 실제 추가 페치는 사용자 요청 시에만
