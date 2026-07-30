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


def _split_on_operators(tokens: list) -> list:
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


def segments(command: str) -> list:
    """Split into command segments on real shell operators AND newlines.

    A NEWLINE ENDS A COMMAND, and missing that made every gate here bypassable by
    the most ordinary shape there is. `shlex` treats `\\n` as plain whitespace, so
    `cd /tmp\\ngit commit` lexed as ONE segment whose command word is `cd` --
    `git commit` became mere arguments and no gate saw it. Measured against all
    four hooks plus a project gate: `git commit`, `git rebase -i`,
    `jj describe`, `rg -rn` and a squash on line 2 ALL passed. A heredoc made it
    worse, because the surviving delimiter word took the next line's command
    position (`cat <<EOF … EOF\\ngit commit` -> command word `EOF`).

    So lines are lexed one at a time. A line that does not lex (an unbalanced
    quote) is a multi-line QUOTED STRING rather than a syntax error, so it is
    joined with the next line and retried -- which is what keeps a multi-line
    commit message a single token, and therefore keeps a gated phrase quoted
    inside one from being read as a command.
    """
    out, buffer = [], ""
    for line in command.split("\n"):
        buffer = line if not buffer else f"{buffer}\n{line}"
        try:
            lexer = shlex.shlex(buffer, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            continue  # unterminated quote: the string continues on the next line
        out.extend(_split_on_operators(tokens))
        buffer = ""
    return out


def invocations_env(command: str, inherited: frozenset = frozenset()) -> list:
    """Every (command-word, args, env) actually being run.

    `env` is the set of assignments that APPLY to that invocation, read the way a
    shell scopes them: an assignment PREFIX applies to the command it prefixes and
    nothing else, while an assignment-only segment (or an `export`) carries forward
    to the commands after it.

    Getting this wrong is an escape hatch, not a nicety. A gate that looked for its
    override anywhere in the command string was disabled by
    `OVERRIDE=1 ls; <gated command>` -- an override attached to a command it was
    never meant for -- and even by `echo "OVERRIDE=1"` naming it, since after
    lexing that quoted mention is the same token. Measured on two gates; four
    escape shapes, all silent.

    The command word has its directory stripped, so `/opt/homebrew/bin/rg` is
    recognised as `rg` while `./tools/notjj` is NOT recognised as `jj`.
    """
    found, carried = [], set(inherited)
    for segment in segments(strip_heredoc_bodies(command)):
        env, index = set(carried), 0
        while index < len(segment) and (
            ASSIGNMENT.match(segment[index]) or segment[index] in PREFIXES
        ):
            if ASSIGNMENT.match(segment[index]):
                env.add(segment[index])
            index += 1

        if index >= len(segment):
            # Assignment-only segment: it survives for the rest of the shell.
            carried = env
            continue

        word, args = Path(segment[index]).name, segment[index + 1:]
        if word == "export":
            carried |= {token for token in args if ASSIGNMENT.match(token)}
            continue

        found.append((word, args, frozenset(env)))
        if word in SHELLS and "-c" in args:
            # An override prefixing the shell reaches the inner command through
            # the environment, so it carries down.
            nested = args.index("-c") + 1
            if nested < len(args):
                found.extend(invocations_env(args[nested], frozenset(env)))
    return found


def invocations(command: str) -> list:
    """Every (command-word, args) pair being run, ignoring environment."""
    return [(word, args) for word, args, _ in invocations_env(command)]


def overrides(env: frozenset, name: str, value: str = "1") -> bool:
    """True if `name=value` is in the env that applies to ONE invocation.

    Pair it with `invocations_env`, never with a whole-command search. The
    predecessor of this function took the command string and answered "does this
    assignment appear anywhere", which meant an override attached to an unrelated
    command -- or merely quoted in an `echo` -- switched the gate off. Scoping is
    the whole point, so the scope is now the only thing you can ask about.
    """
    return f"{name}={value}" in env
