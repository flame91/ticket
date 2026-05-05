# § config — 프로젝트 설정 로드 (내부 참조 전용)

Read `.claude/project.json` from the repo root. `jira.enabled` 가 `false` 이거나 파일이 없으면 "JIRA 미설정. `.claude/project.json` 에 `jira` 섹션을 추가하세요" 출력 후 종료.

## 변수 바인딩

| 변수 | 소스 | 기본값 |
|------|------|--------|
| `{cloudId}` | `jira.cloudId` | (필수) |
| `{projectKey}` | `jira.projectKey` | (필수) |
| `{epicIssueType}` | `jira.epicIssueType` | `"Epic"` |
| `{baseBranch}` | `git.baseBranch` | `"main"` |
| `{repoSlug}` | `project.repoSlug` | `$(basename "$(git rev-parse --show-toplevel)")` |
| `{roleDocDir}` | `agents.roleDocDir` | `".claude/agents"` |
| `{roleMapping}` | `agents.roleMapping` | `{}` |
| `{regression}` | `scripts.regression` | `null` (테스트 프레임워크 자동 감지) — `scripts.regression` 권장 패턴 섹션 참조 |
| `{codexReviewEnabled}` | `codexReview.enabled` | `false` |
| `{choreAllowList}` | `codexReview.choreAllowList` | `["docs/", ".claude/", ".github/"]` |
| `{maxConcurrent}` | `parallel.maxConcurrent` | `3` (최대 5) |
| `{skillKarpathy}` | `skillIntegration.karpathyGuidelinesInImpl` | `false` |
| `{skillDiagnose}` | `skillIntegration.diagnoseOnTestFail` | `false` |
| `{skillSimplify}` | `skillIntegration.simplifyBeforeCommit` | `false` |
| `{skillGrillDocs}` | `skillIntegration.grillWithDocsBeforeOrchestrator` | `false` |
| `{skillReleaseNotes}` | `skillIntegration.releaseNotesOnUserFacing` | `false` |
| `{jiraAttachmentEnabled}` | `jira.attachmentApi.enabled` | `false` |
| `{jiraAttachmentEmail}` | `jira.attachmentApi.userEmail` | (필수 if enabled) |
| `{jiraAttachmentTokenFile}` | `jira.attachmentApi.tokenFile` | (필수 if enabled) |
| `{githubEvidenceEnabled}` | `github.evidenceComment.enabled` | `false` |

## scripts.regression 권장 패턴

`scripts.regression` 의 default 값은 **인자 없이 호출했을 때** 변경 영역을 자체적으로 감지하여 적절한 회귀만 돌리는 형태가 권장된다 (예: `bash scripts/regression.sh` 가 내부에서 `git diff` 기반으로 frontend / backend / compose 등 영향 영역을 골라 실행, backend 가 걸리면 pytest/ruff 자동 포함). § ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md step 3 은 `{regression}` 을 인자 없이 그대로 실행하므로:

- 스크립트가 변경 영역에 회귀 매핑 0건이라고 판정 → exit 0 + 빈 결과. step 8a `/test` 행은 `N/A (사유)` 로 기록되며 step 10 분기에서 `Mark Done` 진로에 포함된다 (예: docs-only · `.claude/` 전용 변경).
- 강제로 모든 회귀를 돌리고 싶을 때를 위해 스크립트는 별도 인자 (예: `all` / `full`) 를 받는 것이 좋지만, **`scripts.regression` default 값 자체에는 인자를 넣지 말 것** — 인자 없는 호출이 cycle 의 자동 판정 경로다.

기존에 `bash scripts/regression.sh default` 등 명시 인자로 등록돼 있다면 인자를 제거하고 스크립트 측에서 인자 없는 호출을 auto 모드로 받도록 정리하는 것이 권장.

## skillIntegration 섹션

`.claude/project.json` 의 `skillIntegration` 객체로 `/ticket` 체인 안에서 자동 호출할 보조 스킬을 opt-in 한다. 모든 키 누락 시 false 폴백 — 신규 키 도입이 기존 프로젝트 동작에 영향 없음. 각 플래그의 효과:

