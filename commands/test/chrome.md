# /test chrome — Chrome DevTools MCP 브라우저 검증

$ARGUMENTS

Chrome DevTools MCP 도구로 프론트엔드 앱의 레이아웃, 접근성, 네트워크 요청, 콘솔 에러를 검증한다. `docs/0406_REGRESSION_CHECKLIST.md` 수동 체크리스트의 자동화 보완 레이어.

> **Tip:** 코드 레벨 회귀 테스트는 `/test` 를 사용. `/test chrome` 은 브라우저에서 실제 렌더링된 결과를 검증하는 용도.

## 범위 결정

인자를 해석한다. 없으면 `git diff --name-only` 기반으로 영향받는 페이지를 자동 판정.

| 인자 | 대상 |
|------|------|
| (없음) | diff 기반 자동 판정 |
| `home` | `/[locale]/` |
| `nearby` | `/[locale]/nearby` |
| `bookmarks` | `/[locale]/bookmarks` |
| `prefecture` | `/[locale]/[prefecture]/` |
| `detail` | `/[locale]/[prefecture]/[id]` |
| `search` | `/[locale]/search` |
| `mobile` | 전 페이지, 모바일 뷰포트 |
| `a11y` | 전 페이지, Lighthouse 접근성 감사 |
| `full` | 전 페이지, 데스크톱+모바일, ja/en/ko, 접근성 |

**diff → 페이지 매핑:**

- `components/home/` 또는 `app/[locale]/page.tsx` → home
- `components/map/` 또는 `app/[locale]/nearby/` → nearby
- `components/facility/` 또는 `app/[locale]/bookmarks/` → bookmarks
- `app/[locale]/[prefecture]/[id]/` → detail
- `app/[locale]/[prefecture]/page.tsx` → prefecture
- `app/[locale]/search/` → search
- `components/layout/`, `lib/api.ts`, `globals.css` → full
- `messages/` → 변경된 locale 로 전 페이지

## Step 0 — 사전 조건 확인

1. **dev 서버**: `curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ja` 실행. 200 이 아니면 **하드 스탑** — "dev 서버가 실행 중이지 않습니다. `cd frontend && npm run dev` 또는 `docker compose up -d` 로 먼저 시작하세요." 안내 후 중단.
2. **브라우저 연결**: `mcp__chrome-devtools__list_pages` 호출. 실패하면 **하드 스탑** — "Chrome DevTools MCP 에 연결할 수 없습니다. Chrome 이 `--remote-debugging-port` 로 실행 중인지 확인하세요." 안내 후 중단.
3. **temp 디렉토리 생성**: `mktemp -d -t "techo-chrome-XXXXXX"` — 스크린샷/보고서 저장용. repo 안에 저장 금지.

## Step 1 — 데스크톱 검증 (locale: ja)

각 대상 페이지에 대해 1a~1d 를 순서대로 실행한다.

### 1a. 페이지 탐색 + 로드 확인

```
mcp__chrome-devtools__navigate_page  url=http://localhost:3000/ja{path}
```

`mcp__chrome-devtools__wait_for` 로 핵심 텍스트 로드를 확인:
- home: 카테고리명 또는 검색 placeholder
- nearby: "リスト" 또는 "マップ"
- bookmarks: "ブックマーク" 또는 로그인 안내
- prefecture: 도도부현명
- detail: 시설명
- search: 검색 입력 필드

### 1b. 접근성 트리 스냅샷

```
mcp__chrome-devtools__take_snapshot
```

스냅샷에서 `docs/0406_REGRESSION_CHECKLIST.md` 실패 조건을 검증:

- **raw slug 노출**: `mental`, `physical`, `public`, `sport` 등 내부 enum 이 라벨 없이 노출되면 FAIL
- **거짓 카운트**: API 실패 시 "0件"/"0건" 표시 대신 fallback/unavailable 이어야 함
- **접근성 역할**: 주요 UI 요소의 role 이 올바른지 (button, link, navigation, tab)
- **locale 일관성**: 현재 locale 과 맞지 않는 문자열 잔류 여부

### 1c. 콘솔 에러 확인

```
mcp__chrome-devtools__list_console_messages  types=["error","warn"]
```

- `error` 레벨 → **FAIL** (단, hydration mismatch 경고·개발 전용 경고는 known-issue 로 표기)
- `Failed to fetch`, `NetworkError`, `CORS` 메시지 → 즉시 **FAIL**
- `warn` 레벨 → 보고하되 FAIL 아님

