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
# <report-dir> is retained only as a state directory; NO report file is read.
#
# Run it via the Monitor tool (persistent): each stdout line becomes one event.
#
# SELF-TERMINATING: once every watched session is terminal (IDLE or DEAD) for
# two consecutive passes, it emits FLEET-COMPLETE and exits. A watcher must not be
# able to outlive the fleet it watches — and because it is edge-triggered, a watcher
# with nothing left to report is INDISTINGUISHABLE from one that is not running, so
# "the orchestrator will remember to stop it" is not a control. Set WATCH_STAY=1 to
# keep it armed across reassignments instead.
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

STAY="${WATCH_STAY:-0}"               # 1 = never self-terminate (fleet gets reassigned)

STATE_DIR="${WATCH_STATE_DIR:-${TMPDIR:-/tmp}/santa-watch-$$}"
mkdir -p "$STATE_DIR"

# A dialog is anything that halts the TUI waiting for a keypress. Every one of
# these has cost real hours: the first-launch update prompt, the hook-trust
# prompt, and the "model is slow" retry prompt all block silently and forever.
DIALOG_RE='Press enter to confirm|Update available|Do you trust|Allow command|Retry with a faster model|Keep waiting|\[y/n\]|\(y/N\)'

# Lines that CONTAIN dialog words but block nothing. Claude Code prints a
# permanent footer banner "Update available! Run: brew upgrade claude-code@latest"
# that matches DIALOG_RE's codex-oriented `Update available` on EVERY tick. A
# check that cries wolf each cycle is worse than no check, because it teaches the
# reader to skip the one real DIALOG when it comes. Stripped before matching, so
# codex's genuinely blocking update PROMPT still fires.
BENIGN_RE='Update available! *Run:'
# Codex prints one of these while a tool call is in flight.
# Claude Code prints NONE of them: its spinner is a RANDOMISED gerund
# ("Blanching…", "Drizzling…", "Sauteed…"), so there is no stable word to match
# and a Claude lane read as IDLE precisely while it was working — every tick.
# Match instead on the three things Claude shows only while live: the streaming
# token counter, an in-flight Bash tool, and the backgrounding hint printed
# beside it. Verified against a real Claude lane mid-run and at an idle prompt.
WORKING_RE='esc to interrupt|Working \(|· ↓ [0-9]|Running… \(|ctrl\+b ctrl\+b|background terminal|[0-9]+ shells?|[0-9]+ monitors?'
# `N shell` / `N monitor` were added 2026-08-14 after a THIRD false IDLE: a Claude
# lane waiting on a cold compile with a Monitor armed shows no spinner at all —
# it had already printed its progress and was blocked on a background job — but
# its footer steadily reads `bypass permissions on · 1 shell, 1 monitor`. That is
# the same kind of signal as `background terminal`: it persists for the whole
# wait instead of flickering between redraws. Verified with a behavioural test
# over six working panes and three genuinely-idle ones; the idle cases carry
# neither token, so this does not trade a false IDLE for a false WORKING.
# `background terminal` is the STEADIEST of these. The spinner line is cleared
# between redraws, so two captures landing in that gap trip the idle debounce on a
# lane that is plainly working — codex3 raised three false IDLE-STALLs during a
# single 4-minute nextest run. The background-terminal text persists for the whole
# tool call, so it does not flicker.

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

