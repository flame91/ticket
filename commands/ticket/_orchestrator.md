# § orchestrator — 오케스트레이터 5필드 분류 (내부 참조 전용)

## 스폰 계약

`Task(subagent_type="executive-orchestrator", prompt=...)` 로 스폰. 프롬프트에 아래 컨텍스트를 포함:

- **session-state**: 호출측이 수집한 worktree/cwd/branch/dirty JSON
- **ticket**: `{key, summary, status, issuetype, priority, labels, parent}`
- **invoking_command**: 호출한 커맨드명 (`/ticket`, `/ticket:auto`, `/ticket:batch`)
- **docs_grill_summary** (조건부): `{skillGrillDocs}` 가 `true` 이고 `invoking_command == "/ticket"` (수동 진입) 일 때만 포함. 스폰 직전에 `Skill(name="grill-with-docs")` 또는 `/grill-with-docs` 를 호출하여 티켓 summary + done_criteria 를 ADR / CONTEXT.md 와 대조한 결과 요약을 받아온다. orchestrator 는 이 컨텍스트를 `reason` 보강에 활용. `/ticket:auto` · `/ticket:batch` 에서는 호출하지 않음 (루프 속도 보존).

서브에이전트는 read-only 로 5필드 분류 결과를 반환한다.

## 5필드 검증

| 필드 | 허용 값 |
|------|---------|
| `classification` | `continue`, `not-related`, `related-but-separate`, `blocked-by-current-work`, `conflict` |
| `owner` | 역할 문자열 |
| `next_command` | 슬래시 커맨드 문자열 |
| `worktree_decision` | `stop`, `reuse-current`, `create-issue-worktree` |
| `reason` | 자유 텍스트 |

**하나라도 규정 외 값이거나 누락이면 하드 스탑** (예상 밖 결과, 사용자 확인).

## classification 별 동작

| classification | 동작 |
|---|---|
| `continue` | 기존 worktree 재사용 경로로 진행 |
| `not-related` | 별도 scope — 새 sibling worktree |
| `related-but-separate` | 별도 done criteria — 새 sibling worktree, `reason` 보고 |
| `blocked-by-current-work` / `conflict` | **하드 스탑** |

## worktree_decision 오버라이드 (classification 보다 우선)

| 값 | 동작 |
|---|---|
| `stop` | **하드 스탑** (classification 무관) |
| `reuse-current` | 기존 worktree 재사용 |
| `create-issue-worktree` | 새 sibling worktree 생성 |

## next_command 처리

호출측 커맨드에 따라 다르게 처리:

| 호출측 | next_command ≠ 자신 | 동작 |
|--------|---------------------|------|
| `/ticket` | 예: `/migrate` | **진행 중단** — "오케스트레이터가 `<next_command>` 를 권고함" 안내 |
| `/ticket:auto` | 예: `/migrate` | **해당 티켓만 스킵**, 루프 계속 |
| `/ticket:batch` | `/ticket*` 바깥 | **해당 키만 스킵**, 큐 계속 |

## owner 활용

반환된 `owner` 로 `{roleDocDir}` + `{roleMapping}` 에서 역할 문서를 참조하여 impl-coder 위임 시 힌트로 전달.
