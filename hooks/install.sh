#!/usr/bin/env bash
# install.sh — copy the PreToolUse gates into place on this machine.
#
#   ./install.sh                 user-scope   -> ~/.claude/hooks/
#   ./install.sh /path/to/repo   also project -> <repo>/.claude/hooks/
#
# Deliberately does NOT edit any settings.json. That file is hand-owned and may
# carry other hooks; merging JSON blind to save one paste risks silently dropping
# someone else's gate. The snippet is printed at the end instead.
#
# An existing file is backed up rather than overwritten, because the copy on the
# target machine may be the NEWER one — this script cannot tell, so it refuses to
# be the step that loses a fix.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPO="${1:-}"

place() {           # place <src-file> <dest-dir>
  local src="$1" dst_dir="$2" name dst
  name="$(basename "$src")"
  dst="$dst_dir/$name"
  mkdir -p "$dst_dir"
  if [ -f "$dst" ]; then
    if cmp -s "$src" "$dst"; then
      printf '  unchanged  %s\n' "$dst"
      return 0
    fi
    cp "$dst" "$dst.bak-$STAMP"
    printf '  backed up  %s -> %s\n' "$dst" "$dst.bak-$STAMP"
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  printf '  installed  %s\n' "$dst"
}

echo "user-scope hooks:"
place "$SRC/rg-flag-gate.py"        "$HOME/.claude/hooks"
place "$SRC/tests/rg-flag-gate.sh"  "$HOME/.claude/hooks/tests"

if [ -n "$REPO" ]; then
  if [ ! -d "$REPO" ]; then
    echo "error: '$REPO' is not a directory" >&2
    exit 1
  fi
  echo "project-scope hooks in $REPO:"
  place "$SRC/vcs-no-squash-gate.sh"       "$REPO/.claude/hooks"
  place "$SRC/tests/vcs-no-squash-gate.sh" "$REPO/.claude/hooks/tests"
  for tool in jq jj; do
    command -v "$tool" >/dev/null 2>&1 || echo "  WARNING: '$tool' not on PATH — vcs-no-squash-gate needs it"
  done
fi

command -v python3 >/dev/null 2>&1 || echo "WARNING: python3 not on PATH — rg-flag-gate needs it"

cat <<'SNIPPET'

Now merge the registration by hand (this script will not touch settings.json).

~/.claude/settings.json:
  { "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "python3 $HOME/.claude/hooks/rg-flag-gate.py" }
  ] } ] } }

<repo>/.claude/settings.json:
  { "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/vcs-no-squash-gate.sh\"", "timeout": 30 }
  ] } ] } }

Then verify:
  bash ~/.claude/hooks/tests/rg-flag-gate.sh
  bash <repo>/.claude/hooks/tests/vcs-no-squash-gate.sh
  /hooks     (in-session; the hook should be listed)
SNIPPET
