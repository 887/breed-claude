#!/usr/bin/env python3
"""sccache-health — never let cargo lazily spawn (or re-spawn) the sccache server.

## The failure this exists to prevent

mozilla/sccache#2771 (open, unreleased as of 0.17.0): the sccache server is
lazily fork+exec'd by whichever compile-job client first needs it, and it
INHERITS that client's open file descriptors — including cargo's jobserver pipe.
The long-lived daemon then holds that pipe's write end open forever, the writer
never observes EOF, and the build deadlocks **at 0.0% CPU** with its output
frozen mid-`Compiling <crate>`.

It looks exactly like a slow compile. It is not one. Measured on this box in a
single session (2026-08-05): 5h43m + 3h32m + 1h41m of wall-clock, all three the
same cycle:

    wedge -> kill -9 the server -> run cargo -> cargo LAZILY SPAWNS a new
    server, which inherits THIS cargo's jobserver pipe -> wedged again

The loop is self-perpetuating, which is why discipline did not break it: the
obvious recovery action (kill the stuck server, re-run the build) IS the thing
that re-creates the bug. Three times.

## Why a hook is the right shape

The one property that fixes this is *who starts the server*. A server started by
a process that owns no jobserver has no build pipe to hold. **This hook is
spawned by Claude Code, not by cargo**, so a server it starts is clean by
construction — the same command typed inside a build is not.

So on any cargo invocation this gate makes a healthy sccache a precondition:

  * orphaned clients       -> reap them (see `_reap_orphan_clients`)
  * server absent          -> start it HERE, closing the lazy-spawn path
  * server wedged          -> stop + start it HERE, before cargo blocks on it
  * all well               -> allow, ~26 ms

It never blocks a build. It repairs and allows, because "your cache is unhealthy"
is not a decision the author needs to make — the correct action is always the
same one.

## Platform: every Unix, NOT macOS-only

Worth stating because the instinct is to scope this to the box it was found on,
and that would leave Linux unprotected. The mechanism is plain POSIX
fd-inheritance across `fork`+`exec` — nothing about it is Darwin-specific, and
#2771's own reproducer is a Linux-flavoured `ninja` build piping through `tee`.
Its fix is gated `cfg(unix)` for the same reason, sweeping fds `>= 3` after
daemonizing.

Windows is the genuine exception, and #2771 says why: *"On Windows there is no
daemon fork, so `daemonize()` just redirects stderr."* No fork, no inherited
pipe, no wedge — so this gate no-ops there rather than paying a probe for a
failure that cannot occur.

(Do not confuse this with mozilla/sccache#221, which IS a macOS-specific
pthread-mutex deadlock. Different bug, similar symptom — that one is a genuine
sccache-internal hang; this one is an inherited descriptor.)

## What it deliberately does NOT catch

* Builds run outside the Bash tool (a terminal the hook does not see).
* A server that wedges *during* a build it was healthy at the start of. Nothing
  at the boundary can see that; the liveness signal there is the request counter
  advancing (`sccache --show-stats | rg 'Compile requests +[0-9]'`), NOT the log
  tail — a stale tail read twice is indistinguishable from progress, which is how
  the first wedge survived an explicit "is it still alive?" check.
* Orphans left by a build that is killed while ANOTHER build is running: the
  reaper's safety interlock declines to act whenever a compile driver is live,
  because it cannot tell that build's legitimate clients from the dead ones. The
  next cargo command with nothing else in flight cleans them up.
* Any wrapper other than sccache.

## Cost

**26 ms measured** per cargo command on this box in the healthy state: an
`sccache --show-stats` probe (~11 ms) plus a `pgrep -x sccache` orphan scan
(~15 ms). Nothing at all on non-cargo commands — the token test exits first.

The expensive call, `lsof` on the sccache port (~98 ms), is only reached when a
stale client already exists, which in the healthy state is never. The scan
cannot be skipped or made conditional on an unhealthy probe: orphans are
INVISIBLE to the probe — the server answered `--show-stats` perfectly while two
of them sat there for hours — and gating on probe health is exactly the blind
spot that let the wedge recur four times.

26 ms against a failure mode that has cost ~11 hours of wall-clock.

When 0.18+ ships with #2771 the daemon sweeps inherited FDs itself and this gate
becomes redundant; delete it then.
"""

import os
import subprocess
import sys

# How long a healthy `--show-stats` may take before we call the server wedged.
# Healthy is ~11 ms here; 5 s is three orders of magnitude of headroom, so a
# timeout means genuinely stuck rather than merely busy.
PROBE_TIMEOUT_S = 5
START_TIMEOUT_S = 30

# Substrings that mean "this command is about to compile something".
BUILD_TOKENS = ("cargo ", "cargo\t", "cargo-nextest")

