# § cycle — 단일 티켓 구현→머지 사이클 (내부 참조 전용)

## 입력 계약

| 필드 | 내용 |
|------|------|
| `ticket_snapshot` | `{key, summary, done_criteria, out_of_scope, verification}` |
| `worktree` | `{cwd, branch, head_sha}` — sibling worktree 절대경로 |
| `role_hint` | 역할 문서 경로 (optional, § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md 의 owner 에서 도출) |
| `config` | § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md 에서 로드한 설정 전체 |

## 사이클 상태 변수 (메모리 — 사이클 시작 시 초기화)

| 변수 | 초기값 | 용도 |
|------|------|------|
| `_cycle_corrections` | `[]` | 사이클 중 발생한 수정사항 누적. 각 항목 `{step, attempt, what, why}`. step 11 코멘트에 한 단락으로 합쳐 첨부. |
| `_cycle_evidence_dir` | `null` | Phase 2 진입 시 `mktemp -d -t "techo-evidence-{key}-XXXXXX"` 로 1회 생성. `/test chrome` 스크린샷·Lighthouse 보고서가 모두 이 경로 안에 누적. step 11 에서 PNG 일괄 업로드 후 step 12 에서 정리. |
| `_cycle_dev_pid` | `null` | (기존) Phase 2 dev 서버 PID. |

---

## Phase 1 — 구현 + 코드 검증 (병렬 가능)

병렬 모드(`--par`)에서 N개 티켓을 동시 실행할 수 있는 구간. 각 에이전트는 자신의 worktree 안에서만 작업.

### 1. Start work transition

티켓이 `To Do` 면 `getTransitionsForJiraIssue` → `transitionJiraIssue` (name="Start work") → `In Progress`. 이미 `In Progress` 면 스킵.

### 2. impl-coder 서브에이전트 위임

`Task(subagent_type="impl-coder", prompt=<입력 계약>)`:
- 티켓 스냅샷: `ticket_snapshot` 그대로 (서브에이전트 재조회 금지)
- Worktree 상태: `worktree`
- `mode: "initial"`
- 역할 문서 힌트: `role_hint` (실존 파일이면 경로 전달)
- `{skillKarpathy}` 가 `true` 면 프롬프트에 `apply_skill_guidelines: "karpathy"` 추가 — impl-coder 가 `andrej-karpathy-skills:karpathy-guidelines` 적용 (surgical 변경, no overcomplication, 검증 가능 성공 기준 명시).

blocker 보고 시 → Phase 1 을 `{status: "blocked", reason: <blocker>}` 로 종료.

### 3. /test — 코드 레벨 리그레션

- `{regression}` 설정 시 해당 스크립트 실행.
- 없으면 프로젝트 테스트 프레임워크 자동 감지 (pytest, jest, vitest).
- **실패 시**: impl-coder 에게 수정 위임 (`mode: "reflect-test-failure"`) 후 재시도. 위임 결과 받은 즉시 `_cycle_corrections.append({step: "test", attempt: N, what: "<impl-coder notes 의 한 줄 요약>", why: "<실패한 테스트 케이스 / 증상>"})`.
- **1차 재시도도 실패 시 (= 두 번째 fail)**: `{skillDiagnose}` 가 `true` 이고 마지막 재시도(2차)가 남아 있으면, 2차 재시도 직전에 `Skill(name="diagnose")` 또는 `/diagnose` 호출하여 root cause 가설 산출. 가설 본문을 다음 reflect-test-failure 위임의 입력에 `diagnostic_hypothesis` 필드로 첨부 → impl-coder 가 가설 기반으로 마지막 수정 시도. correction 항목의 `why` 에 `diagnose: <가설 한 줄>` 도 함께 기록.
- **재시도 2회 실패 시**: `{status: "blocked", reason: <regression 로그> + (diagnose 산출물 있으면 summary)}` 로 종료.

### Phase 1 출력

```json
{
  "status": "ready" | "blocked",
  "reason": null | "<blocker 상세>",
  "files_changed": ["path/a.ts", "path/b.py"],
  "head_sha": "abc1234"
}
```

---

## Phase 2 — 브라우저 검증 + 배포 (순차 전용)

Phase 1 이 `"ready"` 인 티켓만 진입. 병렬 모드에서도 이 구간은 한 번에 한 티켓씩.

