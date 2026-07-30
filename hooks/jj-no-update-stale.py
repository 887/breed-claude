#!/usr/bin/env python3
"""jj-no-update-stale — make `jj workspace update-stale` a DELIBERATE act.

This does not forbid the command. It is the legitimate recovery when a workspace
really is stale, and the override is one prefix away. What it forbids is reaching
it *incidentally* — mid-task, as a reflex to get past an error — because the cost
of being wrong is unrecoverable and an agent cannot see, from the outside, whether
the target workspace holds un-snapshotted work.

## The half of the hazard NO HOOK CAN SEE — pair this with the config

`snapshot.auto-update-stale` decides what jj does when it *notices* staleness. With
it set to `true`, jj updates the workspace ITSELF, on any command at all. Measured
on jj 0.42.0: with `auto-update-stale = true`, a plain **`jj st`** in a stale
workspace printed `removed 2 files` and destroyed both an un-snapshotted file and a
snapshotted-then-rolled-back one. `jj workspace update-stale` was never typed — so
this gate, which matches that command, is structurally blind to it.

`false` is jj 0.42's default, and on that default jj refuses and tells you to run
update-stale — which is where this gate picks up. Since the safe behaviour is a
default rather than a setting, anything that flips it (a repo config, a helpful
agent, a future change of default) silently reopens the invisible path. So
`install.sh` PINS it false at user scope. Note the precedence honestly: a
workspace- or repo-scope `true` still wins over the user scope, so the pin is a
defence against drift, not a guarantee.

Config closes the path you cannot see; this gate makes the path you can see
deliberate.

## Why the visible path is gated at all

When workspace A rebases or describes a commit that workspace B has checked out,
jj marks B **stale**. `jj workspace update-stale` in B re-checks-out the new
commit, **overwriting B's on-disk files**. jj does not snapshot B first, so any
un-snapshotted work there is destroyed with **no op-log record** — jj never saw
it, so `jj undo` cannot bring it back. Unrecoverable by design.

The trap is worse than it looks, and it is why "just be careful" does not work:
snapshotting a *stale* workspace **fails**, because jj refuses to run there. So
the obvious defensive sequence — snapshot first, then update-stale — silently
no-ops on step one and then destroys the work on step two.

REPRODUCED on jj 0.42.0, and the recipe is worth writing down because two obvious
routes do NOT work: rewriting the other workspace's working-copy commit, and
abandoning it, both leave it healthy — jj rebases the descendant and the next
command there snapshots normally, files intact. What DOES make it stale is
`jj op restore <older-op>` in another workspace. Then `jj workspace update-stale`
reports `Added 0 files, modified 0 files, removed 2 files` and both the
un-snapshotted file and a snapshotted-then-rolled-back one are gone from disk. The
un-snapshotted one has no op-log entry, so nothing can bring it back.

An agent cannot tell from the outside whether the target workspace is clean, so
the only safe default is to stop and let a human look. Deciding whether those
files matter is a judgement call, not something to automate.

## Recovering a stale workspace, without this command

1. Look at what is actually on disk there: `ls -la <ws>`, `git -C <ws> status` if
   colocated, or just read the files. jj cannot help — that is the whole problem.
2. Copy anything you care about OUT of the workspace: `cp -a <ws> /tmp/ws-rescue`.
3. Only then, deliberately: `JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale`
4. Put back whatever you rescued.

If the workspace is genuinely empty or its contents are disposable, the override
in step 3 is the whole procedure.

Scanning is command-position based via `_shellscan`, so `rg 'jj workspace
update-stale' docs/` and `echo "never run jj workspace update-stale"` pass — only
a real invocation is refused.

Exit 2 = block. Exit 0 = allow.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import invocations_env, overrides  # noqa: E402

OVERRIDE = "JJ_ALLOW_UNSAFE_UPDATE_STALE"

# jj global flags that CONSUME the next token, so it is not a subcommand word.
# Without this, `jj -R /some/repo workspace update-stale` slips through: dropping
# the flags alone leaves `/some/repo` sitting where `workspace` is expected.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color"}


def blocked_segment(command):
    """True if some invocation RUNS `jj workspace update-stale` without the override.

    The per-invocation env comes from `invocations_env`, which scopes an assignment
    the way a shell does -- so `OVERRIDE=1 ls; jj workspace update-stale` does NOT
    disengage the gate, while a prefix on this command (or on a `bash -c` wrapping
    it, where it really does reach through the environment) does. That walk used to
    live here; it is shared now because two sibling gates had the unscoped bug and
    a third copy is how the next one gets it wrong too.
    """
    for word, args, env in invocations_env(command):
        if word != "jj" or overrides(env, OVERRIDE):
            continue

        words, position = [], 0
        while position < len(args):
            token = args[position]
            if token in JJ_VALUE_FLAGS:
                position += 2
                continue
            if token.startswith("-"):
                position += 1
                continue
            words.append(token)
            position += 1

        if words[:2] == ["workspace", "update-stale"]:
            return True
    return False


def check(command):
    """The whole decision: the message to emit, or None to allow.

    Separate from `main` so `gate.py` can call it in-process — one python3 spawn
    per Bash call instead of one per gate.
    """
    if not command or "update-stale" not in command:
        return None
    if os.environ.get(OVERRIDE) == "1":
        return None
    if not blocked_segment(command):
        return None

    return (
        "JJ UPDATE-STALE BLOCKED: `jj workspace update-stale` overwrites the "
        "workspace's\n"
        "  on-disk files with the new commit, and jj does NOT snapshot them first.\n"
        "  Un-snapshotted work there is destroyed with no op-log record, so "
        "`jj undo`\n"
        "  cannot recover it. Snapshotting a stale workspace FAILS, so "
        "\"snapshot first\"\n"
        "  is not a workaround — it no-ops, then this destroys the work.\n"
        "\n"
        "  Rescue the workspace by hand instead:\n"
        "    1. read what is on disk there (jj cannot help — that is the problem)\n"
        "    2. cp -a <workspace> /tmp/ws-rescue\n"
        f"    3. {OVERRIDE}=1 jj workspace update-stale\n"
        "    4. put back whatever you rescued\n"
        "\n"
        f"  If the workspace is empty or disposable, step 3 alone is enough.\n"
        "\n"
        "  This is not a forbidden command — it is the real recovery for a genuinely\n"
        "  stale workspace. What it must not be is a reflex for getting past an\n"
        "  error, because the work it discards has no op-log entry to recover from.\n")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    message = check(payload.get("tool_input", {}).get("command", ""))
    if message is None:
        return 0
    sys.stderr.write(message)
    return 2


if __name__ == "__main__":
    sys.exit(main())