# Shapes that kill the server the wrong way. `sccache --stop-server` asks it to
# exit and close its descriptors; a signal leaves the next lazily-spawned server
# to inherit a build's pipes, which is the loop above.
HARD_KILL_HINTS = ("pkill", "killall")


def _is_build(command):
    if not command:
        return False
    return any(token in command for token in BUILD_TOKENS)


def _segments(command):
    """Split on shell separators so each piece starts at COMMAND POSITION.

    Deliberately self-contained (no `_shellscan` import): that module is not
    present in every checkout of this directory, and a safety gate that cannot
    import its helper is a gate that does not run.
    """
    out, current = [], []
    for token in command.replace("\n", ";").split():
        if token in (";", "&&", "||", "|", "&"):
            out.append(current)
            current = []
            continue
        stripped = token.strip(";|&")
        if stripped != token and stripped:
            current.append(stripped)
            out.append(current)
            current = []
            continue
        current.append(token)
    out.append(current)
    return [seg for seg in out if seg]


def _kills_sccache(command):
    """True for `pkill sccache` / `killall sccache` / `kill -9 <sccache pid>`.

    Matched only when the killer is in COMMAND POSITION — the first word of a
    pipeline segment. `echo "never pkill sccache"` lexes the same words but they
    are arguments to `echo`, so DOCUMENTING this trap in prose cannot trip the
    gate that describes it. (The first version substring-matched and blocked its
    own test-case describing it, which is the false-positive class that trains
    people to route around a gate.)

    A `kill -9 <pid>` cannot be recognised from text alone, so it is matched only
    when `sccache` also appears in that segment — the shape actually written when
    resolving a wedge, e.g. `kill -9 $(pgrep sccache)`.
    """
    if not command or "sccache" not in command:
        return False
    for segment in _segments(command):
        head = segment[0]
        rest = " ".join(segment)
        if head in HARD_KILL_HINTS and "sccache" in rest:
            return True
        if head == "kill" and "sccache" in rest:
            if "-9" in segment or "-KILL" in segment:
                return True
    return False


