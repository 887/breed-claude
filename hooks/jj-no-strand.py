#!/usr/bin/env python3
"""jj-no-strand — stop work being orphaned by `jj new`, and stop the EMPTY commit
it produces from being pushed.

## The trap, in the order it actually happens

`jj new <target>` with a re-parenting target does NOT carry your working-copy edits
to the new commit. jj snapshots them into the CURRENT change and then makes a new,
EMPTY commit off `<target>` the working copy. Nothing errors. The files vanish from
your working directory and `@` is empty on the target. Then — and this is where the
damage lands — you describe THAT commit, bookmark it, and push:

    <edits in @>
    jj new main              # edits stay behind; @ is now empty
    jj describe -m "..."     # the message describing work the commit does not carry
    jj bookmark set main -r @
    jj git push              # an EMPTY commit lands, with a message that lies

Measured on jj 0.42: `@` went from empty=false with `wip.txt` on disk to empty=true
with `wip.txt` gone, the content left behind on an unnamed head. Not data loss — but
the push is silent, and the branch now claims work it does not contain.

## Two checks, because the first one cannot be made both safe and quiet

CHECK A — `jj new <target>` while `@` holds UNCOMMITTED, UNDESCRIBED, UNBOOKMARKED
work. Deliberately NARROWER than "`@` is non-empty", which is what a predecessor of
this gate tested. A described or bookmarked `@` is a NAMED change: leaving it behind
is the normal way to start a sibling, you can find it again by name, and blocking it
produced exactly the false positives that trained me to prefix the override by
reflex — after which the override was in my fingers for the case that mattered, and
an empty commit reached `main` anyway. A gate that cries wolf on the safe shape is
how the real one gets through.

CHECK B — pushing an EMPTY commit. This is the damage itself rather than one route
to it, so it catches the trap no matter which sequence produced it, including the
one where check A was correctly silent. An empty non-merge commit at a bookmark you
are pushing is essentially never intended: it is a message with no bytes behind it.
Empty MERGE commits are normal and pass.

Right fix when `@` has work you want on the target:

    jj rebase -r @ -d <target>     # moves the CHANGE, edits included

Never blocked: `jj new` / `jj new @` (child of `@` strands nothing), an empty `@`,
`jj new` while `@` is described or bookmarked, and any push of a non-empty commit.

Overrides, each scoped to its own check so disabling one never disables the other:
`JJ_ALLOW_STRANDING=1`, `JJ_ALLOW_EMPTY_PUSH=1`.

This is a fact about **jj**, not a project convention: `jj new` re-parents rather
than moves, and a commit with no diff carries no work in any repository. It takes no
position on squashing, merge method, or commit shape.

Exit 2 = block. Exit 0 = allow.
"""

import json
import os
import sys
from pathlib import Path

# `subprocess` is imported LAZILY, inside the only function that shells out. It
# costs ~5 ms and is needed ONLY for `jj new` / `jj git push`; every other Bash
# call would otherwise pay it to reach an early return. Same lesson as gate.py's
# `traceback`: in a file that runs on every call, an idle import is charged to
# every call.

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import invocations_env, overrides  # noqa: E402

STRAND_OVERRIDE = "JJ_ALLOW_STRANDING"
EMPTY_OVERRIDE = "JJ_ALLOW_EMPTY_PUSH"

# jj global flags that CONSUME the next token, so it is not the subcommand.
VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
               "--config-toml", "--config-file", "--color", "--when-large-revsets"}

# `jj new` flags that take a value, so their argument is not a positional revset.
NEW_VALUE_FLAGS = {"-m", "--message"}

# Flags that re-parent without a positional revset.
INSERT_FLAGS = {"-A", "-B", "--after", "--before", "--insert-after", "--insert-before"}


def words_of(args):
    """Positional words of a jj invocation, with global value-flags consumed."""
    out, index = [], 0
    while index < len(args):
        token = args[index]
        if token in VALUE_FLAGS:
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        out.append(token)
        index += 1
    return out


def rest_after(args, count):
    """Everything after the first `count` positional words."""
    seen, index = 0, 0
    while index < len(args) and seen < count:
        token = args[index]
        if token in VALUE_FLAGS:
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        seen += 1
        index += 1
    return args[index:]


def target_directory(command):
    """Where the command runs: an inline `cd` wins, else this process's cwd.

    An UNEXPANDED variable (`cd "$T/ws"`) cannot be resolved — the variable is set
    inside the very command that has not run yet — so we return None and the caller
    stays silent rather than querying the wrong repo.
    """
    for word, args, _ in invocations_env(command):
        if word == "cd" and args:
            first = args[0]
            if any(ch in first for ch in "$`"):
                return None
            return first if first.startswith("/") else str(Path(os.getcwd()) / first)
    return os.getcwd()


def jj_field(cwd, revision, template, snapshot=False):
    """One `jj log` field, or None when jj cannot answer.

    `--ignore-working-copy` unless the question is ABOUT the working copy: without
    it every query would snapshot, mutating the repo as a side effect of inspecting
    it — and a PreToolUse hook runs on commands that have not happened yet.
    """
    import subprocess

    argv = ["jj", "log", "--no-graph", "-r", revision, "-T", template,
            "--color", "never"]
    if not snapshot:
        argv.insert(2, "--ignore-working-copy")
    try:
        done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return done.stdout.strip()


