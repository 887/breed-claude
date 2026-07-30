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
import shlex
import sys

# Tokens that may precede a command name without ending the pipeline.
PREFIXES = {"xargs", "time", "sudo", "env", "command", "then", "do", "else", "!"}

# Characters that, alone or in a run, form a shell control/redirection operator.
# Any token made only of these ends the current command, so a flag after it
# belongs to a DIFFERENT command and must not be attributed to rg.
PUNCTUATION = set(";|&<>()")

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
    """Return (token, flag-letter) for the first bad rg short flag, else None."""
    # `punctuation_chars=True` makes the lexer return shell operators as their
    # OWN tokens, which plain `shlex.split` does not. Without it, an operator
    # glued to adjacent text -- `2>/dev/null;`, `cmd|rg`, `2>&1` -- arrives as
    # one opaque token that matches no separator, so the command boundary is
    # missed, `in_rg` never resets, and the NEXT command's `-r` is blamed on rg.
    # That false positive fired on `… | rg …; jj file list -r main`, where the
    # `-r` is jj's. Splitting on real operators is what makes the scan track
    # command boundaries rather than guess at them.
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        # Unbalanced quotes: not our problem, let the shell report it.
        return None

    in_rg = False
    for token in tokens:
        if token and all(ch in PUNCTUATION for ch in token):
            in_rg = False
            continue
        if token in PREFIXES:
            continue

        if not in_rg:
            in_rg = token == "rg" or token.endswith("/rg")
            continue

        # Inside an rg invocation. `--` ends flag parsing entirely.
        if token == "--":
            in_rg = False
            continue
        if token.startswith("--"):
            continue

        if len(token) > 1 and token[0] == "-" and token[1:].isalpha():
            for flag in BAD:
                if flag in token[1:]:
                    return token, flag

    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command or "rg" not in command:
        return 0

    found = offending_flag(command)
    if found is None:
        return 0

    token, flag = found
    headline, why, instead = BAD[flag]
    sys.stderr.write(
        f"RG FLAG GATE BLOCKED: `{token}` in `rg`\n\n"
        f"  {headline}\n\n"
        f"  {why}\n\n"
        f"  Use instead:\n  {instead}\n\n"
        "  This is a grep habit that ripgrep spells differently. If you truly want\n"
        "  the ripgrep meaning, pass the long form (--replace=… / --encoding=…) and\n"
        "  this gate will let it through.\n"
        "  Rule: ~/.claude/CLAUDE.md, the ripgrep flag-collision section.\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
