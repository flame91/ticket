# /ticket:batch — 지정 티켓 큐 처리 (순차 / 병렬)

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

사용자가 명시한 키 리스트를 처리한다. `--par` 없으면 한 번에 하나씩 **순차**, `--par` 있으면 Phase 1 을 병렬 스폰하고 Phase 2 를 입력 순서대로 **순차** 처리한다. JQL 자동 선정이 아니라 **명시 큐** 가 소스.

## 인자

| 형식 | 의미 |
|---|---|
| `/ticket:batch TM-a,TM-b,...` | 쉼표 구분 키 리스트, 순차 모드 |
| `/ticket:batch --par TM-a,TM-b,...` | 동일 키 리스트, 병렬 모드 |
| `/ticket:batch 182,183` | 숫자만 입력 시 `{projectKey}-<n>` 으로 자동 보정 |
| `/ticket:batch TM-a, TM-b` | 공백 허용 (trim) |

최소 2개 이상 필요. 1개면 `/ticket:auto once` 또는 `/ticket <{projectKey}-n>` 을 쓰라고 안내 후 종료.

---

## Step 0: 프로젝트 설정 로드

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md 참조

## Step 1: 인자 파싱

쉼표 split → trim → `{projectKey}-<n>` 정규화 → 중복 제거 (입력 순서 유지).
빈 리스트 / 1개 / 유효하지 않은 포맷이면 안내 후 종료.

## Step 2: 세션 상태 체크

`bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/session-state.sh"` 1회.
- `dirty: true` 면 **하드 스탑** (`dirty_files` 목록 보고).
- cwd 가 main repo root 가 아니거나 `branch != {baseBranch}` 이면 **하드 스탑** — `/ticket:batch` 는 main repo root (`{baseBranch}`) 에서만 시작한다.
- 결과 JSON 은 각 사이클의 orchestrator 프롬프트에 재사용.

## Step 3: 사전 검증 (키별 1회 `getJiraIssue`)

각 키에 대해:
- 미존재 / 권한 오류 → 스킵 리스트에 추가 (이유: `not-found`).
- `statusCategory == Done` → 스킵 (이유: `already-done`).
- `issuetype == "{epicIssueType}"` → 스킵 (이유: `epic-excluded`).
- `status == "READY FOR QA"` → 스킵 (이유: `ready-for-qa-manual`). QA-ready 티켓은 상태 전환 충돌 위험 — 개별 `/ticket <{projectKey}-n>` 으로 처리.
- 나머지는 **유효 큐** 에 입력 순서대로 적재.

유효 큐가 비면 스킵 요약 출력 후 natural stop.

---

## 순차 모드 (`--par` 없음)

유효 큐의 각 키에 대해 순서대로:

**Step 4a** — 직전 키 = 현재 키면 스킵.

**Step 4b — Orchestrator 분류**

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md 참조. 추가 배치 규칙:
- `classification ∈ {blocked-by-current-work, conflict}` 또는 `worktree_decision == stop` → **큐 전체 하드 스탑** (해당 키 + 남은 큐 + 분류 근거 보고).
- `next_command` 이 `/ticket*` 바깥 → 해당 키만 스킵 (이유: `orchestrator-routed-elsewhere`), 다음 키로 이동.
- 5필드 누락/규정 외 → **큐 전체 하드 스탑**.

**Step 4c — 사이클 실행**

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md 참조 (Phase 1 → Phase 2 순차). 각 단계 하드 스탑 조건은 `_cycle.md` 를 그대로 따른다. 키 N 의 worktree 정리 + `{baseBranch}` 동기화가 끝난 후 키 N+1 로 진행.

사이클 성공 시 처리 리스트에 `{key, pr_url, merged_sha, regression_mode}` 기록.

---

## 병렬 모드 (`--par`)

### Step 5a — Orchestrator 분류 (키별 순차)

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md 참조. 추가 배치 규칙:
- `classification ∈ {blocked-by-current-work, conflict}` 또는 `worktree_decision == stop` → **해당 키만 제외** (큐 전체 중단 아님).
- `next_command` 이 `/ticket*` 바깥 → 해당 키만 스킵 (이유: `orchestrator-routed-elsewhere`).
- 5필드 누락/규정 외 → **큐 전체 하드 스탑**.

### Step 5b — Worktree 일괄 생성 (순차)

분류 통과한 키 전체에 대해 순서대로 § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md 생성 절차 실행 (키별 1회). 생성 실패 → 해당 키만 제외, 나머지 계속.

### Step 5c — Phase 1 병렬 실행

`_cycle.md` Phase 1 을 `{maxConcurrent}` 개 Agent 로 동시 스폰 (기본 3, 최대 5).
- 입력 키 수 > `{maxConcurrent}` 시 `{maxConcurrent}` 단위로 배치 분할, 배치 완료 후 다음 배치.
- 각 에이전트 결과 수집: `{key, status: "ready"|"blocked", head_sha, reason?}`
- `blocked` → 제외 리스트. `ready` → Phase 2 큐.
- Phase 2 큐가 비면 (전원 blocked) → **하드 스탑**, exit 1.

### Step 5d — Phase 2 순차 실행 (입력 순서 보존)

