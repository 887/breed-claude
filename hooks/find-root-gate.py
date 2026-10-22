#!/usr/bin/env python3
"""find-root-gate — block filesystem-wide scans of `/`, mounted drives and $HOME.

`find / -name x`, `rg pat /`, `du -a /media` and their cousins walk every file under
a root: hundreds of thousands of directory reads, minutes of sustained disk load, and
on a failing or spun-down drive they are exactly the wrong thing to run. The answer
is nearly always one directory (the repo, a build dir, the one clone you already
know) and a search scoped to it.

Blocked, when a scanner's operand is a broad root:
  scanners: find fd fdfind du tree ncdu rg ag ack grep/egrep/fgrep (recursive) ls -R
  broad roots: `/`, `/*`, `/media`, `/media/<drive>`, `/mnt`, `/mnt/<drive>`,
  `/run/media/...`, `/home`, `/home/<user>`, `$HOME`, `~`, `/Users`, `/Volumes`,
  and the top-level system trees `/usr /var /opt /proc /sys /dev /srv`.

Allowed: any narrower path, relative paths, and a root scan that is explicitly
shallow (`find / -maxdepth 1`, `fd -d 1`, `du -d 1`, `tree -L 1`).

Override for the rare real need, scoped to ONE command the way a shell scopes it:
`CLAUDE_ALLOW_ROOT_SCAN=1 find / ...`.

PreToolUse hook on Bash. Exit 2 = block, with the stderr message shown back.
"""

import json
import os
import posixpath
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import invocations_env, overrides  # noqa: E402

OVERRIDE = "CLAUDE_ALLOW_ROOT_SCAN"
HOME = os.path.expanduser("~")

# Scanners that always walk their path operands recursively.
ALWAYS = {"find", "fd", "fdfind", "du", "tree", "ncdu", "rg", "ag", "ack"}
# Scanners that recurse only with a flag.
GREP = {"grep", "egrep", "fgrep"}

SYSTEM_TREES = {"usr", "var", "opt", "proc", "sys", "dev", "srv"}
FIND_LEADING_OPTIONS = re.compile(r"^-(H|L|P|D\w*|O\d)$")
GLOB_TAIL = re.compile(r"(/\*+)+$")


def normalize(operand: str) -> "str | None":
    """The absolute path an operand names, or None for a relative or non-path word."""
    path = operand.replace("${HOME}", HOME).replace("$HOME", HOME)
    if path == "~" or path.startswith("~/"):
        path = HOME + path[1:]
    if not path.startswith("/"):
        return None
    path = GLOB_TAIL.sub("", path) or "/"
    path = posixpath.normpath(path)
    return "/" if path.startswith("//") and path.strip("/") == "" else path


def broad(path: str) -> bool:
    parts = [part for part in path.split("/") if part]
    if not parts:
        return True
    head = parts[0]
    if head in ("media", "mnt", "Volumes"):
        return len(parts) <= 2
    if head == "run":
        return parts[:2] == ["run", "media"] and len(parts) <= 4 or len(parts) == 1
    if head in ("home", "Users"):
        return len(parts) <= 2
    if head in SYSTEM_TREES:
        return len(parts) == 1
    return path == HOME


def depth_limit(word: str, args: list) -> "int | None":
    """An explicit depth bound the command carries, if any."""
    names = {
        "find": ("-maxdepth",),
        "fd": ("-d", "--max-depth", "--maxdepth"),
        "fdfind": ("-d", "--max-depth", "--maxdepth"),
        "du": ("-d", "--max-depth"),
        "tree": ("-L",),
    }.get(word, ())
    for index, token in enumerate(args):
        for name in names:
            value = None
            if token == name and index + 1 < len(args):
                value = args[index + 1]
            elif token.startswith(name + "=") or (
                name.startswith("--") is False and token.startswith(name) and token[len(name):].isdigit()
            ):
                value = token.split("=", 1)[1] if "=" in token else token[len(name):]
            if value is not None and value.isdigit():
                return int(value)
    return None


def operands(word: str, args: list) -> list:
    """The path-like operands of one scanner invocation."""
    if word == "find":
        found = []
        for token in args:
            if FIND_LEADING_OPTIONS.match(token) and not found:
                continue
            if token.startswith(("-", "(", "!", ")")) or token == "--":
                break
            found.append(token)
        return found
    return [token for token in args if not token.startswith("-")]


def recursive(word: str, args: list) -> bool:
    if word in ALWAYS:
        return True
    if word in GREP:
        return any(
            token in ("--recursive", "--dereference-recursive")
            or (re.fullmatch(r"-[A-Za-z]*[rR][A-Za-z]*", token) is not None)
            for token in args
        )
    if word == "ls":
        return any(
            token == "--recursive" or re.fullmatch(r"-[A-Za-z]*R[A-Za-z]*", token) is not None
            for token in args
        )
    return False


def offending(command: str) -> "tuple[str, str] | None":
    """(command word, broad root) for the first unscoped scan, else None."""
    for word, args, env in invocations_env(command):
        if (word not in ALWAYS and word not in GREP and word != "ls") or not recursive(word, args):
            continue
        if overrides(env, OVERRIDE):
            continue
        limit = depth_limit(word, args)
        if limit is not None and limit <= 1:
            continue
        for operand in operands(word, args):
            path = normalize(operand)
            if path is not None and broad(path):
                return word, operand
    return None


def check(command):
    """The whole decision: the message to emit, or None to allow."""
    if not command or not any(
        name in command for name in ("find", "fd", "du", "tree", "ncdu", "rg", "ag", "ack", "grep", "ls")
    ):
        return None
    found = offending(command)
    if found is None:
        return None
    word, operand = found
    return (
        f"FIND ROOT GATE BLOCKED: `{word} … {operand}` scans a whole root\n\n"
        "  That walks every file under it: minutes of sustained disk reads, and the\n"
        "  wrong thing to do to a slow or failing drive.\n\n"
        "  Scope it instead:\n"
        "    - name the one directory you mean (the repo, a clone, a build dir);\n"
        "    - inside a repo use `rg --files`, `jj file list`, `git ls-files`;\n"
        "    - shallow looks are fine: `find / -maxdepth 1`, `fd -d 1`, `du -d 1`.\n\n"
        "  A real need, for ONE command:  CLAUDE_ALLOW_ROOT_SCAN=1 <command>\n"
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
