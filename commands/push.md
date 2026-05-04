# /push — 브랜치 분리 · 커밋 · PR · 머지

현재 작업 내용을 분석해서 아래 순서를 자동으로 수행해줘.

> **리뷰 도구 역할 구분:** `/review` = PR 전 자체 리뷰 (파인딩 리포트). Step 5 의 Codex 교차리뷰 = push 전 크로스 리뷰 게이트 (`codexReview.enabled` 일 때만 자동 실행). 둘은 독립적이다.

## Step 0: 프로젝트 설정 로드

Read `.claude/project.json` from the repo root. 존재하지 않으면 기본값 사용:
- `project.repoSlug`: `$(basename "$(git rev-parse --show-toplevel)")`
- `git.baseBranch`: `"main"`
- `jira.enabled`: `false` (Step 11 전체 스킵)
- `jira.projectKey`: `null`
- `codexReview.enabled`: `false` (Step 5 전체 스킵)
- `codexReview.choreAllowList`: `["docs/", ".claude/", ".github/"]`

이하 `{baseBranch}`, `{projectKey}`, `{repoSlug}` 는 위에서 로드한 값을 참조한다.

## 모드

- `/push` (기본) — 티켓 연동 모드 (`jira.enabled` 시). JIRA 비활성이면 일반 feature/fix PR 모드.
- `/push chore` — 티켓 없이 repo 운영 메타(`.claude/`, `docs/`, `.github/workflows/`, `scripts/` 등) 정리용.
  - 기능/버그 변경은 chore 모드 금지. 애매하면 기본 모드로 진행.

## 실행 순서

### 1. 현재 상태 파악
다음을 병렬로 실행:
- `git status` — 변경 파일 목록 확인
- `git diff HEAD` — 변경 내용 확인
- `git log origin/{baseBranch}..HEAD --oneline` — base 대비 로컬 커밋 확인
- `git branch --show-current` — 현재 브랜치 확인

### 2. 브랜치 결정

공통 원칙: **main repo (repo-root) 는 언제나 `{baseBranch}` 을 유지** — `/push` 는 main repo 에서 feature/fix/chore 브랜치를 만들지 않는다. sibling worktree 가 없는 상태에서 `/push` 가 호출되면 아래 "dirty 복구 시퀀스" 로 안내한다.

**기본 모드**
- 이미 `feat/*` 또는 `fix/*` 브랜치에 있으면 → 그 브랜치 그대로 사용 (sibling worktree cwd 전제).
- `main` 또는 `{baseBranch}` 에 있고 변경사항이 있으면 → **하드 스탑**. "dirty 복구 시퀀스" 를 그대로 출력. 변경사항이 없으면 natural stop.

**chore 모드**
- 이미 `chore/*` 브랜치에 있으면 → 그 브랜치 그대로 사용.
- `main` 또는 `{baseBranch}` 에 있고 변경사항이 있으면 → **하드 스탑**. 동일하게 "dirty 복구 시퀀스" (chore 버전) 를 출력. 변경사항이 없으면 natural stop.

**dirty 복구 시퀀스** (사용자가 수동 실행; Claude 는 자동화하지 않음):

1. main repo 의 관련 파일만 pathspec-scoped stash 로 분리:
   ```
   git stash push -u -m "pre-push-<slug>" -- <옮길 파일 경로…>
   ```
   unscoped `-u` 는 mixed scope 오염 위험이 크므로 경로를 명시.
2. 이제 main repo 가 clean 하므로 `/work <slug>` 로 sibling worktree 생성.
3. 새 worktree 로 이동 (`cd <worktree-path>`) 후 `git stash pop` 으로 옮긴 변경 복원.
4. 해당 worktree 안에서 `/push` (또는 `/push chore`) 재실행.

### 3. 스테이징
- `git add` — 변경된 파일을 개별 확인 후 스테이지
- `.env`, 시크릿 파일, 바이너리는 제외

### 4. 커밋

