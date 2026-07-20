#!/usr/bin/env bash
# Edge-triggered fleet watcher for santaing.
#
# A `.done` file encodes exactly ONE state: "finished AND remembered to write it".
# It is structurally silent on every real failure mode — blocked on a dialog,
# went idle with gates red, tmux session died, machine thrashing. "Not there yet"
# and "dead 40 minutes ago" look identical.
#
# This watcher polls each elf's pane and emits a line ONLY on a state TRANSITION,
# so a helper working for 40 minutes produces one WORKING line, not 40 identical
# ones. That is what keeps monitoring from becoming the context problem it was
# meant to solve.
#
# Usage:  watch-elves.sh <report-dir> <session>...
#   e.g.  watch-elves.sh /tmp/scratch codex codex2 codex3
# For each session <s>, the report file is <report-dir>/<s>.done
#
# Run it via the Monitor tool (persistent): each stdout line becomes one event.
#
# Portability: state lives in files, not `declare -A` — macOS ships bash 3.2,
# which has no associative arrays. This also means a restarted watcher resumes
# with its edge-detection intact instead of re-announcing everything.
set -uo pipefail

REPORT_DIR="${1:?usage: watch-elves.sh <report-dir> <session>...}"
shift
[ $# -gt 0 ] || { echo "usage: watch-elves.sh <report-dir> <session>..." >&2; exit 2; }

TICK="${WATCH_TICK:-60}"              # seconds between polls
IDLE_TICKS="${WATCH_IDLE_TICKS:-2}"   # debounce: codex pauses between tool calls
DISK_MIN_G="${WATCH_DISK_MIN_G:-60}"  # free-GB floor; 3 parallel Rust builds eat a disk
SWAP_MAX_G="${WATCH_SWAP_MAX_G:-4}"   # swap ceiling; thrashing precedes the freeze

STATE_DIR="${WATCH_STATE_DIR:-${TMPDIR:-/tmp}/santa-watch-$$}"
mkdir -p "$STATE_DIR"

# A dialog is anything that halts the TUI waiting for a keypress. Every one of
# these has cost real hours: the first-launch update prompt, the hook-trust
# prompt, and the "model is slow" retry prompt all block silently and forever.
DIALOG_RE='Press enter to confirm|Update available|Do you trust|Allow command|Retry with a faster model|Keep waiting|\[y/n\]|\(y/N\)'
# Codex prints one of these while a tool call is in flight.
WORKING_RE='esc to interrupt|Working \('

emit() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

state_get() { cat "$STATE_DIR/$1.$2" 2>/dev/null || echo "$3"; }
state_set() { printf '%s' "$3" > "$STATE_DIR/$1.$2"; }

# Emit only when the state actually changes — the edge, not the level.
transition() {
    session="$1"; next="$2"; message="$3"
    [ "$(state_get "$session" state '')" = "$next" ] && return 0
    state_set "$session" state "$next"
    emit "$message"
}

resources() {
    free_g=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "${free_g:-}" ] && [ "$free_g" -lt "$DISK_MIN_G" ]; then
        transition __disk low \
            "DISK-PRESSURE ${free_g}G free (floor ${DISK_MIN_G}G) — stagger the builds, reclaim a workspace"
    else
        state_set __disk state ok
    fi
    swap_m=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
    if [ -n "${swap_m:-}" ]; then
        swap_g=$(awk -v m="$swap_m" 'BEGIN{printf "%d", m/1024}')
        if [ "$swap_g" -ge "$SWAP_MAX_G" ]; then
            transition __swap high \
                "MEM-PRESSURE ${swap_g}G swapped (ceiling ${SWAP_MAX_G}G) — machine is thrashing"
        else
            state_set __swap state ok
        fi
    fi
}

while true; do
    for s in "$@"; do
        report="$REPORT_DIR/$s.done"

        if ! tmux has-session -t "$s" 2>/dev/null; then
            transition "$s" dead "DEAD $s — tmux session gone; re-breed it"
            continue
        fi

        # A report appearing is the one unambiguous good signal. Announce it once.
        if [ -f "$report" ] && [ "$(state_get "$s" reported '')" != 1 ]; then
            state_set "$s" reported 1
            emit "REPORT-READY $s ($(wc -l <"$report" | tr -d ' ') lines) :: $(head -c 300 "$report" | tr '\n' ' ')"
        fi

        pane=$(tmux capture-pane -pt "$s" 2>/dev/null | tail -25)

        if printf '%s' "$pane" | grep -qE "$DIALOG_RE"; then
            transition "$s" dialog \
                "DIALOG $s :: $(printf '%s' "$pane" | grep -oE "$DIALOG_RE" | head -1) — send the keypress"
            state_set "$s" idle 0
        elif printf '%s' "$pane" | grep -qE "$WORKING_RE"; then
            transition "$s" working "WORKING $s"
            state_set "$s" idle 0
        else
            idle=$(( $(state_get "$s" idle 0) + 1 ))
            state_set "$s" idle "$idle"
            if [ "$idle" -ge "$IDLE_TICKS" ]; then
                if [ "$(state_get "$s" reported '')" = 1 ]; then
                    # Idle WITH a report: finished. Integrate it.
                    transition "$s" idle-done "IDLE-DONE $s — report present; collect and integrate"
                else
                    # Idle WITHOUT a report: it quit early. This is the distinction a
                    # bare .done file structurally cannot make, and it is the single
                    # most common way a fleet silently stops making progress.
                    transition "$s" idle-stall \
                        "IDLE-STALL $s — idle, NO report; goal likely paused, re-nudge it"
                fi
            fi
        fi
    done
    resources
    sleep "$TICK"
done
