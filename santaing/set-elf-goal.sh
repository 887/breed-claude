#!/usr/bin/env bash
# set-elf-goal.sh — give a Codex elf a REAL /goal (replacing any older one) and PROVE it took.
#
#   set-elf-goal.sh <session> <brief-file> [--wait SECS] [--dry-run]
#
# Why this exists: a plain message never changes a Codex goal, so the elf keeps pursuing
# its OLD goal and "falls back" to it at the end of every turn. And a `/goal ...` message
# longer than talk-to-elf's inline limit is delivered as a "Read this file" pointer, so the
# text `/goal` never runs as a command. A real replacement also stops at a "Replace goal?"
# confirmation menu that needs Enter.
#
# What it does:
#   1. builds a SHORT goal (<= GOAL_MAX bytes) that points at <brief-file> (the binding brief);
#   2. sends it inline through talk-to-elf.sh (verified byte-for-byte, queued if the elf is busy);
#   3. waits for the "Replace goal?" menu, and ONLY when that menu's New objective is OUR goal
#      (it names <brief-file>) and option 1 "Replace current goal" is the highlighted one, presses Enter;
#   4. proves success: the footer reads "Pursuing goal (<age>)" with age < FRESH_MAX seconds AND the
#      pane shows our brief path. Otherwise exits 1 with the reason and the last footer.
#
# Exit: 0 pursuing OUR new goal; 1 not proven (reason on stderr). Never presses Enter on a menu
# whose objective is not ours, and never presses Enter in Codex transcript-browse mode.

set -euo pipefail
# The pane has multibyte glyphs and awk substr() is byte-based: work bytewise everywhere here.
export LC_ALL=C

GOAL_MAX=${GOAL_MAX:-340}     # talk-to-elf INLINE_MAX is 380; stay below it
FRESH_MAX=${FRESH_MAX:-300}   # a goal younger than this (seconds) is the one we just set
WAIT=${WAIT:-300}
POLL=${POLL:-3}
HERE="$(cd "$(dirname "$0")" && pwd)"
TALK="${TALK:-$HERE/talk-to-elf.sh}"

die() { printf 'set-elf-goal: FAILED: %s\n' "$*" >&2; exit 1; }

