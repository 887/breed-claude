#!/usr/bin/env python3
"""jj-no-update-stale — refuse `jj workspace update-stale`.

## Why refuse it outright

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

from _shellscan import ASSIGNMENT, PREFIXES, segments, strip_heredoc_bodies  # noqa: E402

OVERRIDE = "JJ_ALLOW_UNSAFE_UPDATE_STALE"

# jj global flags that CONSUME the next token, so it is not a subcommand word.
# Without this, `jj -R /some/repo workspace update-stale` slips through: dropping
# the flags alone leaves `/some/repo` sitting where `workspace` is expected.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color"}


SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def blocked_segment(command, inherited_override=False):
    """True if some segment RUNS `jj workspace update-stale` without the override.

    The override is checked **per segment**, not across the whole command string.
    A command-wide check is an accidental escape hatch: `JJ_ALLOW_UNSAFE_...=1 ls;
    jj workspace update-stale` would disable the gate for a command the override
    was never attached to. An env assignment only applies to the command it
    prefixes, so the gate has to read it the same way the shell does.
    """
    for segment in segments(strip_heredoc_bodies(command)):
        index, overridden = 0, inherited_override
        while index < len(segment) and (
            ASSIGNMENT.match(segment[index]) or segment[index] in PREFIXES
        ):
            if segment[index] == f"{OVERRIDE}=1":
                overridden = True
            index += 1
        if index >= len(segment):
            continue

        word = Path(segment[index]).name
        args = segment[index + 1:]

        # `bash -c '…'` really does run what is inside, so scan it. An override
        # prefixing the shell reaches the inner command through the environment,
        # so it carries down.
        if word in SHELLS and "-c" in args:
            nested = args.index("-c") + 1
            if nested < len(args) and blocked_segment(args[nested], overridden):
                return True
            continue

        if word != "jj":
            continue

        words = []
        position = 0
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

        if words[:2] == ["workspace", "update-stale"] and not overridden:
            return True
    return False


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command or "update-stale" not in command:
        return 0
    if os.environ.get(OVERRIDE) == "1":
        return 0
    if not blocked_segment(command):
        return 0

    sys.stderr.write(
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
        f"  If the workspace is empty or disposable, step 3 alone is enough.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
