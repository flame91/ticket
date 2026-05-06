# /test chrome — Chrome DevTools MCP browser verification

$ARGUMENTS

Use the Chrome DevTools MCP tools to verify a frontend app's layout, accessibility, network requests, and console errors. This is the automation layer that complements the manual checklist in `docs/0406_REGRESSION_CHECKLIST.md`.

> **Tip:** For code-level regression tests, use `/test`. `/test chrome` is for verifying what is actually rendered in the browser.

## Scope selection

Parse the argument. If absent, auto-detect impacted pages from `git diff --name-only`.

| Argument | Target |
|------|------|
| (none) | auto-detect from diff (verifies both PC and SP) |
| `home` | `/[locale]/` (PC + SP) |
| `nearby` | `/[locale]/nearby` (PC + SP) |
| `bookmarks` | `/[locale]/bookmarks` (PC + SP) |
| `prefecture` | `/[locale]/[prefecture]/` (PC + SP) |
| `detail` | `/[locale]/[prefecture]/[id]` (PC + SP) |
| `search` | `/[locale]/search` (PC + SP) |
| `pc-only` | all pages, desktop viewport only (debug / quick check) |
| `sp-only` | all pages, mobile viewport only (debug / quick check) |
| `a11y` | all pages, Lighthouse accessibility audit |
| `full` | all pages, PC+SP, ja/en/ko, accessibility |

**Default policy: always verify both PC (desktop) and SP (mobile) viewports.** Skip one side only when `pc-only` / `sp-only` is explicit.

**diff → page mapping:**

- `components/home/` or `app/[locale]/page.tsx` → home
- `components/map/` or `app/[locale]/nearby/` → nearby
- `components/facility/` or `app/[locale]/bookmarks/` → bookmarks
- `app/[locale]/[prefecture]/[id]/` → detail
- `app/[locale]/[prefecture]/page.tsx` → prefecture
- `app/[locale]/search/` → search
- `components/layout/`, `lib/api.ts`, `globals.css` → full
- `messages/` → all pages, restricted to the changed locale

## Step 0 — Prerequisites

1. **dev server**: run `curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ja`. If not 200, **hard stop** — print "The dev server is not running. Start it first with `cd frontend && npm run dev` or `docker compose up -d`." and abort.
2. **browser connection**: call `mcp__chrome-devtools__list_pages`. On failure, **hard stop** — print "Cannot connect to Chrome DevTools MCP. Make sure Chrome is running with `--remote-debugging-port`." and abort.
3. **temp directory**: `mktemp -d -t "techo-chrome-XXXXXX"` — for screenshots / reports. Do not store inside the repo.

## Step 1 — Desktop (PC) verification (locale: ja)

Always run unless scope is `sp-only`. For each target page, run 1a–1d in order.

First set the desktop viewport:

```
mcp__chrome-devtools__emulate  viewport="1280x800x1"
```

### 1a. Navigate + load check

```
mcp__chrome-devtools__navigate_page  url=http://localhost:3000/ja{path}
```

Use `mcp__chrome-devtools__wait_for` to confirm the key text has loaded:
- home: category name or search placeholder
- nearby: "リスト" or "マップ"
- bookmarks: "ブックマーク" or login prompt
- prefecture: prefecture name
- detail: facility name
- search: search input field

### 1b. Accessibility tree snapshot

```
mcp__chrome-devtools__take_snapshot
```

Check the snapshot against the failure conditions in `docs/0406_REGRESSION_CHECKLIST.md`:

- **raw slug exposure**: internal enums like `mental`, `physical`, `public`, `sport` exposed without a label → FAIL
- **false counts**: on API failure, the UI must show fallback / unavailable, not "0件" / "0건"
- **a11y roles**: roles on key UI elements must be correct (button, link, navigation, tab)
- **locale consistency**: no leftover strings from a different locale

### 1c. Console error check

```
mcp__chrome-devtools__list_console_messages  types=["error","warn"]
```

