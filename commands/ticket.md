# /ticket — 특정 JIRA 티켓 진입

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

인자로 받은 티켓 번호(`{projectKey}-<n>` 또는 `<n>`) 를 기준으로 티켓을 조회하고 현재 상태에 맞는 다음 액션을 라우팅해줘.

## Step 0: 프로젝트 설정 로드

§ `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md` 참조로 설정 로드.

## 인자 형식

- `/ticket {projectKey}-42`
- `/ticket 42`
- `/ticket {projectKey}-42` (대소문자 무시)

## 실행 순서

1. 인자 파싱:
   - 숫자만 들어오면 `{projectKey}-<숫자>` 로 보정.
   - `{projectKey}-` prefix 는 대문자로 정규화.
   - 유효하지 않으면 올바른 형식을 안내하고 중단.
2. 티켓 조회: `mcp__claude_ai_Atlassian_Rovo__getJiraIssue` 로 `summary / status / priority / issuetype / labels / assignee / description` 확인.
3. 에픽(`{epicIssueType}` 타입) 처리: 직접 구현 대상이 아니므로 자식 티켓(`parent = {projectKey}-<n> AND statusCategory != Done`) 을 `/ticket:list` 형식으로 출력 후, 자식 중 하나를 `/ticket <자식-n>` 으로 다시 호출하도록 안내하고 종료.
4. Worktree 위치 판정 — 병렬 실행: `git rev-parse --show-toplevel`, `git status --short`, `git branch --show-current`, `git worktree list --porcelain`, `git fetch origin --quiet`.
   - cwd 가 해당 티켓 sibling worktree (`feat/{projectKey}-<n>-*` 또는 `fix/{projectKey}-<n>-*`) 안이면:
     - `git status --short` **clean** → 재사용하고 step 5 진입.
     - **dirty** → **하드 스탑**. 변경 파일 목록을 보고하고 사용자가 (a) 해당 worktree 에서 커밋, (b) `git stash push -u -m "pre-ticket-{projectKey}-<n>"`, (c) `git restore` / `git clean` (명백히 버릴 수 있는 경우) 중 하나로 정리한 뒤 `/ticket` 을 재실행하도록 안내.
   - cwd 가 다른 티켓 / chore sibling worktree 안이면 **하드 스탑** — "main repo 로 이동 후 재실행" 안내.
   - cwd 가 main repo root 이고 브랜치가 `{baseBranch}` 이면 step 6-i-3 에서 sibling worktree 를 새로 만든다.
   - cwd 가 main repo root 인데 브랜치가 `{baseBranch}` 이 아니면 **하드 스탑** — `git checkout {baseBranch}` 후 재실행 안내.