def reparents(args):
    """True if this `jj new` names a target other than `@` (positional or -A/-B)."""
    if INSERT_FLAGS & set(args):
        return True
    index = 0
    while index < len(args):
        token = args[index]
        if token in NEW_VALUE_FLAGS:
            index += 2
            continue
        if token.startswith("-"):
            # `-Atarget` / `--insert-after=x`: the value rides on the flag itself.
            if any(token.startswith(f) for f in INSERT_FLAGS):
                return True
            index += 1
            continue
        if token != "@":
            return True
        index += 1
    return False


def pushed_bookmarks(args):
    """Bookmark names an explicit `--bookmark`/`-b` names, in either spelling."""
    found, index = [], 0
    while index < len(args):
        token = args[index]
        if token in {"-b", "--bookmark"} and index + 1 < len(args):
            found.append(args[index + 1])
            index += 2
            continue
        for flag in ("-b=", "--bookmark="):
            if token.startswith(flag):
                found.append(token.split("=", 1)[1])
                break
        index += 1
    return found


def check_stranding(cwd, args):
    if not reparents(args):
        return None                      # child-of-@: nothing is left behind
    # Snapshot deliberately: the question is what the working copy holds RIGHT NOW.
    state = jj_field(cwd, "@", 'if(empty,"empty","full") ++ "|" ++ '
                              'if(description,"described","bare") ++ "|" ++ '
                              'bookmarks', snapshot=True)
    if state is None:
        return None                      # not a jj repo, or jj cannot answer
    empty, described, bookmarks = (state.split("|") + ["", "", ""])[:3]
    if empty == "empty":
        return None                      # nothing to strand
    if described == "described" or bookmarks.strip():
        # A NAMED change. Leaving it behind is how you start a sibling, and you can
        # find it again — this is the shape the older, wider rule blocked wrongly.
        return None
    return (
        "JJ STRANDING BLOCKED: `jj new <target>` while `@` holds uncommitted work that\n"
        "  is neither described nor bookmarked.\n\n"
        "  jj does NOT carry those edits to the new commit. They stay in the current\n"
        "  change — unnamed, so nothing points at it — and `@` becomes an EMPTY commit\n"
        "  off your target. Nothing errors; the files simply leave your working\n"
        "  directory.\n\n"
        "  If you want the current edits ON that target, move the CHANGE:\n"
        "      jj rebase -r @ -d <target>\n"
        "  To keep building here, keep editing, or name it first with `jj describe -m`.\n"
        f"  To leave the work behind deliberately: {STRAND_OVERRIDE}=1 <command>\n")


def check_empty_push(cwd, args):
    names = pushed_bookmarks(args)
    if not names:
        # No explicit --bookmark: which commits a bare push would send depends on
        # tracking state this gate does not model. Staying silent rather than
        # guessing — a wrong block here trains you to disable the check.
        return None
    for name in names:
        state = jj_field(cwd, name, 'if(empty,"empty","full") ++ "|" ++ '
                                    'parents.len() ++ "|" ++ description.first_line()')
        if state is None:
            continue
        empty, parents, subject = (state.split("|") + ["", "", ""])[:3]
        if empty != "empty":
            continue
        if parents.strip() not in {"0", "1"}:
            continue                     # an empty MERGE commit is normal
        return (
            f"JJ EMPTY PUSH BLOCKED: bookmark `{name}` points at a commit with NO changes.\n\n"
            f"  subject: {subject or '(no description)'}\n\n"
            "  Pushing it publishes a message with no bytes behind it. This is the\n"
            "  landing shape of the `jj new` trap: the edits stayed in the previous\n"
            "  change, and the description was written on the empty commit that\n"
            "  replaced it.\n\n"
            "  Look for your work first:   jj log -r 'heads(all())'\n"
            "  Move the change onto the bookmark, rather than re-describing:\n"
            "      jj rebase -r <the-change-with-your-edits> -d <target>\n"
            "      jj bookmark set <name> -r <that-change>\n"
            f"  If the empty commit is genuinely intended: {EMPTY_OVERRIDE}=1 <command>\n")
    return None


def check(command):
    """The whole decision: the message to emit, or None to allow."""
    if not command or "jj" not in command:
        return None

    cwd = None
    for word, args, env in invocations_env(command):
        if word != "jj":
            continue
        words = words_of(args)

        if words[:1] == ["new"] and not overrides(env, STRAND_OVERRIDE):
            if cwd is None:
                cwd = target_directory(command)
            if cwd is None:
                return None
            message = check_stranding(cwd, rest_after(args, 1))
            if message:
                return message

        if words[:2] == ["git", "push"] and not overrides(env, EMPTY_OVERRIDE):
            if cwd is None:
                cwd = target_directory(command)
            if cwd is None:
                return None
            message = check_empty_push(cwd, rest_after(args, 2))
            if message:
                return message
    return None


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
