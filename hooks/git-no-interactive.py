#!/usr/bin/env python3
"""git-no-interactive — block git commands that would open an editor and hang,
or open a stdin-driven TUI and silently do nothing.

Same premise as its jj sibling: an agent has no terminal. A git command that
launches `$GIT_EDITOR` does not fail, it **waits forever**, holding the tool call
open until it times out. Nothing errors, nothing prints, and the transcript shows
a command that simply never returned — the worst failure shape there is, because
there is no signal at all.

This is a fact about **git plus the absence of a tty**, not a repo convention, so
it holds in every repository. It takes no position on commit shape, squashing, or
merge method — those are project decisions and belong to the project (see
README.md, "What does NOT belong here").

## Everything here was MEASURED, not recalled

Each rule was probed against real git with `GIT_EDITOR` set to a script that logs
and then sleeps, run with stdin at /dev/null under `timeout` — so "opens an
editor" and "hangs" are observations, with a control case in every run that had to
report a hang or the run was discarded. That mattered: three of these I would have
gotten wrong from memory, and blocking a correct command is not cosmetic — it
trains you to reflexively prefix the override, which switches the whole gate off.

Measured EDITOR + HANG, therefore blocked:

    git commit                       no message flag -> editor
    git commit --amend               without --no-edit/-m
    git commit --squash=<c>          --squash does NOT supply a message
    git commit -e/--edit             forces the editor even alongside -m
    git commit -c/--reedit-message   lowercase -c REedits; blocked
    git commit -t/--template         opens the template for editing
    git commit --allow-empty-message still opens the editor
    git add -e/--edit                edits the patch in $EDITOR
    git merge -e/--edit              forces the merge-message editor
    git rebase -i/--interactive      via GIT_SEQUENCE_EDITOR
    git rebase --edit-todo
    git pull --rebase=interactive    same sequence editor, one call deeper
    git tag -a/-s/-u  without -m/-F
    git notes add/append without -m/-F, and `notes edit` always (takes no -m)
    git branch --edit-description
    git config --edit/-e
    git revert -e/--edit

Measured NO editor, therefore deliberately allowed — these are the
false-positive cases, and they outnumber the blocks on purpose:

    git commit --fixup=<c>           builds the message itself
    git commit --amend --no-edit
    git commit -C/--reuse-message    UPPERCASE -C reuses without editing
    git commit -F/--file, -m
    git commit -i                    -i is --INCLUDE for commit, NOT interactive
    git merge / git merge --no-ff    editor is tty-conditional; without one, none
    git rebase <upstream>            plain rebase never edits
    git revert / git cherry-pick     also tty-conditional
    git tag -a -m / git notes add -m

Measured NO editor and NO hang, but blocked anyway on the other half of the bar —
they read stdin, hit EOF immediately, and **exit 0 having done nothing**, which is
the same "succeeds while doing the wrong thing" shape as the rg `-r` case:

    git add -p/-i, git commit -p, git checkout/restore/reset -p,
    git stash push/save -p, git clean -i, git am -i,
    git mergetool, git difftool (without -y/--no-prompt)

No correct command is lost to these: every one is interactive by definition, so
there is no non-interactive intent they could have expressed.

Override, for a human at a real terminal: prefix with
`GIT_GATE_ALLOW_INTERACTIVE=1`.

Scanning is command-position based via `_shellscan`, so `rg 'git commit' docs/`,
`echo "never run git rebase -i"`, and a heredoc brief naming these commands all
pass — only a real invocation is blocked.

Exit 2 = block, with the stderr message shown back. Exit 0 = allow.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _shellscan import has_env_assignment, invocations  # noqa: E402

OVERRIDE = "GIT_GATE_ALLOW_INTERACTIVE"

# git GLOBAL flags that consume the following token, so it is not the subcommand.
# (`git -c core.editor=x commit` must still be seen as `commit`.)
GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                   "--exec-path", "--super-prefix", "--config-env"}

SHORT_CLUSTER = re.compile(r"^-[A-Za-z]+$")

HANG_NOTE = ("An agent has no terminal, so this does NOT error — it HANGS until the\n"
             "  tool call times out, with no output to say why.")
NOOP_NOTE = ("This reads its choices from stdin. With no terminal it hits EOF at once\n"
             "  and exits 0 having done NOTHING — it looks like it worked.")


def subcommand(args):
    """First non-flag arg (the subcommand) plus everything after it."""
    index = 0
    while index < len(args):
        token = args[index]
        if token in GIT_VALUE_FLAGS:
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token, args[index + 1:]
    return None, []


def shorts(args):
    """Every short-flag LETTER present, unbundling clusters.

    `git commit -am "msg"` carries its message in a cluster; reading only whole
    tokens would miss the `m`, block the single most common commit form, and get
    the gate switched off. Case is preserved because for `git commit` `-C` reuses
    a message while `-c` reopens the editor — opposite verdicts, one letter apart.
    """
    found = set()
    for token in args:
        if token == "--":
            break
        if SHORT_CLUSTER.match(token):
            found.update(token[1:])
    return found


def has_long(args, names):
    """True if any of `names` appears as `--flag` or `--flag=value`."""
    for token in args:
        if token == "--":
            break
        if token in names or any(token.startswith(f"{n}=") for n in names):
            return True
    return False


def long_value(args, name):
    """Value of `--name value` or `--name=value`, else None."""
    for index, token in enumerate(args):
        if token == name and index + 1 < len(args):
            return args[index + 1]
        if token.startswith(f"{name}="):
            return token.split("=", 1)[1]
    return None


# Subcommands that only ever run a TUI, with nothing to opt out to.
ALWAYS_TUI = {
    "mergetool": "`git mergetool` exists only to drive an interactive merge tool.",
}

# (subcommand, {long patch flags}) whose -p/--patch selects hunks interactively.
PATCH_SUBCOMMANDS = {
    "add": "git add <paths>",
    "commit": "git commit -m \"msg\" <paths>",
    "checkout": "git checkout <rev> -- <paths>",
    "restore": "git restore --source <rev> -- <paths>",
    "reset": "git reset -- <paths>",
    "stash": "git stash push -- <paths>",
}


def commit_verdict(name, rest):
    """`git commit` / `git commit --amend` — the editor matrix, all measured."""
    letters = shorts(rest)

    if "e" in letters or has_long(rest, {"--edit"}):
        return (f"`git {name} -e/--edit` FORCES the editor open even alongside -m.\n"
                "    Instead: drop --edit and pass the whole message to -m.")
    if "c" in letters or has_long(rest, {"--reedit-message"}):
        return (f"`git {name} -c/--reedit-message` REOPENS the message in the editor.\n"
                "    Instead: `-C`/`--reuse-message` (uppercase) reuses it without "
                "editing.")
    if "t" in letters or has_long(rest, {"--template"}):
        return (f"`git {name} -t/--template` opens the template in the editor.\n"
                "    Instead: read the template yourself and pass it via "
                "-m \"$(cat tmpl)\".")
    if "p" in letters or has_long(rest, {"--patch"}):
        return (f"`git {name} -p/--patch` selects hunks interactively.\n"
                f"    Instead: stage the paths you want, then {PATCH_SUBCOMMANDS['commit']}.\n"
                f"    (Note `git {name} -i` is --INCLUDE, not interactive, and is fine.)")

    provides_message = (
        bool({"m", "F", "C"} & letters)
        or has_long(rest, {"--message", "--file", "--reuse-message", "--fixup",
                           "--no-edit"})
    )
    if provides_message:
        return None

    if has_long(rest, {"--squash"}):
        return (f"`git {name} --squash=<commit>` still opens the editor — unlike "
                "--fixup,\n"
                "    it does NOT supply a finished message.\n"
                "    Instead: add -m \"squash! <subject>\", or use --fixup=<commit>.")
    if has_long(rest, {"--amend"}):
        return (f"`git {name} --amend` with no -m reopens the existing message in "
                "$EDITOR.\n"
                "    Instead: `--amend --no-edit` to keep it, or "
                "`--amend -m \"new message\"`.")
    return (f"`git {name}` with no message flag opens $EDITOR.\n"
            "    Instead: `git commit -m \"your message\"`.\n"
            "    For a long message: `-m \"$(cat msg.txt)\"` or `-F msg.txt`.\n"
            "    (--allow-empty-message does NOT skip the editor; --no-edit does.)")


def verdict(command):
    """Return (reason, note) to block, or None to allow."""
    for word, args in invocations(command):
        if word != "git":
            continue
        name, rest = subcommand(args)
        if name is None:
            continue

        # Asking for help never runs the thing. `git commit --help` must not be
        # mistaken for a `git commit` that needs a message.
        if {"-h", "--help"} & set(args):
            continue

        letters = shorts(rest)

        if name in ALWAYS_TUI:
            return (ALWAYS_TUI[name] + "\n"
                    "    Instead: `git diff` to read the conflict, edit the files "
                    "directly\n"
                    "    (git leaves real conflict markers), then `git add` them.",
                    NOOP_NOTE)

        if name == "commit":
            reason = commit_verdict(name, rest)
            if reason:
                note = NOOP_NOTE if "--patch" in reason or "-p/--patch" in reason else HANG_NOTE
                return (reason, note)
            continue

        if name == "rebase":
            if "i" in letters or has_long(rest, {"--interactive"}):
                return ("`git rebase -i/--interactive` opens the todo list in "
                        "GIT_SEQUENCE_EDITOR.\n"
                        "    Instead: for a plain replay use `git rebase <upstream>` "
                        "(no editor).\n"
                        "    To rewrite messages, `git commit --amend -m` each "
                        "commit as you go.", HANG_NOTE)
            if has_long(rest, {"--edit-todo"}):
                return ("`git rebase --edit-todo` exists only to open the todo list "
                        "in an editor.", HANG_NOTE)

        if name == "pull":
            if long_value(rest, "--rebase") == "interactive":
                return ("`git pull --rebase=interactive` runs the interactive "
                        "sequence editor.\n"
                        "    Instead: `git pull --rebase` (non-interactive) or "
                        "fetch + `git rebase <upstream>`.", HANG_NOTE)

        if name == "merge":
            if "e" in letters or has_long(rest, {"--edit"}):
                return ("`git merge -e/--edit` forces the merge-message editor open.\n"
                        "    Instead: drop --edit (without a tty git writes the "
                        "default message),\n"
                        "    or set the message explicitly with -m \"msg\".",
                        HANG_NOTE)

        if name in ("revert", "cherry-pick"):
            if "e" in letters or has_long(rest, {"--edit"}):
                return (f"`git {name} -e/--edit` opens the message in $EDITOR.\n"
                        f"    Instead: drop --edit — without a tty `git {name}` "
                        "writes the default\n"
                        "    message itself — then `git commit --amend -m` if you "
                        "must reword.", HANG_NOTE)

        if name == "tag":
            annotated = bool({"a", "s", "u"} & letters) or has_long(
                rest, {"--annotate", "--sign", "--local-user"})
            has_msg = bool({"m", "F"} & letters) or has_long(
                rest, {"--message", "--file"})
            if annotated and not has_msg:
                return ("`git tag -a/-s` with no -m opens $EDITOR for the tag "
                        "message.\n"
                        "    Instead: `git tag -a <name> -m \"message\"` or "
                        "`-F msg.txt`.", HANG_NOTE)

        if name == "notes":
            action, action_rest = subcommand(rest)
            if action == "edit":
                return ("`git notes edit` exists only to open the note in $EDITOR "
                        "(it takes no -m).\n"
                        "    Instead: `git notes add -f -m \"text\" <object>` to "
                        "replace the note.", HANG_NOTE)
            if action in ("add", "append"):
                has_msg = bool({"m", "F", "C"} & shorts(action_rest)) or has_long(
                    action_rest, {"--message", "--file", "--reuse-message"})
                if not has_msg:
                    return (f"`git notes {action}` with no -m opens $EDITOR.\n"
                            f"    Instead: `git notes {action} -m \"text\" <object>` "
                            "or `-F file`.", HANG_NOTE)

        if name == "branch":
            if has_long(rest, {"--edit-description"}):
                return ("`git branch --edit-description` opens $EDITOR.\n"
                        "    Instead: `git config branch.<name>.description "
                        "\"text\"`.", HANG_NOTE)

        if name == "config":
            if "e" in letters or has_long(rest, {"--edit"}) or rest[:1] == ["edit"]:
                return ("`git config --edit` opens the config file in $EDITOR.\n"
                        "    Instead: read it with `git config --list`, write with\n"
                        "    `git config <key> <value>`.", HANG_NOTE)

        if name == "add":
            if "e" in letters or has_long(rest, {"--edit"}):
                return ("`git add -e/--edit` opens the patch in $EDITOR.\n"
                        "    Instead: `git add <paths>`, or apply a patch you built "
                        "with `git apply`.", HANG_NOTE)

        if name == "am":
            if "i" in letters or has_long(rest, {"--interactive"}):
                return ("`git am -i/--interactive` prompts per patch.\n"
                        "    Instead: `git am <mbox>`, or `git am --abort` and apply "
                        "with `git apply`.", NOOP_NOTE)

        if name == "clean":
            if "i" in letters or has_long(rest, {"--interactive"}):
                return ("`git clean -i/--interactive` prompts for what to delete.\n"
                        "    Instead: `git clean -n` to see the list, then "
                        "`git clean -f <paths>`.", NOOP_NOTE)

        if name == "difftool":
            if not ({"y"} & letters) and not has_long(
                    rest, {"--no-prompt", "--tool-help"}):
                return ("`git difftool` prompts before each file.\n"
                        "    Instead: `git diff` — an agent reads the patch as text.\n"
                        "    (`git difftool -y/--no-prompt` is allowed.)", NOOP_NOTE)

        if name in PATCH_SUBCOMMANDS and name != "commit":
            if "p" in letters or has_long(rest, {"--patch"}):
                return (f"`git {name} -p/--patch` selects hunks interactively.\n"
                        f"    Instead: {PATCH_SUBCOMMANDS[name]}.", NOOP_NOTE)
            if name == "add" and ("i" in letters or has_long(rest, {"--interactive"})):
                return ("`git add -i/--interactive` is a menu-driven TUI.\n"
                        "    Instead: `git add <paths>`.", NOOP_NOTE)
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not command or "git" not in command:
        return 0
    if has_env_assignment(command, OVERRIDE):
        return 0

    found = verdict(command)
    if found is None:
        return 0
    reason, note = found

    sys.stderr.write(
        f"GIT INTERACTIVE BLOCKED: {reason}\n\n"
        f"  {note}\n"
        f"  If you are a human at a real terminal, re-run prefixed with {OVERRIDE}=1\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
