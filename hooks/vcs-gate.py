#!/usr/bin/env python3
"""vcs-gate — PreToolUse(Bash) VCS command-safety gate.

Two cheap checks, each with its OWN override so disabling one never disables the
other:

  A. NO SQUASH / NO REWRITE OF SHARED HISTORY (CLAUDE.md)
     override VCS_GATE_ALLOW_HISTORY_REWRITE=1. Blocks `jj squash`, a PR
     squash-merge (`gh pr merge --squash`/`-s`, or `merge_method=squash`),
     `jj rebase -b/--branch`, and a history-rewriting jj op
     (describe/squash/abandon/edit/metaedit) aimed at an already-bookmarked rev.
     Rationale: a jj change ID survives rebases and amends where a git hash does
     not, so squashing destroys the only durable identifier the work has.

  B. NO `jj new` STRANDING OF A DIRTY @ (CLAUDE.md / kg memory)
     override VCS_GATE_ALLOW_JJ_NEW_STRANDING=1. `jj new <target>` (a positional
     revset other than `@`, or -A/-B) while `@` is non-empty does NOT move your
     edits. jj snapshots them into `@` first, then makes a NEW empty commit off
     <target> the working copy — so the files vanish from your working directory
     and `@` is empty on the target. Nothing errors. Verified 2026-07-30:
     `@` went from empty=false with wip.txt on disk to empty=true with wip.txt
     gone, the content left behind on an unnamed head. Not data loss, but if you
     then bookmark and push you push the EMPTY commit (this is how the KG-F
     ledger, auth/pat, and plan-252/008 all landed empty).
     Right fix when @ is dirty: `jj rebase -r @ -d <target>` moves the CHANGE
     with its content (verified: same change ID, new parent, files intact).
     Never blocked: the child-of-@ forms (`jj new`, `jj new @`), or an empty `@`
     where there is nothing to strand.

## Why this TOKENIZES instead of grepping the command text

The previous shell implementation pattern-matched the raw command string, so any
command that merely MENTIONED a gated phrase was blocked: `rg 'jj squash'
CLAUDE.md`, `echo "never pass merge_method=squash"`, an inline `jj describe -m`
whose message quotes the rule, a heredoc brief telling a helper what to avoid.
Measured against a dirty `@`: 7 of 7 such commands tripped. It was self-
demonstrating — the shell command written to TEST the false positive was itself
blocked by its own test data.

That matters beyond annoyance. The documented way past is the override env var,
which switches the whole check off — so a gate that fires on harmless text
trains you to prefix the override reflexively, and then it is not guarding the
case it exists for.

So this scans COMMAND POSITIONS: the string is split into segments on real shell
operators, each segment's command word is found (skipping env assignments and
prefixes like sudo/env/time), and a check fires only when the command word is
actually `jj` or `gh`. Quoted text stays one token and can never be a command
word. Heredoc BODIES are stripped, being data. `bash -c '…'` is recursed into,
which also closes a false NEGATIVE the text grep had no notion of.

Exit 2 = block, with the stderr message shown back. Exit 0 = allow.
"""

import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

# Characters that, alone or in a run, form a shell control/redirection operator.
OPERATORS = set(";|&<>()")

# Tokens that may precede a command word without being one.
PREFIXES = {"sudo", "env", "time", "command", "nohup", "then", "do", "else", "!", "{", "}"}

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# jj global flags that CONSUME the next token, so it is not the subcommand.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color", "--when-large-revsets"}

# Shells whose `-c` argument is itself a command and must be scanned.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}

HISTORY_REWRITE_OPS = {"describe", "squash", "abandon", "edit", "metaedit"}

OVERRIDE_HISTORY = "VCS_GATE_ALLOW_HISTORY_REWRITE"
OVERRIDE_STRANDING = "VCS_GATE_ALLOW_JJ_NEW_STRANDING"


def strip_heredoc_bodies(command: str) -> str:
    """Drop heredoc bodies. Their text is DATA, never commands.

    A brief written to a helper (`cat > brief.txt <<EOF … EOF`) routinely names
    the very commands this gate blocks, precisely because it is telling the
    helper not to run them.
    """
    lines = command.split("\n")
    kept: "list[str]" = []
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


def segments(command: str) -> "list[list[str]]":
    """Split into command segments on real shell operators.

    `punctuation_chars=True` is what makes operators arrive as their OWN tokens;
    plain `shlex.split` returns `2>/dev/null;` as one opaque token, which is the
    bug that made two earlier gates misattribute a later command's flags.
    """
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return []  # unbalanced quotes: let the shell report it

    out: "list[list[str]]" = []
    current: "list[str]" = []
    for token in tokens:
        if token and all(ch in OPERATORS for ch in token):
            # `jj new 2>&1` lexes as [jj, new, 2, >&, 1]; that bare `2` is a file
            # descriptor, not a positional revset. Drop it before it can be read
            # as one -- the exact misread that blocked a safe `jj new`.
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


def invocations(command: str) -> "list[tuple[str, list[str]]]":
    """Every (command-word, args) pair, recursing into `bash -c '…'`."""
    found: "list[tuple[str, list[str]]]" = []
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


