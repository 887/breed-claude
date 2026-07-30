#!/usr/bin/env bash
# install.sh — SYMLINK the user-scope PreToolUse gates into ~/.claude/hooks/.
#
#   ./install.sh
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
# USER SCOPE ONLY, deliberately. Gates here encode facts about a TOOL, so they are
# correct in every repo. A gate that encodes one project's conventions — commit
# shape, merge method, branch policy — belongs in that project's own .claude/hooks,
# tracked in its own history, and is not installable from here. See README.md,
# "What does NOT belong here".
#
# Does NOT touch settings.json. That file is hand-owned and may carry other hooks;
# merging JSON blind to save one paste risks silently dropping someone else's gate.
# The snippet is printed at the end.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Is <file> version-controlled at its own location? Then some repo OWNS it, and
# replacing it with a symlink would commit the symlink. Never touch that case.
is_tracked() {
  local f="$1" d
  d="$(dirname "$f")"
  git -C "$d" ls-files --error-unmatch "$f" >/dev/null 2>&1
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
      printf '  tracked by another repo — left alone: %s\n' "$dst"
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

# `_shellscan.py` is NOT symlinked and does not need to be: each hook does
# `Path(__file__).resolve()`, which follows its own symlink back into this repo,
# so the shared module is found beside the real file. That is also why these must
# be symlinked rather than copied — a lone copied hook has no module to import.
echo "user-scope hooks:"
link_in "$SRC/rg-flag-gate.py"              "$HOME/.claude/hooks"
link_in "$SRC/jj-no-interactive.py"         "$HOME/.claude/hooks"
link_in "$SRC/tests/rg-flag-gate.sh"        "$HOME/.claude/hooks/tests"
link_in "$SRC/tests/jj-no-interactive.sh"   "$HOME/.claude/hooks/tests"

command -v python3 >/dev/null 2>&1 || echo "WARNING: python3 not on PATH — both hooks need it"

cat <<'SNIPPET'

Now merge the registration by hand (this script will not touch settings.json).

~/.claude/settings.json:
  { "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "python3 $HOME/.claude/hooks/rg-flag-gate.py" },
    { "type": "command", "command": "python3 $HOME/.claude/hooks/jj-no-interactive.py" }
  ] } ] } }

Then verify:
  bash ~/.claude/hooks/tests/rg-flag-gate.sh
  bash ~/.claude/hooks/tests/jj-no-interactive.sh
  /hooks     (in-session; both hooks should be listed. Hooks hot-reload — if one is
             missing, that is real wiring breakage, not a stale session)
SNIPPET
