#!/usr/bin/env python3
"""jj-no-edit-on-pushed — refuse a file edit while `@` is a commit that is
already on a remote, because jj's auto-snapshot silently rewrites it.

## The trap

jj has no staging area. The working copy IS a commit, and the next jj command
snapshots whatever is on disk into `@`. So editing a file while `@` sits on an
already-pushed commit does not create new work — it AMENDS the pushed commit:

    jj git push --bookmark my-branch   # @ REMAINS on the pushed commit
    <edit a file>                      # snapshotted into THAT commit
    jj new                             # too late; @ already carries the edit

The local change now differs from the remote counterpart sharing its change id.
That is divergence: the next push is refused, or accepted as a rewrite of
history someone else may already have pulled.

## Why jj's own immutability does NOT already cover this

Measured on jj 0.42, and this is the whole reason the gate is narrow rather
than redundant:

- Pushing **trunk** is safe on its own. `builtin_immutable_heads()` includes
  `trunk()`, so after `jj git push --bookmark main` jj prints "The working-copy
  commit became immutable; a new commit has been created on top of it" and
  moves `@` off. A later `jj edit main` is refused outright.
- Pushing a **feature bookmark** is NOT. `@` stays exactly where it was, and
  the commit reports `MUTABLE`. Nothing warns, nothing moves, and the next
  edit lands in the pushed commit.

So the exposure is precisely: work pushed to a branch that is not trunk — which
is every ordinary feature branch, and the shape that actually cost this fleet
repeated divergence repairs.

## The revset, and the subtraction that looks right and is wrong

An earlier draft of this gate used:

    @ & ::(remote_bookmarks() ~ remote_bookmarks(remote=exact:"git"))

reasoning that a colocated repo gives every local bookmark a `<name>@git`
counterpart, so the git remote must be excluded or ordinary local work looks
pushed. The exclusion is necessary. That expression does not achieve it.

`~` subtracts COMMITS, not bookmarks. In a colocated repo `mybranch@git` and
`mybranch@origin` point at the SAME commit, so subtracting the git set removes
that commit from the result entirely — and the gate silently never fires. It
tested green on every "must pass" case for exactly the wrong reason.

The working form enumerates real remotes by NAME (`jj git remote list` does not
report the implicit git remote) and unions a per-remote revset. If a remote is
literally named "git" it is skipped, which is the only case the name-based
filter needs to handle.

## Why this FAILS OPEN, unlike the Bash gates

`gate.py` fails closed: a broken gate blocks the command. That is right for a
gate guarding a handful of dangerous VCS commands.

This one runs on EVERY file edit, everywhere — including directories that are
not jj repos, and machines without jj. Failing closed there would make the tool
unable to edit anything, a far worse failure than the one it prevents. So: no
repo, no jj, no remotes, or an unparseable answer means allow. The narrowing
that makes that acceptable is that it only blocks on a POSITIVE answer — jj
must actively report `@` reachable from a real remote's bookmark.

## What it deliberately does NOT catch

- A pushed commit with no remote bookmark at or after it. Invisible here, and
  equally invisible to `jj git push`.
- A tool call with no `file_path`.
- Deliberate amendment of a pushed commit. That is what the override is for.

Exit 2 = block, message on stderr. Exit 0 = allow.
"""

import json
import os
import sys

OVERRIDE = "CLAUDE_ALLOW_EDIT_ON_PUSHED"

# NotebookEdit and MultiEdit write to disk exactly as Edit does; the trap does
# not care which tool produced the bytes.
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}


def run(argv, cwd):
    """stdout of a successful command, else None. jj is never required to exist."""
    import subprocess

    try:
        done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return done.stdout


def workspace_root(start):
    """The jj workspace containing `start`, or None.

    Resolved from the EDITED FILE's directory rather than the process cwd: a
    session often has several workspaces open at once, and the cwd need not be
    the one the edit lands in.
    """
    out = run(["jj", "workspace", "root"], start)
    return out.strip() if out and out.strip() else None


