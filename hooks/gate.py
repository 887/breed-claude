#!/usr/bin/env python3
"""gate — the ONE PreToolUse(Bash) entry point. Runs every gate in-process.

## Why this exists

Claude Code runs each registered hook as its own process, sequentially, on every
single Bash tool call. With the four gates registered separately that was four
`python3` spawns per call — measured on this box:

    bare `python3 -c pass`                      ~9.5 ms
    one gate (spawn + import _shellscan + work) ~18 ms
    the four-gate chain                         ~68 ms per Bash call
    THIS dispatcher                             ~18 ms per Bash call

Interpreter startup dominates, and it was being paid four times to answer four
questions about the same string. This dispatcher pays it once: one spawn, one
`json.load`, `_shellscan` imported once and shared, four `check()` calls. 3.7x.

Registration becomes one line, which is also the point — the fewer hook entries,
the less there is to get out of sync between machines.

## Contract each gate keeps

Every gate module exposes `check(command) -> str | None`: the exact text to write
to stderr, or None to allow. Message building stays in the gate that owns the
rule, so this file holds no policy at all — it only decides ORDER and what to do
when a gate is broken.

The modules keep their `main()` and stay directly runnable, which is not
vestigial: each one's test suite invokes the real file over stdin, so the gates
remain independently testable and independently debuggable
(`echo '{...}' | python3 jj-no-interactive.py`).

## Order

Cheapest and most specific first, so the common case exits early. Order is only a
latency choice, not a correctness one: the first gate that objects wins, and no
two gates claim the same command.

## A broken gate FAILS LOUD

If a gate cannot be imported or raises, this blocks the command and says which
gate and why, rather than skipping it. A safety gate that silently stops running
is the failure shape this whole directory exists to avoid — the alternative
(carry on with three of four gates) would be indistinguishable from working.

That is deliberately recoverable: the message names `CLAUDE_GATE_SKIP=1`, which
bypasses the dispatcher entirely, so a syntax error in one gate cannot lock you
out of your own shell.

Exit 2 = block, with the message on stderr. Exit 0 = allow.
"""

import importlib.util
import json
import os
import sys
from pathlib import Path

# `traceback` is imported LAZILY, inside the only path that uses it. Measured on
# this box: importing it costs ~13 ms of the ~26 ms this file would otherwise pay
# at startup — on EVERY Bash call, to serve a debug path that almost never runs.
# Leaving it at module scope silently gave back half of what consolidating the
# registrations bought.

HERE = Path(__file__).resolve().parent

# Cheapest / most specific first — see "Order" above.
GATES = (
    # Cheapest first: the text-only gates decide without touching the repo.
    "rg-flag-gate",
    "jj-no-update-stale",
    "jj-no-interactive",
    "git-no-interactive",
    # Last: this one SHELLS OUT to jj, but only for `jj new` / `jj git push`, so
    # every other Bash call still exits above without paying for a subprocess.
    "jj-no-strand",
)

ESCAPE = "CLAUDE_GATE_SKIP"


def load(name):
    """Import a gate by filename. Hyphens make these non-importable normally."""
    path = HERE / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    # Registered in sys.modules so a gate importing _shellscan resolves once and
    # is shared by every later gate.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def broken(name, error):
    return (
        f"GATE BROKEN: {name} could not run — blocking rather than skipping it.\n\n"
        f"  {type(error).__name__}: {error}\n\n"
        "  A gate that silently stops running looks exactly like a gate that is\n"
        "  working, which is the failure this directory exists to prevent. So the\n"
        "  command is refused until the gate is fixed.\n\n"
        f"  Fix it in the repo:  {HERE / (name + '.py')}\n"
        f"  Verify:              bash {HERE / 'tests' / (name + '.sh')}\n"
        f"  Bypass everything:   {ESCAPE}=1 <your command>\n"
    )


def main() -> int:
    if os.environ.get(ESCAPE) == "1":
        return 0

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command:
        return 0

    for name in GATES:
        try:
            module = load(name)
            message = module.check(command)
        except Exception as error:                      # noqa: BLE001
            if os.environ.get("CLAUDE_GATE_DEBUG") == "1":
                import traceback
                traceback.print_exc()
            sys.stderr.write(broken(name, error))
            return 2
        if message is not None:
            sys.stderr.write(message)
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