**기본 모드 (`jira.enabled`)**
- 제목 형식: `<type>: <what> ({projectKey}-<n>)` — JIRA 스마트 커밋 자동 인식
  - 예: `fix: refresh nearby results after map move ({projectKey}-232)`

**기본 모드 (JIRA 비활성)**
- 제목 형식: `<type>: <what>` — 티켓 접미사 없이

**chore 모드**
- 제목 형식: `<type>: <what>` — 티켓 접미사 없이
  - `<type>` 은 보통 `chore`, `docs`, `ci` 중 하나

공통
- 50자 이내 요약 + 필요 시 본문(기존 커밋 스타일 따름, 한/영 모두 허용)
- 트레일러: `Co-Authored-By: Claude <noreply@anthropic.com>`

### 5. Codex 교차리뷰 (`codexReview.enabled` 일 때만)

> `codexReview.enabled` 가 `false` 이면 이 단계 전체 스킵 → Step 6 으로.

푸시 전에 Claude 가 Codex 교차리뷰 스크립트를 실행해 ack / cycle 상태를 `<git-dir>/codex-review-ledger.json` 에 기록한다. PreToolUse 훅이 ack SHA ≠ HEAD 이면 `git push` 를 블록한다.

스크립트 경로: `$HOME/.claude/scripts/codex-auto-review.sh` (글로벌) 또는 프로젝트 로컬 `scripts/claude/codex-auto-review.sh` — 존재하는 쪽 사용.

Exit code 별 처리:

- **0** — approve → ack 자동 기록. 다음 단계 (푸시) 진행.
- **1** — 정상 rejection (streak=0). **`impl-coder` 서브에이전트에 반영 위임** — `Agent(subagent_type="impl-coder", prompt=<입력 계약>)`, `mode: "reflect-exit1"`. 서브에이전트는 critical/high 을 반영한 새 커밋을 만들고 보고. 메인은 새 HEAD 로 스크립트 재실행.
- **5** — 사이클 감지 (streak≥1). **메인(opus) 이 직접 전략 수립**, 그 뒤 재구현만 `impl-coder` 로 위임. 전략: `opus_remodel` → `opus_scope_cut` → `opus_essence_review` → stop-and-ask.
- **4** — 사이클 MAX 초과 (기본 streak≥4). **유저 결정 필요**. Claude 자율 범위 외.
- **2/3** — 인프라 오류. stderr 원문 전달, stop.

기타 동작:
- medium/low severity 는 자율 통과, 요약만 출력.
- chore 브랜치이고 변경 경로가 `codexReview.choreAllowList` 내면 자동 통과.

### 6. 푸시
- `git push -u origin <브랜치명>`

### 7. PR 생성
- `gh pr create --base {baseBranch} --title "<커밋 제목>" --body "<본문>"`

**기본 모드 (`jira.enabled`)**
- 본문 기본 링크: `Refs: {projectKey}-<n>` (검증 미완 시)
- 검증이 이미 완료됐고 사용자가 명시적으로 즉시 Done 을 요청한 경우에만 `Closes: {projectKey}-<n>`

**기본 모드 (JIRA 비활성) / chore 모드**
- 본문에 JIRA 링크 생략. 필요 시 한 줄 요약만 기재.

### 8. 머지
- `gh pr merge --squash --delete-branch`

### 9. Worktree cleanup (두 모드 공통)

현재 cwd 가 `/work` 또는 `/ticket` 으로 생성된 sibling worktree 인 경우 이 단계에서 자동 제거한다.

- `git worktree list --porcelain` 로 현재 cwd 가 main repo root 인지, sibling worktree 인지 판정.
- 현재 cwd == main repo root → cleanup 스킵, 다음 단계로.
- 현재 cwd == sibling worktree →
  - uncommitted 변경이 남아 있으면 **stop**. 자동 제거 금지.
  - 클린이면: main repo root 로 이동 → `git worktree remove <sibling-path>` → `git worktree prune` → `git fetch origin --prune`.
  - 제거 실패 시 stderr 원문 그대로 전달하고 stop.

