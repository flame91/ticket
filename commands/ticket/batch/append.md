# /ticket:batch:append — 진행 중 batch 큐 끝에 키 추가

> `jira.enabled` 가 `false` 이면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

현재 세션에서 진행 중인 `/ticket:batch` 의 잔여 큐 **끝에** 키를 append 한다. 독립 실행되는 명령이 아니다 — `/ticket:batch` 가 돌고 있는 세션에서만 의미가 있다. 큐 중간 삽입·우선순위 변경·기존 키 재정렬은 지원하지 않는다 (race 위험으로 단순 append 만 허용).

## 인자

| 형식 | 의미 |
|---|---|
| `/ticket:batch:append TM-a` | 단일 키 append |
| `/ticket:batch:append TM-a,TM-b` | 여러 키 append (쉼표 구분, 입력 순서 보존) |
| `/ticket:batch:append 228` | 숫자만 입력 시 `{projectKey}-<n>` 으로 자동 보정 |

## Step 0: 프로젝트 설정 로드

§ `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md` 참조.

## Step 1: 진행 중 batch 확인

- 현재 세션에 `/ticket:batch` 가 진행 중이 아니면 — "진행 중인 `/ticket:batch` 가 없습니다. 새 큐는 `/ticket:batch <KEY,...>` 로 시작하세요" 안내 후 종료.
- 진행 중 batch 가 **병렬 모드 + Phase 1 종료 후 (Phase 2 진입)** 면 — "병렬 batch 가 Phase 2 단계입니다. 신규 키 삽입은 별도 `/ticket:batch` 또는 `/ticket:auto` 로 처리하세요" 안내 후 종료. (Phase 2 는 사전 머지된 ready 집합을 입력 순서대로 처리하므로, 신규 키 삽입은 Phase 1 재실행이 필요해 단순 append 의 범위를 벗어남.)
- 그 외 (순차 모드 진행 중 / 병렬 모드 Phase 1 진행 중) 는 진행.

## Step 2: 인자 파싱

쉼표 split → trim → `{projectKey}-<n>` 정규화 → 중복 제거 (입력 순서 유지).
이미 진행 중 batch 의 큐(처리 완료/처리 중/스킵/잔여) 와 중복되는 키는 사용자에게 보고하고 제외.

## Step 3: 사전 검증 (`/ticket:batch` Step 3 와 동일)

각 키에 대해 `getJiraIssue` 1회:
- 미존재 / 권한 오류 → 스킵 (이유: `not-found`).
- `statusCategory == Done` → 스킵 (이유: `already-done`).
- `issuetype == "{epicIssueType}"` → 스킵 (이유: `epic-excluded`).
- `status == "READY FOR QA"` → 스킵 (이유: `ready-for-qa-manual`).

유효 키만 잔여 큐 **끝에** append. 입력 순서 보존.

## Step 4: 보고 + 흐름 복귀

```
/ticket:batch:append 완료
추가됨: K개
  - TM-228 (잔여 큐 위치: M번째)
스킵: P개
  - TM-227: already-done
현재 batch 상태:
  - 모드: 순차 / 병렬-Phase1
  - 처리 완료: x개, 잔여: y개 (큐: TM-..., TM-..., TM-228, ...)
```

진행 중 batch 는 자연 흐름대로 다음 키부터 새로 추가된 키를 처리한다 (별도 phase 트리거 없음).

## 주의사항

- **단순 끝-추가 전용.** 큐 중간 삽입·우선순위 swap·기존 키 제거 등은 지원하지 않는다. 더 복잡한 큐 조작이 필요하면 현재 batch 가 끝나기를 기다린 뒤 별도 `/ticket:batch` 로 묶는다.
- **병렬/순차 모드 결정은 진행 중 batch 의 모드를 따름.** 키 단위 모드 override 없음. 병렬 페어링·파일 충돌 분석 등은 LLM 휴리스틱 (orchestrator 분류 + cycle 진행 시 판단) 에 위임.
- **세션 로컬.** 큐 파일 영속화 없음. 세션이 죽으면 append 한 키도 함께 사라짐 — 새 세션에서 `/ticket:batch` 재시작.
- 안전장치는 `/ticket:batch` 를 그대로 상속 (`{baseBranch}` / `main` 직접 push 금지, sibling worktree 격리, JQL 우회 등).
