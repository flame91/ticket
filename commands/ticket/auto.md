# /ticket:auto — 자동 티켓 루프

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

JIRA 백로그에서 다음 티켓을 자동으로 고르고 **구현 → 리그레션 → 머지 → 상태 전환** 까지 수행해줘. 상태 전환은 `_cycle.md` step 10 의 분기 규칙 — 3중 리뷰가 모두 통과 + 잔여 리스크 없음이면 `Mark Done`, 아니면 `Submit for QA`. 사용자가 자리를 비울 때 연속 코딩을 맡기는 용도.

## 인자

| 형식 | 의미 |
|---|---|
| `/ticket:auto` | 루프 모드 (기본). 더 이상 처리할 티켓이 없을 때까지 반복. |
| `/ticket:auto once` | 단건 모드. 티켓 하나 끝내고 종료. |
| `/ticket:auto loop` | 명시적 루프 (기본과 동일). |

## 한 사이클 절차

### Step 0: 프로젝트 설정 로드

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md 참조

### Step 1: 세션 상태 체크

`bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/session-state.sh"` 1회 실행. 결과 JSON (`branch`, `dirty`, `dirty_files`, `upstream`, `ahead`, `behind`, `worktrees`, `cwd`) 을 step 3 프롬프트에 재사용.

- `dirty: true` 면 **하드 스탑** (`dirty_files` 목록 보고).
- cwd 가 main repo root 가 아니거나 `branch != {baseBranch}` 이면 **하드 스탑** — `/ticket:auto` 는 main repo root (`{baseBranch}` 체크아웃 상태) 에서만 시작한다. sibling worktree 안에서 실행 중이면 `cd <main-repo-root>` 후 재실행.

### Step 2: 다음 티켓 선정

`mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`:
- cloudId: `{cloudId}`
- jql: `project = {projectKey} AND statusCategory != Done AND status != "READY FOR QA" AND issuetype != "{epicIssueType}" ORDER BY priority DESC, updated DESC`
- fields: `["summary","status","issuetype","priority","labels","assignee","parent"]`
- 후보 필터링 (선정 전 필수):
  1. `QA FAILED` — 항상 후보.
  2. `In Progress` — **본 머신의 잔존 작업만 후보**. `git worktree list --porcelain` 과 `git branch --list 'feat/{projectKey}-<n>-*' 'fix/{projectKey}-<n>-*'` 으로 해당 키와 매칭되는 로컬 worktree/브랜치가 있을 때에만 후보로 본다. 원격에만 있는 브랜치는 타 세션/사람 작업으로 간주하고 후보에서 제외.
  3. `To Do` — Priority 높음, `size-s` 약간 선호.
- 우선순위: `QA FAILED` > 로컬 흔적 있는 `In Progress` > `To Do`.
- `READY FOR QA` 는 자동 선정 제외.
- **empty-candidate 판정**: JQL 결과 0건이거나 필터링 후 후보 0건이면 "자동 구현 대상 없음" 처리. 필터링에서 드롭된 `In Progress` 티켓의 키 목록을 세션 요약에 포함.
- "자동 구현 대상 없음" 일 때 보조 JQL `project = {projectKey} AND status = "READY FOR QA" AND issuetype != "{epicIssueType}"` 로 대기 중 QA 티켓 수 K 를 조회:
  - K = 0 → 순수 natural stop, 세션 요약 출력 후 exit 0.
  - K ≥ 1 → "자동 구현 큐는 비었지만 READY FOR QA 가 K 건 (키 목록) 남아있음. `/ticket <{projectKey}-n>` 으로 수동 QA 를 진행하세요" 후 exit 0. 조용히 종료 금지.

### Step 3: 오케스트레이터 분류

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md 참조

**auto-specific**: `next_command` 가 `/ticket:auto` 가 아니면 **해당 티켓만 스킵**하고 루프 계속 — "오케스트레이터가 `<next_command>` 를 권고함 ({projectKey}-<n>), 자동 루프 범위 밖이므로 건너뜀" 을 사이클 로그에 기록.

### Step 4: 티켓 본문 보강

`getJiraIssue` 로 description 확인. `## Done Criteria` / `## Out of Scope` / `## Verification` 누락 시 `editJiraIssue` 로 보강. 실패 시 **하드 스탑** + 티켓 코멘트.

### Step 5: Sibling worktree 생성/재개

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md "생성/재개" 참조

### Step 6: Start work transition

`getTransitionsForJiraIssue` → `transitionJiraIssue` (name="Start work") → `In Progress`.

### Steps 7–18: 구현 → 머지 사이클

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md 참조 (Phase 1 → Phase 2 순차 실행). 하드 스탑 발생 시 루프를 끊고 사용자 보고.

### Step 18: 분기

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md 완료 후 루프 모드면 step 2 복귀. 단건 모드면 종료.

## 중단 조건 (hard stop)

사이클 수준 중단 조건은 § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md + § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md 참조. auto-specific 중단 조건:

| 종류 | 트리거 | 동작 |
|---|---|---|
| Natural | 백로그 비었음 (step 2 결과 0건) | exit 0, 요약 보고 |
| Dirty workspace | 사이클 시작 시 working tree dirty | exit 1, 변경 파일 목록 |
| MCP auth | Atlassian Rovo 401/403 | `getAccessibleAtlassianResources` 재확인 후 여전히 실패 시 exit 1 |
| Repeat | 같은 티켓을 연속 2회 선정 (직전 사이클 미해결) | exit 1 |

## 안전장치

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md + _worktree.md 의 안전장치를 상속. auto-specific 추가:

- `{baseBranch}` / `main` 직접 push 금지.
- main repo (repo-root) 는 언제나 `{baseBranch}` 유지 — feature/fix 브랜치로 절대 체크아웃하지 않는다.
- Epic(`{epicIssueType}` 타입) 은 자동 선정에서 제외 (JQL 필터링). 자식 티켓은 포함.
- PR 머지를 Done 으로 취급하지 말 것 — `_cycle.md` step 10 의 분기 규칙을 따름. 3중 리뷰 (`/test` + `/test chrome` + Codex) 가 모두 통과 + 잔여 리스크 없음이면 `Mark Done` → `Done`. 어느 하나라도 스킵/잔여 리스크 있으면 `Submit for QA` → `READY FOR QA`.

## 결과 보고 형식

세션 종료 시 최종 요약:

```
/ticket:auto 종료 (<natural|hard-stop>)
처리한 티켓: N개
  - {projectKey}-<n>: <summary> → <merged-sha|blocked reason> (PR #nnn)
  - ...
블로커: <hard-stop 사유 또는 "없음">
다음 선정 가능 티켓 수: M 개
```

## 주의사항

- `/ticket:auto` 는 머지까지 자동 진행하므로 **반드시 사용자 감독 없이 돌아가는 환경에서만** 사용할 것.
- 수동으로 티켓 하나씩 확인·구현하려면 `/ticket <{projectKey}-n>`.
- 단건만 실행하려면 `/ticket:auto once`.
- MCP 인증이 끊기면 `getAccessibleAtlassianResources` 로 재확인.