| 플래그 | 발동 위치 | 효과 |
|---|---|---|
| `karpathyGuidelinesInImpl` | impl-coder 위임 (`§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 2) | 시스템 프롬프트에 `andrej-karpathy-skills:karpathy-guidelines` 참조 라인 주입. 가벼움. 기본 ON 권장. |
| `diagnoseOnTestFail` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 3 (테스트 실패) | 1차 재시도 실패 후, 2차 재시도 직전에 `/diagnose` 호출하여 root cause 가설 산출 → impl-coder reflect 입력에 첨부. |
| `simplifyBeforeCommit` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 5 (커밋) 직전 | staged diff 에 `/simplify` 호출 → 재사용 누락·과도 추상화 발견 시 자동 수정. 시간 비용 큼, 기본 OFF. |
| `grillWithDocsBeforeOrchestrator` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_orchestrator.md` step 1 (분류) | `invoking_command == "/ticket"` (수동 진입) 일 때만 `/grill-with-docs` 호출, 결과를 `reason` 보강 컨텍스트로 사용. `/ticket:auto`·`/ticket:batch` 에서는 무시. |
| `releaseNotesOnUserFacing` | `§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 11 (post-merge JIRA 코멘트) | 티켓 라벨에 `user-facing` 또는 `release-impacting` 있으면 `pm-execution:release-notes` 산출물 한 단락을 코멘트에 첨부. |

## jira.attachmentApi 섹션

`§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 11b 의 evidence 스크린샷 첨부에 필요. Atlassian Rovo MCP 가 attachment 도구를 노출하지 않으므로 REST API 직접 호출 (`curl`) 로 처리. 별도 토큰 셋업 필요.

| 키 | 의미 |
|---|---|
| `enabled` | true/false. false (기본) 면 step 11b 전체 스킵, 코멘트 본문에서도 스크린샷 섹션 제외. |
| `userEmail` | Atlassian 계정 이메일 (REST 인증의 사용자명). |
| `tokenFile` | API 토큰을 담은 파일 경로 (예: `~/.config/jira/api-token`). 토큰을 settings/project.json 에 직접 적지 말 것 (commit 위험). 파일 권한 600 권장. |

**1회 셋업:**
```bash
# 1. 토큰 발급: https://id.atlassian.com/manage-profile/security/api-tokens
# 2. 파일 저장
mkdir -p ~/.config/jira && echo '<token>' > ~/.config/jira/api-token && chmod 600 ~/.config/jira/api-token
# 3. .claude/project.json 에 jira.attachmentApi 추가:
#    { "jira": { ..., "attachmentApi": { "enabled": true, "userEmail": "you@example.com", "tokenFile": "~/.config/jira/api-token" } } }
```

## github.evidenceComment 섹션

`§ ${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/ticket/_cycle.md` step 11c — evidence 스크린샷을 GitHub PR 코멘트에 인라인 표시. JIRA 첨부와 독립이며 둘 다 켜도 무방.

| 키 | 의미 |
|---|---|
| `enabled` | true/false. false (기본) 면 step 11c 전체 스킵. |

작동 방식: PNG/HTML 파일을 별도 orphan 브랜치 `evidence/{key}-{short_sha}` 에 push 하고, raw.githubusercontent.com URL 로 PR 코멘트에 markdown 이미지 삽입. binary 가 develop 머지 대상 브랜치에 섞이지 않으므로 main history 오염 없음. 기존 git remote 인증 (gh CLI) 만 있으면 별도 셋업 불필요.

**별도 셋업 없음** — `.claude/project.json` 에 `github.evidenceComment.enabled: true` 한 줄만 추가:
```jsonc
{ "github": { "evidenceComment": { "enabled": true } } }
```

**주기적 청소** (선택): evidence 브랜치가 누적되므로 분기 1회 정리 권장.
```bash
git ls-remote --heads origin 'evidence/*' | awk '{print $2}' | sed 's|refs/heads/||' \
  | xargs -I {} git push origin --delete {}
```