DRY=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
[ "${#POS[@]}" -eq 2 ] || die "usage: set-elf-goal.sh <session> <brief-file> [--wait SECS] [--dry-run]"
SESSION="${POS[0]}"; BRIEF="${POS[1]}"
[ -f "$BRIEF" ] || die "no such brief file: $BRIEF"
case "$BRIEF" in /*) ABS="$BRIEF" ;; *) ABS="$PWD/$BRIEF" ;; esac

GOAL="/goal Santa's binding assignment in $ABS (read it first); replaces older goals; never mark blocked while an item exists; report only when a PR is ready or blocked with exact error text"
BYTES=$(printf '%s' "$GOAL" | wc -c | tr -d ' ')
if [ "$DRY" = 1 ]; then
  printf 'set-elf-goal: dry run, %s bytes (max %s):\n%s\n' "$BYTES" "$GOAL_MAX" "$GOAL"
  [ "$BYTES" -le "$GOAL_MAX" ] || exit 1
  exit 0
fi
[ "$BYTES" -le "$GOAL_MAX" ] || die "goal is $BYTES bytes (max $GOAL_MAX): the brief path is too long; copy the brief to a shorter path (a long goal would be sent as a file pointer and NOT run as /goal)"

tmux has-session -t "$SESSION" 2>/dev/null || die "no tmux session: $SESSION"
cap() { tmux capture-pane -t "$SESSION" -p -S -80; }
cap | grep -qE '← for agents|Ask Codex to do anything' || die "$SESSION is not a Codex pane (this script sets Codex goals)"
DENSE_ABS="$(printf '%s' "$ABS" | tr -d '[:space:]')"

LC_ALL=en_US.UTF-8 "$TALK" "$SESSION" -m "$GOAL" >&2 || die "talk-to-elf.sh could not deliver the goal"

# Seconds from the footer's "Pursuing goal (1h 2m)" / "(12s)" / "(5m)"; empty if not pursuing.
footer_age() {
  local raw h m s
  raw="$(printf '%s\n' "$1" | grep -oE 'Pursuing goal \([^)]*\)' | tail -1 | sed -E 's/Pursuing goal \(([^)]*)\)/\1/')"
  [ -n "$raw" ] || return 0
  h=$(printf '%s' "$raw" | grep -oE '[0-9]+h' | tr -d h || true)
  m=$(printf '%s' "$raw" | grep -oE '[0-9]+m' | tr -d m || true)
  s=$(printf '%s' "$raw" | grep -oE '[0-9]+s' | tr -d s || true)
  echo $(( ${h:-0} * 3600 + ${m:-0} * 60 + ${s:-0} ))
}

# The Codex menu is an overlay: the pane's other text shares each row with it, and rows carry
# multibyte glyphs, so columns must be computed in CHARACTERS (python, not awk). menu_right returns only
# the menu's own columns (the title's column to the end of each following row, wrapped objective text
# included); menu_opt returns the option rows.
menu_py() {
  cap | python3 -I -c '
import sys
mode = sys.argv[1]
lines = sys.stdin.buffer.read().decode("utf-8", "replace").split("\n")
title = -1
for i, l in enumerate(lines):
    if "Replace goal?" in l:
        title = i
if title < 0:
    sys.exit(0)
col = lines[title].index("Replace goal?")
if mode == "right":
    out = [lines[title][col:]] + [l[col:] for l in lines[title + 1 : title + 15]]
else:
    out = [l for l in lines[title + 1 : title + 15] if "1. Replace current goal" in l or "2. Cancel" in l]
print("\n".join(out))
' "$1"
}
menu_right() { menu_py right; }
menu_opt() { menu_py opt; }

pressed=0
last_footer=""
SECONDS=0
while [ "$SECONDS" -le "$WAIT" ]; do
  PANE="$(cap)"
  MENU="$(menu_right)"
  OPTS="$(menu_opt)"
  if [ -n "$MENU" ] && printf '%s' "$OPTS" | grep -q '1\. Replace current goal'; then
    DENSE_MENU="$(printf '%s' "$MENU" | tr -d '[:space:]')"
    if printf '%s' "$DENSE_MENU" | grep -qF -- "$DENSE_ABS" && printf '%s' "$OPTS" | grep -qE '›[[:space:]]*1\. Replace current goal'; then
      printf '%s' "$PANE" | grep -qE 'Browsing transcript|↵ rewind' && die "$SESSION is in Codex transcript-browse mode; refusing Enter (it would rewind)"
      tmux send-keys -t "$SESSION" Enter
      pressed=$((pressed + 1))
      printf 'set-elf-goal: %s: confirmed "Replace goal?" for %s\n' "$SESSION" "$ABS" >&2
      sleep 3
      continue
    fi
    # A Replace-goal menu for someone else's objective: never confirm it.
    last_footer="Replace goal? menu present but its objective is not ours"
  fi
  AGE="$(footer_age "$PANE")"
  if [ -n "$AGE" ] && [ "$AGE" -lt "$FRESH_MAX" ] && printf '%s' "$(printf '%s' "$PANE" | tr -d '[:space:]')" | grep -qF -- "$DENSE_ABS"; then
    printf 'set-elf-goal: %s PURSUING our goal (footer age %ss, Enter pressed %s time(s)): %s\n' "$SESSION" "$AGE" "$pressed" "$ABS"
    exit 0
  fi
  last_footer="$(printf '%s\n' "$PANE" | grep -oE 'Pursuing goal[^·]*|Goal (stalled|paused|achieved)[^·]*|Replace goal\?' | tail -1)"
  sleep "$POLL"
  [ "$POLL" != 0 ] || sleep 1
done
die "$SESSION did not show a fresh 'Pursuing goal' naming $ABS within ${WAIT}s (last footer: ${last_footer:-none}, Enter pressed $pressed time(s))"
