#!/usr/bin/env python3
"""jj-no-undo — refuse `jj undo` and `jj op restore` in a shared-op-log repo.

Every workspace of a jj repo shares ONE operation log. `jj undo` reverts the most
recent operation in the whole repo, which under a fleet of agents is often another
agent's bookmark move or commit, not yours. `jj op restore <op>` rewinds the entire
repo view to an older operation and reverts every agent's work since then. It also
makes other workspaces stale, which then invites a destructive
`jj workspace update-stale` (see jj-no-update-stale.py).

Observed: an agent's `jj undo` silently reverted another agent's pushed
`acs-help-permissions` bookmark.

Use instead:
  - `jj op revert <your-op-id>`: reverses exactly one named operation, yours;
  - or fix forward with a new commit or `jj bookmark set`.

Override (a human deciding the whole repo should rewind): `JJ_ALLOW_UNDO=1`.

Scanning is command-position based via `_shellscan`, so `rg 'jj undo' docs/` and
`echo "never run jj undo"` pass. Only a real invocation is refused.

Exit 2 = block. Exit 0 = allow.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import invocations_env, overrides  # noqa: E402

OVERRIDE = "JJ_ALLOW_UNDO"

# jj global flags that CONSUME the next token, so it is not a subcommand word.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color"}


def subcommand_words(args):
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
    return words


def blocked_segment(command):
    """True if some invocation RUNS `jj undo` / `jj op restore` / `jj op undo` without the override."""
    for word, args, env in invocations_env(command):
        if word != "jj" or overrides(env, OVERRIDE):
            continue
        words = subcommand_words(args)
        if words[:1] == ["undo"]:
            return True
        if words[:2] in (["op", "restore"], ["operation", "restore"],
                         ["op", "undo"], ["operation", "undo"]):
            return True
    return False


def check(command):
    """The message to emit, or None to allow."""
    if not command or ("undo" not in command and "restore" not in command):
        return None
    if os.environ.get(OVERRIDE) == "1":
        return None
    if not blocked_segment(command):
        return None
    return (
        "JJ UNDO BLOCKED: every workspace shares ONE jj operation log.\n"
        "  `jj undo` reverts the most recent operation in the WHOLE repo, which may\n"
        "  be another agent's bookmark move. `jj op restore` rewinds everyone's work.\n"
        "\n"
        "  Instead:\n"
        "    jj op log                     # find YOUR operation id\n"
        "    jj op revert <your-op-id>     # reverses exactly that one operation\n"
        "  or fix forward (a new commit, `jj bookmark set`).\n"
        "\n"
        f"  A deliberate whole-repo rewind by a human: {OVERRIDE}=1 jj undo\n")


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
