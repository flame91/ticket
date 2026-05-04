#!/usr/bin/env bash
# Install plugin contents as symlinks in ~/.claude (user-scope) for the home machine.
# This lets the home computer continue using the workflow as user-scope slash commands
# (immediate edit-in-place feedback) while the same files serve as the plugin source
# for a different machine that installs it via /plugin install.
#
# Idempotent. Existing real files are backed up to *.bak.<timestamp> before symlinking.
# Existing symlinks pointing elsewhere are replaced. Symlinks already pointing to the
# right place are left alone.
#
# Usage:
#   bash scripts/install-symlinks-home.sh           # apply
#   bash scripts/install-symlinks-home.sh --dry-run # preview only
#   bash scripts/install-symlinks-home.sh --rollback <timestamp>  # restore from backup

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_SCOPE="$HOME/.claude"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$USER_SCOPE/_backups/$TS"
DRY=0
ROLLBACK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --rollback) ROLLBACK="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's|^# \?||' | head -20
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Mapping: plugin-relative path -> user-scope-relative path
# Top-level files individually (so we don't symlink ~/.claude/commands itself)
declare -a MAPPINGS=(
  "commands/ticket.md            commands/ticket.md"
  "commands/ticket               commands/ticket"
  "commands/test.md              commands/test.md"
  "commands/test                 commands/test"
  "commands/work.md              commands/work.md"
  "commands/push.md              commands/push.md"
  "commands/review.md            commands/review.md"
  "agents/impl-coder.md          agents/impl-coder.md"
  "agents/qa-verifier.md         agents/qa-verifier.md"
  "agents/executive-orchestrator.md  agents/executive-orchestrator.md"
  "scripts/session-state.sh      scripts/session-state.sh"
  "skills/diagnose               skills/diagnose"
  "skills/grill-with-docs        skills/grill-with-docs"
)

if [[ -n "$ROLLBACK" ]]; then
  echo "── Rollback mode (timestamp=$ROLLBACK) ──"
  ROLL_ROOT="$USER_SCOPE/_backups/$ROLLBACK"
  if [[ ! -d "$ROLL_ROOT" ]]; then
    echo "no backup root at $ROLL_ROOT" >&2
    exit 1
  fi
  for entry in "${MAPPINGS[@]}"; do
    read -r src dst <<<"$entry"
    target="$USER_SCOPE/$dst"
    backup="$ROLL_ROOT/$dst"
    if [[ -e "$backup" || -L "$backup" ]]; then
      echo "restore: $target  ←  $backup"
      [[ $DRY -eq 0 ]] && { rm -rf "$target"; mkdir -p "$(dirname "$target")"; mv "$backup" "$target"; }
    fi
  done
  echo "done."
  exit 0
fi

echo "── Install symlinks (plugin → user-scope) ──"
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
echo "USER_SCOPE=$USER_SCOPE"
echo "timestamp=$TS  dry-run=$DRY"
echo

for entry in "${MAPPINGS[@]}"; do
  read -r src dst <<<"$entry"
  src_abs="$PLUGIN_ROOT/$src"
  dst_abs="$USER_SCOPE/$dst"

  if [[ ! -e "$src_abs" ]]; then
    echo "MISS source: $src_abs (skip)" >&2
    continue
  fi

  mkdir -p "$(dirname "$dst_abs")"

  # Already correct symlink?
  if [[ -L "$dst_abs" ]]; then
    cur="$(readlink "$dst_abs")"
    if [[ "$cur" == "$src_abs" ]]; then
      echo "OK   (already linked) $dst_abs"
      continue
    fi
    echo "REPL (symlink → symlink) $dst_abs  cur=$cur  new=$src_abs"
    [[ $DRY -eq 0 ]] && { rm "$dst_abs"; ln -s "$src_abs" "$dst_abs"; }
    continue
  fi

  # Real file/dir present → backup OUTSIDE commands/agents (else slash-command loader would still register the backup)
  if [[ -e "$dst_abs" ]]; then
    bak="$BACKUP_ROOT/$dst"
    echo "BAK  $dst_abs  →  $bak"
    if [[ $DRY -eq 0 ]]; then
      mkdir -p "$(dirname "$bak")"
      mv "$dst_abs" "$bak"
    fi
  else
    echo "NEW  $dst_abs"
  fi

  [[ $DRY -eq 0 ]] && ln -s "$src_abs" "$dst_abs"
done

echo
echo "Backups (if any): $BACKUP_ROOT"
echo "Rollback:         bash $0 --rollback $TS"
