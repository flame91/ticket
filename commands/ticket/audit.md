# /ticket:audit — 오래된 오픈 티켓이 후속 변경으로 이미 무효화됐는지 감사 + 승인 시 적용

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

오래 방치된 오픈 티켓을 `created ASC` 로 순회하며, 각 티켓이 **자기 `created` 이후 Done 된 티켓·디자인 문서 변경** 으로 전제·범위가 덮였는지 판정한 리포트를 출력한다. 판정은 `keep` / `revise` / `close(NO_NEEDED)` 세 버킷.

리포트 출력 후 **사용자에게 "적용할까요?" 를 묻는다.** 사용자가 승인하면 (전체 / 부분 / 키 지정) 해당 변경을 직접 실행한다. 사용자가 거절하면 read-only 로 종료. 기본 모드에서는 사용자 응답을 받기 전 어떤 JIRA 쓰기도 수행하지 않는다.

## Step 0: 프로젝트 설정 로드

Read `.claude/project.json` from the repo root. `jira.enabled` 가 `false` 이거나 파일이 없으면 위 안내 후 종료.
- `{cloudId}` = `jira.cloudId`
- `{projectKey}` = `jira.projectKey`
- `{epicIssueType}` = `jira.epicIssueType` (기본: `"Epic"`)

## 인자

| 형식 | 의미 |
|---|---|
| `/ticket:audit` | 기본. `created ASC` 상위 **10건** 을 주체로 깊게 감사. |
| `/ticket:audit --top <N>` | 상위 N 건 (기본 10). |
| `/ticket:audit --all` | 오픈 전부 감사. 티켓별 JQL 이 N 회 발생하므로 의식적 사용. |
| `/ticket:audit {projectKey}-<n>` | 해당 오픈 티켓 하나만 감사 (앵커 셋은 자동 계산). |
| `/ticket:audit --parent {projectKey}-<에픽>` | 에픽 자식 오픈 티켓으로 범위 한정 (여전히 `created ASC`). |
| `/ticket:audit --doc <path>` | 디자인/정책/스키마 문서를 모든 주체 티켓의 앵커 셋에 공통 추가. |
| `/ticket:audit --dry-run` | 리포트만 출력하고 적용 프롬프트 생략 (구 read-only 동작). |

- 조합 가능 (예: `--top 5 --parent {projectKey}-150`, `{projectKey}-187 --doc docs/DESIGN.md`, `--all --dry-run`).
- `--doc <path>` 지정 시 경로가 없으면 중단.

## 실행 순서

1. **주체(오픈 티켓) 로드**
   - `mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`
   - cloudId: `{cloudId}`
   - jql: `project = {projectKey} AND statusCategory != Done AND issuetype != "{epicIssueType}" ORDER BY created ASC` (+ `AND parent = <{projectKey}-에픽>` 지정 시, + `AND key = {projectKey}-<n>` 단건 지정 시)
   - fields: `["summary","status","issuetype","priority","labels","description","created","updated","parent"]` — `created` 는 필수.
   - `--all` 이 아닌 한 상위 `--top N` (기본 10) 만 유지. 나머지는 "감사 제외 (오래된 순 하위 M-N 건)" 로 카운트만 언급.
   - `totalCount` 와 반환된 `nodes.length` 를 리포트 상단에 명시.

2. **티켓별 앵커 셋 계산**
   - 각 주체 티켓에 대해 개별 JQL:
     - `project = {projectKey} AND statusCategory = Done AND updated >= "<해당 오픈 티켓의 created 일자>"`
     - fields: `["summary","status","description","updated"]`, `maxResults`: 50.
   - 결과가 50 건 초과 시 nextPageToken 존재만 리포트에 명시하고 추가 페치는 사용자 요청 시에만.
   - `--doc <path>` 지정 시 로컬 read (read-only) 로 내용 확보 후 모든 주체 티켓의 앵커 셋에 공통 추가.
   - `created` 가 아닌 `updated >= …` 를 쓰는 이유: Done 전환 시점은 `updated` 에 반영되므로, "후속으로 덮은 사건" 을 찾는 데 정확함.

