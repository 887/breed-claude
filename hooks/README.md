# hooks — PreToolUse(Bash) gates

Gates that live here are **tool-level and project-agnostic**: they block a command
that *succeeds while doing the wrong thing*, for reasons that hold in any repo,
in any language. That is the bar for inclusion, and it is narrow on purpose — see
"What does NOT belong here" below.

Clone this repo on the other machine, run `install.sh`, paste the settings
snippet. No package, no build step. `install.sh` **symlinks** back into the
checkout, so from then on `git pull` is the whole update path — don't copy the
files out.

## The gates

| Hook | Scope | Installs to | Needs |
| --- | --- | --- | --- |
| `gate.py` | **the only registration** | `~/.claude/hooks/` | `python3` |
| `rg-flag-gate.py` | dispatched by `gate.py` | `~/.claude/hooks/` | `python3` |
| `jj-no-interactive.py` | dispatched by `gate.py` | `~/.claude/hooks/` | `python3` |
| `git-no-interactive.py` | dispatched by `gate.py` | `~/.claude/hooks/` | `python3` |
| `jj-no-update-stale.py` | dispatched by `gate.py` | `~/.claude/hooks/` | `python3` |
| `jj-no-strand.py` | dispatched by `gate.py` | `~/.claude/hooks/` | `python3` + a jj repo |
| `sccache-health.py` | dispatched by `gate.py` | `~/.claude/hooks/` | `python3` + `sccache` (Unix; no-ops on Windows) |

### `gate.py` — one registration, four gates, one process

**Register only this.** Claude Code runs each registered hook as its own process,
sequentially, on *every* Bash tool call. Four separate registrations therefore meant
four `python3` spawns to answer four questions about the same string — measured on
this box:

| | per Bash call |
| --- | --- |
| bare `python3 -c pass` | ~10 ms |
| one gate (spawn + import + work) | ~18 ms |
| **four gates registered separately** | **~68 ms** |
| **`gate.py` dispatching all four** | **~18 ms** |

Interpreter startup dominates, and it was being paid four times. The dispatcher
pays it once: one spawn, one `json.load`, `_shellscan` imported once and shared,
four `check()` calls — 3.7x.

Watch what you import at module scope here, because it is paid on every Bash call
to serve paths that almost never run. `traceback` alone costs ~13 ms and
`subprocess` ~5.5 ms; leaving `traceback` at the top silently handed back half of
what consolidating bought (27 ms, against 18 ms once it moved inside the debug
branch). Measure before adding an import to a dispatcher.

Each gate exposes `check(command) -> str | None` — the exact stderr text, or None
to allow — so `gate.py` holds no policy at all. It decides only ORDER (cheapest
first; the first gate to object wins) and what happens when a gate is broken.

The gates keep their `main()` and stay directly runnable, which is not vestigial:
each one's suite invokes the real file over stdin, so they remain independently
testable and debuggable (`echo '{…}' | python3 jj-no-interactive.py`).

**A broken gate fails LOUD.** If a gate cannot be imported or raises, the command
is blocked and the message names the gate, the file, and its suite. Consolidating
four registrations into one otherwise creates a new failure mode: a single import
error silently disabling every gate while still exiting 0, indistinguishable from
"all clear". Recoverable on purpose — `CLAUDE_GATE_SKIP=1 <your command>` bypasses the
dispatcher entirely, so a broken gate cannot lock you out of your own shell.

**That escape was itself broken, and the way it stayed broken is worth keeping.**
The dispatcher read only `os.environ`, but the form every message advertises is
an INLINE assignment — part of the command string the tool is about to run, so
it never reaches the hook process at all. The escape was therefore unreachable
from a tool call, and unreachable precisely when needed: a broken gate refuses
every command, including the one that would repair it. Measured the hard way —
deleting a function while a dispatcher still named it locked a session out of
Bash entirely, and the documented bypass did nothing. The suite had a green
escape-hatch case the whole time, because it set the variable in the *hook
process's* environment: a shape no caller can produce. A test that exercises a
form the real caller cannot emit is how an unreachable escape stays green.