**Phase 2 불변식 — dev 서버 정리:** 이 구간에서 dev 서버를 기동한 경우, 종료 시점(정상·하드 스탑 어느 경우든)에 반드시 `kill $_cycle_dev_pid && wait` 실행. step 12 에서 수행하되, 하드 스탑 경로에서도 동일.

**Phase 2 진입 시 evidence 디렉토리 생성:** Phase 2 의 첫 substep (4a) 직전에 `_cycle_evidence_dir = $(mktemp -d -t "techo-evidence-{ticket_snapshot.key}-XXXXXX")` 1회 실행. 이 경로를 `/test chrome` 의 `EVIDENCE_DIR` 환경변수로 노출 (`export EVIDENCE_DIR="$_cycle_evidence_dir"`) 하여 chrome.md step 0 의 mktemp 대신 이 경로를 재사용하도록. step 11 에서 PNG 일괄 업로드, step 12 에서 정리.

### 4a. Dev 서버 기동 (자동 워크플로 전용)

> 호출측이 `/ticket*` 일 때만 실행. 사용자가 `/test chrome` 을 직접 호출한 경우 이 substep 은 존재하지 않는다 (chrome.md 의 하드 스탑 규칙이 적용).

1. **Chrome DevTools MCP 확인** — `mcp__chrome-devtools__list_pages` 호출. 실패 → 4a 전체 스킵 (사유: "Chrome DevTools MCP 미연결").
2. **기존 서버 확인** — `curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ja`. 200 → `_cycle_dev_pid = null` (외부 기동), **4b 로 진행.**
3. **포트 충돌 확인** — `lsof -ti :3000`. PID 존재 → 4a 스킵 (사유: "포트 3000 점유 (PID N) — 200 미응답. 수동 확인 필요").
4. **의존성 확인** — `[ -x "{worktree.cwd}/frontend/node_modules/.bin/next" ]`. 없으면 `( cd "{worktree.cwd}/frontend" && npm ci )`. 실패 → 4a 스킵 (사유: "npm ci 실패").
5. **기동** — `cd "{worktree.cwd}/frontend" && NEXT_PUBLIC_API_URL=/api NEXT_PUBLIC_BACKEND_URL=http://localhost:8000 API_INTERNAL_URL=http://localhost:8000 npm run dev &` PID 를 `_cycle_dev_pid` 에 기록.
6. **Ready 폴링** — 5초 간격, 최대 60초. 200 수신 → **4b 로 진행.** 60초 초과 → `kill $_cycle_dev_pid; wait`. `_cycle_dev_pid = null`. 4a 스킵 (사유: "dev 서버 60초 내 미응답").

### 4b. /test chrome — 브라우저 검증 (필수 단계, 조건부 N/A · SKIP)

**이 단계는 Phase 2 의 필수 구성이다. 에이전트가 자율적으로 생략하지 말 것.** diff 분석 → 4a 결과 순서로 분기한다.

**N/A 자동 판정 (4a 보다 우선, 두 조건 AND):** N/A 는 다음 두 조건이 **모두** 충족될 때만 적용. 하나라도 미충족이면 N/A 가 아니다 — 정상 가용 판정으로 진행.

1. **chore allowlist 내부**: `git diff --name-only origin/{baseBranch}..HEAD` 결과의 **모든** 파일이 `{choreAllowList}` (기본 `["docs/", ".claude/", ".github/"]`, 프로젝트 설정으로 확장 가능) 내부 경로에 매치. allowlist 밖 파일이 1개라도 있으면 N/A 아님.
2. **UI 매핑 0건**: chrome.md "diff → 페이지 매핑" 의 UI 경로 (`app/[locale]/`, `components/`, `messages/`, `lib/api.ts`, `globals.css`) 와 매치 0건.

두 조건 AND 충족 → **N/A 처리** — `/test chrome` 미실행, 4a 스킵, dev 서버 기동 시도도 안 함. Phase 2 로그에 "`/test chrome` N/A: 변경이 chore allowlist 내부 + UI 매핑 0건 (변경 파일: <대표 경로 1-2개>)" 명시. **N/A 는 SKIP 과 다르다 — 검증 대상 자체가 부재한 의도된 상태이며 잔여 리스크로 분류하지 않는다.**