3. **스코프 대조**
   - 각 주체 티켓의 `## Done Criteria` · `## Out of Scope` · summary · description 을 앵커의 동일 섹션(또는 `--doc` 문서) 과 비교.
   - 앵커가 티켓의 전제 — 입력 데이터 모양 · API 계약 · UX 흐름 · 스키마 · 정책 — 를 바꾸는지 판단.
   - 한 티켓이 여러 앵커 영향을 받으면 가장 강한 판정(`close` > `revise` > `keep`) 채택, 근거는 복수 나열.

4. **판정 (3 버킷)**
   - `keep` — 중첩 없음 또는 판단 근거 부족. 리포트 본문에서 생략 (카운트만).
   - `revise` — 부분 중첩. 제안 항목:
     - description 패치 (diff 스타일 bullet: `- (remove)` / `+ (add)`)
     - `## Out of Scope` 에 추가할 항목
     - 필요 시 라벨 제안 (예: `scope-reduced-by-{projectKey}-<x>`, 선택 사항)
   - `close` — 전면 중첩 또는 전제 붕괴. 제안 항목:
     - CLOSED transition (`getTransitionsForJiraIssue` 에서 `CLOSED` 이름 매칭)
     - `NO_NEEDED` 라벨 추가
     - 근거 코멘트 (앵커 `{projectKey}-<n>` 또는 문서 경로 + 한 줄 이유)

5. **리포트 출력**. 이 시점까지 JIRA 쓰기 호출 금지. 리포트 끝에 적용 프롬프트를 둔다:
   > "위 변경 사항을 적용할까요? 옵션: `전부` (revise + close 모두) / `close 만` / `revise 만` / `TM-X, TM-Y` (키 지정) / `취소`"
   - `--dry-run` 이 지정됐다면 프롬프트 생략하고 종료.
   - 프롬프트 후 사용자 응답을 기다린다. 응답을 받기 전 어떤 쓰기도 시도하지 않는다.

6. **적용 (사용자 응답 후)**
   - 사용자가 `취소` / `no` / 부정 응답이면 종료.
   - 사용자가 적용 의사를 표하면, 적용 대상 티켓 목록을 결정한다 (전부 / close 만 / revise 만 / 키 명시).
   - 각 대상 티켓에 대해:
     - `close` 판정: `getTransitionsForJiraIssue` 로 CLOSED transition ID 사전 조회 (티켓별로 워크플로우가 다를 수 있으므로 첫 close 대상에서 한 번만 조회 후 캐시).
     - 라벨 추가: `getJiraIssue` 로 현재 라벨 조회 → 기존 라벨 + 제안 라벨 union 후 `editJiraIssue` (덮어쓰기 방지). 라벨이 없으면 그냥 단일 항목 set.
     - 코멘트: `addCommentToJiraIssue` (`contentFormat=markdown`) — 리포트의 "제안 코멘트" 그대로.
     - transition: `close` 인 경우 `transitionJiraIssue` 로 CLOSED 적용.
   - 동일 의도의 batch 작업이 권한 시스템에 일부 거부되면 즉시 재시도 1회. 그래도 실패한 항목은 결과표에 표시.
   - 적용 결과를 표 형태로 보고: `티켓 키 | 라벨 | 코멘트 | transition` 각 칸에 ✅ / ❌ / —.

## 출력 형식

