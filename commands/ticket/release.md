# /ticket:release — pre-release verification checklist

Run the §release-check workflow defined in `AGENTS.md` at the repo root. Read-only — no writes, no git operations.

After all 7 checks return OK, the maintainer applies the release manually:

```bash
git tag v$(jq -r .version .claude-plugin/plugin.json)
git push origin --tags
```

## Source

Ported from vocatrack's release-check (vocatrack/AGENTS.md §release-check). The 7 rules and their bash snippets live in this repo's AGENTS.md, mirroring vocatrack's location convention. The slash command is just an entry point.
