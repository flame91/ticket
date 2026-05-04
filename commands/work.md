# /work — 작업용 sibling worktree 생성

새 작업을 시작할 때 main repo 를 건드리지 않도록 별도 worktree 를 만들어 분리한다. 평문 작업 요청 / chore 정리 / 실험성 브랜치 등에 사용. JIRA 티켓이 있는 기능·버그 작업은 보통 `/ticket <KEY-n>` 이 상위 래퍼로 이 역할을 대체한다.

## Step 0: 프로젝트 설정 로드

Read `.claude/project.json` from the repo root. 존재하지 않으면 기본값 사용:
- `project.repoSlug`: `$(basename "$(git rev-parse --show-toplevel)")`
- `git.baseBranch`: `"main"`
- `jira.enabled`: `false`
- `jira.projectKey`: `null`

이하 `{repoSlug}`, `{baseBranch}`, `{projectKey}` 는 위에서 로드한 값을 참조한다.

## 인자

- `/work <slug>` — 티켓 번호가 없는 일반 작업용. 기본 브랜치명: `chore/<slug>`. Claude 판단으로 `feat/{projectKey}-<n>-<slug>` · `fix/{projectKey}-<n>-<slug>` 가 더 맞다고 보면 사용자에게 확인 후 해당 규칙 사용.
- slug 규칙: ASCII kebab-case, ≤ 5 단어. 예: `remove-discord-bot`, `tune-nearby-cache`, `audit-oauth-flow`.

## 실행 순서

### 1. 입력 검증
- slug 가 비어 있거나 비-ASCII 거나 6 단어 이상이면 중단하고 규칙 안내.
- `jira.enabled` 이고 slug 가 `{projectKey}-<n>` 만 포함하면 "`/ticket <{projectKey}-n>` 을 쓰세요" 로 리다이렉트.

### 2. 현재 상태 파악 (병렬)
- `git rev-parse --show-toplevel` — main repo 루트.
- `git status --short` — dirty 여부.
- `git branch --show-current` — 현재 브랜치.
- `git worktree list --porcelain` — 기존 worktree 목록.
- `git fetch origin --quiet` — `{baseBranch}` 최신 참조 확보.

### 3. 브랜치명 결정
- `chore/<slug>` 기본.
- `jira.enabled` 이고 대화 맥락에서 티켓이 확정되어 있으면 `feat/{projectKey}-<n>-<slug>` 또는 `fix/{projectKey}-<n>-<slug>` 로 바꿀지 사용자에게 한 번 확인.
- `main` / `{baseBranch}` / 예약 프리픽스 (`feat/` 없이 `{projectKey}-<n>` 만 등) 은 거부.

### 4. Worktree 경로 결정
- `<repo-root>/../{repoSlug}-<slug>` 로 정규화.
- 해당 경로가 이미 존재하면:
  - 존재하는 쪽이 이미 worktree 로 등록됐으면 "기존 worktree 로 이동하세요" 안내 후 중단.
  - 디렉토리만 있는 고아 경로면 "`git worktree prune` 후 재시도" 안내 후 중단. 자동 삭제 금지.

### 5. dirty working tree 처리
- main repo 에 uncommitted 변경이 있으면 **하드 스탑**. 새 worktree 는 `origin/{baseBranch}` 기준으로 생성되므로 main repo 의 변경은 자동으로 따라가지 않는다. silent 진행은 변경을 main repo 에 남긴 채 새 worktree 로 분기하는 위험한 상태를 만든다.
  - 사용자에게 다음 중 하나를 먼저 수행한 뒤 `/work <slug>` 를 재실행하도록 안내:
    - (a) 변경을 새 worktree 로 옮기고 싶으면 **pathspec-scoped stash**: `git stash push -u -m "pre-work-<slug>" -- <옮길 파일 경로…>` → `/work <slug>` → 완료 보고의 cwd 로 이동 후 `git stash pop` 으로 복원. **경고**: `-- <pathspec>` 없이 `git stash push -u` 를 하면 repo-global 로 저장되어 `stash pop` 시 무관한 변경까지 새 브랜치에 따라 들어간다. mixed scope 일 때는 반드시 pathspec 으로 좁힐 것.
    - (b) 변경을 main repo 와 무관한 다른 브랜치로 넘기려면: 그 브랜치 worktree 로 이동해서 커밋 후 재실행 (가장 안전한 경로).
    - (c) 명백히 버릴 수 있는 변경이면: `git restore` / `git clean` 으로 정리 후 재실행.
  - Claude 가 사용자 동의 없이 stash / restore / clean 을 자동 수행하지 말 것. 특히 unscoped `stash -u` 는 mixed scope 오염 위험이 커서 사용자 확인 없이 권장하지 않는다.

### 6. Worktree 생성
- 브랜치가 이미 로컬/원격에 존재하면 블로커 보고 후 중단 (재사용 위험).
- 실행: `git worktree add -b <branch> <path> origin/{baseBranch}` (옵션은 positional `<path>` 앞).
- 실패 시 stderr 원문 그대로 전달.

### 7. 완료 보고
- 다음을 한 블록으로 출력:
  - 새 worktree 절대 경로.
  - 브랜치명.
  - 다음 턴부터 사용할 cwd 안내 (`cd <path>`).
  - step 5 를 stash 경유로 돌파해 왔다면 "새 cwd 에서 `git stash pop` 으로 복원" 메모.
- 이 커맨드 자체는 cwd 를 바꾸지 않는다. Claude 는 다음 작업부터 Bash 에서 `cd <path> && ...` 형식으로 새 worktree 를 쓴다.

## 주의사항

- 이 커맨드는 읽기·쓰기 모두 **현재 main repo root 에서만** 실행한다. 이미 다른 worktree 내부라면 "main repo 로 이동 후 재실행" 안내 후 중단.
- 경로 충돌·브랜치 충돌·dirty 상태는 자동 덮어쓰지 않는다 — 전부 사용자 확인 포함 블로커 보고.
- 새 worktree 생성 직후 `/push` 로 넘어가기 전까지 main repo 에는 손대지 말 것.
- worktree 제거는 `/push` 머지 단계가 자동으로 수행한다. 여기서는 생성만 담당.