The check is now self-contained (it must survive a gate that will not import)
and honours the assignment only in COMMAND POSITION, so documenting the escape
in prose or an `echo` cannot switch every gate off.

`_shellscan.py` is a shared helper the others import, not a hook. It is not symlinked
and does not need to be: each hook resolves its own symlink back into this repo,
so the module is found beside the real file. That is another reason these are
symlinked rather than copied — a lone copied hook has no module to import.

**Every gate is only as good as this module, so bugs here are bugs in all of them
at once.** Two were found by measurement, not review, and both were silent:

- **A newline did not end a command.** `shlex` treats `\n` as ordinary whitespace,
  so `cd /tmp` + newline + `git commit` lexed as ONE segment whose command word is
  `cd` — the real command became mere arguments and no gate saw it. Verified
  bypassable on all four hooks (`git commit`, `git rebase -i`, `jj describe`,
  `rg -rn`, `update-stale`), plus a project gate. Lines are now lexed one at a
  time, and a line that does not lex is treated as an unterminated multi-line
  *string* and joined with the next — which is what keeps a gated phrase quoted
  inside a two-line commit message from reading as a command.
- **An override was honoured command-wide.** `OVERRIDE=1 ls; <gated command>`
  disabled the gate for a command the override was never attached to, and since a
  quoted mention lexes to the same token, `echo "OVERRIDE=1"` disabled it too.
  Assignments are now scoped the way a shell scopes them — via `invocations_env`,
  which pairs each invocation with the env that applies to it — while still
  carrying into `bash -c '…'` and forward from an `export`.

Both fixes were confirmed by running the new cases against the pre-fix code: 14
failures, all green after. A test that never failed against the broken version is
not evidence.

### `jj-no-strand.py` — orphaned work, and the empty commit that lands instead

`jj new <target>` does **not** move your working-copy edits. jj snapshots them into
the *current* change and makes a new, EMPTY commit off `<target>` your working copy.
Nothing errors — the files just leave your working directory. The damage lands one
step later:

```
<edits in @>
jj new main              # edits stay behind; @ is now empty
jj describe -m "..."     # a message describing work this commit does not carry
jj bookmark set main -r @
jj git push              # an EMPTY commit lands, with a message that lies
```

**Two checks, because one cannot be made both safe and quiet.**

| | fires when | override |
| --- | --- | --- |
| A — stranding | `jj new <target>` while `@` holds uncommitted work that is **neither described nor bookmarked** | `JJ_ALLOW_STRANDING=1` |
| B — empty push | a bookmark you are pushing points at an **empty non-merge commit** | `JJ_ALLOW_EMPTY_PUSH=1` |
| C — no-op push | the bookmark **already matches** its remote, so the push sends nothing | `JJ_ALLOW_NOOP_PUSH=1` |

Check A is deliberately **narrower** than its predecessor, which fired on any
non-empty `@`. A described or bookmarked `@` is a *named* change: leaving it behind
is how you start a sibling, and you can find it again. Blocking that produced steady
false positives, which trained the operator to prefix the override by reflex — so
the override was already in hand for the case that mattered, and an empty commit
reached `main` anyway. **Over-blocking is not a milder failure than under-blocking;
it is the mechanism that causes it.**

Check B is the reason this gate is worth having at all: it guards the **damage**
rather than one route to it, so it fires however you got there — including the
sequence where check A was correctly silent. An empty non-merge commit at a bookmark
is a message with no bytes behind it. Empty *merge* commits are normal and pass.

Check C is the third face of the same failure: a push that reads as success and did
nothing. jj prints `Bookmark X@origin already matches X` and exits 0. The usual cause
is a bookmark move refused moments earlier — jj declines a backwards or sideways move
without `--allow-backwards` — and that error is easy to lose in a script that
redirects stderr. Measured: four branches were reported as pushed when not one of them
had moved, and the `already matches` line was read as confirmation.