### 1d. 네트워크 요청 확인

```
mcp__chrome-devtools__list_network_requests  resourceTypes=["fetch","xhr"]
```

- 4xx/5xx 응답 → **FAIL**
- home: `/v1/prefectures/regions`, `/v1/facility-types` 요청 존재 확인
- nearby: `/v1/map/clusters` 요청에 `lat`, `lng`, `radius_km` 파라미터 포함 확인
- detail: `/v1/facilities/{id}` 요청 존재 확인

## Step 2 — 모바일 검증

scope 가 `mobile`, `full` 이거나, diff 에 레이아웃/CSS 변경이 포함되면 실행. 아니면 스킵.

### 2a. 모바일 에뮬레이션 설정

```
mcp__chrome-devtools__emulate  viewport="390x844x3,mobile,touch"
```

### 2b. 각 대상 페이지 재검증

Step 1a~1d 반복. 추가로 스냅샷에서:

- 하단 `MobileTabBar` 가 콘텐츠를 가리지 않는지
- nearby: 반경 토글과 검색 입력 겹침 여부
- home: 검색 placeholder 가 충분한 폭 확보
- 탭 전환 후 빈 화면이 아닌지

### 2c. 데스크톱 복원

```
mcp__chrome-devtools__emulate  viewport="1280x800x1"
```

## Step 3 — 다국어 검증

scope 가 `full` 이거나 `messages/` 변경이 있으면 실행. 아니면 스킵.

대상: `en`, `ko` (ja 는 Step 1 완료).

각 locale 에 대해:
1. `navigate_page` → `http://localhost:3000/{locale}{path}`
2. `take_snapshot` → 접근성 트리 확인
3. 판정: 이전 locale 텍스트 잔류 없는지, trigger/summary/preview 문자열이 현재 locale 과 일치하는지

## Step 4 — Lighthouse 접근성 감사

scope 가 `a11y` 또는 `full` 이면 실행. 아니면 스킵.

```
mcp__chrome-devtools__lighthouse_audit  device="mobile"  mode="navigation"
```

- Accessibility < 90 → **FAIL**
- SEO < 80 → **WARN**
- 개별 violation 모두 보고

보고서 파일은 Step 0 에서 만든 temp 디렉토리에 저장.

## Step 5 — 결과 요약

아래 형식으로 최종 결과 출력:

```
## /test chrome 결과

scope: <실행 범위>
locale: <검증한 locale 목록>
viewport: <desktop | mobile | desktop+mobile>

### 페이지별 결과

| 페이지 | 콘솔 | 네트워크 | 스냅샷 | 모바일 | a11y | 판정 |
|--------|-------|----------|--------|--------|------|------|
| /ja/   | PASS  | PASS     | PASS   | PASS   | 92   | PASS |

### 실패 상세 (있을 경우)

- [FAIL] /ja/nearby — 콘솔 에러: "Failed to fetch /v1/map/clusters"

### 잔여 리스크

- 인증 흐름 미검증 (로그인 필요)
- 저장 후 재진입 시나리오 미검증
```

temp 경로를 한 줄로 보고. 실패 evidence 스크린샷이 있으면 `take_screenshot` 으로 temp 에 저장.

## 주의사항

- dev 서버 미실행 시 절대 진행 금지. 서버를 직접 시작하지도 말 것.
- `take_snapshot` (접근성 트리) 우선. `take_screenshot` 은 실패 evidence 용도만.
- 스크린샷/보고서는 repo 안에 저장 금지. `mktemp -d -t "techo-chrome-XXXXXX"` 사용.
- 검증 실패를 "문제 없음" 으로 마무리 금지. FAIL 은 명확히 FAIL.
- 이 스킬은 `docs/0406_REGRESSION_CHECKLIST.md` 의 보완이지 대체가 아니다. 자동화 불가 항목(저장 후 재진입, 위치 거부 등)은 잔여 리스크로 명시.
- 인증 필요 흐름은 미로그인 fallback UI 만 검증. 로그인 자동화는 범위 밖.
- **자동 워크플로 연동:** `/ticket*` 에서 호출 시, dev 서버 기동은 `_cycle.md` step 4a 가 사전 수행. 이 스킬 자체는 서버를 시작하지 않는다.