`ready` 키를 입력 순서대로 `_cycle.md` Phase 2 실행:
- dev 서버 라이프사이클은 `_cycle.md` step 4a/12 가 관리: 직전 키의 step 12 에서 종료 → 현재 키의 step 4a 에서 worktree frontend 기동. 포트 3000 충돌 없음 (순차 보장).
- merge 충돌 → 해당 키만 제외, 나머지 계속.
- 각 키 완료 후 § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md 정리 + `{baseBranch}` 동기화.

---

## 하드 스탑 표

| 종류 | 트리거 | 모드 | 동작 |
|---|---|---|---|
| Argument | 0 / 1개 키 또는 파싱 실패 | 공통 | exit 1, 사용법 안내 |
| Dirty workspace | step 2 에서 working tree dirty | 공통 | exit 1, 변경 파일 목록 |
| Pre-check empty | 사전 검증 후 유효 큐 0개 | 공통 | exit 0, 스킵 요약 |
| Orchestrator malformed | 5필드 누락/규정 외 | 공통 | exit 1, 원본 반환값 보고 |
| Orchestrator block | `blocked-by-current-work` / `conflict` / `stop` | 순차 | exit 1, 해당 키 + 남은 큐 + 근거 |
| Ticket description | `editJiraIssue` 실패 | 순차 | exit 1, 현재 키 + 남은 큐 보고 |
| Regression fail | regression 비정상 종료 | 순차 | exit 1, 현재 키 + 남은 큐 보고 |
| Merge conflict | `gh pr merge` 실패 | 순차 | exit 1, PR 링크 + 남은 큐 보고 |
| MCP auth | Atlassian Rovo 401/403 | 공통 | `getAccessibleAtlassianResources` 재확인 후 여전히 실패 시 exit 1 |
| Phase 1 전체 blocked | 모든 키 blocked | 병렬 | exit 1 |
| Worktree 생성 실패 | `git worktree add` 오류 | 병렬 | 해당 키 제외, 나머지 계속 |
| Phase 2 merge 충돌 | `gh pr merge` 실패 | 병렬 | 해당 키 제외, 나머지 계속 |

## 스킵 (해당 키만 건너뛰고 다음 진행)

| 종류 | 트리거 |
|---|---|
| Not found | `getJiraIssue` 에서 미존재 |
| Already done | `statusCategory == Done` |
| Epic excluded | `issuetype == "{epicIssueType}"` |
| Ready for QA manual | `status == "READY FOR QA"` — 수동 `/ticket <{projectKey}-n>` 로 처리 |
| Orchestrator routed elsewhere | `next_command` 이 `/ticket*` 바깥 |

---

## 안전장치

- `_cycle.md` 의 안전장치를 모두 상속: `{baseBranch}` / `main` 직접 push 금지, `--force` / `--no-verify` / `--no-gpg-sign` 금지, 사이클마다 새 sibling worktree + 새 브랜치.
- **티켓당 sibling worktree.** 경로: `<repo-root>/../{repoSlug}-{projectKey}-<n>-<slug>`.
- **Phase 2 merge 순서는 입력 순서 보존 (race 방지). 병렬 impl 간 파일 충돌 없음 (각 worktree 격리).**
- **JQL 우회.** 배치는 명시 입력된 키만 처리. JQL 자동 선정 로직은 쓰지 않는다.
- 큐는 세션 로컬. repo 안에 큐 파일을 만들지 말 것.

---

## 결과 보고 형식

### 순차 모드

```
/ticket:batch 종료 (<natural|hard-stop>)
입력 큐: N개
  - TM-182, TM-183, TM-184, ...
처리 완료: K개
  - TM-182: <summary> → <merged-sha> (PR #nnn, regression: frontend)
스킵: M개
  - TM-<n>: <not-found|already-done|epic-excluded|orchestrator-block>
미처리 (하드 스탑 시): L개
  - TM-<n>, TM-<m>, ...
블로커: <하드 스탑 사유 또는 "없음">
```

### 병렬 모드 (`--par`)

```
/ticket:batch --par 종료 (<natural|hard-stop>)
입력 큐: N개
Phase 1 병렬: K개 완료, M개 blocked
  - TM-214: ready (impl 3m12s, test 45s)
  - TM-215: blocked — "vitest assertion failure"
Phase 2 순차: L개 머지, P개 실패
  - TM-214: merged → abc1234 (PR #291, chrome: PASS)
미처리: Q개
  - TM-215: Phase 1 blocked
블로커: "없음" 또는 사유
```

---

## 주의사항

- `/ticket:batch` 는 머지까지 자동 진행한다. 사용자 감독 없이 돌아가는 환경에서만 사용.
- 수동 티켓 하나씩 확인·구현은 `/ticket <{projectKey}-n>`. JQL 자동 선정 루프는 `/ticket:auto`. 이 커맨드는 **명시 큐 전용**.
- batch 진행 중 신규 티켓이 등장하면 `/ticket:batch:append <KEY>` 로 잔여 큐 끝에 append 가능 (순차 모드 또는 병렬 Phase 1 진행 중에 한함). 큐 중간 삽입·우선순위 변경은 지원하지 않으며 race 위험으로 명시적으로 거부.