**보수적 판정**: backend 라우터, DB 스키마, auth/세션, 런타임 config, API 계약이 변경됐는데 UI 매핑만 0건인 경우는 N/A 가 아니다 — chore allowlist 외부이므로 첫 조건에서 탈락. 이 보수성이 codex 의 "absence-of-evidence shipping" 위험을 막는다.

**N/A 가 아닌 경우, 가용 판정**: dev 서버(http://localhost:3000/ja == 200) + Chrome DevTools MCP(list_pages) 양쪽 모두 응답.

- **가용**: `/test chrome` 실행 (`EVIDENCE_DIR=$_cycle_evidence_dir` 노출 — chrome.md step 0 의 mktemp 대신 이 경로 사용). scope 는 diff 기반 자동 판정. FAIL 시 impl-coder 수정 위임 → step 3 부터 재시도. 위임 결과 받은 즉시 `_cycle_corrections.append({step: "test-chrome", attempt: N, what: "<수정 한 줄 요약>", why: "<페이지·증상: 예 'home/콘솔 Failed to fetch'>"})`. 재시도 실패 시 **하드 스탑** + 티켓 코멘트. 하드 스탑 전에 `_cycle_dev_pid` 정리.
- **불가** (4a 스킵됨): 반드시 "⚠ /test chrome SKIP: <4a 사유>" 를 Phase 2 로그에 명시 기록. 잔여 리스크로 최종 보고에도 포함.

**Evidence 스크린샷:** chrome.md step 5 의 "실패 evidence 스크린샷이 있으면 take_screenshot 으로 temp 에 저장" 가 `$EVIDENCE_DIR` 로 떨어지므로 별도 작업 불필요. 추가로 PASS 케이스에도 최종 상태 1장씩 (페이지별) 저장하도록 chrome.md 호출 시 `--evidence=always` 같은 힌트 전달하거나, /test chrome 결과 처리 후 cycle 측에서 직접 `mcp__chrome-devtools__take_screenshot` 호출하여 `${EVIDENCE_DIR}/<page>-final.png` 로 저장. 첨부 대상 결정 규칙: PASS 면 final 1장/페이지, FAIL 면 fail 시점 + 수정 후 final 모두.

**FAIL 재시도 시:** impl-coder 수정 → step 3 재실행 후 4b 재진입 시, `_cycle_dev_pid` 가 살아 있으면 서버 유지. 죽어 있으면 4a 부터 재실행.

### 5. 커밋

관련 변경만 스테이지 (`.env`·시크릿·무관 생성 파일 제외).

`{skillSimplify}` 가 `true` 면 `git add` 직후·`git commit` 직전에 staged diff 에 대해 `Skill(name="simplify")` 또는 `/simplify` 호출 → 재사용 누락·과도 추상화·죽은 코드 발견 시 자동 수정. 수정이 일어났으면 다시 stage 하고 진행. 수정 없으면 그대로 commit. 시간 비용이 크니 OFF 가 기본.

- 제목: `<type>: <what> ({projectKey}-<n>)`
- 트레일러: `Co-Authored-By: Claude <noreply@anthropic.com>`

### 6. Codex 교차리뷰

> `{codexReviewEnabled}` 가 `false` 면 스킵 → step 7.

`push.md` 섹션 5 를 정본으로 참조. Exit code 별 처리:
- **0**: 다음 단계.
- **1**: impl-coder 에게 반영 위임 (`mode: "reflect-exit1"`). 새 커밋 후 재실행. 위임 결과 받은 즉시 `_cycle_corrections.append({step: "codex-review", attempt: N, what: "<반영한 finding 한 줄 요약 — 예 'critical: SQL injection 방어 추가'>", why: "codex exit 1 (streak=0)"})`.
- **5**: 메인(opus) 직접 전략 수립 → impl-coder 재구현 위임. `_cycle_corrections.append({step: "codex-review", attempt: N, what: "<opus 전략 한 줄 — 예 'opus_remodel: 권한 체크 레이어 분리'>", why: "codex exit 5 (streak≥1)"})`.
- **4**: 유저 결정 필요, **하드 스탑**.
- **2/3**: 인프라 오류, **하드 스탑**.

### 7. 푸시

`git push -u origin <branch>`

### 8. PR 생성

`gh pr create --base {baseBranch} --title "<커밋 제목>" --body "Refs: {projectKey}-<n>..."`

### 8a. 검증 요약 리포트 (사용자 향)

PR 생성 직후, 머지 전에 **사용자가 읽을 수 있도록** 이번 사이클에서 수행한 검증 결과를 한 블록으로 출력한다. 자동 루프(`/ticket:auto`, `/ticket:batch`) 에서도 생략하지 말 것 — 사용자가 돌아와서 확인하는 첫 지점이 여기다.

```
── {projectKey}-<n> 검증 요약 ──
/test:        PASS (86/86) | FAIL (2 실패, 재시도 후 PASS) | N/A (변경이 회귀 매핑 무관 — 예 docs-only / .claude/ 전용) | ⚠ SKIP: <사유>
/test chrome: PASS (home, detail) | FAIL → 수정 → PASS | N/A (변경 영역에 UI 매핑 0건) | ⚠ SKIP: dev 서버 미실행
codex review: PASS (exit 0) | 반영 1회 (exit 1 → reflect) | PASS (chore allowlist auto) | N/A (codexReview.enabled=false)
PR:           #<n> (<PR URL>)
잔여 리스크:  없음 | /test chrome SKIP — 수동 브라우저 검증 권장
───────────────────────────────
```

각 행은 실제 결과로 채운다. 상태 어휘: `PASS` (실행됨, 통과), `FAIL → 수정 → PASS` (재시도 후 통과), `N/A (사유)` (의도된 비대상 — `/test chrome` 은 4b 자동 판정, `/test` 는 프로젝트 regression 스크립트가 auto 모드에서 변경 영역에 회귀 매핑 0건으로 판정한 경우 — 예 docs-only / `.claude/` 전용), `⚠ SKIP: <사유>` (환경 의존 미실행). N/A 와 SKIP 은 다르다 — N/A 는 잔여 리스크 아님, SKIP 은 잔여 리스크. 잔여 리스크가 있으면 마지막 행에 집약.

### 9. 머지

`gh pr merge --squash --delete-branch`. 충돌 시 **하드 스탑** (PR 링크 보고, `--force` 금지).

### 10. JIRA 상태 전환

8a 검증 요약 기준 분기. 솔로 워크플로에서는 `/test` + `/test chrome` + Codex 교차리뷰가 모두 통과 (또는 비대상으로 N/A) 한 시점에 같은 코드를 같은 사람이 한 번 더 보는 READY FOR QA 게이트는 추가 효용이 거의 없으므로 우회한다. 단, 어느 한 단계라도 환경 의존으로 SKIP 되거나 잔여 리스크가 명시된 경우는 사용자 수동 QA 신호로 READY FOR QA 에 남긴다.

- **모두 PASS / N/A + 잔여 리스크 없음** → `Mark Done` → `Done`.
  - 판정 조건: `/test` **PASS 또는 N/A** (재시도 후 PASS 포함, 또는 regression 스크립트가 auto 모드에서 변경 영역에 회귀 매핑 0건으로 판정 — 예 docs-only / `.claude/` 전용), `/test chrome` **PASS 또는 N/A** (= 4b 자동 판정으로 변경 영역에 UI 매핑 0건), Codex review **exit 0 / chore allowlist auto-pass / `{codexReviewEnabled}=false` (= N/A by config)**, 8a 의 "잔여 리스크" 행이 "없음" 또는 비어 있음.
- **하나라도 SKIP / 잔여 리스크 명시** → `Submit for QA` → `READY FOR QA`.
  - 트리거 예: `/test chrome` SKIP (dev 서버 미기동 / WSL WebGL 미지원 등 — 환경 의존 미실행), Codex 자율 통과 finding 이 잔여 리스크로 명시된 경우, 사용자 향 변경에 a11y 미감사 등. **`{codexReviewEnabled}=false` 는 SKIP 이 아니라 N/A 로 취급** (의도된 비대상, 잔여 리스크 아님).
- **N/A 와 SKIP 의 차이 (핵심)**: N/A 는 검증 대상이 변경 영역에 0건이거나 설정상 의도적으로 끈 상태 — 자동/설정 판정, PASS 와 동일하게 Mark Done 진로. SKIP 은 환경/도구 미가용으로 실행 못한 상태 — 운영자 수동 QA 요구 신호로 READY FOR QA 진로. 이 구분은 release 게이트의 신뢰성을 결정하므로 N/A 사유는 8a 요약과 step 11 코멘트 양쪽에 반드시 명시 (예: `codex review: N/A (codexReview.enabled=false)`).

`getTransitionsForJiraIssue` 응답에서 transition id 는 이름으로 매칭. transition 실패 시 코멘트로 블로커 기록 후 진행 중단. 분기 판정은 step 11 의 `검증 요약` 코멘트 본문에도 한 줄로 명시 (`상태 전환: Mark Done` / `상태 전환: Submit for QA (사유: <skip 항목>)`).

### 11. 증거 코멘트 + 스크린샷 첨부

**11a. JIRA 코멘트 본문 작성:** `addCommentToJiraIssue` 본문에 다음 섹션 순서로 합쳐 한 번에 등록:

1. **검증 요약** (필수): PR URL, 머지 commit sha, regression 모드·결과, 브라우저 검증 결과 (PASS/FAIL/스킵).
2. **사이클 중 수정사항** (조건부): `_cycle_corrections` 가 비어 있지 않으면 `## 사이클 중 수정사항` 섹션 추가. 각 항목을 한 줄로 렌더 — `- [<step>] attempt N: <what> (사유: <why>)`. step 분류: `test` / `test-chrome` / `codex-review`. 비어 있으면 섹션 자체 생략 (한 번도 재시도 없이 통과한 경우).
3. **첨부된 스크린샷** (조건부): step 11b 에서 업로드 성공한 파일이 있으면 `## 첨부 스크린샷` 섹션 추가하여 파일명 목록 명시 (JIRA UI 의 attachment 패널과 함께 보기 위함). 본문 안에 인라인 미리보기 원하면 `!<filename>|thumbnail!` (JIRA wiki markup) 또는 `[^<filename>]` (ADF reference) 사용.
4. **release-notes** (조건부): `{skillReleaseNotes}` 가 `true` 이고 티켓 라벨에 `user-facing` 또는 `release-impacting` 이 포함되어 있으면 `## 사용자 향 변경 요약` 섹션 추가, `Skill(name="pm-execution:release-notes")` 산출물 한 단락 첨부.

**11b. 스크린샷 첨부 (조건부 — `{jiraAttachmentEnabled}` 가 `true` 일 때):**

`_cycle_evidence_dir` 안의 `*.png` (있으면 `*.html` Lighthouse 보고서 포함) 을 JIRA REST API 로 업로드. Rovo MCP 가 attachment 도구를 노출 안 하므로 `curl` 직접 호출.

```bash
TOKEN=$(cat "${jiraAttachmentTokenFile/#\~/$HOME}")  # ~ 확장
[ -z "$TOKEN" ] && echo "⚠ JIRA token 없음 — 첨부 스킵" && return
shopt -s nullglob
for f in "$_cycle_evidence_dir"/*.png "$_cycle_evidence_dir"/*.html; do
  [ -f "$f" ] || continue
  curl -sS -X POST \
    -u "${jiraAttachmentEmail}:${TOKEN}" \
    -H "X-Atlassian-Token: no-check" \
    -H "Accept: application/json" \
    -F "file=@${f}" \
    "https://${cloudId}/rest/api/3/issue/${ticket_snapshot.key}/attachments" \
    > /tmp/jira-attach-$$.log 2>&1 \
    && echo "uploaded: $(basename "$f")" \
    || { echo "⚠ upload 실패: $(basename "$f") — $(tail -1 /tmp/jira-attach-$$.log)"; }
done
rm -f /tmp/jira-attach-$$.log
```

업로드 성공 파일 목록은 step 11a 의 `## 첨부 스크린샷` 섹션 입력으로 사용. 토큰 미설정·`{jiraAttachmentEnabled}` false·디렉토리 비어 있으면 조용히 스킵하고 코멘트 본문에서도 해당 섹션 제외.

> **토큰 셋업 (1회)**: 사용자가 https://id.atlassian.com/manage-profile/security/api-tokens 에서 토큰 생성 → `mkdir -p ~/.config/jira && echo '<token>' > ~/.config/jira/api-token && chmod 600 ~/.config/jira/api-token` → `.claude/project.json` 의 `jira.attachmentApi` 설정 (`enabled:true`, `userEmail`, `tokenFile`). § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_config.md 의 `jira.attachmentApi` 섹션 참조.

**11c. GitHub PR 증거 코멘트 (조건부 — `{githubEvidenceEnabled}` 가 `true` 일 때):**

같은 evidence dir 의 파일을 GitHub PR 코멘트로도 게시. binary 를 PR 브랜치(=develop 머지 대상)에 직접 commit 하면 squash 머지 시 develop 에 binary 가 섞이므로, **별도 orphan 브랜치 `evidence/{key}-{short_sha}`** 에 push 후 raw URL 로 참조한다. 머지 시 `--delete-branch` 는 PR 자체 브랜치만 지우므로 evidence 브랜치는 보존됨.

```bash
[ -d "$_cycle_evidence_dir" ] || return
shopt -s nullglob
files=("$_cycle_evidence_dir"/*.png "$_cycle_evidence_dir"/*.html)
[ ${#files[@]} -eq 0 ] && return

REMOTE_URL=$(git -C "{worktree.cwd}" remote get-url origin)
OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
SHORT_SHA="${head_sha:0:7}"
EV_BRANCH="evidence/${ticket_snapshot.key}-${SHORT_SHA}"

# Orphan 브랜치 push — main repo / PR 브랜치 양쪽 다 안 건드림
EV_PUSH_TMP=$(mktemp -d -t "evidence-push-${ticket_snapshot.key}-XXXXXX")
(
  cd "$EV_PUSH_TMP"
  git init -q -b "$EV_BRANCH"
  git config user.email "${jiraAttachmentEmail:-noreply@anthropic.com}"
  git config user.name "Cycle evidence"
  cp "${files[@]}" .
  git add .
  git commit -q -m "evidence: ${ticket_snapshot.key} (${SHORT_SHA})"
  git push -q "$REMOTE_URL" "HEAD:refs/heads/$EV_BRANCH"
)
rm -rf "$EV_PUSH_TMP"

# PR 코멘트 본문 작성 (PNG 만 인라인, HTML 은 링크)
BODY="## Verification Evidence ($SHORT_SHA)"$'\n\n'
for f in "$_cycle_evidence_dir"/*.png; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  BODY+="![${name%.png}](https://raw.githubusercontent.com/${OWNER_REPO}/${EV_BRANCH}/${name})"$'\n'
done
for f in "$_cycle_evidence_dir"/*.html; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  BODY+="- [${name}](https://raw.githubusercontent.com/${OWNER_REPO}/${EV_BRANCH}/${name})"$'\n'
done
BODY+=$'\n'"JIRA: https://${cloudId}/browse/${ticket_snapshot.key}"

gh pr comment "$PR_NUMBER" --body "$BODY"
```

브랜치 명명 규칙 `evidence/{key}-{short_sha}` 로 같은 티켓 재시도 시 충돌 없이 누적. 주기적 청소는 사용자 책임 — `git push origin --delete $(git ls-remote --heads origin 'evidence/*' | awk '{print $2}' | sed 's|refs/heads/||')` 로 일괄 정리 가능.

`{githubEvidenceEnabled}` false·디렉토리 비어 있음·gh CLI 미인증 시 조용히 스킵. 11b (JIRA) 와 독립적 — 한쪽만 켜기/둘 다 켜기 모두 가능.

### 12. Worktree 정리

**Dev 서버 정리 (선행):** `_cycle_dev_pid` 가 non-null 이고 프로세스가 살아 있으면 `kill $_cycle_dev_pid; wait $_cycle_dev_pid 2>/dev/null` 실행. 정상 경로뿐 아니라 하드 스탑 시에도 반드시 수행.

**Evidence 디렉토리 정리:** `_cycle_evidence_dir` 가 non-null 이면 step 11 종료 후 (정상·하드 스탑 모두) `rm -rf "$_cycle_evidence_dir"` 로 정리. 업로드 실패한 파일이 있으면 정리 직전에 경로를 사용자에게 한 줄 보고하여 수동 회수 기회 제공.

§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_worktree.md "정리" 섹션 참조. uncommitted 확인 → `worktree remove` → `prune` → `fetch` → `pull`.
