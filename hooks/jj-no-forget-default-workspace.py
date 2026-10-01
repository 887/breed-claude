#!/usr/bin/env python3
"""jj-no-forget-default-workspace — never sweep the canonical workspace into a
bulk `jj workspace forget`.

## What happens, and why it is not obvious

`jj workspace forget default` de-registers the repository's ORIGINAL workspace —
the checkout at the repo root that everything else was created from. jj accepts it
without complaint. The next jj command there fails with:

    Error: Workspace `default` doesn't have a working-copy commit

Every subsequent jj invocation in that directory fails the same way. `jj st`,
`jj log`, `jj git push` — all of it. The directory and its files are untouched and
git still works, so the checkout LOOKS healthy; only jj is dead.

Recoverable, but only if you know the one command:

    jj op log        # find the `forget workspace default` entry
    jj op revert <that-op-id>

Note it is `jj op revert`, not `jj undo <op>` and not `jj op undo` — neither
exists in current jj, and both error in ways that read like the repo is broken
rather than like the command is wrong. That detour is most of the damage.

## Why a gate rather than care

The real incident was a CLEANUP LOOP, not a typo. Stale per-task workspaces
accumulate, and the obvious way to find the disposable ones is "its working copy
is empty". That predicate is correct for an abandoned lane — and it is ALSO true
of a canonical checkout sitting idle between tasks, which is exactly the state an
integrator's workspace is in whenever it is not mid-merge. So the classifier put
`default` on the safe list, the loop forgot it along with fifty genuinely-dead
workspaces, and an integrator lost jj mid-queue.

"Empty working copy" cannot distinguish disposable from canonical. Nothing about
inspecting the workspace can: the canonical one is the one every other workspace
was forked from, and that fact is not visible in its contents.

## Deliberately narrow

This blocks ONE name, `default`, on ONE subcommand. It says nothing about
forgetting any other workspace — that is ordinary, correct hygiene and the whole
point of the command. A bulk forget of fifty stale workspaces passes untouched as
long as `default` is not among them, which is precisely the edit the incident
needed: not "stop cleaning up", but "keep the one you cannot lose".

It also does not attempt to detect forgetting the workspace you are CURRENTLY in.
That needs a shell-out to resolve the current workspace name, and this gate is
text-only so it can sit among the cheap gates that decide without touching the
repo. Self-forget of a non-default workspace is also recoverable the same way and
costs far less.

If you genuinely mean to de-register the canonical workspace — tearing down a
checkout, migrating a repo — the override is one prefix away.

Scanning is command-position based via `_shellscan`, so `rg 'jj workspace forget
default' docs/` and `echo "never run jj workspace forget default"` pass; only a
real invocation is refused.

Exit 2 = block. Exit 0 = allow.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import invocations_env, overrides  # noqa: E402

OVERRIDE = "JJ_ALLOW_FORGET_DEFAULT_WORKSPACE"

# The canonical workspace's name is fixed by jj, not chosen by a project.
CANONICAL = "default"

# jj global flags that CONSUME the next token, so it is not a subcommand word.
# Without this, `jj -R /some/repo workspace forget default` slips through:
# dropping the flags alone leaves `/some/repo` where `workspace` is expected.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color"}


def blocked_segment(command):
    """True if some invocation RUNS `jj workspace forget default` without override.

    `jj workspace forget` takes MANY names, so the check is membership in the
    argument list rather than a positional match — the incident's command forgot
    `default` somewhere in the middle of a long list, not as the only name.

    Per-invocation env comes from `invocations_env`, which scopes an assignment the
    way a shell does, so `OVERRIDE=1 ls; jj workspace forget default` does NOT
    disengage the gate while a real prefix does.
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

        if words[:2] == ["workspace", "forget"] and CANONICAL in words[2:]:
            return True
    return False


def check(command):
    """The whole decision: the message to emit, or None to allow.

    Separate from `main` so `gate.py` can call it in-process — one python3 spawn
    per Bash call instead of one per gate.
    """
    if not command or CANONICAL not in command or "forget" not in command:
        return None
    if os.environ.get(OVERRIDE) == "1":
        return None
    if not blocked_segment(command):
        return None

    return (
        "JJ FORGET-DEFAULT BLOCKED: `jj workspace forget default` de-registers the\n"
        "  repository's CANONICAL workspace — the checkout at the repo root. jj\n"
        "  accepts it silently, and every later jj command in that directory then\n"
        "  fails with `Workspace \"default\" doesn't have a working-copy commit`.\n"
        "  The files and git are untouched, so the checkout looks healthy while jj\n"
        "  is dead.\n"
        "\n"
        "  If you are cleaning up stale workspaces: drop `default` from the list and\n"
        "  re-run. Forgetting the others is fine and is what this command is for.\n"
        "\n"
        "  \"Its working copy is empty\" does NOT mean disposable. A canonical\n"
        "  checkout sitting idle between tasks looks exactly like an abandoned lane\n"
        "  by that test — that is how this gate came to exist.\n"
        "\n"
        "  Already done it? Recover with:\n"
        "    jj op log                  # find `forget workspace default`\n"
        "    jj op revert <that-op-id>  # NOT `jj undo <op>`, NOT `jj op undo`\n"
        "\n"
        f"  Genuinely tearing down the checkout:  {OVERRIDE}=1 <your command>\n")


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
