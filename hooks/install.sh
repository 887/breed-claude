#!/usr/bin/env bash
# install.sh — SYMLINK the PreToolUse gates into place on this machine.
#
#   ./install.sh                 user scope    -> ~/.claude/hooks/
#   ./install.sh /path/to/repo   also project  -> <repo>/.claude/hooks/
#
# SYMLINKS, not copies, per the repo's hard rule in ../CLAUDE.md: this repo is the
# source of truth, so every install on every machine points back at a checkout and
# `git pull` alone updates behaviour. A copy silently keeps working while going
# stale, which is the worst failure shape for a safety gate — it still runs, just
# not the version you think. Follows cc-heel-on-resume/install.sh rather than
# reinventing the pattern.
#
# COROLLARY, and it applies to Claude too: do NOT edit the installed path. Editing
# `~/.claude/hooks/rg-flag-gate.py` edits this repo's file through the symlink, so
# the change is real but uncommitted and invisible — `git status` here is the only
# place it shows. Edit the file in this repo and commit it.
#
# Does NOT touch settings.json. That file is hand-owned and may carry other hooks;
# merging JSON blind to save one paste risks silently dropping someone else's gate.
# The snippet is printed at the end.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-}"

# Is <file> tracked by a VCS at its own location? A tracked file is OWNED by that
# repo: replacing it with a symlink would commit the symlink, so it is never
# touched. This is the one case where the symlink invariant must NOT be forced.
is_tracked() {
  local f="$1" d
  d="$(dirname "$f")"
  git -C "$d" ls-files --error-unmatch "$f" >/dev/null 2>&1 && return 0
  jj file list -r @ "$f" 2>/dev/null | grep -q . && return 0
  return 1
}

link_in() {         # link_in <src-file> <dest-dir>
  local src="$1" dst_dir="$2" dst
  dst="$dst_dir/$(basename "$src")"
  mkdir -p "$dst_dir"
  chmod +x "$src"
  if [ -L "$dst" ]; then
    ln -sfn "$src" "$dst"
    printf '  relinked   %s -> %s\n' "$dst" "$src"
  elif [ -e "$dst" ]; then
    if is_tracked "$dst"; then
      # The destination repo version-controls this file. Report drift; never force.
      if cmp -s "$src" "$dst"; then
        printf '  tracked, in sync (correctly left as a real file)  %s\n' "$dst"
      else
        printf '  tracked, DIVERGED — left alone: %s\n' "$dst"
        printf '             diff "%s" "%s"\n' "$dst" "$src"
      fi
    elif cmp -s "$src" "$dst"; then
      # Untracked and byte-identical: nothing to lose, so establish the invariant.
      ln -sfn "$src" "$dst"
      printf '  was a copy, now symlinked  %s -> %s\n' "$dst" "$src"
    else
      # Untracked but different — could be a local fix that never made it back.
      printf '  untracked and DIFFERS — left alone: %s\n' "$dst"
      printf '             diff "%s" "%s"\n' "$dst" "$src"
      printf '             adopt the shared version:  ln -sfn "%s" "%s"\n' "$src" "$dst"
    fi
  else
    ln -s "$src" "$dst"
    printf '  symlinked  %s -> %s\n' "$dst" "$src"
  fi
}

echo "user-scope hooks:"
link_in "$SRC/rg-flag-gate.py"        "$HOME/.claude/hooks"
link_in "$SRC/tests/rg-flag-gate.sh"  "$HOME/.claude/hooks/tests"

if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || { echo "error: '$REPO' is not a directory" >&2; exit 1; }
  echo "project-scope hooks in $REPO:"
  # A repo that TRACKS its own .claude/hooks owns that file — foundlings does, and
  # replacing a tracked file with a symlink would commit the symlink. link_in
  # reports the difference instead of forcing it; that is intended, not a gap.
  link_in "$SRC/vcs-gate.py"       "$REPO/.claude/hooks"
  link_in "$SRC/tests/vcs-gate.sh" "$REPO/.claude/hooks/tests"
  command -v jj >/dev/null 2>&1 || echo "  WARNING: 'jj' not on PATH — vcs-gate needs it to ask whether @ is empty"
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
    { "type": "command", "command": "python3 \"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/vcs-gate.py\"", "timeout": 30 }
  ] } ] } }

Then verify:
  bash ~/.claude/hooks/tests/rg-flag-gate.sh
  bash <repo>/.claude/hooks/tests/vcs-gate.sh
  /hooks     (in-session; the hook should be listed. Project hooks hot-reload —
             if it is missing, that is real wiring breakage, not a stale session)
SNIPPET
