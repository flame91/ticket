# /review — 커밋 전 리뷰

현재 diff, 브랜치, 또는 지정된 변경을 코드 리뷰 관점에서 검토해줘. 실제 리뷰는 `qa-verifier` 서브에이전트가 수행한다.

> **역할 구분:** `/review` 는 PR 전 자체 리뷰 (파인딩 리포트). `codex:review` 는 push 전 크로스 리뷰 게이트 (`/push` 워크플로가 자동 호출). 독립 호출 시 "내 코드 점검 → `/review`" · "push 게이트 → `/push` 가 자동 호출" 로 구분.

## Step 0: 프로젝트 설정 로드

Read `.claude/project.json` from the repo root. 존재하지 않으면 기본값 사용:
- `jira.enabled`: `false` (JIRA 관련 단계 스킵)
- `jira.projectKey`: `null`
- `scripts.qaSummary`: `null` (회귀 스크립트 스킵)

## 실행 순서

1. **변경 범위 파악** — `git diff --stat` 또는 `git diff <base>...HEAD --stat` 으로 영향 파일 집합 확보. `jira.enabled` 이면 관련 JIRA 티켓 키(`{projectKey}-<n>`) 가 있으면 함께 수집.
2. **`qa-verifier` 스폰** — `Agent(subagent_type="qa-verifier", prompt=...)` 호출. 프롬프트에 다음을 포함:
   - diff 범위 (base..HEAD 또는 특정 커밋들)
   - 영향 파일 목록
   - JIRA 티켓 키 + Done Criteria (있고 `jira.enabled` 이면)
   - 리뷰 포커스(사용자가 특정 영역을 지정했으면)
   - `scripts.qaSummary` 경로 (project.json 에 있으면)
3. **중계** — 서브에이전트가 반환한 findings(심각도 순) 를 그대로 사용자에게 전달. 메인 세션에서 추가 칭찬/개요 덧붙이지 않는다.

## 결과 형식 (qa-verifier 가 반환)

- 심각도 순 findings (title / severity / steps / expected / actual / suspected area)
- findings 없음 시 `findings: none` + 잔여 test gap
- 짧은 변경 요약 (맨 끝)

## 주의사항

- `/review` 는 read-only 리뷰 패스 — 수정은 하지 않음.
- 심층 조사가 필요한 파인딩이 있으면 `/diagnose` 활용을 권장.
- 티켓 스코프가 잘못 라우팅된 것으로 보이면 `qa-verifier` 가 `executive-orchestrator` 로 에스컬레이션을 권고.
