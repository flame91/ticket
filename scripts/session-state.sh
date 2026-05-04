#!/usr/bin/env bash
set -uo pipefail

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

dirty_files_raw=$(git status --porcelain 2>/dev/null || true)
if [[ -z "$dirty_files_raw" ]]; then
  dirty_files_json='[]'
  dirty_count=0
else
  dirty_files_json=$(printf '%s\n' "$dirty_files_raw" | jq -R . | jq -cs 'map(select(length > 0))')
  dirty_count=$(jq 'length' <<<"$dirty_files_json")
fi
if (( dirty_count > 0 )); then dirty=true; else dirty=false; fi

upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
ahead=0
behind=0
if [[ -n "$upstream" ]]; then
  counts=$(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || true)
  if [[ -n "$counts" ]]; then
    behind=$(awk '{print $1+0}' <<<"$counts")
    ahead=$(awk '{print $2+0}' <<<"$counts")
  fi
fi

worktree_porcelain=$(git worktree list --porcelain 2>/dev/null || true)
if [[ -z "$worktree_porcelain" ]]; then
  worktrees_json='[]'
else
  worktrees_json=$(printf '%s\n' "$worktree_porcelain" | python3 -c '
import json, sys
entries = []
current = None
for line in sys.stdin.read().splitlines():
    if line.startswith("worktree "):
        if current is not None:
            entries.append(current)
        current = {"path": line[len("worktree "):], "branch": None}
    elif line.startswith("branch refs/heads/") and current is not None:
        current["branch"] = line[len("branch refs/heads/"):]
    elif line.strip() == "detached" and current is not None:
        current["branch"] = "(detached)"
if current is not None:
    entries.append(current)
print(json.dumps(entries, ensure_ascii=False))
')
fi

cwd=$(pwd)

jq -cn \
  --arg branch "$branch" \
  --argjson dirty "$dirty" \
  --argjson dirty_count "$dirty_count" \
  --argjson dirty_files "$dirty_files_json" \
  --arg upstream "$upstream" \
  --argjson ahead "$ahead" \
  --argjson behind "$behind" \
  --argjson worktrees "$worktrees_json" \
  --arg cwd "$cwd" \
  '{
    branch: (if $branch == "" then null else $branch end),
    dirty: $dirty,
    dirty_count: $dirty_count,
    dirty_files: $dirty_files,
    upstream: (if $upstream == "" then null else $upstream end),
    ahead: $ahead,
    behind: $behind,
    worktrees: $worktrees,
    cwd: $cwd
  }'
