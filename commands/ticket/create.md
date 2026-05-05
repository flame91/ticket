# /ticket:create — JIRA 신규 티켓 생성

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

> **Tip:** 기획 단계에서 `/write-prd` 로 PRD 를 먼저 작성하면 더 정밀한 Done Criteria 를 만들 수 있습니다.

## Step 0: 프로젝트 설정 로드

Read `.claude/project.json` from the repo root. `jira.enabled` 가 `false` 이거나 파일이 없으면 위 안내 후 종료.
- `{cloudId}` = `jira.cloudId`
- `{projectKey}` = `jira.projectKey`
- `{epicIssueType}` = `jira.epicIssueType` (기본: `"Epic"`)

## 인자

| 형식 | 의미 |
|---|---|
| `/ticket:create` | 기본. 사용자 의도가 "user feature" 로 분류되면 description / AC 초안을 보조 스킬로 자동 생성. |
| `/ticket:create --bare` | 보조 스킬 호출 없이 사용자 입력 그대로 사용. chore / 운영 메타 / 즉석 버그 리포트용. |
| `/ticket:create --feature` | "user feature" 로 강제 분류. summary 가 모호할 때 자동 분류 우회. |

## 실행 순서

1. 사용자 입력 확인:
   - 제목 (필수)
   - 설명 (필수 — `## Done Criteria`, `## Out of Scope`, `## Verification` 섹션 포함 권장. 데이터/API 티켓은 `## 핵심 설계 결정` 추가 필수 — 아래 §디자인-결정 섹션 참조)
   - 이슈 타입 (`Task` 기본, `Bug`, `Story`, `{epicIssueType}` 택1)
   - 우선순위 (`Medium` 기본, `Highest` / `High` / `Low` / `Lowest` 가능)
   - 라벨 (옵션)
   - 상위 Epic (`parent`, 옵션)
2. **Design-heavy detection (`--bare` 와 무관, 라벨/description 자동 검사):**
   - 다음 중 하나라도 매치되면 design-heavy ticket 으로 분류:
     - 라벨에 `data-quality` / `data` / `data-pipeline` / `schema` / `api` / `backend` / `migration` / `llm` / `facet` 중 1개 이상 포함
     - description 안에 키워드: `마이그레이션`, `Alembic`, `스키마`, `column`, `테이블`, `endpoint`, `API`, `schema`
   - design-heavy 면 description 에 `## 핵심 설계 결정` 섹션 자동 삽입 (§디자인-결정 의 템플릿 그대로). 사용자에게 "이 섹션의 빈 항목을 지금 채우면 사이클 sprawl 회피. 비워두면 `/ticket` 진입 시점에 다시 묻습니다" 안내. 사용자가 채우면 그대로 사용; 비워두면 placeholder 그대로 description 에 포함 (`<TBD>` 표시).
3. **Feature 의도 분류 + 보조 스킬 호출 (`--bare` 미사용 시):**
   - `--feature` 명시되어 있거나, summary 가 동사 + 명사 패턴 ("add", "show", "enable", "보여주다", "추가" 등) 으로 시작하면 "user feature" 로 분류.
   - "user feature" 로 분류된 경우:
     - `Skill(name="pm-execution:write-stories")` 또는 `/pm-execution:write-stories` 호출 → WWA (Why-What-Acceptance) 포맷의 description 초안 생성. 사용자 입력 description 이 비어 있거나 짧으면 이 초안을 채택; 사용자 입력이 충분하면 보조 컨텍스트로만 사용.
     - `Skill(name="pm-execution:test-scenarios")` 또는 `/pm-execution:test-scenarios` 호출 → AC (수용 기준) 테스트 시나리오 생성. description 의 `## Verification` 섹션을 이 산출물로 보강.
   - 분류가 애매하거나 "chore" / "bug" 로 보이면 보조 스킬 호출 스킵.
