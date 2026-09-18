#!/usr/bin/env bash
# talk-to-elf.sh — send a message to a tmux agent and VERIFY it landed before pressing Enter.
#
#   talk-to-elf.sh <session> <file-with-message>
#   talk-to-elf.sh <session> -m "short message"
#
# Why this exists: `tmux send-keys -l "$LONG"` silently truncates. The receiving
# agent gets an UNMARKED fragment that reads as a complete instruction. Three
# briefs were corrupted this way before it was caught, and the corruption is
# invisible from the sending side.
#
# Strategy:
#   * Any message over $INLINE_MAX bytes is NOT pasted. It is left in a file and
#     only a short, fixed-length pointer line is typed. A pointer that does not
#     fit cannot exist.
#   * The typed line is read BACK off the pane and compared byte-for-byte with
#     what was intended. Enter is pressed only on an exact match.
#   * On mismatch: clear, retry, and hard-fail rather than submit a fragment.

set -euo pipefail

INLINE_MAX=${INLINE_MAX:-380}   # deliberately conservative
RETRIES=${RETRIES:-3}

die() { printf 'talk-to-elf: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: talk-to-elf.sh <session> <file> | -m <text>"
SESSION="$1"; shift

if [ "${1:-}" = "-m" ]; then
  shift; BODY="$*"; SRC_FILE=""
else
  SRC_FILE="$1"
  [ -f "$SRC_FILE" ] || die "no such file: $SRC_FILE"
  BODY="$(cat "$SRC_FILE")"
fi

tmux has-session -t "$SESSION" 2>/dev/null || die "no tmux session: $SESSION"

# Decide what actually gets typed.
if [ "${#BODY}" -gt "$INLINE_MAX" ]; then
  if [ -z "$SRC_FILE" ]; then
    SRC_FILE="$(mktemp "${TMPDIR:-/tmp}/elf-brief-${SESSION}-XXXXXX.md")"
    printf '%s\n' "$BODY" > "$SRC_FILE"
  fi
  # Absolute path so the agent can always resolve it.
  case "$SRC_FILE" in /*) ABS="$SRC_FILE" ;; *) ABS="$PWD/$SRC_FILE" ;; esac
  LINE="Read $ABS -- full brief, sent as a file because it exceeds the safe paste length."
  MODE="pointer ($(printf '%s' "$BODY" | wc -c | tr -d ' ') bytes -> $ABS)"
else
  LINE="$BODY"
  MODE="inline (${#BODY} bytes)"
fi

[ "${#LINE}" -le "$INLINE_MAX" ] || die "pointer line itself too long (${#LINE}); shorten the path"

# Wait for the agent to go idle. Sending into a working pane collides with its
# own self-driving input and the text is silently cleared or misrouted.
waited=0
while tmux capture-pane -t "$SESSION" -p | grep -qE 'esc to interrupt'; do
  [ "$waited" -lt "${BUSY_WAIT:-120}" ] || die "$SESSION still busy after ${BUSY_WAIT:-120}s; not sending into a working pane"
  sleep 5; waited=$((waited+5))
done
[ "$waited" -gt 0 ] && printf 'talk-to-elf: waited %ds for %s to go idle\n' "$waited" "$SESSION" >&2

attempt=0
while : ; do
  attempt=$((attempt+1))
  [ "$attempt" -le "$RETRIES" ] || die "input never matched after $RETRIES attempts; NOT submitting a fragment"

  # Equalize prompt mode (vim-mode agents), then clear the input line.
  tmux send-keys -t "$SESSION" Escape
  sleep 0.2
  tmux send-keys -t "$SESSION" C-u
  sleep 0.2

  # Deliver via BRACKETED PASTE, never `send-keys -l`.
  #
  # The Claude TUI routes typed keystrokes through a command/completion picker,
  # which EATS the first few characters. Observed live: "Read /tmp/x.md ..."
  # arrived as "d /tmp/x.md ..." -- the truncation is at the FRONT, and it is
  # invisible from the sending side. `paste-buffer -p` wraps the text in
  # bracketed-paste markers, which the TUI treats as paste data and does not
  # route through the picker, so the whole string lands intact.
  BUF="cc-talk-$$"
  printf '%s' "$LINE" | tmux load-buffer -b "$BUF" -
  tmux paste-buffer -p -b "$BUF" -t "$SESSION"
  tmux delete-buffer -b "$BUF" 2>/dev/null || true
  sleep 0.8

  # Read the pane back and compare. capture-pane HARD-WRAPS at pane width, so it
  # inserts newlines mid-line; a whole-line grep can never match. Strip all
  # whitespace from both sides and compare the resulting dense strings.
  PANE="$(tmux capture-pane -t "$SESSION" -p | tr -d '[:space:]')"
  WANT="$(printf '%s' "$LINE" | tr -d '[:space:]')"
  if printf '%s' "$PANE" | grep -qF -- "$WANT"; then
    tmux send-keys -t "$SESSION" Enter
    printf 'talk-to-elf: %s VERIFIED and submitted [%s]\n' "$SESSION" "$MODE"
    exit 0
  fi

  printf 'talk-to-elf: %s attempt %d did NOT match; clearing and retrying\n' "$SESSION" "$attempt" >&2
  tmux send-keys -t "$SESSION" Escape
  tmux send-keys -t "$SESSION" C-u
  sleep 0.5
done