def real_remotes(cwd):
    """Remote names, excluding the implicit colocated git remote.

    `jj git remote list` prints `<name> <url>` per line and does not report the
    implicit git remote of a colocated repo — which is what makes a name-based
    filter correct where a revset subtraction is not.
    """
    out = run(["jj", "git", "remote", "list"], cwd)
    if not out:
        return []
    names = []
    for line in out.splitlines():
        name = line.split(None, 1)[0] if line.split() else ""
        if name and name != "git":
            names.append(name)
    return names


def pushed_revset(remotes):
    union = " | ".join(f'remote_bookmarks(remote=exact:"{n}")' for n in remotes)
    return f"@ & ::({union})"


def working_copy_is_pushed(cwd, remotes):
    """(is_pushed, change_id). True only on an affirmative answer from jj.

    `--ignore-working-copy` matters twice over: without it the query would
    snapshot the working copy — performing, as a side effect of inspecting,
    exactly the mutation this gate exists to prevent, before the edit it is
    judging has happened.
    """
    out = run(
        ["jj", "log", "--ignore-working-copy", "--no-graph",
         "-r", pushed_revset(remotes),
         "-T", 'change_id.short() ++ "\\n"', "--color", "never"],
        cwd,
    )
    if out is None:
        return False, None
    text = out.strip()
    return bool(text), (text.splitlines()[0] if text else None)


def bookmarks_at(cwd, remotes):
    """Bookmark names on `@`, for the message. Best effort; never blocks."""
    out = run(
        ["jj", "log", "--ignore-working-copy", "--no-graph",
         "-r", pushed_revset(remotes), "-T", 'bookmarks ++ "\\n"', "--color", "never"],
        cwd,
    )
    return out.strip() if out else ""


def message(change_id, names):
    where = f" ({names})" if names else ""
    ident = change_id or "@"
    return (
        f"BLOCKED: `@` is `{ident}`{where} — a commit already pushed to a remote.\n"
        "\n"
        "jj has no staging area: the working copy IS a commit, and the next jj\n"
        "command snapshots this edit INTO it. Editing now amends a pushed commit\n"
        "rather than starting new work, which diverges the local change from the\n"
        "remote counterpart sharing its change id — refused, or worse accepted,\n"
        "on the next push.\n"
        "\n"
        "jj does not catch this for you here. Pushing TRUNK moves `@` off the\n"
        "commit and makes it immutable; pushing a FEATURE bookmark leaves `@`\n"
        "sitting on it, mutable, with no warning.\n"
        "\n"
        "Do this first:\n"
        "\n"
        "    jj new\n"
        "\n"
        "then make the edit. That is the entire fix — the trap is only that the\n"
        "two orders look identical while you are typing them.\n"
        "\n"
        "If you genuinely mean to amend the pushed commit — and the house rule is\n"
        f"that you usually do not — set {OVERRIDE}=1 for that call.\n"
    )


def check(file_path):
    """The gate's whole policy. Returns stderr text to block with, or None."""
    if not file_path:
        return None
    if os.environ.get(OVERRIDE) == "1":
        return None

    start = os.path.dirname(os.path.abspath(file_path)) or os.getcwd()
    # An edit may create a file in directories that do not exist yet; walk up to
    # something real before asking jj, or jj answers about the wrong place.
    while start and not os.path.isdir(start):
        parent = os.path.dirname(start)
        if parent == start:
            return None
        start = parent

    root = workspace_root(start)
    if root is None:
        return None                       # not a jj workspace, or no jj: allow

    remotes = real_remotes(root)
    if not remotes:
        return None                       # nothing pushed anywhere: allow

    pushed, change_id = working_copy_is_pushed(root, remotes)
    if not pushed:
        return None

    return message(change_id, bookmarks_at(root, remotes))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    if payload.get("tool_name") not in EDIT_TOOLS:
        return 0

    text = check(payload.get("tool_input", {}).get("file_path", ""))
    if text is None:
        return 0
    sys.stderr.write(text)
    return 2


if __name__ == "__main__":
    sys.exit(main())