### 10. base branch 동기화
- main repo root 에서 `git checkout {baseBranch} && git pull`.
- 다른 워크트리가 `{baseBranch}` 을 체크아웃 중이면 체크아웃하지 말고 블로커 보고.

### 11. JIRA 상태 전환 (`jira.enabled` 일 때만)

> `jira.enabled` 가 `false` 이면 이 단계 전체 스킵.

**기본 모드**
- 머지 성공 후 `getTransitionsForJiraIssue` 로 사용 가능한 transition 확인.
- 분기 규칙:
  - 직전 사이클이 `/ticket:auto` / `/ticket <TM-n>` 의 step 8a 검증 요약 (`/test`, `/test chrome`, `codex review`, `잔여 리스크` 4행) 을 산출했고, **3중 리뷰 모두 PASS / N/A + 잔여 리스크 행 비어 있음** → `Mark Done` → `Done`. 솔로 워크플로에서 자동 검증이 모두 통과 (또는 비대상으로 N/A) 한 시점에 별도 수동 QA 게이트는 추가 효용이 거의 없으므로 우회.
  - 8a 요약은 있는데 **어느 하나라도 SKIP / 잔여 리스크 명시** (예: chrome SKIP, codex 자율통과 finding 의 잔여 리스크) → `Submit for QA` → `READY FOR QA`. 사용자가 수동 QA 로 보강해야 한다는 신호.
  - **N/A 와 SKIP 의 차이**: `/test chrome` 이 변경 영역에 UI 매핑 0건으로 자동 N/A 처리된 경우는 PASS 와 동일하게 Mark Done 진로. `/test chrome` 이 환경 의존(dev 서버 / Chrome MCP) 미가용으로 SKIP 된 경우는 READY FOR QA 진로. Codex 도 동일 — chore allowlist auto-pass + **`codexReview.enabled=false` (= N/A by config) 는 PASS 효력**, 잔여 리스크 아님.
  - **`/push` 가 사이클 컨텍스트 없이 호출된 경우 (= 8a 요약 부재)**: 안전을 위해 기본값 `Submit for QA` → `READY FOR QA`. Mark Done 경로는 (a) 사용자 명시 (`"QA 생략"`) 또는 (b) 동일 세션에서 3중 리뷰가 실제로 수행된 증거가 있을 때만 진입.
  - 사용자가 명시적으로 "QA 생략 후 바로 Done" 또는 반대로 "QA 게이트 유지" 를 요청하면 그 명시를 우선.
- transition 이후 `addCommentToJiraIssue` 로 PR URL + 머지 커밋 sha + 분기 결과 (`상태 전환: Mark Done (사유: <PASS 또는 N/A 사유>)` 또는 `상태 전환: Submit for QA (사유: <skip 항목 또는 "no-cycle-evidence">)`) 기록. N/A 가 포함된 경우 사유는 반드시 명시 (예: `Mark Done (사유: /test chrome N/A — docs+슬래시 명세 only)`).

**chore 모드**
- 이 단계 전체 스킵 (연결된 티켓 없음).

## 주의사항
- `{baseBranch}` / `main` 에 직접 push 하지 말 것 (두 모드 공통)
- main repo root 에서 호출되고 변경사항이 있으면 `/push` 는 브랜치를 만들지 않고 하드 스탑한다.
- PR 머지 전 충돌이 있으면 사용자에게 알리고 중단
- `--force` push 는 절대 사용하지 말 것
- PR 머지를 티켓 완료로 취급하지 말 것 — `Done` 전환은 QA 통과 또는 유저 명시 후에만
- chore 모드는 운영 메타 정리에 한정. 앱 코드/DB 스키마/API 계약이 포함된 변경은 기본 모드로.
- Worktree cleanup 단계에서 uncommitted 변경을 자동 삭제·덮어쓰기 하지 말 것.
