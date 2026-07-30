"""_shellscan — find the COMMAND POSITIONS in a shell command string.

Shared by the hooks in this directory. Every gate here needs the same thing: not
"does this text contain X" but "is X actually being run". Matching text instead
has produced three separate false positives across these hooks, each blocking a
correct command:

  * `rg -n pat f 2>/dev/null; jj file list -r main` -- the `-r` is jj's, but
    `2>/dev/null;` arrives from `shlex.split` as ONE token matching no separator,
    so the scan never saw the command boundary and blamed it on rg.
  * `jj new 2>&1 | tail` -- a shell-side segment grab cut at the first `&`,
    leaving the fragment `2>`, which was then read as a positional revset.
  * `rg 'jj squash' CLAUDE.md`, `echo "never pass merge_method=squash"`, a heredoc
    brief naming the commands it tells a helper to avoid -- all blocked by a gate
    grepping raw text, including the very command written to test it.

Why a false positive is not cosmetic: a gate that fires on harmless text trains
you to prefix its override by reflex, and the override disables the whole check.
So over-blocking is how the real protection gets switched off.

The fix in all three cases is the same, so it lives here once:
`shlex.shlex(..., punctuation_chars=True)` returns shell operators as their OWN
tokens, which plain `shlex.split` does not. From that, command boundaries are
real, and quoted text -- which stays a single token -- can never be mistaken for
a command word.
"""

import re
import shlex
from pathlib import Path

# Characters that, alone or in a run, form a shell control/redirection operator.
OPERATORS = set(";|&<>()")

# Tokens that may precede a command word without being one.
PREFIXES = {"sudo", "env", "time", "command", "nohup", "then", "do", "else",
            "!", "{", "}", "if", "while", "until",
            # `xargs rg …` really is running rg, with rg's own flags following,
            # so treat the wrapper as a prefix and let rg be the command word.
            "xargs"}

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Shells whose `-c` argument is itself a command and must be scanned. Recursing
# closes a false NEGATIVE that text matching cannot even express: `bash -c 'jj
# squash'` really does run the thing.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def strip_heredoc_bodies(command: str) -> str:
    """Drop heredoc bodies. Their text is DATA, never commands.

    A brief written to an agent (`cat > brief.txt <<EOF ... EOF`) routinely names
    the very commands a gate blocks, precisely because it is saying not to run
    them.
    """
    lines = command.split("\n")
    kept = []
    index = 0
    while index < len(lines):
        line = lines[index]
        kept.append(line)
        match = re.search(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?", line)
        index += 1
        if not match:
            continue
        delimiter = match.group(1)
        while index < len(lines) and lines[index].strip() != delimiter:
            index += 1
        index += 1  # drop the delimiter line too
    return "\n".join(kept)


def segments(command: str) -> list:
    """Split into command segments on real shell operators."""
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return []  # unbalanced quotes: let the shell report it

    out, current = [], []
    for token in tokens:
        if token and all(ch in OPERATORS for ch in token):
            # `cmd 2>&1` lexes as [cmd, 2, >&, 1]; that bare `2` is a file
            # descriptor, not an argument. Drop it before anything reads it as one.
            if token[0] in "<>" and current and current[-1].isdigit():
                current.pop()
            if current:
                out.append(current)
                current = []
            continue
        current.append(token)
    if current:
        out.append(current)
    return out


def invocations(command: str) -> list:
    """Every (command-word, args) pair actually being run.

    The command word has its directory stripped, so `/opt/homebrew/bin/rg` is
    recognised as `rg` while `./tools/notjj` is NOT recognised as `jj`.
    """
    found = []
    for segment in segments(strip_heredoc_bodies(command)):
        index = 0
        while index < len(segment) and (
            ASSIGNMENT.match(segment[index]) or segment[index] in PREFIXES
        ):
            index += 1
        if index >= len(segment):
            continue
        word, args = segment[index], segment[index + 1:]
        found.append((Path(word).name, args))
        if Path(word).name in SHELLS and "-c" in args:
            nested = args.index("-c") + 1
            if nested < len(args):
                found.extend(invocations(args[nested]))
    return found


def has_env_assignment(command: str, name: str, value: str = "1") -> bool:
    """True if `name=value` appears as an environment ASSIGNMENT.

    Deliberately not a substring test: an override named inside a quoted string
    or a heredoc must NOT disable a gate, or documenting the override in prose
    would silently switch it off.
    """
    target = f"{name}={value}"
    for segment in segments(strip_heredoc_bodies(command)):
        for token in segment:
            if token == target:
                return True
    return False