settled=0
while true; do
    terminal=0
    total=0

    for s in "$@"; do
        total=$(( total + 1 ))

        if ! tmux has-session -t "$s" 2>/dev/null; then
            transition "$s" dead "DEAD $s — tmux session gone; re-breed it"
            terminal=$(( terminal + 1 ))
            continue
        fi

        # NO DONE-FILES. The PANE is the signal, and that is the entire premise of
        # this script. A `.done` file encodes exactly ONE state — "finished AND
        # remembered to write it" — and is structurally silent on a premature FAIL,
        # an unconfirmed modal, a content filter, a false self-declared block, a
        # dead session, and a disk squeeze. Every one of those happened in a single
        # campaign that hand-rolled done-file monitors instead.
        #
        # An IDLE pane with no further output IS the completion signal: go read it.
        # That is strictly more informative than a sentinel file, because the pane
        # also distinguishes finished from blocked from crashed — which a file
        # cannot. Do not reintroduce a report sweep here; it was added and reverted
        # on 2026-08-13 by an orchestrator who mistook a broken idle check for a
        # missing completion signal.

        # BLANK LINES ARE STRIPPED BEFORE `tail`. A pane whose TUI does not fill its
        # height is padded with blanks at the BOTTOM, so a raw `tail -25` returns 25
        # EMPTY lines and every pattern misses. Measured live: codex1 and claude1
        # had 18 and 20 non-blank lines in their last 25; codex3 had ZERO, and
        # raised a false IDLE-STALL on every tick while visibly running two
        # background terminals — the watcher was reading empty padding and calling
        # it an idle lane.
        #
        # The strip is a single-quoted pattern. An earlier fix embedded shell
        # quote-escaping into the file literally, which `bash -n` accepts and which
        # silently made the strip a NO-OP — the bug survived its own fix, and only a
        # behavioural test on a padded fixture caught it.
        pane=$(tmux capture-pane -pt "$s" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -25)

        # AN EMPTY CAPTURE IS UNKNOWN, NOT IDLE. `tmux capture-pane` can return
        # nothing while a pane is being redrawn heavily — codex3 prints process
        # tables during its builds and tripped IDLE-STALL repeatedly while a
        # reproduction of the same pipeline seconds later read WORKING. Absence of
        # data is not evidence of absence of work: counting it as an idle tick is
        # the same error as reading an empty search result as a fact. Skip the tick
        # entirely and let the next one decide.
        if [ -z "$(printf '%s' "$pane" | tr -d '[:space:]')" ]; then
            continue
        fi

        # A session that is visibly working cannot be blocked on a modal, so the
        # WORKING signal outranks a DIALOG match. Without this the two are decided
        # by check ORDER alone, and a benign banner anywhere in the pane silently
        # outvotes live evidence of progress.
        dialog_pane=$(printf '%s' "$pane" | grep -vE "$BENIGN_RE")
        if printf '%s' "$pane" | grep -qE "$WORKING_RE"; then
            transition "$s" working "WORKING $s"
            state_set "$s" idle 0
        elif printf '%s' "$dialog_pane" | grep -qE "$DIALOG_RE"; then
            transition "$s" dialog \
                "DIALOG $s :: $(printf '%s' "$dialog_pane" | grep -oE "$DIALOG_RE" | head -1) — send the keypress"
            state_set "$s" idle 0
        elif printf '%s' "$pane" | grep -qE "$WORKING_RE"; then
            transition "$s" working "WORKING $s"
            state_set "$s" idle 0
        else
            idle=$(( $(state_get "$s" idle 0) + 1 ))
            state_set "$s" idle "$idle"
            if [ "$idle" -ge "$IDLE_TICKS" ]; then
                # ONE idle signal, and it means GO READ THE PANE.
                #
                # This used to split on whether a `.done` file existed — IDLE-DONE
                # versus IDLE-STALL. That split was a lie dressed as information: the
                # file only ever encoded "finished AND remembered to write it", so a
                # lane that finished and forgot, or finished with a name the watcher
                # did not expect, was reported as a stall. Worse, the orchestrator
                # learned to treat IDLE-STALL as noise, and then missed three genuinely
                # finished lanes in one afternoon.
                #
                # The pane already carries the distinction the file could not: read it
                # and you see finished, blocked, crashed, or waiting on a question.
                # A signal that says "look" and is always worth looking at beats two
                # signals where one is routinely wrong.
                transition "$s" idle \
                    "IDLE $s — no output for $IDLE_TICKS ticks; READ THE PANE (finished, blocked, or waiting on you)"
            fi
        fi
        case "$(state_get "$s" state '')" in
            idle) terminal=$(( terminal + 1 )) ;;
        esac
    done
    resources

    # Wind down when the whole fleet is terminal. Confirmed over two passes so a
    # session caught mid-relaunch cannot end the watch early.
    if [ "$STAY" != 1 ] && [ "$terminal" -eq "$total" ]; then
        settled=$(( settled + 1 ))
        if [ "$settled" -ge 2 ]; then
            emit "FLEET-COMPLETE all $total helper(s) terminal — disarming watcher"
            exit 0
        fi
    else
        settled=0
    fi

    sleep "$TICK"
done