def has_override(command: str, name: str) -> bool:
    """True if `name=1` appears as an environment ASSIGNMENT, not inside a string."""
    for segment in segments(strip_heredoc_bodies(command)):
        for token in segment:
            if token == f"{name}=1":
                return True
    return False


def jj_subcommand(args: "list[str]") -> "tuple[str | None, list[str]]":
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


def workspace_root(payload: dict, command: str) -> str:
    """Directory the command actually runs in; a leading `cd …` wins."""
    base = payload.get("cwd") or "."
    for word, args in invocations(command):
        if word == "cd" and args:
            target = args[0]
            return target if target.startswith("/") else f"{base}/{target}"
    return base


def jj_query(root: str, template: str, revision: str) -> str:
    """One `jj log` field, or '' when jj cannot answer."""
    try:
        result = subprocess.run(
            ["jj", "log", "--no-graph", "-r", revision, "-T", template],
            cwd=root, capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def block(message: str, *lines: str) -> "int":
    sys.stderr.write(f"VCS GATE BLOCKED: {message}\n")
    for line in lines:
        sys.stderr.write(f"{line}\n")
    return 2


def check_history_rewrite(payload: dict, command: str,
                          calls: "list[tuple[str, list[str]]]") -> int:
    tail = ("Repo rule (CLAUDE.md): we keep commits separate — no squashing, no "
            "rewriting shared history.",
            f"If the user EXPLICITLY asked for this, re-run prefixed with {OVERRIDE_HISTORY}=1")

    for word, args in calls:
        if word == "jj":
            subcommand, rest = jj_subcommand(args)
            if subcommand == "squash":
                return block("`jj squash` squashes changes together.", *tail)
            if subcommand == "rebase" and ({"-b", "--branch"} & set(rest)):
                return block(
                    "`jj rebase -b/--branch` rebases the entire branch/stack — "
                    "rebase a specific revision (-r) instead, or ask first.", *tail)
            if subcommand in HISTORY_REWRITE_OPS:
                revision = "@"
                for index, token in enumerate(rest):
                    if token in {"-r", "--revisions"} and index + 1 < len(rest):
                        revision = rest[index + 1]
                        break
                    if token.startswith(("-r=", "--revisions=")):
                        revision = token.split("=", 1)[1]
                        break
                root = workspace_root(payload, command)
                bookmarks = jj_query(root, "bookmarks", revision).replace(" ", "")
                if bookmarks:
                    return block(
                        f"a history-rewriting jj op targets revision '{revision}', "
                        f"which is already bookmarked ({bookmarks}).", *tail)

        if word == "gh":
            if args[:2] == ["pr", "merge"] and ({"--squash", "-s"} & set(args)):
                return block(
                    "`gh pr merge --squash` squash-merges the PR "
                    "(use --merge / merge_method=merge).", *tail)
            if "merge_method=squash" in args:
                return block(
                    "a squash merge (merge_method=squash) — use merge_method=merge "
                    "so commits + change-ids survive.", *tail)
    return 0


def check_new_stranding(payload: dict, command: str,
                        calls: "list[tuple[str, list[str]]]") -> int:
    for word, args in calls:
        if word != "jj":
            continue
        subcommand, rest = jj_subcommand(args)
        if subcommand != "new":
            continue

        insert_flags = {"-A", "-B", "--after", "--before",
                        "--insert-after", "--insert-before"}
        has_target = bool(insert_flags & set(rest))
        if not has_target:
            index = 0
            while index < len(rest):
                token = rest[index]
                if token in {"-m", "--message"}:
                    index += 2
                    continue
                if token.startswith("-"):
                    index += 1
                    continue
                if token != "@":
                    has_target = True
                    break
                index += 1
        if not has_target:
            return 0  # child-of-@: the edits stay in @, nothing is stranded

        root = workspace_root(payload, command)
        if jj_query(root, "empty", "@") != "false":
            return 0  # an empty @ has nothing to strand

        return block(
            "`jj new` with a re-parenting target while @ has uncommitted edits.",
            "Those working-copy edits will NOT travel to the new commit — they stay behind in the",
            "current change as a sibling, and @ becomes an EMPTY commit off your target.",
            "",
            "If you want the current edits ON that target, move the CHANGE instead:",
            "    jj rebase -r @ -d <target>",
            "To keep building the current change, just keep editing (or `jj describe`/`jj commit`).",
            "If you REALLY mean to leave the WIP behind and start fresh, re-run prefixed with",
            f"    {OVERRIDE_STRANDING}=1")
    return 0


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command:
        return 0
    # Cheap bail-out: neither tool named anywhere means neither check can fire.
    if "jj" not in command and "gh" not in command:
        return 0

    calls = invocations(command)

    if not has_override(command, OVERRIDE_HISTORY):
        verdict = check_history_rewrite(payload, command, calls)
        if verdict:
            return verdict

    if not has_override(command, OVERRIDE_STRANDING):
        verdict = check_new_stranding(payload, command, calls)
        if verdict:
            return verdict

    return 0


if __name__ == "__main__":
    sys.exit(main())