Check C skips a command that MOVES the bookmark before pushing it
(`jj bookmark set main -r @ && jj git push --bookmark main`). A hook runs before the
command does, so the state it reads is the state from *before* the move — and an
about-to-be-real push looks like a no-op. This gate blocked its own author's
`describe && set && push`, and blocked the whole chain, so not one step ran.

All three checks shell out to `jj`, but only for `jj new` and `jj git push`, so every
other Bash call still returns before paying for a subprocess (and `subprocess` itself
is imported lazily inside the query). Queries pass `--ignore-working-copy` except the
one question that is genuinely *about* the working copy — otherwise inspecting the
repo would snapshot it, mutating state as a side effect of a hook that runs on
commands which have not happened yet.

A `cd` through an unexpanded variable (`cd "$T/ws" && jj new main`) makes the target
directory unknowable — the variable is set inside the very command that has not run.
The gate stays **silent** rather than querying whichever repo it happens to be
standing in: a confident answer about the wrong repository is worse than none.

Shareable on the same test as its siblings: `jj new` re-parents rather than moves,
and a commit with no diff carries no work — true in every repository. It takes no
position on squashing, merge method, or commit shape.

### `rg-flag-gate.py` — ripgrep short flags that mean something else

Two grep habits are silently wrong in ripgrep:

