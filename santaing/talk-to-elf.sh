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
    SRC_FILE="$(mktemp "${TMPDIR:-/tmp}/elf-brief-${SESSION}-XXXXXX")"  # macOS mktemp only substitutes a TRAILING XXXXXX
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
# BUSY DETECTION IS PER-HARNESS. Codex prints 'esc to interrupt'; Claude prints a
# spinner with a timer like '(2m 45s · ↓ 3.1k tokens)' and NEVER prints that
# string. Matching only the Codex form makes this loop exit instantly for a
# WORKING Claude pane, after which the Escape below interrupts its in-flight
# tool call -- for an integrator, that is a killed merge gate.
# Busy iff the LAST status marker in the pane is a live one. A finished turn's
# "Working (… esc to interrupt)" line stays visible higher up and must not count, and a queued-
# message block can push the live line far from the bottom, so a fixed tail window fails both ways.
# Live: "esc to interrupt" (Codex) or the Claude spinner timer "Ns · ↓", which may follow other
# text in the parentheses ("(running PreToolUse hooks… 1/2 · 15m 11s · ↓"). Done: Codex
# "Worked for …" or Claude "… for Ns · done".
pane_busy() {
  tmux capture-pane -t "$SESSION" -p | awk '
    /esc to interrupt|[0-9]+[hms][^)]*· ↓/ { state = "busy" }
    /Worked for [0-9]|[0-9]+[hms] · done / { state = "idle" }
    END { exit (state == "busy") ? 0 : 1 }'
}
# CODEX QUEUES INPUT WHILE BUSY. A message submitted into a working Codex pane is
# held as "Messages to be submitted after next tool call" and delivered between
# tool calls, without interrupting anything. So a busy Codex pane is not waited
# on (an always-busy integrator would otherwise never be reachable: a send sat
# 60 minutes on one). Queue mode skips the Escape/C-u below too, because Escape
# INTERRUPTS a working Codex turn. Claude panes keep the wait: typing into a busy
# Claude pane collides with its self-driving input.
# The pane's foreground process is the reliable signal; the footer text can scroll off
# or be replaced while a long tool call renders.
is_codex() {
  [ "$(tmux display-message -t "$SESSION" -p '#{pane_current_command}' 2>/dev/null)" = codex ] && return 0
  tmux capture-pane -t "$SESSION" -p | grep -qE '← for agents|Ask Codex to do anything'
}
QUEUE=0
if pane_busy && is_codex && [ "${NO_QUEUE:-0}" != 1 ]; then
  QUEUE=1
else
  while pane_busy; do
    [ "$waited" -lt "${BUSY_WAIT:-120}" ] || die "$SESSION still busy after ${BUSY_WAIT:-120}s; not sending into a working pane"
    sleep 5; waited=$((waited+5))
  done
fi
[ "$waited" -gt 0 ] && printf 'talk-to-elf: waited %ds for %s to go idle\n' "$waited" "$SESSION" >&2

attempt=0
# CODEX TRANSCRIPT-BROWSE TRAP. In Codex, Escape on an empty composer (and
# especially Escape twice) enters "Browsing transcript" mode, whose footer reads
# "↵ rewind · esc back". An Enter there REWINDS the conversation to an old
# message and throws away everything after it. The vim-mode Escape below and the
# retry Escape can put a Codex pane into that mode. So: leave it with ONE Escape
# whenever it shows, and never press Enter while it shows.
in_browse() { tmux capture-pane -t "$SESSION" -p | grep -qE 'Browsing transcript|↵ rewind'; }
leave_browse() {
  local n=0
  while in_browse; do
    n=$((n+1)); [ "$n" -le 3 ] || die "$SESSION stuck in Codex transcript-browse mode; NOT sending (Enter would rewind)"
    tmux send-keys -t "$SESSION" Escape; sleep 0.6
  done
}
while : ; do
  attempt=$((attempt+1))
  [ "$attempt" -le "$RETRIES" ] || die "input never matched after $RETRIES attempts; NOT submitting a fragment"

  # Equalize prompt mode (vim-mode agents), then clear the input line. Skipped in
  # queue mode: Escape would interrupt the working Codex turn.
  if [ "$QUEUE" = 0 ]; then
    tmux send-keys -t "$SESSION" Escape
    sleep 0.2
    leave_browse
    tmux send-keys -t "$SESSION" C-u
    sleep 0.2
  else
    leave_browse
  fi

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
    in_browse && die "$SESSION is in Codex transcript-browse mode; refusing Enter (it would rewind)"
    tmux send-keys -t "$SESSION" Enter
    if [ "$QUEUE" = 1 ]; then
      printf 'talk-to-elf: %s busy (Codex) — VERIFIED and QUEUED for its next tool call [%s]\n' "$SESSION" "$MODE"
    else
      printf 'talk-to-elf: %s VERIFIED and submitted [%s]\n' "$SESSION" "$MODE"
    fi
    exit 0
  fi

  printf 'talk-to-elf: %s attempt %d did NOT match; clearing and retrying\n' "$SESSION" "$attempt" >&2
  if [ "$QUEUE" = 0 ]; then
    tmux send-keys -t "$SESSION" Escape
    sleep 0.3
    leave_browse
  fi
  tmux send-keys -t "$SESSION" C-u
  sleep 0.5
done
