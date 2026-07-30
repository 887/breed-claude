#!/usr/bin/env python3
"""rg-flag-gate — block ripgrep short flags that silently mean something else.

Two grep habits produce WRONG-BUT-EXIT-0 output in ripgrep:

  rg -r  ->  --replace=TEXT   (NOT grep's "recursive"; rg recurses by default)
             `rg -rn 'pat' .` parses as --replace=n and rewrites every match to
             the literal "n". Exit 0, no error, output silently destroyed.
             See anthropics/claude-code#62016.

  rg -E  ->  --encoding=ENC   (NOT grep's "extended regex"; rg is already
             extended by default). `rg -E 'a|b'` consumes the pattern as an
             encoding name and errors, or worse consumes the NEXT argument.

Both are the same failure: a grep short flag that ripgrep spells differently.
This fails them EARLY, at the call site, instead of after you have read
corrupted output and theorised about rendering bugs.

Explicit long forms (--replace=, --encoding=) pass through: if you genuinely
mean them, say so.

PreToolUse hook on Bash. Exit 2 = block, with the stderr message shown back.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import invocations  # noqa: E402

BAD = {
    "r": (
        "`-r` is ripgrep's --replace=TEXT, NOT grep's recursive.",
        "ripgrep recurses by DEFAULT. `rg -rn 'pat' .` parses as --replace=n and\n"
        "  rewrites every match to the literal \"n\" -- exit 0, no error, output\n"
        "  silently destroyed (anthropics/claude-code#62016).",
        "rg -n 'pat' [path]      # line numbers, recursive by default\n"
        "  rg -ln 'pat' [path]     # files with matches\n"
        "  rg -C 3 'pat' [path]    # context",
    ),
    "E": (
        "`-E` is ripgrep's --encoding=ENC, NOT grep's extended-regex.",
        "ripgrep is ALREADY extended-regex by default, so -E is never needed for\n"
        "  alternation or grouping. `rg -E 'a|b'` consumes your pattern as an\n"
        "  encoding name.",
        "rg 'a|b' [path]         # alternation works with no flag\n"
        "  rg -e '-leading-dash'   # -e passes an explicit PATTERN\n"
        "  rg --encoding=utf-8 …   # if you really meant the encoding",
    ),
}


def offending_flag(command: str) -> "tuple[str, str] | None":
    """Return (token, flag-letter) for the first bad rg short flag, else None.

    Command boundaries come from `_shellscan`, which is what keeps a LATER
    command's flags from being blamed on rg — the false positive this gate
    shipped with (`… | rg …; jj file list -r main`, where the `-r` is jj's).
    """
    for word, args in invocations(command):
        if word != "rg":
            continue
        for token in args:
            if token == "--":
                break            # `--` ends flag parsing; the rest are operands
            if token.startswith("--"):
                continue         # long forms are explicit: --replace=/--encoding=
            if len(token) > 1 and token[0] == "-" and token[1:].isalpha():
                for flag in BAD:
                    if flag in token[1:]:
                        return token, flag
    return None


def check(command):
    """The whole decision: the message to emit, or None to allow.

    Kept separate from `main` so `gate.py` can call it in-process. Four separate
    hook registrations meant four python3 spawns per Bash call (~74 ms measured);
    one dispatcher importing four `check`s costs one.
    """
    if not command or "rg" not in command:
        return None

    found = offending_flag(command)
    if found is None:
        return None

    token, flag = found
    headline, why, instead = BAD[flag]
    return (
        f"RG FLAG GATE BLOCKED: `{token}` in `rg`\n\n"
        f"  {headline}\n\n"
        f"  {why}\n\n"
        f"  Use instead:\n  {instead}\n\n"
        "  This is a grep habit that ripgrep spells differently. If you truly want\n"
        "  the ripgrep meaning, pass the long form (--replace=… / --encoding=…) and\n"
        "  this gate will let it through.\n"
        "  Rule: ~/.claude/CLAUDE.md, the ripgrep flag-collision section.\n"
    )


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