5. **오케스트레이터 분류** — § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md` 참조.

   **`next_command` 처리 (ticket.md 전용)**: 반환값이 `/ticket` 이 아닌 다른 슬래시 커맨드면 **진행 중단** 후 사용자에게 "오케스트레이터가 `<next_command>` 를 권고함 — 해당 커맨드로 재시작하세요" 안내. Claude 가 자발적으로 라우팅을 override 하지 말 것.

   메인 세션은 반환된 `owner` 로 step 6-i-4 의 역할 문서 참조를 고정.

6. 현재 티켓 상태 기반 라우팅:
   - `To Do` / `In Progress` / `QA FAILED` → 구현 준비:
     1. 세션 타이틀에 `[{projectKey}-<n>]` 접두사 부여: `/rename` 슬래시 커맨드를 사용해 현재 세션 타이틀을 `[{projectKey}-<n>] <기존 타이틀 또는 티켓 summary 요약>` 형태로 변경. 이미 `[{projectKey}-<n>]` 접두사가 붙어 있으면 재설정하지 않음. (다른 `[{projectKey}-*]` 접두사가 있으면 새 티켓 번호로 교체.)
     2. 본문에 `## Done Criteria` / `## Out of Scope` / `## Verification` 섹션이 없으면 `editJiraIssue` 로 보강.
     2.5. **핵심 설계 결정 사전 점검** (design-heavy 티켓 한정):
        - 라벨에 `data-quality` / `data` / `data-pipeline` / `schema` / `api` / `backend` / `migration` / `llm` / `facet` 중 1개 이상 포함하면 design-heavy ticket 으로 분류.
        - description 의 `## 핵심 설계 결정` 섹션 검사:
          - **부재** → opus 가 description 분석해서 빠진 항목 (멀티값 컬럼 형식, breaking change 정책, 응답 직렬화, idempotency 등) 1~3개 추출 → `AskUserQuestion` 으로 사용자에게 결정 요청.
          - **존재하지만 빈 항목 (`<TBD>` / `?` / 빈 줄)** 있으면 빈 항목만 추출해서 동일하게 사용자 확인.
          - **모든 항목 채워짐** → 점검 통과, i-3 으로 진행.
        - 사용자 답변 받은 후 `editJiraIssue` 로 description 갱신 (기존 섹션이 없으면 신설, 있으면 빈 항목 자리에 답변 삽입).
        - **사용자가 "잘 모름 / impl-coder 자율" 선택**: description 에 그 명시 (`판단: impl-coder 자율, codex finding 발생 시 follow-up 분리`) — 이후 cycle 의 codex 라운드 sprawl 시 force-ack / follow-up 분리 정당화. 점검은 통과로 처리.
        - **목적**: TM-231 사례 (codex 13라운드, 1h 27m, finding 50%+ 가 단일 설계 결정 누락에서 cascade) 같은 sprawl 차단. 사이클 시작 전 결정을 잠그는 게 핵심.
        - **자동 흐름 (`/ticket:auto` / `/ticket:batch`) 에서 i-2.5**: AskUserQuestion 호출 시 자동 흐름이 잠시 멈춤 — 의도된 동작. 자동 흐름의 design-heavy 처리 변경은 별도 follow-up.
     3. § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md` "생성/재개" 참조.
     4. 티켓이 `To Do` 면 `getTransitionsForJiraIssue` → `Start work` → `transitionJiraIssue` 로 `In Progress`.
     5. § `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` 참조 (Phase 1 → Phase 2 순차 실행).
   - `READY FOR QA` → 티켓 `## Verification` 섹션과 직전 `검증 요약` 코멘트의 SKIP/잔여 리스크 항목을 출력하고 수동 QA 체크 가이드 제공. (현 정책상 3중 리뷰가 모두 PASS / N/A 인 티켓은 `_cycle.md` step 10 에서 바로 Done 으로 전환되므로, READY FOR QA 에 도착한 티켓은 거의 항상 환경 의존 SKIP 또는 잔여 리스크가 있는 케이스다 — 그 부분 위주로 점검. N/A 처리된 항목은 자동으로 PASS 효력으로 통과했으므로 여기서 다시 검증할 필요 없음.) 통과 시 `getTransitionsForJiraIssue` → `Mark Done` → `transitionJiraIssue`. 실패 시 `Fail QA` 로 전환하고 원인 코멘트 요청.
   - `Done` / `CLOSED` → 요약만 출력하고 "이미 완료된 티켓" 임을 안내. 재작업이 필요하면 새 티켓(`/ticket:create`) 생성을 권장.

## 주의사항

- `/ticket` 은 단일 티켓 진입점. `/ticket:create`(신규), `/ticket:list`(백로그 요약), `/ticket:auto`(자동 루프) 와 역할이 다르다.
- main repo (repo-root) 는 항상 `{baseBranch}` 를 유지. `/ticket` 은 절대 main repo 를 feature/fix 브랜치로 체크아웃하지 않으며, 티켓 작업은 전적으로 sibling worktree (`<repo-root>/../{repoSlug}-{projectKey}-<n>-<slug>`) 안에서 진행한다.
- 상태 전환 실패(권한·transition 조건 미충족) 시 코멘트로 블로커를 기록하고 진행 중단.
- transition id 는 프로젝트 설정 변경에 따라 바뀌므로 `getTransitionsForJiraIssue` 응답에서 이름으로 매칭.
- PR 머지 자체를 완료로 취급하지 말 것. `Mark Done` 전환은 QA 통과 후에만.
- design-heavy 티켓 (data/api/schema/migration/llm/facet 라벨) 은 step 6 i-2.5 의 사전 점검 통과 필수. 점검 우회는 사용자 명시 결정 시점에만 (예: "impl-coder 자율" 응답).