4. **Bug 재현 (이슈 타입이 `Bug` 인 경우 필수, `--bare` 여부와 무관):**
   - 프론트엔드 / 웹 UI 결함이면 **chrome-devtools MCP 로 직접 재현**한 뒤 티켓을 만든다. 임의 추측·스크린샷 글로만 작성한 버그 리포트 금지.
   - 재현 절차에서 확보해야 할 항목 (description 에 그대로 포함):
     - 정확한 URL · locale · 사전 상태 (localStorage / 쿠키 / 로그인 등 setup 스크립트).
     - 클릭·입력 순서 (snapshot uid 가 아닌 사람이 따라할 수 있는 자연어 + 가능하면 콘솔에서 붙여넣을 수 있는 스크립트).
     - 관찰된 결과(예상 vs 실제) — DOM / localStorage / 네트워크 / console 로그 중 하나 이상의 객관 증거.
   - 재현 도중 근본 원인이 좁혀지면 관련 파일·라인을 description 의 "근본 원인" 절에 명시.
   - 브라우저로 재현 불가능한 결함(백엔드 / 스크래퍼 / 데이터 파이프라인 / CLI 등)은 한 줄 사유와 함께 스킵하고, 가능하면 대체 재현 수단(curl / pytest / 로그 발췌)을 description 에 포함.
5. 중복 확인: 제목 핵심 키워드로 `searchJiraIssuesUsingJql` 실행 (예: `project = {projectKey} AND summary ~ "keyword" AND statusCategory != Done`). 유사 열린 티켓이 있으면 사용자에게 알리고 중단.
6. 중복이 없거나 사용자가 확인하면 `mcp__claude_ai_Atlassian_Rovo__createJiraIssue` 실행.
   - cloudId: `{cloudId}`
   - `project.key`: `{projectKey}`
7. 생성된 티켓 키와 URL 반환. 보조 스킬을 호출했으면 어떤 스킬이 description / Verification 에 기여했는지 한 줄 보고. Bug 재현 단계를 거쳤으면 어떤 재현 증거(스크립트·콘솔 출력 등)가 description 에 포함됐는지 함께 보고.

## 주의사항

- 추측으로 티켓 만들지 말 것 — 제목·설명이 모호하면 먼저 질문
- 중복 가능성이 있으면 먼저 멈추고 설명
- `{epicIssueType}` 타입 생성 시 설명에 상위 자식 티켓 구조를 나열
- 라벨은 신규 발명하지 말고 기존 프로젝트 라벨 중에서 고를 것

## §디자인-결정 — 핵심 설계 결정 (Core Design Decisions) 가이드

데이터/API 티켓 description 에 다음 형식으로 추가. impl-coder 가 임의 결정으로 cascade 못 만들도록 사전 잠금. **누락 시 codex round sprawl 의 주된 원인** (TM-231 사례: 13라운드, finding 50% 이상이 단일 설계 결정 누락에서 cascade).

### 템플릿

```markdown
## 핵심 설계 결정

### 데이터 모델
- 멀티값 컬럼 형식: <string (comma-joined) | ARRAY[] | junction table | enum>. 이유: <한 줄>
- NOT NULL / NULL 정책: <컬럼별>
- 인덱스: <필드별 또는 N/A>

### API 계약
- breaking change 허용: <yes / no — frontend 호환성 mapping 필요한지>
- 응답 직렬화: <raw 값 / split token list / 둘 다>
- 새 query param: <enum 화이트리스트 / 자유 형식>

### 파이프라인 (LLM/스크립트 시)
- 출력 형식: <canonical code / raw label / both>
- Failed row state: <retry / quarantine / mark-done>
- Idempotency: <re-run 안전성, --force 시맨틱>

### 기타 (티켓별)
- <필요 시 추가>
```

### 빈 항목 처리

`/ticket:create` 시점에 항목이 비어 있으면 `<TBD>` 로 표시. `/ticket <KEY>` 진입 시 step 6-i-2.5 가 다시 점검 → 사용자에게 `AskUserQuestion` 으로 채워달라 요청. 사용자가 "잘 모름 / impl-coder 자율" 이라 하면 description 에 그 사실을 명시 (`판단: impl-coder 자율, codex finding 발생 시 follow-up 분리`) — 이후 cycle 의 codex 라운드 sprawl 시 force-ack / follow-up 분리 정당화.

### Trigger 조건 (어떤 티켓에 적용)

다음 중 하나라도 매치 시 design-heavy:

- 라벨: `data-quality` / `data` / `data-pipeline` / `schema` / `api` / `backend` / `migration` / `llm` / `facet`
- description 키워드: `마이그레이션`, `Alembic`, `스키마`, `column`, `테이블`, `endpoint`, `API`, `schema`

순수 frontend 티켓 (`area-frontend` only, backend/data 키워드 없음) 은 적용 X.
