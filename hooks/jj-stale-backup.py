#!/usr/bin/env python3
"""jj-stale-backup — back a workspace up before `jj workspace update-stale`
overwrites it, and refuse the command if the backup cannot be made.

## The hazard

When workspace A rebases or describes a commit that workspace B has checked out,
jj marks B **stale**. `jj workspace update-stale` in B then re-checks-out the new
commit, **overwriting B's on-disk files**. jj does not snapshot B first, so any
un-snapshotted work there is destroyed with **no op-log record** — jj never saw
it, so `jj undo` cannot bring it back. Unrecoverable by design.

The trap is worse than it first looks, and this is what makes a guard necessary
rather than merely nice: snapshotting a *stale* workspace **fails**, because jj
refuses to run there. So the obvious defensive sequence — "snapshot first, then
update-stale" — silently no-ops on step one and then destroys the work on step
two. Doing the careful thing by hand is not enough.

This is the only hook here that **takes an action** instead of just refusing one:
it copies the workspace source, then allows the command. Worst case you lose
nothing and have a directory to restore from. If the copy fails, the command is
blocked, because an unbacked update-stale is a coin flip on unrecoverable data.

## Why this is user-scope and not a project hook

It encodes a fact about **jj**: `update-stale` clobbers un-snapshotted files and
the op log cannot undo it. True in every jj repo, in any language — which is the
bar for living here (see README.md).

It also has to be user-scope to work at all. Project hooks are registered as
`${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/…`, and `CLAUDE_PROJECT_DIR` is unset
whenever the session root is not the repo — an orchestrator session driving
several `jj workspace add` checkouts from a *different* cwd resolves that path to
`./.claude/hooks/…`, finds nothing, and enforces **zero** gate legs. That is
exactly the multi-workspace setup where update-stale gets run and where staleness
arises in the first place, so a project-scoped version of this guard is inert
precisely when it is needed.

## Scanning

Command-position based via `_shellscan`, so `rg 'jj workspace update-stale' docs/`
and `echo "never run jj workspace update-stale"` pass — the predecessor of this
hook grepped raw text and fired on both. The target directory is taken from a
`cd` in the same command when there is one, else from the payload's `cwd` (which
is the directory the tool call actually runs in — more reliable than the hook
process's own).

Override, when the tree is genuinely empty and you do not care:
`JJ_ALLOW_UNSAFE_UPDATE_STALE=1`.

Exit 2 = block, with the stderr message shown back. Exit 0 = allow (after the
backup, whose location is printed on stderr).
"""

import json
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import has_env_assignment, invocations  # noqa: E402

OVERRIDE = "JJ_ALLOW_UNSAFE_UPDATE_STALE"

BACKUP_ROOT = Path(os.environ.get("JJ_STALE_BACKUP_DIR",
                                  Path.home() / ".claude" / "jj-stale-backups"))

# Build output and VCS internals: never worth copying, and `target/` alone can be
# tens of GB, which would turn a safety net into a disk-filling hazard.
EXCLUDES = {"target", ".jj", ".git", "node_modules", "__pycache__",
            ".venv", "venv", "dist", "build", ".next", ".gradle", ".tox"}

# Above this, copying is itself a problem; say so and let the human decide.
MAX_MIB = int(os.environ.get("JJ_STALE_BACKUP_MAX_MIB", "4096"))


def block(message, *lines):
    sys.stderr.write(f"JJ STALE GUARD BLOCKED: {message}\n")
    for line in lines:
        sys.stderr.write(f"{line}\n")
    return 2


# jj global flags that CONSUME the next token, so it is not a subcommand word.
# Without this, `jj -R /some/repo workspace update-stale` slips through: dropping
# the flags alone leaves `/some/repo` sitting where `workspace` is expected.
JJ_VALUE_FLAGS = {"-R", "--repository", "--at-op", "--at-operation", "--config",
                  "--config-toml", "--config-file", "--color"}


def targets_update_stale(command):
    """True if `jj workspace update-stale` is actually being RUN."""
    for word, args in invocations(command):
        if word != "jj":
            continue
        words, index = [], 0
        while index < len(args):
            token = args[index]
            if token in JJ_VALUE_FLAGS:
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            words.append(token)
            index += 1
        if words[:2] == ["workspace", "update-stale"]:
            return True
    return False


def target_directory(payload, command):
    """Directory the command runs in; a `cd …` in the same command wins."""
    base = payload.get("cwd") or os.getcwd()
    for word, args in invocations(command):
        if word == "cd" and args:
            first = args[0]
            return first if first.startswith("/") else str(Path(base) / first)
    return base


def workspace_root(start):
    """Nearest ancestor containing `.jj`, or None."""
    path = Path(start).resolve()
    for candidate in [path, *path.parents]:
        if (candidate / ".jj").exists():
            return candidate
    return None


def source_size_mib(root):
    total = 0
    for dirpath, dirnames, filenames in os.walk(root, topdown=True):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDES]
        for name in filenames:
            try:
                total += (Path(dirpath) / name).stat().st_size
            except OSError:
                pass
    return total // (1024 * 1024)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command or "update-stale" not in command:
        return 0
    if not targets_update_stale(command):
        return 0
    if has_env_assignment(command, OVERRIDE) or os.environ.get(OVERRIDE) == "1":
        return 0

    where = target_directory(payload, command)
    if not Path(where).is_dir():
        return block(
            f"cannot resolve the workspace directory for update-stale "
            f"(guessed '{where}').",
            "Run it as:  cd /abs/path/to/workspace && jj workspace update-stale")

    root = workspace_root(where)
    if root is None:
        return block(f"'{where}' is not inside a jj workspace.",
                     "Check the path.")

    size = source_size_mib(root)
    if size > MAX_MIB:
        return block(
            f"workspace source at '{root}' is {size} MiB — too large to "
            "auto-backup safely.",
            "Back it up yourself, confirm the work is snapshotted from INSIDE the",
            f"workspace (cd '{root}' && jj st), then re-run prefixed with",
            f"{OVERRIDE}=1.")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = BACKUP_ROOT / f"{stamp}-{root.name}"
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(root, dest,
                        ignore=shutil.ignore_patterns(*EXCLUDES),
                        symlinks=True, ignore_dangling_symlinks=True)
    except (OSError, shutil.Error) as error:
        shutil.rmtree(dest, ignore_errors=True)
        return block(
            f"backup of '{root}' FAILED ({error}) — refusing to let update-stale "
            "overwrite un-snapshotted work.",
            "Copy the workspace by hand, then re-run prefixed with "
            f"{OVERRIDE}=1.")

    sys.stderr.write(
        f"jj-stale-backup: copied {root} -> {dest} ({size} MiB) before "
        "update-stale.\n"
        "jj-stale-backup: if update-stale discards work, restore from there.\n"
        "  (jj takes no op-log snapshot of a stale workspace, so `jj undo` "
        "cannot.)\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
