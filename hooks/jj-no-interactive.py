#!/usr/bin/env python3
"""jj-no-interactive — block jj commands that would open an editor and hang.

An agent has no terminal to type into. A jj command that opens `$EDITOR`, a diff
editor, or a merge tool therefore does not fail — it **waits forever**, holding
the tool call open until it times out or the session is killed. Nothing errors,
nothing prints, and the transcript shows a command that simply never returned.
That is the worst shape a failure can take for an unattended agent: no signal.

This is a fact about **jj plus the absence of a tty**, not a repo convention, so
it applies in every repository. (A gate that encoded one project's commit policy
would not belong here — see README.md, "What does NOT belong here".)

## What blocks, and the non-interactive form to use instead

Verified against jj 0.4x `jj help` output rather than assumed:

  -i / --interactive          on any subcommand      -> select with paths instead
  --tool <t>                  implies --interactive   -> omit it (`:ours`/`:theirs`
                              (jj help restore says   /`:none` are non-interactive
                              so outright)            builtins and DO pass)
  describe / commit  with no -m/--message/--stdin     -> pass -m "msg"
                              ("Starts an editor to let you edit the
                              description"; `jj commit` with no path args is
                              documented as equivalent to `jj describe`)
  squash             with no -m/--message/--stdin     -> -m "msg", or -u to keep
                              and no -u/--use-destination-  the destination's
                              message. MEASURED: prompts to  description
                              COMBINE when source AND
                              destination both have a
                              description, and hangs
  --editor                    on describe/commit/squash -> drop it; it FORCES an
                              editor even alongside -m/--stdin
  split                       always                  -> "Starts a diff editor";
                                                         use `jj new` + moves, or
                                                         `jj squash --into`
  diffedit                    always                  -> "Touch up ... with a
                                                         diff editor"
  resolve            without -l/--list                -> `--list` to inspect, or
                                                         `--tool :ours`/`:theirs`

Override, for a human at a real terminal: prefix with
`JJ_GATE_ALLOW_INTERACTIVE=1`.

Scanning is command-position based via `_shellscan`, so `rg 'jj split' docs/`,
`echo "never run jj diffedit"`, and a heredoc brief naming these commands all
pass — only an actual invocation is blocked. See `_shellscan` for why that
matters more than it sounds.

Exit 2 = block, with the stderr message shown back. Exit 0 = allow.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import has_env_assignment, invocations  # noqa: E402

OVERRIDE = "JJ_GATE_ALLOW_INTERACTIVE"

# jj global flags that CONSUME the next token, so it is not the subcommand.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color"}

# Merge/diff "tools" that are builtin and non-interactive: naming one is a way of
# resolving WITHOUT an editor, so it must not be blocked.
NON_INTERACTIVE_TOOLS = {":ours", ":theirs", ":none"}

MESSAGE_FLAGS = {"-m", "--message", "--stdin"}

ALWAYS_INTERACTIVE = {
    "split": "`jj split` always starts a diff editor.\n"
             "    Instead: `jj new` and move content with `jj squash --into <rev>`,\n"
             "    or split by path with `jj squash --into <rev> <paths>`.",
    "diffedit": "`jj diffedit` exists only to open a diff editor.\n"
                "    Instead: edit the files and let jj snapshot them, or\n"
                "    `jj restore --from <rev> <paths>` for a whole-file revert.",
}


def subcommand(args):
    """First non-flag arg (the subcommand) plus everything after it."""
    index = 0
    while index < len(args):
        token = args[index]
        if token in JJ_VALUE_FLAGS:
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token, args[index + 1:]
    return None, []


def has_message(args):
    """True if a message is supplied inline, in either the spaced or `=` form."""
    return bool(MESSAGE_FLAGS & set(args)) or any(
        token.startswith(("-m=", "--message=")) for token in args
    )


def flag_value(args, names):
    """Value of the first of `names` present, as `--flag v` or `--flag=v`."""
    for index, token in enumerate(args):
        if token in names and index + 1 < len(args):
            return args[index + 1]
        for name in names:
            if token.startswith(f"{name}="):
                return token.split("=", 1)[1]
    return None


def verdict(command):
    """Return a block reason, or None to allow."""
    for word, args in invocations(command):
        if word != "jj":
            continue
        name, rest = subcommand(args)
        if name is None:
            continue

        # Asking for help never runs the thing. This is not hypothetical: the
        # predecessor of this hook blocked `jj squash --help`, which is how the
        # squash rule below came to be written in the first place.
        if {"-h", "--help"} & set(args):
            continue

        if {"-i", "--interactive"} & set(rest):
            return (f"`jj {name} -i/--interactive` opens an editor, which an agent "
                    "cannot answer.\n"
                    "    Instead: select the content with explicit paths, e.g.\n"
                    f"    `jj {name} <paths>` — or a revset where the subcommand takes one.")

        tool = flag_value(rest, {"--tool"})
        if tool is not None and tool not in NON_INTERACTIVE_TOOLS:
            return (f"`jj {name} --tool {tool}` implies --interactive (jj's own help "
                    "says so).\n"
                    "    Instead: omit --tool. For `resolve`, the builtin "
                    "non-interactive tools\n"
                    "    `--tool :ours` / `:theirs` are allowed and do not open anything.")

        if name in ALWAYS_INTERACTIVE:
            return ALWAYS_INTERACTIVE[name]

        if name in {"describe", "commit", "squash"}:
            if "--editor" in rest:
                return (f"`jj {name} --editor` FORCES an editor open even with "
                        "-m/--stdin.\n"
                        "    Instead: drop --editor and pass the whole message to -m.")

        # `jj squash` prompts to COMBINE descriptions when the source and the
        # destination both have one — measured: editor opens and hangs. Which shape
        # you are in depends on repo state the hook cannot see from the command
        # string, so the safe default is to require an explicit choice. Both escapes
        # are cheap and both were verified non-interactive, so this is not a dead
        # end: -m sets the message, -u keeps the destination's.
        if name == "squash" and not has_message(rest) and not (
            {"-u", "--use-destination-message"} & set(rest)
        ):
            return ("`jj squash` opens an editor to COMBINE descriptions when the "
                    "source and\n"
                    "    destination both have one (jj cannot know which you meant).\n"
                    "    Instead: `jj squash -m \"combined message\"`, or\n"
                    "    `jj squash -u` to keep the destination's description as-is.")

        if name in {"describe", "commit"} and not has_message(rest):
            return (f"`jj {name}` with no -m/--message opens $EDITOR for the "
                    "description.\n"
                    f"    Instead: `jj {name} -m \"your message\"`.\n"
                    "    For a long message, write it to a file and use\n"
                    f"    `jj {name} -m \"$(cat msg.txt)\"` or `--stdin`.")

        # `resolve` needs BOTH escapes acknowledged: --list only inspects, and a
        # builtin `--tool :ours`/`:theirs` resolves without opening anything. The
        # --tool check above already let those through; blocking here anyway would
        # have made the documented non-interactive resolve unreachable.
        if (name == "resolve"
                and not ({"-l", "--list"} & set(rest))
                and tool not in NON_INTERACTIVE_TOOLS):
            return ("`jj resolve` opens a merge editor on each conflict.\n"
                    "    Instead: `jj resolve --list` to see the conflicted paths, then\n"
                    "    edit the files directly (jj leaves real conflict markers), or\n"
                    "    `jj resolve --tool :ours` / `:theirs` to take one side.")
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command or "jj" not in command:
        return 0
    if has_env_assignment(command, OVERRIDE):
        return 0

    reason = verdict(command)
    if reason is None:
        return 0

    sys.stderr.write(
        f"JJ INTERACTIVE BLOCKED: {reason}\n\n"
        "  An agent has no terminal, so this would not error — it would HANG until\n"
        "  the tool call times out, with no output to say why.\n"
        f"  If you are a human at a real terminal, re-run prefixed with {OVERRIDE}=1\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
