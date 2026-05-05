# /ticket:batch:plan — 입력 큐 분할 제안 (read-only)

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

지정 키 리스트를 분석해 의존성·진행상태·라벨 기준으로 **여러 `/ticket:batch` 호출로 분할 제안**한다. 실제 실행은 하지 않는 read-only 모드 — 사용자가 출력된 명령을 직접 복사해 실행한다.

`/ticket:batch` 의 `--par` 모드는 입력 큐를 그대로 받아 동시에 돌린다 (자동 묶음 판단 없음). 이 스킬은 batch 직접 호출 전 "어떻게 묶을지" 권장안을 미리 산출하는 용도.

## 인자

| 형식 | 의미 |
|---|---|
| `/ticket:batch:plan TM-a,TM-b,...` | 쉼표 구분 키 리스트 |
| `/ticket:batch:plan 182,183` | 숫자만 입력 시 `{projectKey}-<n>` 으로 자동 보정 |
| `/ticket:batch:plan TM-a, TM-b` | 공백 허용 (trim) |

최소 2개 이상 필요. 1개면 `/ticket <{projectKey}-n>` 안내 후 종료.

---

## Step 0: 프로젝트 설정 로드

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md 참조.

## Step 1: 인자 파싱

쉼표 split → trim → `{projectKey}-<n>` 정규화 → 중복 제거 (입력 순서 유지).
빈 리스트 / 1개 / 유효하지 않은 포맷이면 안내 후 종료.

## Step 2: 메타데이터 수집 (키별 1회 `getJiraIssue`)

각 키에 대해 다음 필드만 조회 (가볍게):
`summary, status, issuetype, parent, issuelinks, labels, priority`

## Step 3: 분류

각 키를 카테고리로 분류:

| 카테고리 | 조건 | 처리 |
|---|---|---|
| `runnable` | status ∈ {To Do, READY FOR DEV} 이고 issuetype != `{epicIssueType}` | runnable 큐에 적재 |
| `in-progress` | status == In Progress | 스킵 (이유: 현 worktree 진행 중, 별도 처리) |
| `ready-for-qa` | status == "READY FOR QA" | 스킵 (이유: 수동 `/ticket <{projectKey}-n>` 권장) |
| `already-done` | statusCategory == Done | 스킵 |
| `epic-excluded` | issuetype == `{epicIssueType}` | 스킵 |
| `not-found` | API 미존재 / 권한 오류 | 스킵 |

## Step 4: 의존성 그래프 빌드

`runnable` 큐에 한해:
- `issuelinks` 에서 `type.name ∈ {"Blocks", "Depends", "is blocked by"}` 항목 추출
- linked key 가 같은 runnable 큐 내부에 있는 경우만 엣지로 사용 (외부 키 의존성은 정보성 표시)
- 사이클 검출 시 → "의존성 사이클 감지: TM-x ↔ TM-y" 보고 후 종료

## Step 5: 위상 정렬 + 레벨 분할

DAG 위상 정렬 → 레벨별 그룹화. 레벨 N 의 키들은 서로 독립이라 `--par` 후보, 레벨 간은 순차.

## Step 6: 그룹 내 추가 분할 (5개 청크)

각 레벨 내 키 K개:

| K | 권장 호출 |
|---|---|
| 1 | `/ticket <키>` (단일 batch 의미 없음) |
| 2-5 | `/ticket:batch --par <키1>,<키2>,...` |
| 6+ | 입력 순서대로 5개씩 청크 분할, 각 청크가 독립 `--par` |

## Step 7: 휴리스틱 경고 (강제 분할 아님, 표시만)

다음 패턴은 ⚠️ 로 보고하지만 분할은 강제하지 않음:

- **size-l 다중 동시 실행**: 같은 그룹에 size-l 라벨 2개 이상 → "큰 변경끼리 동시 머지 시 회귀 검증 부담. 분리 권장"
- **같은 EPIC + 같은 area-***: parent 가 같고 area-* 라벨이 일치하는 키 2개 이상 → "같은 파일 영역 충돌 가능성"
- **priority Highest 단독**: Highest 1개가 다른 키와 묶임 → "실패 영향 최소화 위해 단독 권장"
- **외부 의존성**: linked key 가 큐 외부 + status != Done → "TM-x 미완료 상태로 시작 시 블로킹 위험"

## Step 8: 출력 형식

```
=== /ticket:batch 분할 제안 ===

입력: N개
runnable: K개
스킵: M개

분할 plan (총 P개 호출):

[1/P] sequential — <근거 요약>
  /ticket:batch <key1>,<key2>
  근거: <key1> blocks <key2>

[2/P] parallel — <근거 요약>
  /ticket:batch --par <key3>,<key4>,<key5>
  근거: 같은 EPIC <parent>, 의존성 링크 없음, 모두 size-m

[3/P] sequential — <근거 요약>
  /ticket:batch <key6>,<key7>
  근거: 둘 다 size-l, 회귀 격리 위해 순차

스킵 항목:
  TM-x: in-progress (현 worktree 진행 중)
  TM-y: epic-excluded
  TM-z: already-done

⚠️ 주의:
  TM-c, TM-d 모두 frontend area-* 라벨 + 같은 EPIC <parent> — 같은 파일 영역 가능성
  TM-f 외부 의존: TM-200 (To Do) 미완료 상태로 시작 시 블로킹 위험

복사 실행:
  /ticket:batch <key1>,<key2>
  /ticket:batch --par <key3>,<key4>,<key5>
  /ticket:batch <key6>,<key7>
```

---

## 안전장치 / 한계

- **read-only**. orchestrator / worktree / cycle 호출 금지. JIRA `getJiraIssue` 만 사용.
- 실제 실행은 사용자 책임. plan 출력을 자동 실행하지 않는다.
- `issuelinks` 가 누락된 의존성은 잡지 못함 — 사용자가 필드 보강 후 재실행 권장.
- 파일 영역 충돌 추정은 라벨 기반 휴리스틱이라 정확하지 않음. 실 충돌 여부는 머지 시점에 판별.
- worktree / merge race / port 3000 충돌 등 batch 실행 중 안전장치는 `_cycle.md` Phase 2 순차 보장으로 처리되므로 plan 단계에서 검증하지 않음.
- 그룹 청크 사이즈(5)는 `parallel.maxConcurrent` 의 상한 (기본 3, 최대 5) 과 별개. plan 은 추천만 하고, 실 실행은 batch.md 의 `{maxConcurrent}` 가 적용된다.