- **`-r` is `--replace=TEXT`**, not grep's recursive — ripgrep recurses by
  default. `rg -rn 'pat' .` parses as `--replace=n` and rewrites every match to
  the literal `n`. **Exit 0, no error, output destroyed.**
  ([anthropics/claude-code#62016](https://github.com/anthropics/claude-code/issues/62016))
- **`-E` is `--encoding=ENC`**, not grep's extended-regex — ripgrep is already
  extended-regex, so `-E` is never needed for alternation. `rg -E 'a|b' f`
  consumes the pattern as an encoding name.

The smoking gun that `-r` is `--replace` and not a display bug: a search for
`cross_org_peek` came back as `n` — a string containing no letter `n`. Impossible
under any rendering theory, exactly what `--replace=n` does.

Long forms pass through: say `--replace=` or `--encoding=` and the gate agrees you
meant it.

This qualifies as shareable because it encodes a fact about **ripgrep**, not a
preference about a codebase. It is wrong to type `rg -rn` anywhere, by anyone.

### `jj-no-interactive.py` — jj commands that would open an editor and hang

An agent has no terminal to type into. A jj command that opens `$EDITOR`, a diff
editor, or a merge tool therefore does **not fail** — it waits forever, holding
the tool call open until it times out. Nothing errors, nothing prints, and the
transcript shows a command that simply never returned. For unattended work that
is the worst failure shape there is: no signal at all.

Blocked, with the non-interactive form named in the message. Each rule was read
off `jj help` rather than assumed:

| Blocked | Use instead |
| --- | --- |
| `-i` / `--interactive`, any subcommand | select with explicit paths |
| `--tool <t>` — jj's own help says it *implies* `--interactive` | omit it; `--tool :ours`/`:theirs`/`:none` are non-interactive builtins and **do** pass |
| `describe` / `commit` with no `-m`/`--message`/`--stdin` | `-m "msg"`, or `-m "$(cat msg.txt)"` for a long one |
| `--editor` — forces an editor open *even alongside* `-m` | drop it |
| `split` — "Starts a diff editor", always | `jj new` + `jj squash --into`, or squash by path |
| `diffedit` — exists only to open a diff editor | edit files and let jj snapshot, or `jj restore --from` |
| `resolve` with neither `-l/--list` nor a builtin tool | `--list` to inspect, then edit the real conflict markers |

Override for a human at a real terminal: `JJ_GATE_ALLOW_INTERACTIVE=1`.

This qualifies as shareable on the same test as the rg gate: it encodes a fact
about **jj plus the absence of a tty**, true in every repository. Note what it
deliberately does *not* do — it takes no position on squashing, merge method, or
commit shape. Those are project decisions and belong to the project.

### `git-no-interactive.py` — the same hazard, in git

Git has the larger surface of the two, and the two failure shapes are worth
keeping apart:

- **Opens `$GIT_EDITOR` → hangs.** `git commit` with no message flag, `--amend`
  without `--no-edit`, `git rebase -i`, `git tag -a` without `-m`, `git notes
  add`/`edit`, `git branch --edit-description`, `git config --edit`, and every
  `-e/--edit` form. No error, no output — the call sits there until it times out.
- **Reads a TUI off stdin → exits 0 having done nothing.** `git add -p`/`-i`,
  `git commit -p`, `-p` on `checkout`/`restore`/`reset`/`stash push`, `git clean
  -i`, `git am -i`, `git mergetool`, `git difftool` without `--no-prompt`. These
  don't hang: they hit EOF immediately and return success having staged, cleaned,
  or applied *nothing*. That is the `rg -r` shape — succeeds while doing the wrong
  thing — so they are blocked too.

**Every rule was probed against real git, not recalled.** `GIT_EDITOR` set to a
script that logs and then sleeps, stdin at `/dev/null`, under `timeout`, with a
control case in each run that had to report a hang or the run was thrown away.
That control earned its keep three times: one harness ran the *label* as the
command, another had `git clean -fd` delete the probe editor out of the repo it
was probing, and both produced a clean sheet of plausible "no editor" rows. A
uniform negative is usually a broken measurement, not a finding.

Six verdicts came out opposite to what the flag names suggest, and each is a
regression case in the suite:

| Looks blockable | Actually | Why |
| --- | --- | --- |
| `git commit --squash=<c>` | **blocks** | unlike `--fixup`, it does *not* supply a finished message — the editor still opens |
| `git commit --fixup=<c>` | passes | builds the message itself |
| `git commit -c <c>` | **blocks** | lowercase `-c` is `--reedit-message` |
| `git commit -C <c>` | passes | uppercase `-C` is `--reuse-message`, no editor |
| `git commit -i` | passes | for `commit`, `-i` is `--include` — *not* interactive (whereas `git add -i` is) |
| `git merge`, `git revert` | passes | their editor is tty-conditional; with no terminal, git writes the default message |

`git commit -am "msg"` also has to pass, which means short-flag **clusters** must
be unbundled — a whole-token check misses the `m` in `-am` and blocks the single
most common commit form. `--allow-empty-message`, by contrast, does *not* skip the
editor, so it is not treated as a message flag.

Override for a human at a real terminal: `GIT_GATE_ALLOW_INTERACTIVE=1`.

Shareable on the same test as its siblings: it encodes a fact about **git plus the
absence of a tty**. It takes no position on commit shape, squash-merges, rebase
policy, or branch naming — `git rebase <upstream>`, `git merge --no-ff`, and
`git commit --amend --no-edit` all pass, because whether you *should* run them is
the project's call, not this hook's.

### `jj-no-update-stale.py` — make `jj workspace update-stale` a deliberate act

**Not a forbidden command.** It is the real recovery for a genuinely stale
workspace, and the override is one prefix away. What the gate stops is reaching it
*incidentally* — as a reflex to clear an error mid-task — because an agent cannot
tell from the outside whether the target workspace holds un-snapshotted files, and
if it does they are gone for good.

#### Pair it with the config — one half of this hazard no hook can see

`snapshot.auto-update-stale` decides what jj does when it *notices* staleness:

| value | behaviour on a stale workspace | can a hook see it? |
| --- | --- | --- |
| `true` | jj re-checks-out the workspace **itself, on any command** | **No** |
| `false` (jj 0.42 default) | jj refuses and tells you to run `update-stale` | Yes — that is this gate |

Measured on jj 0.42.0 with `auto-update-stale = true`: a plain **`jj st`** in a
stale workspace printed `removed 2 files` and destroyed an un-snapshotted file.
`jj workspace update-stale` was never typed, so a gate matching that command is
structurally blind to it. With the setting `false`, the same `jj st` errors and the
file survives — verified both ways.

So `install.sh` **pins `snapshot.auto-update-stale = false` at user scope.** That
changes nothing today, because it is already the default — the point is that
safe-by-*default* is not safe-by-*decision*: a repo config, an agent "fixing" a
stale-workspace error, or a future change of default would reopen the invisible
path with nothing to announce it. Precedence, honestly: workspace > repo > user >
default, so a repo-scope `true` still wins. It is a defence against drift, not a
guarantee.

**Config closes the path you cannot see; the gate makes the path you can see
deliberate.**

When workspace A rebases or describes a commit that workspace B has checked out,
jj marks B *stale*. `jj workspace update-stale` in B then re-checks-out the new
commit, **overwriting B's on-disk files**. jj does not snapshot B first, so
un-snapshotted work there is destroyed with **no op-log record** — jj never saw
it, so `jj undo` cannot help. Unrecoverable by design.

What makes a guard necessary rather than merely nice is the second-order trap:
snapshotting a *stale* workspace **fails**, because jj refuses to run there. So
the obvious defensive sequence — snapshot first, then update-stale — silently
no-ops on step one and then destroys the work on step two. Being careful by hand
is not sufficient, which is why this is mechanical.

Rescue procedure, named in the block message: read what is on disk (jj cannot help
— that is the problem), `cp -a <workspace> /tmp/ws-rescue`, then deliberately
`JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale`, then put back what you
rescued. If the workspace is empty or disposable, the override alone is the whole
procedure.

An earlier cut of this hook took the backup *itself* — tar the workspace, then
allow the command. That was too much: a gate that copies gigabytes is doing work
the human should be deciding about, and it made the failure modes (disk full,
partial copy, excludes wrong) the gate's problem rather than obviously nobody's.
Refusing is smaller, and it puts the judgement where it belongs.

The override is scoped **per command segment**, not across the whole string.
Checking the string was an accidental escape hatch:
`JJ_ALLOW_UNSAFE_UPDATE_STALE=1 ls; jj workspace update-stale` would have disabled
the gate for a command the override was never attached to. It does carry into
`bash -c '…'`, because there it really does reach the inner command through the
environment. Both directions are regression cases.

**Why user scope, emphatically.** It encodes a fact about jj, so it passes the bar
like its siblings. But it also *cannot work* as a project hook. Project hooks are
registered as `${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/…`, and `CLAUDE_PROJECT_DIR`
is unset whenever the session root is not the repo. An orchestrator session
driving several `jj workspace add` checkouts from a different cwd therefore
enforces **zero** gate legs — verified by running a command the project gate
should have blocked and watching it sail through to jj untouched. That is exactly
the multi-workspace arrangement where staleness arises and where update-stale gets
run, so a project-scoped copy of this guard is inert precisely when it is needed.
Anything standing between an agent and **irreversible data loss** has to be user
scope for that reason alone.

### `sccache-health.py` — the build that wedges at 0% CPU, and the loop that re-creates it

**The bug is upstream and unreleased:** [mozilla/sccache#2771](https://github.com/mozilla/sccache/pull/2771).
The sccache server is **lazily fork+exec'd by whichever compile-job client first
needs it**, and it inherits that client's open file descriptors — including
cargo's jobserver pipe. The long-lived daemon then holds that pipe's write end
open forever, the writer never sees EOF, and the build deadlocks **at 0.0% CPU**
with its output frozen mid-`Compiling <crate>`.

It is indistinguishable from a slow compile by looking at it. Measured in one
session: **5h43m + 3h32m + 1h41m** of wall-clock lost.

**Why discipline could not fix it.** The recovery action *is* the bug:

```
wedge -> kill -9 the server -> re-run cargo -> cargo LAZILY SPAWNS a new server,
which inherits THIS cargo's jobserver pipe -> wedged again
```

All three wedges above were that cycle. The remedy was written into two files
between the second and third one and did not prevent the third — the standing
lesson that a warning is invisible at the point of the mistake.

**Why a hook is the right shape, and not merely a convenient one.** The single
property that fixes this is *who starts the server*: one started by a process
owning no jobserver has no build pipe to hold. **A hook is spawned by Claude
Code, not by cargo**, so a server it starts is clean by construction — the same
command typed inside a build is not. The gate is not automating a remedy a human
could type; it is the only place the remedy is reliably correct.

So on `cargo …` it probes the server (**11 ms** when healthy) and, if absent or
wedged, stops and starts it *from the hook process*, then allows the build. It
never blocks one — there is only ever one correct action, so making the author
choose it would be ceremony. Separately it **refuses** `pkill sccache` /
`kill -9 $(pgrep sccache)`, pointing at `sccache --stop-server`, because that is
the action that re-creates the state.

**Platform: every Unix, deliberately NOT macOS-only.** The instinct is to scope a
bug to the box it was found on; that would leave Linux unprotected. The mechanism
is plain POSIX fd inheritance across `fork`+`exec`, #2771's own reproducer is a
`ninja` build piping through `tee`, and its fix is gated `cfg(unix)`. Windows is
the real exception and #2771 says why — *"On Windows there is no daemon fork"* —
so the gate no-ops there rather than paying a probe for an impossible failure.
(Not to be confused with [#221](https://github.com/mozilla/sccache/issues/221),
which IS macOS-specific: a pthread-mutex deadlock. Same symptom, different bug.)

**Delete this gate when sccache 0.18+ ships #2771** — the daemon then sweeps its
own inherited descriptors and this becomes dead weight. Noted here and in the
file so it is removed rather than accumulating.

**What it deliberately does not catch:** builds run outside the Bash tool; a
server that wedges *during* a build it was healthy at the start of (nothing at
the boundary can see that — there the signal is the request counter advancing,
`sccache --show-stats | rg 'Compile requests +[0-9]'`, never the log tail, since
a stale tail read twice is indistinguishable from progress); any wrapper that is
not sccache.

## What does NOT belong here

**A hook that enforces one project's conventions.** The distinction is whether the
hook would be *correct* in a repo that has never heard of the project it came from.

Worked example, because I got this wrong: foundlings has a
`vcs-gate.py` blocking `jj squash`, PR squash-merges, whole-branch rebases, and
`jj new <target>` while `@` is dirty. I briefly shipped it here labelled "any `jj`
repo". That was wrong — its own error message says *"Repo rule (CLAUDE.md): we
keep commits separate — no squashing"*, which is that repo's decision. Plenty of
jj repos squash deliberately, and squash-merge is the default on many forges.
Installing it elsewhere would impose one project's convention as if it were a
tool-level truth, and the person hitting it would have no idea why.

Its second check (`jj new` stranding a dirty `@`) describes a real jj hazard that
would bite anyone — but *blocking* it is still a policy call, and it is entangled
with check A in one file and one message vocabulary. It stays with the repo whose
rules it enforces: `foundlings/.claude/hooks/vcs-gate.py`, version-controlled
there, gated by that repo's own history.

Keeping it out also removes a duplication: while it lived in both places the two
copies could drift, and nothing would say which was authoritative.

**Rule of thumb.** Encodes a fact about a *tool* (`rg` flags, a shell parsing
trap) → shareable, put it here. Encodes a decision about a *codebase* (commit
shape, merge method, branch policy) → belongs to that codebase, in its own
`.claude/hooks`, tracked in its own history.

## Install

```sh
./install.sh
```

Two things happen: the hooks are symlinked into `~/.claude/hooks/`, and one jj
config key is pinned — `snapshot.auto-update-stale = false` at user scope, reported
on stdout (see the stale-workspace gate above for why, and for the precedence
caveat). That is the **only** config the script writes; it does not touch
`settings.json`, and it never writes a project-scoped anything.

**Symlinks, not copies** — per the hard rule in [`../CLAUDE.md`](../CLAUDE.md):
this repo is the source of truth, so every install points back at a checkout and
`git pull` alone updates behaviour. A copy keeps working while going stale, which
is the worst failure shape for a safety gate: it still runs, just not the version
you think it is.

**Corollary, and it applies to Claude too: do not edit the installed path.**
Editing `~/.claude/hooks/rg-flag-gate.py` edits *this repo's* file through the
symlink — a real change that is uncommitted and invisible, showing up only in
`git status` here. Edit the file in this repo and commit it.

An existing **real file** at a destination is left alone rather than clobbered:
the script reports whether it differs and prints the `diff` and `ln -sfn`
commands. A file that is version-controlled at its destination is never touched at
all, because replacing it with a symlink would commit the symlink.

The script does **not** edit any `settings.json` — it prints the snippet and you
merge it, because a settings file is hand-owned and clobbering someone's other
hooks to save a paste is a bad trade.

### Registration

`~/.claude/settings.json`:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "python3 $HOME/.claude/hooks/rg-flag-gate.py" },
  { "type": "command", "command": "python3 $HOME/.claude/hooks/jj-no-interactive.py" },
  { "type": "command", "command": "python3 $HOME/.claude/hooks/git-no-interactive.py" },
  { "type": "command", "command": "python3 $HOME/.claude/hooks/jj-no-update-stale.py" }
] } ] } }
```

Project-settings hooks are **hot-reloaded** — editing `settings.json` mid-session
registers the hook immediately and it takes effect on the next matching tool call.
No restart. So if a freshly-added hook does *not* appear in `/hooks`, that is a
real wiring problem (bad JSON, wrong path, non-executable script), not a stale
session. `/hooks` is read-only; there is no in-session approve step.

## Tests

```sh
bash tests/gate.sh                 # 25 cases — dispatch, not rules
bash tests/rg-flag-gate.sh         # 26 cases
bash tests/jj-no-interactive.sh    # 50 cases
bash tests/git-no-interactive.sh   # 119 cases
bash tests/jj-no-update-stale.sh   # 38 cases
bash tests/jj-no-strand.sh         # 34 cases
```

Each harness invokes the **real** hook with synthetic `PreToolUse` payloads — no
double of the hook itself. Neither needs a repo: both decide from the command
string alone, which is the point — a command that would hang must be refused
*before* it runs, not diagnosed after.

Every case asserts **both** directions. A gate is only trustworthy once it has
been observed *blocking* what it must block; a suite that only checked the pass
direction would go green against a hook that returns 0 unconditionally — which is
precisely how the first cut of this hook shipped broken (it read the script from
stdin, so the payload never arrived and everything passed).

### Why the false-positive cases outnumber the true positives

A gate that blocks correct commands gets routed around, and the workaround is
indiscriminate — for a gate with an override env var, it switches the whole check
off. So a false positive is not cosmetic; it is how the real protection gets
disabled.

This hook shipped with one: it used `shlex.split`, which returns `2>/dev/null;` as
a single opaque token matching no separator. The scanner therefore never saw the
command boundary and kept attributing later flags to `rg` — it blocked
`rg -n pat f 2>/dev/null; jj file list -r main`, where the `-r` is jj's. Fixed by
lexing with `punctuation_chars=True` so operators arrive as their own tokens.
Regression case: `the recorded false positive`. Verified by running the suite
against the pre-fix hook — 3 failures, all green after. A fix whose test never
failed against the broken version is not evidence of anything.

### When there is no broken version to test against

The git suite passed 116/116 on its first run, which is not evidence either — the
same sheet of greens is what a hook returning 0 unconditionally produces. So it was
run against three deliberate mutants instead, and it has to kill all three:

| Mutant | Expected | Observed |
| --- | --- | --- |
| `verdict()` returns `None` always (allow everything) | every block case fails | 54 failures |
| scan raw `shlex.split` tokens instead of command positions | the mention/boundary cases fail | 54 failures |
| `shorts()` ignores clusters longer than one letter | `git commit -am` false-positives | caught, plus `rebase -im` |

Mutant 2 is the one that matters most: it fails *pass*-direction cases, so it
proves the suite constrains over-blocking and not just under-blocking.
