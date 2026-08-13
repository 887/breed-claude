#!/usr/bin/env python3
"""rustc-wrapper-gate — refuse a cargo command that disables the compilation cache.

`RUSTC_WRAPPER` is set machine-wide in `~/.cargo/config.toml` (kache since
2026-08-06). Clearing it for a child cargo forces a cold compile against a warm
multi-gigabyte cache the build is then forbidden to touch. One such command cost
~40 minutes rebuilding down to `tokio`.

## Why no TEST can catch this

A content-addressed compilation cache cannot change WHAT is compiled, only where
the object code comes from. It can never affect which tests an inventory
enumerates, which lints fire, or what any gate observes. So the results stay
correct and only the PRICE changes — and no correctness suite can see a price.
Cost regressions need a gate of their own or they survive indefinitely.

## Why a hook and not the in-repo gate

Foundlings already has `oracle_must_not_disable_the_compilation_cache`, which
sweeps `tools/`, `crates/` and `servers/` for these shapes in SOURCE. A
hand-typed shell prefix is structurally outside its reach. Same division as
rg-flag-gate: the repo polices what it contains, only the Bash boundary polices
what is typed.

## Why it recurs, which is the actual reason this file exists

The advice is DEAD but the commands are still legible. `CLAUDE.local.md` carries
a HISTORICAL sccache section whose prose still reads "finished in about a minute
with `RUSTC_WRAPPER=\"\"`", and a legitimate DIAGNOSTIC one line further down:

    env -u RUSTC_WRAPPER zsh -c 'echo ${RUSTC_WRAPPER:-unset}'

Two readers have now lifted a prefix off that page and put it in front of a real
build — the maintainer on 2026-08-11, and a fleet lane on 2026-08-13. **A
"HISTORICAL" banner above a command is not a strike-through; readers skim to the
code block.** That is a class, not a slip, so it earns a check rather than a
third warning.

## Deliberately ALLOWED

  * The diagnostic above — `env -u RUSTC_WRAPPER` in front of a NON-cargo command
    (`zsh -c 'echo …'`, `printenv`). Asking what the environment would be is
    legitimate, and is exactly how you detect a stale shell.
  * `cargo kani` / `cargo verus`, which substitute their own compiler and are the
    documented exceptions.
  * `RUSTC_WRAPPER=kache …` — explicitly SETTING it is the correct thing.
  * Searching for the text (`rg 'RUSTC_WRAPPER=\"\"' CLAUDE.local.md`).

## Deliberately NOT caught

Stated so nobody mistakes silence for coverage: a wrapper cleared inside a script
this command invokes, an `export RUSTC_WRAPPER=` on an earlier line of a
multi-line command, `.cargo/config.toml` edits, and `CARGO_BUILD_RUSTC_WRAPPER`.
This is the narrowest check that catches the observed failure.

A module of `gate.py`, the single registered PreToolUse hook — not a second hook.
Exit 2 = block, stderr shown back to the caller.
"""

import re

# The three shapes that clear it, each anchored to a command boundary so a
# mention inside a quoted string or a longer variable name does not match.
_CLEAR = re.compile(
    r"(?:^|[;&|(]|\s)(?:"
    r"RUSTC_WRAPPER=(?:''|\"\"|)(?=\s)"                 # RUSTC_WRAPPER= / ="" / =''
    r"|env\s+(?:-u\s+\S+\s+)*-u\s+RUSTC_WRAPPER\b"      # env -u RUSTC_WRAPPER
    r"|unset\s+RUSTC_WRAPPER\b"
    r")"
)

# Does this command actually build? `cargo` alone is not enough — `echo cargo`
# compiles nothing — but being generous costs only a false block on a no-op,
# while being stingy misses the expensive case.
_CARGO = re.compile(r"(?:^|[;&|(]|\s)cargo\s+\S")

# Documented exceptions: these substitute their own compiler on purpose.
_EXEMPT = re.compile(r"cargo\s+(?:kani|verus)\b")


def check(command):
    """The whole decision: text to block on, or None to allow."""
    if not command or not _CLEAR.search(command):
        return None
    if not _CARGO.search(command):
        # The stale-shell diagnostic and friends: no build, nothing to protect.
        return None
    if _EXEMPT.search(command):
        return None
    return (
        "RUSTC-WRAPPER GATE BLOCKED: this cargo command disables the compilation cache.\n"
        "\n"
        "  `RUSTC_WRAPPER` is set machine-wide and must be INHERITED. Clearing it forces a\n"
        "  cold compile against a warm multi-gigabyte cache it is then forbidden to touch.\n"
        "  One such command cost ~40 minutes rebuilding down to `tokio`.\n"
        "\n"
        "  A content-addressed cache cannot change WHAT is compiled, only where the object\n"
        "  code comes from — so it can never affect which tests enumerate, which lints fire,\n"
        "  or what any gate sees. There is no correctness argument for clearing it, only a\n"
        "  performance one, and it runs backwards. Your existing results are NOT invalidated.\n"
        "\n"
        "  Run it plain, with no prefix:\n"
        "      cargo <verb> …\n"
        "\n"
        "  If you copied this from CLAUDE.local.md: that is a HISTORICAL sccache note. The\n"
        "  workaround was for sccache's jobserver-pipe bug on cargo-inside-cargo; this box\n"
        "  replaced sccache with kache on 2026-08-06 and does not have it.\n"
        "\n"
        "  Allowed on purpose: `env -u RUSTC_WRAPPER` in front of a NON-cargo command (the\n"
        "  stale-shell diagnostic), and `cargo kani` / `cargo verus`, which substitute their\n"
        "  own compiler.\n"
        "\n"
        "  Rule: CLAUDE.md, \"NEVER disable the compilation cache\".\n"
        "  Bypass everything: CLAUDE_GATE_SKIP=1 <command>"
    )