def _sccache_pids():
    """Every live `sccache` process. Cheap (~31 ms) and the common answer is one."""
    try:
        done = subprocess.run(
            ["pgrep", "-x", "sccache"], capture_output=True, timeout=PROBE_TIMEOUT_S
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    return [int(line) for line in done.stdout.split() if line.isdigit()]


def _build_in_flight():
    """True if any compile driver is running, so clients may be legitimate.

    This is the safety interlock for orphan reaping: the gate fires BEFORE a
    build starts, so in the normal sequential case nothing is in flight and every
    non-listener client is provably dead weight. If something IS building — a
    second session, a terminal — we do nothing at all rather than risk killing a
    healthy build's clients. A gate that kills a colleague's build gets disabled,
    and then it protects nothing.
    """
    try:
        done = subprocess.run(
            ["pgrep", "-f", r"cargo-nextest|bin/cargo\b|bin/rustc\b"],
            capture_output=True,
            timeout=PROBE_TIMEOUT_S,
        )
    except (subprocess.TimeoutExpired, OSError):
        return True  # cannot tell -> assume busy, act on nothing
    return bool(done.stdout.split())


def _listening_pid():
    """The server: whoever holds the sccache port. `None` if it cannot be told.

    Identity comes from the PORT, never from `comm`. Observed on this box, the
    server rendered as `/opt/homebrew/bin/sccache` and its clients as bare
    `sccache` — but that difference is an accident of how each was launched
    (absolute path vs PATH lookup), not a property, and killing the server by
    mistake is exactly what re-triggers the lazy-respawn wedge this file exists
    to prevent. Costs ~98 ms, so it is only ever reached on the rare path where
    a stale client already exists.
    """
    port = os.environ.get("SCCACHE_SERVER_PORT", "4226")
    try:
        done = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            timeout=PROBE_TIMEOUT_S,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    pids = [int(line) for line in done.stdout.split() if line.isdigit()]
    return pids[0] if len(pids) == 1 else None


def _reap_orphan_clients():
    """Kill sccache CLIENTS left behind by a killed build. Returns how many.

    ## Why this half exists

    The server half of this gate does not catch the failure that actually made
    the wedge RECUR. Killing a stuck build (`kill -9` on cargo/rustc) leaves its
    per-compilation `sccache rustc …` CLIENT wrappers alive; they hold their
    connection, and every later "clean" restart rejoins a pool that still
    contains them. Measured today, mid-session:

        41731  03:08:25  /opt/homebrew/bin/sccache   <- the server
        62677  01:11:59  sccache                     <- orphan, 1h11m
        87358  02:47:59  sccache                     <- orphan, 2h47m

    Two orphans, from two previously-killed builds, while the server answered
    `--show-stats` perfectly. **Orphans are invisible to a health probe** — which
    is precisely why the first version of this gate reported healthy through four
    separate wedges.

    They are also invisible to the obvious search: their `comm` is `sccache`, so
    `pgrep -f 'cargo|rustc'` — the natural thing to check after killing a build —
    shows nothing. `pgrep -x sccache` shows them instantly. That blind spot cost
    hours before anyone looked at the right process name.

    ## The rule, and why it is safe

    An orphan is a live `sccache` process that is NOT the port listener, reaped
    only when no compile driver is running at all. With no build in flight there
    are no legitimate clients by construction, so this cannot race one. If the
    listener cannot be identified, nothing is killed — refusing to act beats
    killing the server and re-triggering the lazy-respawn wedge.
    """
    pids = _sccache_pids()
    if len(pids) <= 1:
        return 0  # just the server (or nothing): the overwhelmingly common case
    if _build_in_flight():
        return 0  # someone is compiling; their clients are legitimate
    server = _listening_pid()
    if server is None:
        return 0  # cannot tell server from client: do nothing, never guess
    reaped = 0
    for pid in pids:
        if pid == server:
            continue
        try:
            os.kill(pid, 9)
            reaped += 1
        except OSError:
            pass  # already gone between the scan and here — fine
    return reaped


def _probe():
    """(healthy, running). Never raises."""
    try:
        done = subprocess.run(
            ["sccache", "--show-stats"],
            capture_output=True,
            timeout=PROBE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return False, True  # answering nothing = wedged, but alive
    except (OSError, ValueError):
        return True, False  # sccache absent entirely: not our problem, allow
    return done.returncode == 0, True


def _restart(stop_first):
    """Stop (optionally) and start the server FROM THIS PROCESS.

    This process owns no jobserver, which is the entire point — see the module
    docstring. `SCCACHE_IDLE_TIMEOUT=0` keeps the clean server alive so cargo
    never gets the chance to spawn a dirty one later.
    """
    env = dict(os.environ, SCCACHE_IDLE_TIMEOUT="0")
    if stop_first:
        try:
            subprocess.run(
                ["sccache", "--stop-server"],
                capture_output=True,
                timeout=START_TIMEOUT_S,
                env=env,
            )
        except (subprocess.TimeoutExpired, OSError):
            # A server too wedged to stop politely must still be replaced, and
            # the signal is safe HERE precisely because the replacement is
            # started below by this jobserver-free process rather than by cargo.
            subprocess.run(["pkill", "-9", "-x", "sccache"], capture_output=True)
    try:
        subprocess.run(
            ["sccache", "--start-server"],
            capture_output=True,
            timeout=START_TIMEOUT_S,
            env=env,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return True


def check(command):
    """The whole decision: text to emit and block on, or None to allow."""
    # Windows has no daemon fork, so nothing inherits a jobserver pipe and the
    # wedge cannot happen — see "Platform" above. Every OTHER platform is in
    # scope: this is POSIX fd inheritance, not a Darwin quirk.
    if sys.platform.startswith("win"):
        return None

    if _kills_sccache(command):
        return (
            "SCCACHE HARD-KILL BLOCKED\n\n"
            "  Signalling the sccache server leaves the NEXT build to lazily spawn a\n"
            "  replacement, which inherits that build's jobserver pipe and holds it\n"
            "  open forever — the build then wedges at 0.0% CPU, looking exactly\n"
            "  like a slow compile (mozilla/sccache#2771).\n\n"
            "  That kill -> re-run -> wedge cycle cost ~11 hours in one session.\n\n"
            "  Use instead:  sccache --stop-server\n"
            "  You do not need to start it again by hand — this gate starts a clean\n"
            "  server automatically before the next cargo command.\n"
        )

    if not _is_build(command):
        return None
    if os.environ.get("RUSTC_WRAPPER", "").split("/")[-1] != "sccache":
        return None

    # Orphaned clients are checked FIRST and unconditionally, because they are
    # invisible to the health probe below — the server answered `--show-stats`
    # perfectly while two of them sat there for hours. Gating this on an
    # unhealthy probe would reproduce exactly the blind spot that let the wedge
    # recur four times.
    _reap_orphan_clients()

    healthy, running = _probe()
    if healthy:
        return None
    # Repair silently and ALLOW: there is only ever one correct action here, so
    # making the author choose it would be ceremony, not a decision.
    _restart(stop_first=running)
    return None


def main():
    import json

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)
    command = payload.get("tool_input", {}).get("command", "")
    message = check(command)
    if message:
        print(message, file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
