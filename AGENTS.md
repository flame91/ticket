# AGENTS.md

Specialized workflows for the flow plugin repository (renamed from `ticket` in v0.2.0; GitHub repo URL is unchanged).

---

## release-check

**Description:** Pre-release verification checklist for the flow plugin.

**Steps:**

1. **Version match**: verify `plugin.json` version matches README version mentions
   ```bash
   grep '"version"' .claude-plugin/plugin.json
   grep -n 'version\|v0\.' README.md
   ```

2. **i18n key sync**: all `messages/*.tsv` files must have identical key sets
   ```bash
   diff <(cut -f1 messages/ko.tsv | sort) <(cut -f1 messages/en.tsv | sort)
   diff <(cut -f1 messages/ko.tsv | sort) <(cut -f1 messages/ja.tsv | sort)
   ```
   Skip with `N/A (no messages/)` if the directory is absent.

3. **No hardcoded user-scope paths in SKILL.md** (except `~/.claude/projects/`, the standard Claude Code session path)
   ```bash
   grep -rn '~/\.claude/' skills/*/SKILL.md | grep -v 'projects/'
   ```

4. **No hardcoded Korean in scripts**: grep for U+AC00-U+D7A3 outside comments
   ```bash
   grep -rn '[가-힣]' scripts/*.sh | grep -v '^\s*#'
   ```

5. **Command .md files use variable paths**: all command files should reference `${CLAUDE_PLUGIN_ROOT}` (not absolute paths)
   ```bash
   grep -rn '/home\|/Users\|~/\.claude' commands/
   ```

6. **CHANGELOG.md**: verify the new version has an entry in CHANGELOG.md
   ```bash
   VERSION=$(jq -r .version .claude-plugin/plugin.json)
   grep -q "\[$VERSION\]" CHANGELOG.md && echo "OK: CHANGELOG has $VERSION" || echo "MISSING: CHANGELOG entry for $VERSION"
   ```

7. **git status clean**: no uncommitted changes
   ```bash
   git status --porcelain
   ```

**Verdict:** all 7 OK → `READY TO RELEASE`. Any FAIL → `BLOCKED`.

This workflow is read-only. The maintainer applies the release (version bump, tag, push) manually after a green report.
