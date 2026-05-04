# § worktree — Worktree 생성/재개/정리 (내부 참조 전용)

main repo (repo-root) 는 언제나 `{baseBranch}` 를 유지. 모든 티켓 작업은 sibling worktree 에서 격리. 티켓 번호(`{projectKey}-<n>`) 기준 매칭 — slug 는 매칭 키가 아니다.

## 생성/재개

### 선행 스캔

```bash
git worktree list --porcelain
git branch --list 'feat/{projectKey}-<n>-*' 'fix/{projectKey}-<n>-*'
git ls-remote --heads origin 'feat/{projectKey}-<n>-*' 'fix/{projectKey}-<n>-*'
```

**local 집합** = worktree + local branch. **remote-only 집합** = origin 에만 존재. 양쪽에 같은 이름이면 local 로 카운트.

### 분기 판정

**distinct branch ≥ 2 (local + remote-only)** → **하드 스탑** (분열 상태, 사용자 확인 필요). 티켓 코멘트에 브랜치 목록 기록.

**local 집합 1 개** (정상 재개):
- worktree 등록됨 → `git status --short` 확인.
  - clean → 해당 경로 재사용.
  - dirty → **하드 스탑** (자동 삭제/커밋 금지). 사용자가 (a) 커밋, (b) `git stash push -u -m "pre-ticket-{projectKey}-<n>" -- <경로…>`, (c) `git restore`/`git clean` 중 하나로 정리 후 재실행.
- 고아 로컬 브랜치 → `git worktree add <repo-root>/../{repoSlug}-<existing-branch-without-prefix> <existing-branch>` 로 재부착 + clean 검증.

**local 0 + remote-only 1** → **하드 스탑** (타 머신/사람 가능성). `git fetch origin <branch> && git log origin/<branch> --pretty=oneline -5` 로 provenance 확인 안내. 사용자가 수동으로 `git worktree add --track -b <branch> <path> origin/<branch>` 후 재실행. 자동 adopt 금지.

**local 0 + remote-only 0** (완전 신규):
- 경로: `<repo-root>/../{repoSlug}-{projectKey}-<n>-<slug>` (slug ASCII kebab, ≤5단어).
- 해당 경로가 worktree 미등록 고아 디렉토리로 존재 → **하드 스탑** (`git worktree prune` 안내, 자동 삭제 금지).
- `git worktree add -b feat/{projectKey}-<n>-<slug> <path> origin/{baseBranch}` (버그 티켓은 `fix/`). 옵션은 positional `<path>` 앞.

### dirty 복구 시퀀스 (main repo dirty 시)

main repo 가 dirty 이면 **하드 스탑**. 사용자가 수동 실행:
1. `git stash push -u -m "pre-ticket-{projectKey}-<n>" -- <파일 경로…>` (pathspec-scoped)
2. worktree 생성 후 이동
3. `git stash pop`
4. 재실행

## 정리 (cleanup)

1. sibling worktree 에 uncommitted 변경 / stash 잔존 → **하드 스탑** (자동 삭제 금지).
2. main repo root 로 이동.
3. `git worktree remove <sibling-path>` → `git worktree prune` → `git fetch origin --prune`.
4. `git pull` (`{baseBranch}` 체크아웃 상태 전제).