- `error` level → **FAIL** (hydration-mismatch warnings and dev-only warnings may be noted as known issues)
- `Failed to fetch`, `NetworkError`, `CORS` messages → immediate **FAIL**
- `warn` level → report but not FAIL

### 1d. Network request check

```
mcp__chrome-devtools__list_network_requests  resourceTypes=["fetch","xhr"]
```

- 4xx / 5xx response → **FAIL**
- home: confirm requests to `/v1/prefectures/regions` and `/v1/facility-types`
- nearby: confirm `/v1/map/clusters` request includes `lat`, `lng`, `radius_km` parameters
- detail: confirm `/v1/facilities/{id}` request

## Step 2 — Mobile (SP) verification

Always run unless scope is `pc-only`. By default, SP verification must follow PC.

### 2a. Mobile emulation

```
mcp__chrome-devtools__emulate  viewport="390x844x3,mobile,touch"
```

### 2b. Re-verify each target page

Repeat steps 1a–1d. Additionally, in the snapshot:

- the bottom `MobileTabBar` does not occlude content
- nearby: radius toggle does not overlap the search input
- home: search placeholder has enough width
- screen is not blank after tab switch

### 2c. Restore desktop

```
mcp__chrome-devtools__emulate  viewport="1280x800x1"
```

> **Do not mark PASS based on only one of PC / SP.** Report the two viewports separately; if either fails, the overall verdict is FAIL.

## Step 3 — i18n verification

Run when scope is `full` or there are changes under `messages/`. Otherwise skip.

Targets: `en`, `ko` (`ja` is already covered by Step 1).

For each locale:
1. `navigate_page` → `http://localhost:3000/{locale}{path}`
2. `take_snapshot` → check the accessibility tree
3. Verdict: no leftover text from a previous locale; trigger / summary / preview strings match the current locale.

## Step 4 — Lighthouse accessibility audit

Run when scope is `a11y` or `full`. Otherwise skip.

```
mcp__chrome-devtools__lighthouse_audit  device="mobile"  mode="navigation"
```

- Accessibility < 90 → **FAIL**
- SEO < 80 → **WARN**
- Report every individual violation

Save the report file to the temp directory created in Step 0.

## Step 5 — Result summary

Print the final result in this format:

```
## /test chrome result

scope: <executed scope>
locale: <verified locales>
viewport: PC + SP (default) | PC only | SP only

### Per-page result

| page   | PC console | PC network | PC snapshot | SP console | SP network | SP snapshot | a11y | verdict |
|--------|------------|------------|-------------|------------|------------|-------------|------|---------|
| /ja/   | PASS       | PASS       | PASS        | PASS       | PASS       | PASS        | 92   | PASS    |

### Failure detail (if any)

- [FAIL] /ja/nearby — console error: "Failed to fetch /v1/map/clusters"

### Outstanding risk

- auth flow not verified (login required)
- save-then-revisit scenario not verified
```

Report the temp path on a single line. If you have failure-evidence screenshots, save them into temp via `take_screenshot`.

## Notes

- **PC + SP verification is the default.** Unless `pc-only` / `sp-only` is explicit, do not run only one side. Even if the diff looks backend-only, SP layout can be affected, so check both.
- Never proceed when the dev server is not running. Do not start it yourself.
- Prefer `take_snapshot` (accessibility tree). `take_screenshot` is for failure evidence only.
- Do not save screenshots / reports inside the repo. Use `mktemp -d -t "techo-chrome-XXXXXX"`.
- Do not close out a failed verification as "no problem". FAIL is FAIL.
- This skill complements `docs/0406_REGRESSION_CHECKLIST.md`, it does not replace it. Items that cannot be automated (save-then-revisit, location denial, etc.) must be listed as outstanding risk.
- For auth-required flows, only verify the unauthenticated fallback UI. Login automation is out of scope.
- **Auto workflow integration:** when invoked from `/ticket*`, dev server startup is handled in advance by `_cycle.md` step 4a. This skill itself does not start the server.