```
## /ticket:audit 요약
감사 모드: top-10 (created ASC) | --all | single={projectKey}-<n>
범위: <전체 오픈 | parent={projectKey}-<에픽>>
주체 티켓: 오픈 M건 중 가장 오래된 N건 감사 (나머지 M-N건은 이 리포트 대상 아님)
앵커 계산: 각 주체 티켓 created 이후 Done 티켓 집합
추가 앵커 문서: <--doc path | 없음>
결과: 감사된 N개 중 keep=a, revise=b, close=c
페이지네이션: <nextPageToken 있음/없음>

## revise (b개)
- {projectKey}-<n> <summary>   (created: 2025-10-14, 나이: 191d)
  앵커 근거: {projectKey}-<x>:Done Criteria 3번 (Done 2026-04-18) | docs/xxx.md:section
  제안 description 패치:
    - (remove) <기존 문장>
    + (add)    <대체 문장>
  Out of Scope 추가: <한 줄>
  제안 라벨: scope-reduced-by-{projectKey}-<x>  (선택)

## close (c개)
- {projectKey}-<n> <summary>   (created: 2025-09-02, 나이: 234d)
  앵커 근거: {projectKey}-<x> (Done 2026-04-18) | docs/xxx.md
  제안 transition: CLOSED
  제안 라벨: NO_NEEDED
  제안 코멘트: "{projectKey}-<x> 머지로 본 티켓 전제(<사유>) 가 소멸. CLOSED 처리."

---
위 변경 사항을 적용할까요?
- `전부` — revise + close 모두 적용
- `close 만` / `revise 만` — 한 버킷만 적용
- `{projectKey}-X, {projectKey}-Y` — 키 명시
- `취소` — 적용하지 않음
```

사용자가 적용을 승인한 후의 결과 보고 (Step 6 완료 후):

```
## 적용 결과

| 티켓 | 라벨 | 코멘트 | transition |
|---|---|---|---|
| {projectKey}-<n> | ✅ NO_NEEDED | ✅ | ✅ CLOSED |
| {projectKey}-<m> | ❌ (사유) | ✅ | — (revise 라 transition 없음) |
```

## 주의사항

- **Step 5 까지는 read-only.** `editJiraIssue` / `addCommentToJiraIssue` / `transitionJiraIssue` 는 사용자가 적용을 승인한 Step 6 에서만 호출. 사용자 응답 전에는 절대 시도하지 않는다.
- `--dry-run` 플래그가 있으면 Step 5 에서 종료 (구 read-only 동작 보존).
- 적용 시 라벨은 **반드시 기존 라벨 보존** — `getJiraIssue` 로 현재 라벨 조회 후 union. 단순 set 으로 덮어쓰면 기존 라벨 손실.
- 적용 시 transition ID 는 워크플로우마다 다를 수 있으므로 `getTransitionsForJiraIssue` 로 사전 조회. 같은 프로젝트 내 첫 close 대상에서 한 번만 조회 후 캐시 권장.
- `revise` / `close` 판정은 **명시적 앵커 근거** 가 있어야 한다. 근거가 없으면 `keep` 이 기본값.
- 한 티켓에 대한 판정 근거는 티켓 섹션·줄 단위까지 구체적으로 적는다 (예: `{projectKey}-200:Done Criteria 3번`).
- MCP 401/403 → `mcp__claude_ai_Atlassian_Rovo__getAccessibleAtlassianResources` 로 재확인하고 그 사실을 리포트에 명시.
- 주체 티켓별 앵커 셋 계산으로 JQL 호출이 최대 N+1 회 발생. `--all` 에서는 수백 회가 될 수 있으므로 사용자가 의식적으로 호출.
- 앵커 결과가 50 건 초과 시 nextPageToken 존재만 언급, 추가 페치는 사용자 요청 시에만.
- `NO_NEEDED` 라벨은 본 커맨드가 도입한 컨벤션이다. 이 커맨드 외 경로에서 붙이는 것은 권장하지 않는다.
- 인자 없이 호출 시 기본 `--top 10` 을 리포트 상단 `감사 모드:` 줄에 명시한다.

## 연관 커맨드

- 단건 티켓 처리: `/ticket <{projectKey}-n>`
- 신규 티켓 생성: `/ticket:create`
- 자동 구현 루프: `/ticket:auto`
- 백로그 상태 요약: `/ticket:list`

`/ticket:audit` 는 위 네 커맨드의 빈틈 — "오래 방치된 오픈 티켓이 후속 변경으로 이미 무효화됐는지" — 만 채운다. 감사 → 사용자 승인 → 적용을 한 흐름으로 처리하므로 매번 `/ticket <{projectKey}-n>` 으로 단건 진입할 필요는 없다. 단건 편집·코멘트만 필요하면 여전히 `/ticket <{projectKey}-n>` 사용.
