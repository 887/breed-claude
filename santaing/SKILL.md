---
name: santaing
description: Run a fleet of headless coding agents as a controlled workshop — YOU are Santa, the orchestrator: you brief the helpers, make the decisions, keep the ledger, and touch NO checkout. Always create **rudolph**, a dedicated tmux integrator that owns the canonical checkout and is the only agent that merges. The elves (a dynamic number of Codex/Claude sessions in tmux, count and kind the user's call) each work an isolated VCS workspace on a long-lived branch per phase, push their own branch, open their own PR, and keep working without waiting. Use when the user says "go santaing", "drive the fleet", "orchestrate the codexes", "use the helpers to build X", "santa this plan", "fan the helpers out on <plan/branch>", or otherwise asks you to coordinate several tmux agents toward one goal. The core discipline: elves push branches and never merge; rudolph runs the full gate and merges; Santa orchestrates and never touches the canonical checkout. Never run the integrator as an orchestrator subagent — it reinitialises context every message and burns tokens rebuilding what a tmux agent simply keeps. Repo-, VCS-, and build-tool-agnostic — nothing about a specific project is hardwired. Composes the breed-codex (and breed-claude) primitives for spawning/briefing/goal-setting/monitoring individual agents.
---

# santaing

**You are Santa. The tmux agents are your little helpers in the workshop.**

Santaing is a pattern for driving a *dynamic* fleet of headless coding agents (Codex
or Claude sessions in `tmux`) toward a single objective — a plan, a branch, a set of
work packages — while **you alone** keep control of the repository's integration
points. You don't do the big implementation grind yourself; you orchestrate helpers
who do, and you integrate, verify, and ship their output.

This skill is **policy and choreography**. The per-agent mechanics (spawn, brief,
`/goal`, `/clear`, done-file, kill/restart) live in **breed-codex** (for Codex) and
**breed-claude** (for Claude); santaing composes them.

Nothing here is tied to a specific repo, VCS, or build tool. Throughout, substitute:

| Placeholder | Meaning | Common instances |
| --- | --- | --- |
| `<REPO>` | the project being worked on | any repo — never hardwire a name |
| `<VCS>` | the version-control system | `jj` (colocated), `git` |
| `<WORKSPACE-NEW>` | recipe to make an **isolated** checkout | `jj workspace add` / a `just`/make target / `git worktree add` |
| `<CHECK>` | the **cheap, scope-limited** check helpers may run — NEVER `--all-features`, `--all-targets`, `--workspace`, a full sweep, or `-p <composition-crate>` | `cargo check -p <crate>`, `cargo test -p <crate>`, `nextest -E 'test(x)'`, `tsc --noEmit` |
| `<GATE>` | the **full** gate only rudolph runs | `cargo clippy -D warnings` + fmt + lint + tests + deny |
| `<TARGET>` | the trunk the fleet's work lands on | `main`, or the phase branch rudolph owns |

---

## The one rule that defines santaing

**The integration boundary is owned by exactly one agent; helpers never cross it.**

That agent is **rudolph** — a dedicated tmux agent that owns the canonical checkout and
is the only one that merges. **Always create a rudolph.** Santa orchestrates and does
not touch the checkout.

- **Rudolph alone**: owns the canonical checkout, runs the **full `<GATE>`**, fixes gate
  findings, and **merges**. It is the only agent that writes to `<TARGET>`.
- **Santa (you)**: briefs helpers, makes decisions, keeps the ledger, and hands rudolph
  branches. **You do not touch the canonical checkout** — not `jj git fetch`, not
  `jj new`, not a rebase. Every one of those mutates shared state and will strand
  rudolph's working copy mid-verification. Verify through `git ls-remote` and `gh api`,
  which read the remote without touching local VCS state, or ask rudolph to run it.
- **Helpers (elves)**: implement in their **own isolated workspace**. They **push their
  own branch and open their own PR**; they never merge. **One standing branch and one
  open PR per lane** — name the branch after the lane's phase (`rp-lane`, `qq-lane`,
  `tj-lane`), not after the substep, so there is one obvious place every substep goes.
  **One open PR per lane at a time** — a lane pushes each new substep onto the SAME branch and lets the PR grow,
  and only opens a fresh PR once the integrator has merged the previous one. N open
  PRs from one lane multiply the integrator's verification work N times over the same
  phase, and the integrator is already the serial bottleneck. Letting them push means the
  push gate runs at their desk, surfacing findings where the author is — and it means
  they never idle waiting on integration.
  They may run the **cheap, scope-limited `<CHECK>`** (e.g. `cargo check -p <touched-crate>`).
  When a change alters a public signature they **enumerate the dependents and name them
  in the report** — they do NOT build the expensive ones; rudolph verifies those once, in
  the warm canonical tree. They **never** run the full `<GATE>`/whole-project sweep in
  their own workspace: **each full build cold-populates that workspace's own multi-GB
  output tree, times N helpers in parallel, which fills the disk** (see the disk/artifact
  hard rule below). And they never touch the canonical checkout or each other's workspace.

If you remember one thing: **elves `<CHECK>` + push their branch; rudolph `<GATE>` +
merges; Santa orchestrates and touches nothing.**

---

## Rudolph — the integrator, always a tmux agent

**Always create one.** Never run the integrator as an orchestrator subagent: a subagent
reinitialises its context on every message, so the integration knowledge — which
branches are dangerous, which conflicts must not be resolved, what was already verified
— is rebuilt from scratch each time and burns tokens doing it. A tmux agent keeps it.

```bash
# Launch a SHELL first, then the agent inside it. Never `-- claude` directly.
tmux new-session -d -s rudolph -c <CANONICAL-CHECKOUT>
tmux send-keys -t rudolph 'claude --name "rudolph (integrator)"' Enter
```

**Spawn every tmux agent through a shell — this applies to elves too.** `tmux
new-session -- claude` starts the harness with **no shell in its path**, so it inherits
the **tmux server's** environment, which is as old as the server. A profile fix
(`~/.zshenv`) reaches every shell including non-interactive ones — and cannot reach a
process that never ran one.

The failure is nasty because it is invisible and misattributed: on one machine the tmux
server predated a build-cache change, so harness-spawned agents carried a
`RUSTC_WRAPPER` pointing at an uninstalled binary. Every push died inside the gate, and
the gate reported it as a *documentation* failure — sending the author to audit docs
that were never wrong. Shell-spawned lanes on the same host pushed fine, which made it
look session-specific rather than structural.

**To repair an already-mis-spawned agent without losing its context:** take its session
id from `~/.claude/projects/<project-dir>/<id>.jsonl` (newest mtime), kill the tmux
session, recreate it running the shell, then `claude --resume <id>` inside it. The
conversation is on disk; only the process is replaced. **Verify the fix directly** —
`echo $RUSTC_WRAPPER` (or whatever the variable was) in the new session, before
concluding it worked.

Brief it once as a **standing role**, not a task. The brief must carry:

- **The boundary**: it merges, elves never do; Santa never touches its checkout.
- **Verify by CONTENT, not ancestry.** A change can be an ancestor of the trunk with its
  content absent. Pair every claim with a **control that must come out different** — a
  marker present after the merge and absent on the pre-merge revision.
- **Route stderr separately from stdout.** An error's text is non-empty and reads as
  success. This single habit catches more than any other.
- **Know which outputs are impossible, not merely wrong** — an empty trunk ref, a subset
  larger than its total, a test count from a run you watched compile. When one appears,
  **suspect the instrument, never the repository.** Impossibility ends the argument;
  a wrong value only starts one about methodology.
- **Freeze BEFORE the integrator starts, not alongside it.** The handshake has a race:
  a lane told "keep working locally" while a verification is already running may have
  pushed seconds earlier, and the integrator then discards evidence gathered against a
  head that moved. Send the freeze first, confirm the lane acknowledged it, and only
  then hand the PR over. When it races anyway, say plainly that the timing was yours —
  the lane followed the instruction it had.
- **The freeze never blocks a fix.** A frozen lane still owes pushes that make its
  branch verifiable — a rebase, a conflict resolution, a finding the integrator raised.
  The freeze protects verification **in progress**, nothing else; if the branch cannot be
  verified until the lane pushes, unfreeze, let it push, refreeze. This collides on first
  contact otherwise, and the collision looks like the lane being obstinate.
- **Tell a lane to rebase EARLY, not at merge time.** A long-lived branch drifts behind
  trunk while it works, and the cost is not the conflict — it is that every number the
  lane measured (floors, counts, ledger figures) describes a tree that no longer exists,
  and every check it ran was against the old base. Merging such a branch can silently
  carry an old ceiling forward and re-permit retired debt. Watch the fork distance and
  say so while the lane is still working; rebasing at merge time means verifying twice.
- **Check mergeability BEFORE spending verification.** A conflicting branch cannot be
  verified at all, so a full contract run against it is wasted from the first command.
  And the freeze below does not apply to it — there is nothing to protect while it cannot
  be verified, and resolving the conflict *requires* the push the freeze forbids. Unfreeze,
  let the lane rebase, re-freeze when it reports clean, and re-capture the base: the
  pre-rebase revision is void, not stale.
- **A branch under verification is frozen — tell the lane, do not just hope.** A lane
  that pushes while the integrator is verifying its PR invalidates every result gathered
  so far, and the only remedy is to discard the work and re-run it. The lane is not doing
  anything wrong; nothing tells it the integrator started. Santa announces "your branch is
  under verification, hold" and "merged, push freely" as an explicit handshake. This is
  the cheapest of the three head-movement defences and it prevents the problem the other
  two only detect.
- **Pin the head in the merge call itself, not in a check before it.** Comparing the
  head and then merging leaves a window; passing the expected revision to the merge API
  (`gh api ... -f sha=<verified-head>`) makes the platform reject the merge if the branch
  moved. **Evidence is only valid against the revision it was gathered on**, and standing
  branches move during verification, not merely before it.
- **Never squash** — change IDs are the durable identifiers a ledger cites.
- **Stop rather than resolve** a conflict in any shared bookkeeping file (allow-lists,
  ledgers). Those have no mechanically obvious side: one arm restores retired entries,
  the other silently drops live ones, and both produce a plausible file.
- **Do NOT fix gate findings — report them.** Leave a PR comment with the rule name, the
  file:line, the verbatim gate output, and what would satisfy it; tell Santa the PR
  failed and why; move to the next branch without blocking. **A fix by rudolph teaches
  nobody**: in one campaign the same lint was fixed by the integrator twice in an hour
  because the lane that produced it never saw the rule. A comment reaches the author.
  - **Carry the measurements, AND tell the lane to re-measure.** A comment naming the
    exact numbers saves the author a re-derivation — but on a **standing branch the lane
    keeps pushing to**, those numbers have a shelf life and the lane will invalidate them
    before it reads the comment. Numbers without "re-measure before you act on this" turn
    precision into a trap: the author fixes to a figure that was true when you measured
    and is wrong when they land it.
- **Never baseline, never gate-skip, never override** without explicit per-instance
  authorization from Santa. Only *who fixes* changed, not *whether* it gets fixed.
- **Report BOTH outcomes** — merged and failed — to Santa and on the PR. Santa needs both
  to tell an improving lane from a repeating one.
- **Report after each merge, not per queue** — and **report absences too**. A prediction
  that fails is as informative as one that holds.

## Elves — count and kind are the user's call

**How many elves and whether they are codex or claude is dynamic.** Ask or take the
user's stated preference; there is no fixed number. What is fixed is the shape:

- one isolated workspace each
- **a long-lived branch per phase**, not per task — each step is the base for the next,
  and re-deriving it is how a serial lane or a multi-step migration stalls
- before every step: fetch, rebase onto trunk, and **abandon changes that have become
  empty** — an empty change post-rebase is work that landed, not work lost
- after a step: push the branch, open or update the PR, **and immediately continue**

**Give each long-running phase a PERMANENT lane.** A phase that keeps getting picked up
and put down is re-derived every time; a permanent lane keeps the map in its head. Where
phases build on each other, this matters twice over:

- **Their work lands on trunk continuously, not at phase completion.** Rudolph merges
  what is ready as it is ready, even while the phase has work left.
- **Each rebases onto trunk at the start of every WP or substep**, so it picks up the
  others' landed work instead of diverging from it.
- Expect several phase PRs open and **growing** at once. Rudolph re-reads each head
  immediately before merging — the change-ID list it inspected may be short by then.

**When a lane's PR fails the gate, the LANE fixes it, not rudolph.** That is what makes
the permanent-lane arrangement compound: the author sees the rule and stops reproducing
it, instead of an integrator silently absorbing the same finding repeatedly.

**Re-arm the watcher whenever the fleet changes, and check what it actually counts.**
Replacing an agent, adding a lane, or losing one to a quota limit leaves the monitor
watching the old set. A watcher that counts *sessions* rather than *work* reports full
health while pointed at dead panes — a killed agent's tmux session still exists, so
"N/N alive" stays true while the lanes that replaced it are unwatched. Restate the
session list on every fleet change, and confirm the names you passed are the names
that are working.

**Watch for silent model changes and memory pressure — both look like healthy work.**
A tmux agent can fall back to a smaller model mid-run; the footer is the only place it
shows. An integrator on a 200k window carrying 400k of context keeps reasoning fluently
while dropping the verification history it is merging on. Check the model line, not the
output quality. Fix with `/model`, choosing the large-context variant explicitly — the
bare model name may select a smaller window.

**Size the fleet to the INTEGRATOR's throughput, not to the number of slices.**
One integrator verifying thoroughly is the serial constraint. Lanes that outproduce it
do not ship sooner — they queue, while contending for the same shared build cache and
slowing every lane including the integrator's own. If the queue keeps growing, park
lanes that already have a PR in it. Three lanes that merge beat five that wait.

**N lanes compiling at once is over-subscription, and the machine says so before you do.**
Watch swap, not just liveness. When it thrashes, park lanes rather than capping the
build's job count — the repo's `jobs` value is checked in and stands. Park the lanes
whose output is *already queued for merge*: more branches from them cannot help while
the integrator is the constraint. Tell a parked lane a kill by `signal: 9` is the
machine, not its branch, or it will diagnose a defect that is not there.

**Releasing a parked lane takes `/goal resume`, not a message.** An interrupted goal
shows `Goal stalled` and a plain instruction leaves it stalled — it acknowledges and
does nothing.

**A PR comment does not reach a lane. Santa relays every finding into the pane.**
A tmux lane reads its pane; nothing makes it poll GitHub. So a finding left only as a PR
comment lands where the one agent who must act on it never looks — and the failure is
silent in the worst way: the comment exists, it is correct, it is even courteous, and
the work simply never happens.

- **Rudolph reports each finding to Santa AND comments on the PR.** The comment is the
  durable record for humans and for the next integrator; the relay is what actually
  changes the code.
- **Santa relays it into the lane's pane**, in full — file, exact edit, and why no gate
  caught it. Do not summarise it to "see the PR comment".
- **The tell is repetition without motion:** the same finding commented twice and pushes
  landing in between that do not touch the named file. Read that as *not delivered*,
  not as *deprioritised*. Instruct rudolph to escalate rather than comment a third time —
  a third comment is the protocol failing louder, not working.
- **Numbers in a comment go stale on a standing branch.** Whenever a finding carries
  measured values, the relay must say **re-derive at the moment of commit, never copy
  the figure** — the lane's own progress is what invalidates it.

---

## Roles and topology

```
                ┌─────────────────────────────────────────┐
                │  SANTA  (you, the orchestrator)          │
                │  • owns the canonical checkout           │
                │  • owns <TARGET> branch + all pushes     │
                │  • runs the full <GATE>, fixes, merges   │
                │  • briefs, goals, monitors, integrates   │
                └───────┬───────────────┬───────────────┬──┘
                        │               │               │
            brief+goal  │   brief+goal  │   brief+goal  │   (temp-file protocol)
                        ▼               ▼               ▼
                 ┌───────────┐   ┌───────────┐   ┌───────────┐
                 │ helper A  │   │ helper B  │   │ helper C  │   (dynamic count)
                 │ codex/... │   │ codex/... │   │ codex/... │
                 │ own wkspc │   │ own wkspc │   │ own wkspc │
                 │  <CHECK>  │   │  <CHECK>  │   │  <CHECK>  │
                 └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
                       │ .done         │ .done         │ .done
                       └───────────────┴───────────────┘
                          Santa collects, integrates onto <TARGET>,
                          runs <GATE>, pushes.
```

- **Dynamic number of helpers.** Use as many as the work parallelizes into and no
  more. You do **not** have to keep every helper busy at once — schedule them: a
  helper that finishes picks up the next independent slice. Idle helpers are fine;
  over-subscribing dependent work is not.
- **Santa may also run a helper** on its own checkout if that's convenient — but keep
  the roles straight: when you're acting as Santa you push/gate; a helper never does.
- **Isolation is mandatory.** Every helper works in its **own** `<WORKSPACE-NEW>`
  checkout so concurrent edits never collide. In a colocated `<VCS>` (e.g. `jj`), use
  the VCS's workspace mechanism, **not** a shared-HEAD `git checkout`/`git worktree`,
  which would yank sibling workspaces onto the same branch.

---

## Dependency-aware workspace planning (do this before fanning out)

Parallel work is only safe when the slices are independent. Before you spawn helpers:

1. **Map the dependency graph of the work.** Which slices are independent? Which
   depend on another slice's output? (E.g. WP-2 and WP-3 build on WP-1's new module.)
2. **Base each helper's workspace correctly.**
   - Independent slices → each helper's workspace off the **current `<TARGET>` tip**.
   - A dependent slice → either base its workspace off the **parent slice's** change
     (so it sees that code) and accept the serialization, or give it its **own fresh
     workspace off `<TARGET>`** and have Santa integrate the parent first, then rebase.
   Decide deliberately and write it down; don't let a hidden dependency turn into a
   merge conflict you discover at integration time.
3. **Rebase `<TARGET>` onto the latest mainline FIRST**, before creating helper
   workspaces, so everyone branches from current reality.

> This is the **composable-not-hierarchical** gate applied to *work scheduling*: name
> the real dependency web among the slices before you flatten it into a parallel
> fan-out; a slice you wrongly treated as independent is a dropped edge that returns
> as a conflict.

---

## The lifecycle

### 0. Prep (Santa, once)

- Update the canonical checkout; **rebase `<TARGET>` onto latest mainline**.
- Map the work into slices + their dependency graph (above).
- Decide how many helpers and which slice each starts on.
- Ensure helpers exist (BREED-CODEX / BREED-CLAUDE) — one tmux session each, each in
  its own `<WORKSPACE-NEW>`.

### 1. Initialize each helper (fresh context)

A freshly-spawned or reused helper is **dumb about the project** until told otherwise.
For **brand-new** work, give it a clean slate first (**REINIT**: `/clear`, or
exit+relaunch codex in its window — you can also just close the tmux session and breed
a new one; whichever is cleaner).

Then hand it an **initialization brief via the temp-file protocol** (never the
cmdline — special characters and hook-trigger strings mangle or block):

- Have it read the project's `README`, `AGENTS.md`/`CLAUDE.md`, contributing +
  implementation/house-rules docs, and skim recent history, so it relearns how the
  repo works.
- Give it its **slice**: exactly what to build, the acceptance criteria, and the
  guardrails — **work only in your assigned workspace `<DIR>`; drive everything through
  `<VCS>`; you may run `<CHECK>` but NOT the full gate; you do NOT push and you do NOT
  merge; write the done-file when complete.**
- End with *"Work through THIS message first and confirm you understand before doing
  anything; do not modify or inspect any workspace yet."*
- **Wait for the helper to go idle and read back its acknowledgement** before setting
  its goal. A helper that misread the brief will happily do the wrong thing for an
  hour.

### 2. Set the goal (autonomous run)

Once acknowledged, set the helper's **`/goal`** (GOAL op) so it runs to completion
autonomously. The goal must restate the terminal done-condition and the guardrails,
and must include **writing the unique `.done` file** on completion (DONE-FILE op).

### 3. Monitor — an EDGE-TRIGGERED watcher, not a done-file

**A `.done` file encodes exactly ONE state: "finished AND remembered to write it".**
It is structurally silent on every real failure mode:

- blocked on a dialog waiting for a keypress (update prompt, hook-trust prompt,
  "retry with a faster model" — each blocks *forever* and says nothing);
- went idle without writing a report (quit early, goal silently paused);
- the tmux session died;
- still "working" but thrashing the machine.

Those are the failures that actually cost hours, and a done-file cannot express any
of them — it just never appears, so **"not there yet" looks identical to "dead 40
minutes ago."**

> **NEVER hand-roll `until [ -f <done> ]; do sleep …; done`.** That loop is
> *exactly* the blindness this whole section exists to remove: it can only ever fire
> on the one happy state and is structurally silent on a helper that blocked, paused
> to ask you a question, quit early, or died — so you sit waiting on a corpse. Reading
> this section and then writing that loop anyway (it has happened) defeats the point.
> The reflex when you want to "wait for the helper" is to **arm `watch-elves.sh`**,
> not to write a sleep-loop on the done-file.

**Arm the persistent watcher instead** (`watch-elves.sh`, shipped next to this file),
run through the `Monitor` tool so each stdout line becomes one event:

```bash
<skill-dir>/watch-elves.sh <report-dir> codex codex2 codex3 rudolph
```

**For a long campaign, arm `supervise-elves.sh` instead** (shipped next to this
file); it wraps the watcher and closes the one gap the watcher cannot close for
itself:

```bash
HB_EVERY=600 <skill-dir>/supervise-elves.sh <report-dir> codex codex2 codex3 rudolph
```

Edge-triggering is what keeps `watch-elves.sh` from becoming the context problem
it exists to solve — but it also means **a healthy quiet watcher and a dead one
emit exactly the same thing: nothing.** Silence is not evidence that the fleet is
fine. The supervisor adds three things: a `HEARTBEAT` on a fixed cadence (so
silence past ~2 beats is *diagnostic*), an append-only log so events survive the
harness task dying and can be read back afterwards, and auto-restart if the
watcher exits — with the restart emitted as its own event. Verify the monitor is
alive before you end a turn, not merely that you started one; the harness-side
task can die while the shell process lingers, so a process count is not proof.
The log is.

It emits seven signals, and **only on a state transition**:

| Event | Trigger | Your response |
|---|---|---|
| `REPORT-READY` | report file appears (+ line count + first 300 chars) | verify → integrate → gate → push |
| `DIALOG` | pane matches an update / trust / allow / retry prompt | send the keypress |
| `WORKING` | pane shows a tool call in flight | nothing — it's healthy |
| `IDLE-STALL` | N idle ticks, **no** report | re-nudge; it quit early **or is waiting on you** — read the pane: a helper that stopped to surface a genuine blocker (a move-map conflict, a missing decision) shows up here too, and the right response is to answer it + resume its goal, not just poke it |
| `IDLE-DONE` | idle **with** a report | collect and integrate |
| `DEAD` | `tmux has-session` fails | re-breed that helper |
| `DISK`/`MEM` | `< 60G` free, or `> 4G` swapped | stagger the builds, reclaim a workspace |

**Four design rules that make it work — keep them if you rewrite it:**

- **Edge-triggered, never level-triggered.** It stores prior state per helper and
  speaks only on a transition, so a helper working 40 minutes produces exactly ONE
  `WORKING` line, not 40. Otherwise monitoring itself floods your context — which is
  the very problem monitoring was supposed to solve.
- **`IDLE-STALL` vs `IDLE-DONE` is the whole trick.** Same observable condition (the
  pane stopped moving); the presence of the report file disambiguates *finished* from
  *gave up*. This is precisely the distinction a bare `.done` file cannot make, and
  "helper went idle with gates red" is the single most common way a fleet silently
  stops making progress.
- **Debounce idle by 2 ticks.** Codex briefly stops printing between tool calls; a
  1-tick trigger cries wolf constantly.
- **Guard the machine, not just the fleet.** N concurrent Rust builds is exactly the
  shape that fills a disk. The resource check wakes you *before* the machine dies
  instead of after.

**Portability:** state lives in files, not `declare -A` — macOS ships bash 3.2, which
has no associative arrays. (Learned the hard way: the first version died instantly on
`declare: -A: invalid option`.) A restarted watcher therefore resumes with its
edge-detection intact instead of re-announcing everything.

**After unsticking, re-confirm the helper is back ON its goal.** Answering a prompt or
clearing a menu frequently leaves an autonomous agent **paused, not resumed** — a
codex drops to `Goal paused (/goal resume)` and then sits idle forever. Every unstick
ends with: capture the footer, and if it is not actively pursuing, resume/re-set the
goal. An unstuck helper that isn't pursuing its goal is still effectively stuck — it
just looks calm. (The watcher will tell you: it reappears as `IDLE-STALL`.)

**Arm it at dispatch time, not later.** "No watcher armed" is a real failure the user
will feel as silence.

**It disarms itself — and that is deliberate.** Once every watched helper is terminal
(`IDLE-DONE` or `DEAD`) for two consecutive passes, it emits `FLEET-COMPLETE` and
exits. `IDLE-STALL` is NOT terminal: a stalled helper needs a nudge, not abandonment,
so the watch stays armed. Pass `WATCH_STAY=1` when you intend to reassign helpers and
want one watcher across the whole session.

Why this is built in rather than left to the orchestrator: an edge-triggered watcher
with nothing left to report is **indistinguishable from one that is not running**. A
forgotten watcher therefore polls a finished fleet indefinitely and stays silent about
it — which is exactly how this was found (a watcher ran ~2.5 hours against an elf whose
work had already been integrated). "Remember to stop it" is not a control when the
failure mode is silence.

### 4. Collect + integrate (Santa)

When a helper signals done:

1. Read its `.done` (branch/change id + its `<CHECK>` status), then **delete the
   done-file** so the next assignment starts clean.
2. **Pull its change into `<TARGET>`** from its workspace (VCS-appropriate: fetch the
   change / cherry-pick / merge the workspace's commit). Do the integration work on the
   canonical checkout you own — helpers never do it.
3. **Resolve conflicts** and reconcile against anything you've already integrated.
4. **Run the full `<GATE>`** on `<TARGET>`. Fix whatever it flags — *this is Santa's
   job, not the helper's.* (You may hand a well-scoped fix back to a helper, but the
   gate itself runs on your checkout.)
5. **Merge to `<TARGET>`.** Only rudolph merges — never squash; change IDs are the durable identifiers a ledger cites.

### 5. Reassign or wind down

**Wind-down is a step, not an afterthought.** When the objective is done: confirm the
watcher has disarmed (`FLEET-COMPLETE`, or stop it explicitly if you passed
`WATCH_STAY=1`), delete the report files so a stale one cannot read as "finished" for
the next assignment, and reclaim each helper's workspace and its multi-GB output tree.
A fleet that is "done" but still holding watchers, reports, and workspaces is not done.


- A finished helper gets its **next independent slice** (REINIT for clean context →
  initialize → goal). Schedule to keep progress flowing without over-subscribing
  dependent work.
- When the objective is complete, do a final `<GATE>` + push, update any plan/ledger
  the project expects, and (optionally) wind helpers down — but helpers usually should
  outlive a single objective, so don't kill them unless asked.

---

## Fan-out — helpers can recurse

A helper is itself a capable agent: if you tell it to **"fan out"**, it can spawn its
own subagents to parallelize *its* slice. Use this when a single slice is itself broad
(a sweep, an audit, a wide refactor). You stay Santa at the top; the helper becomes a
sub-orchestrator for its slice. The integration boundary rule still holds all the way
down: **only Santa (the top) pushes and runs the gate**; a fanned-out helper collects
its subagents' work in its own workspace and hands the single result up to you.

---

## Hard rules — don't break these

- **Only rudolph merges and runs the full `<GATE>`.** Elves run `<CHECK>` and push their own branch; Santa touches no checkout at all.
  This is the whole point; if a helper pushes, the discipline is gone.
- **Heavy builds live in ONE checkout — never multiplied across the N helper
  workspaces (the disk/artifact bomb).** Every isolated `<WORKSPACE-NEW>` has its
  **own build-output tree** (`target/`, `node_modules/.cache`, `__pycache__`, a Go
  build cache, …). A **full**, whole-project build — a workspace-wide lint
  (`cargo clippy --workspace --all-targets --all-features`), a full test sweep
  (`cargo nextest run` / `go test ./...` / the whole `pytest`), or any cold
  build-the-world — cold-populates a **multi-GB output tree, times N helpers, in
  parallel**. That slows every machine to a crawl and can **fill the disk to the
  point the whole run dies**. So:
  - **Helpers run ONLY the cheap, scope-limited `<CHECK>`** in their workspace
    (`cargo check -p <touched-crate>`, `cargo test -p <touched-crate>`, a named
    `cargo nextest run -E 'test(x)'`, `tsc --noEmit` on the touched project).
    **FORBIDDEN in a helper workspace, with no exception worth the disk:**
    `--all-features`, `--all-targets`, the two together, `clippy` carrying either,
    `--workspace`, a full `nextest`/`go test ./...`/`pytest` sweep, and **`-p
    <composition-crate>`** — a crate that depends on everything (a kernel, a boot
    or wiring crate, the composition root) is a whole-workspace build wearing a
    `-p` costume, and its `--all-features` graph is the entire tree.
  - **This rule is broken by a SECOND, well-meant instruction — check every brief
    against it.** Measured: after a helper shipped an API change that broke a
    dependent crate, the orchestrator added "check every direct dependent" to the
    briefs. Correct instinct, ruinous mechanics — the dependent WAS the
    composition crate, so four helpers each cold-built the world in their own
    `target/`, and thirteen workspaces reached 60 GB. The orchestrator had quoted
    this very rule at them in the same brief.
  - **So verify dependents like this instead — report, then build ONCE.** The
    helper enumerates them (`cargo metadata` gives a real census, not a guess),
    checks only the ones that are genuinely cheap leaves, and **names the rest in
    its done-file**. Santa builds those in the canonical warm tree — which costs
    nothing extra, because the gate already compiles the world at push time. The
    check moves to where the build already happens.  
  - **The full `<GATE>` and any whole-project verification/closeout run once,
    SEQUENTIALLY, in the single canonical checkout** — one **warm** output tree
    reused across every slice, not N cold ones. Finish one slice's gate+merge, then
    the next; don't fan the heavy builds back out.
  - If the closeout must itself be driven by an agent, point **one dedicated
    closeout helper at the canonical checkout** (not at each slice's own workspace),
    so the heavy builds still hit a single output tree while the original helpers
    stay parked in their workspaces.
  - **Reclaim each helper's workspace IN THE SAME STEP as its merge** (drop the
    workspace + its output tree; e.g. `jj workspace forget <name>` + remove the
    dir). Not "at the end of the round" — the end of a round is when the next
    round starts, and a dead workspace is indistinguishable from a live one at a
    glance. Measured: twelve merged slices sat un-reclaimed at 54 GB while a
    thirteenth was still building. Tie it to the ledger update so it cannot be
    forgotten: merge, ledger, reclaim. Watch free disk across the run; if it drops
    toward a danger threshold, stop and reclaim before continuing.
- **Every helper works in its own isolated `<WORKSPACE-NEW>`.** Never two agents in one
  checkout. In a colocated `<VCS>`, use its workspace mechanism, never a shared-HEAD
  worktree/checkout that would drag siblings onto another branch.
- **Rebase `<TARGET>` onto mainline before fanning out**, and integrate onto `<TARGET>`
  — never let helpers target mainline directly.
- **Brief via the temp-file protocol, never the cmdline.** Write the brief with a file
  tool; `cat` it; `send-keys -l`; separate Enter. This avoids special-char mangling and
  host-hook trigger strings.
- **Wait for acknowledgement before setting a goal.** Confirm the helper understood the
  brief; only then `/goal`.
- **Keep every active helper on a LIVE goal — this is how they keep working.**
  Autonomous helpers (codex especially — it's lazy) only keep grinding while a goal is
  active; a plain message will NOT sustain a long run, and a goal silently **pauses**
  after any interruption. So: after the brief is acknowledged → set the goal; after any
  unstick/answer/correction → re-confirm it's `Pursuing goal` and resume if paused. A
  helper off its goal produces nothing and never writes its done-file — it's silently
  idle, not working.
- **Unique, cleaned-up report files.** Mint fresh (or delete stale first); delete on
  collect. A leftover report is a false "finished" — and it will also make the watcher
  call a fresh assignment `IDLE-DONE` the moment it pauses.
- **Arm the watcher at dispatch time.** A fleet running with no watcher is a fleet you
  will discover is dead 40 minutes late. The report file alone cannot tell you.
- **Map dependencies before parallelizing.** An unnoticed dependency edge becomes a
  merge conflict. Base dependent slices deliberately.
- **Don't over-subscribe or busy-wait.** Idle helpers are fine; scheduling dependent
  work in parallel is not. Never hand-poll `capture-pane` in a loop — arm the
  edge-triggered watcher (step 3) and let it wake you.
- **Reinit for new work.** Old context bleeds into new slices — `/clear` or
  exit+relaunch (or close+re-breed the session) before a brand-new assignment.
- **Intent over wording.** These recipes are defaults; adapt the choreography to the
  actual task. If a step doesn't fit the work in front of you, do the thing the pattern
  is *for* (parallelize safely, keep the integration boundary, ship verified work),
  not the literal step.

---

## Pattern in chat

When the user says *"go santaing"* / *"drive the fleet on <plan/branch>"* / *"fan the
helpers out on X"* / *"orchestrate the codexes to build Y"*:

1. **Prep** — rebase `<TARGET>` onto mainline; map the work into slices + dependencies;
   decide helper count and starting slices.
2. **Ensure helpers** — spawn/reuse one tmux agent per active slice, each in its own
   `<WORKSPACE-NEW>` (breed-codex / breed-claude).
3. **Initialize each** — reinit for clean context; temp-file brief (read repo docs +
   the slice + guardrails); wait for acknowledgement.
4. **Goal each** — set `/goal` with the terminal done-condition + the `.done` file.
5. **Monitor** — arm `watch-elves.sh` via `Monitor` at dispatch; act on its events
   (`DIALOG` → keypress, `IDLE-STALL` → re-nudge, `DEAD` → re-breed, `DISK` → reclaim).
6. **Integrate** — on each done: pull the change onto `<TARGET>`, resolve, run `<GATE>`,
   fix, **push** (Santa only).
7. **Reassign** — hand finished helpers the next independent slice; repeat until the
   objective is done; final `<GATE>` + push + update any project ledger.

Report progress as a fleet status: per-helper (session, slice, state: briefed /
pursuing / done / stuck / integrated) plus what's on `<TARGET>` and what's left.

## Judge a long job from its ARTIFACT, not its process table

When you hold a fleet idle waiting on one long job, the temptation is to confirm
progress the cheap way: `pgrep` counts, a live compiler at 99% CPU, a process
that is 4 seconds old. **All of that proves the machine is busy. None of it
proves the command is doing what you meant.**

A regen once ran a full hour under a held quiet window and produced nothing —
the helper had written `2>&1 > file`, which sends stderr to the terminal and
only stdout to the file, so the real error was discarded at second one. Santa
and the helper both watched process liveness the whole hour and both saw a
healthy-looking run.

**Read the output artifact early — minutes in, not at the end — and confirm it
contains what you expect.** An empty or malformed capture file is the signal a
process count structurally cannot give you. This is the same rule as "only an
exit code is authoritative", extended: while a job is still running, the
artifact is the only honest progress signal available.

Corollary for the redirect itself: `> file 2>&1` captures both streams;
`2>&1 > file` captures only stdout and throws the errors at your terminal.
When you hand a helper a long backgrounded command, check the redirect order
in the command it actually ran.

## When a gate blocks the integrator, it reports — it does not rephrase

The integrator is the only agent touching the integration boundary, so a habit
of routing around a block is the single habit that cannot be allowed to settle
in there. A blocked gate is a stop-and-report event: Santa decides whether the
gate is wrong. If it is, the override is explicit and leaves a trace; if it is
right, the underlying setup gets fixed.

**But establish that a bypass actually happened before calling one.** Santa
once accused the integrator of evading a gate because a refused command was
followed by a differently-spelled one that succeeded — `git -C <path> push`
after a workspace-resolution refusal. Reading the classifier afterwards showed
`-C` was in its value-consuming flag table *specifically* so it cannot hide a
subcommand: the second command was fully gated, and the long wait that looked
like a bypass was the gate running. The integrator had done exactly what the
error message asked — made the target unambiguous.

The cost of getting this wrong is not just an unfair accusation. Telling an
integrator to halt and report on a class of operation that was never a bypass
slows every subsequent merge for no reason. **Read the gate's own classifier
before concluding it was circumvented** — a refusal followed by a success is
equally consistent with the operator fixing the thing the gate objected to.

Related, and the reason that block happened at all: **scratch trees for
integration work belong in the project's own isolated-workspace mechanism, not
in a temp directory.** A build tree under `/tmp` is invisible to the repo's
artifact-reclamation tooling and never gets cleaned up, and in a jj-colocated
repo a *git* worktree is the shape that tangles sibling workspaces. That part of
the finding held up; the bypass part did not.

## Rebasing a shared lane branch is a fleet-wide event — warn the lane first

Rebasing a long-lived lane branch before landing it is correct practice, and it
is usually Santa who asks for it. But a lane branch is shared: any helper still
building on it has its base moved out from under it by the force-push.

**Send the warning before the push lands, not after**, and make it actionable:
fetch first, check where your work sits relative to the new tip, rebase your own
commits onto it, commit loose working state before rebasing, and stop and report
rather than resolving anything that looks tangled. Two lanes independently
guessing at the same rewritten graph is how a branch ends up carrying both the
pre-rebase commits and their rebased twins.

## The integrator defers too — and its deferrals look like diligence

Helpers get briefed against a no-deferral rule. The integrator often does not,
because its job is framed as *merge the queue* — so when it notices something
adjacent to a merge, the tidy-sounding move is to flag it for later and keep the
queue moving. That is still a deferral, and it is the most plausible-looking
kind: it names the problem, records the evidence, and sounds like good hygiene.

Observed shape, immediately after landing a lane: *"the substeps are still
unchecked on the master plan even though the work is now shipped — not fixing it
inline since it's not urgent and you're tracking the merge chain, flagging for
whoever picks up that ledger next."* Every clause is reasonable and the whole is
wrong. The integrator was standing in front of the problem with the evidence in
hand and a few minutes of work between it and a correct ledger.

**Two things make this worth interrupting a merge queue for.** A checkbox
unticked against landed code is not cosmetic — it *understates what exists*, so
the next reader either redoes the work or plans around a capability they believe
is missing. And "not urgent" is the wrong axis entirely: a wrong ledger is wrong
from the moment it is wrong, and the cost is paid by whoever reads it next, not
by whoever wrote it.

**Santa's move is not just "don't defer" — it is to remove the excuse.** Verify
the evidence yourself and hand it over ready-made (the resolved change IDs, the
exact lines, the regeneration command, and confirmation that the landing is
inside an existing gate exception rather than needing an override). A deferral
that survives after the work has been reduced to five minutes of typing is a
different conversation from one made while the work still looks open-ended.

## Landing a stack has a second half: retarget the child when the parent merges

A stacked PR is based on its parent's branch. When the parent merges, that
branch becomes subsumed by trunk — its tip *is* a commit now in trunk — and the
child PR is left pointing at a dead branch. Merging it as-is lands the work on
that branch instead of trunk, where it quietly does nothing.

This is not a mis-basing error. It is what *success* looks like partway through
a stack, and it will happen once per level on every stack the fleet builds.

**So a "report mis-based PRs to me" rule needs an explicit carve-out for it**,
or the integrator stops on every stack level and waits for a decision that is
always the same. Distinguish the two cases by cause:

- **Parent merged, base now subsumed** → retarget to trunk and carry on. Verify
  first that the base branch really is an ancestor of trunk and that a merge
  simulation against current trunk is clean; then the retarget changes *where*
  the work lands, not *what* lands.
- **Base wrong for any other reason** — never an ancestor of trunk, a dirty
  merge simulation, a branch nobody recognises → that is a real defect and goes
  back to the lane that owns it, because re-parenting would hide the mistake
  from the person who needs to learn about it.

Pre-authorize the whole chain when you authorize the first one. A three-deep
stack otherwise costs three identical round-trips through Santa, each one
blocking the merge queue behind it.

## The implementer ticks the ledger, on the branch, in the landing change

A project whose ledger is the source of truth for "what is done" usually has a
rule that the owner ticks the box with its evidence *as the work lands*. That
phrasing is ambiguous in the worst possible way: it reads equally as "in the
change that lands it" and "once it has landed". Fleets drift to the second
reading, because from inside a lane the tick feels like paperwork that follows
shipping rather than part of it.

The result is a window — sometimes long — where trunk carries the code and the
ledger says the work does not exist. Anyone reading the ledger in that window
either redoes the work or plans around a capability they believe is missing.
Worse, the correction afterwards is a **ledger change arriving without the code
that justifies it**, which is exactly the plan-only landing most such projects
have a gate to refuse.

**Three things make this stick:**

- **Say "in the change that lands it, on the branch, before merge."** Never "as
  it lands". The ambiguity is the whole defect.
- **Kill the not-yet-known-evidence excuse explicitly.** Where the evidence is a
  VCS identifier that is stable from creation — a jj change ID, say — the
  implementer can read it the moment they commit and tick in a follow-up commit
  on the same branch. If the fleet believes the identifier only exists after the
  merge, they will defer the tick every time and be reasonable about it.
- **Make it a merge precondition, and have the integrator bounce rather than
  fix.** A PR implementing a carved substep without its tick goes back to the
  lane. If the integrator patches it, the lane never learns, and the integrator
  becomes a permanent ledger-repair service.

**Audit the fleet rather than assuming.** Diff each open PR's branch against
trunk and check whether it touches the ledger. When this was run on one fleet of
three lanes, one lane was ticking correctly and two were not — so it was neither
"everyone knows" nor "nobody does", and only the diff distinguished them.

## A lane branch needs a DRAIN, not abolishing

The lane model — one standing branch per phase, one open PR at a time from it to
trunk — is a good shape. Work accumulates coherently, the phase has one address,
and the integrator sees one queue item per lane instead of one per unit.

Its failure mode is not the branch. It is a lane that **accumulates with no drain
PR open**. One fleet ran a lane fourteen commits deep before anyone noticed, and
the reason nobody noticed is that the failure is invisible where you look for
work: every individual merge onto the lane *succeeded*, and the PR list showed
nothing waiting. An empty queue and a stalled lane look identical.

**Santa diagnosed that as the lane model being wrong and told the lane to target
trunk directly. That was the wrong lesson and it contradicted the maintainer's
explicit instruction** — other lanes were running the same model without trouble.
Removing a structure because one instance of it went unmaintained is a reflex to
catch in yourself.

**The actual practice:** measure lane depth on a cadence, not from the PR list.
`rev-list --count trunk..<lane>` per active lane. A lane more than a few commits
deep with nothing open to land it is work that has stopped moving, and it is
Santa's job to notice — the lane cannot see it (it is busy building) and the
integrator cannot see it (its queue is empty).

Make this an explicit check when the merge queue goes quiet. A quiet queue is
exactly when a stranded lane is most likely, and exactly when nobody is looking.

## Only the phase reservation lands ahead of the work — substeps and ticks ride the branch

A ledger that tracks work has two kinds of entry, and they land at different
times. **The reservation** — the phase's row and stanza, claiming the number and
saying what it is for — legitimately lands on trunk before any code exists; that
is what stops two lanes claiming the same phase. **Everything else** — new
substeps, and the ticks against them — rides the branch and merges with the code
it describes.

Santa broke this by asking a lane to "mirror the substeps onto the ledger" as its
next unit of work. Framed that way it sounds like a deliverable, and the lane
correctly produced a standalone docs-only PR. But a PR carrying only new ledger
boxes claims structure for work that has not arrived, and merging it is the
plan-only landing most such projects refuse.

**The lane model already solves this if you let it.** The lane has a standing
branch and one open PR; new substeps go on that branch as unchecked boxes, the
lane keeps building on the same branch, each tranche ticks the boxes it actually
finishes, and the whole thing merges as one coherent unit — ledger and code
together, unable to drift.

**Watch for the gate being technically satisfied.** A plan-only landing gate
often exempts "adds only unchecked boxes" as a legitimate truth-correction. That
exemption exists for genuine ledger repair, not for a lane's substeps arriving
ahead of their implementation. So the integrator's check is not "would the gate
pass this" but "does this carry the work it describes" — those differ exactly
here, and only the second one is the rule.

## A stale citation and a false tick look identical — only the code tells them apart

A ledger entry ticked with evidence that resolves to nothing has two completely
different causes and opposite fixes:

- **False tick** — the work never shipped. Fix: untick.
- **Stale citation** — the work shipped, but the commit it cited was rewritten or
  dropped, someone later restored the work under a fresh identifier, and nobody
  walked the ledger to re-point the citation. Fix: re-cite, keep the tick.

From the ledger alone they are indistinguishable, and the instinct — untick,
because the evidence is bad — silently deletes a true completion record.

**The rule: check the tree, not the ledger.** Does the capability actually exist
in the code right now? If yes, hunt for the change that really landed it; a
restore commit usually says so in its own title. If no, untick.

**Why this recurs:** durable change identifiers survive *rebase*, which is what
they are sold on — but they do not survive *abandonment*. A restore is a new
change with a new identifier, and nothing walks the ledger to update citations
pointing at commits that no longer exist. Every rewritten-then-restored piece of
work leaves one of these behind.

Related: where a gate scans for citation-beside-checkbox, the citation must be on
the checkbox's own line. A citation in the paragraph below reads correctly to a
human and is invisible to the scanner.

## Santa's status checks must be read-only — VCS status commands often are not

Santa is told not to touch the canonical checkout, and it is easy to believe a
status check honours that. It frequently does not: in jj, ordinary commands
snapshot the working copy as a side effect, so a Santa polling `jj git fetch` in
the integrator's checkout every few minutes has been *mutating the integrator's
state* on every poll — including snapshotting whatever it had half-finished.

The symptom that surfaces it is a stale-working-copy error appearing in Santa's
own output, which reads like the integrator's problem and is actually Santa's.

**Use commands that only read.** Plain `git fetch`, `git rev-list --count`,
`git ls-remote`, and the forge CLI all answer the orchestration questions —
what is trunk, how deep is each lane, what is open — without touching the
working copy. Reserve the VCS's own porcelain for the agents that own a
checkout.

This matters most exactly when it is least visible: a fleet running for hours
means hundreds of Santa polls, each a chance to snapshot an integrator
mid-operation.

## NEVER slow the integration queue for a lane. The branch that diverged carries the rebase burden.

**This is settled software practice, not a judgement call.** Mainline does not
stop for a long-running refactor. Linux does not freeze the merge window because
an out-of-tree patchset has grown hard to rebase — the tree moves at its own
pace, and reconciliation sits entirely with the branch that diverged. That is why
the standard advice is *upstream early, upstream often*, and why enormous
out-of-tree patchsets bit-rot instead of the tree waiting for them.

**The failure mode to recognise in yourself.** One lane runs much deeper than the
others. It reports conflicts every cycle and the conflicts get *worse*. It is
tempting to measure trunk's merge rate against the lane's depth, conclude the
lane is being "starved", and freeze the queue so it can catch up. Santa did
exactly this on one fleet and the maintainer reversed it immediately and
emphatically. It is wrong on every axis:

- **It stops N-1 lanes to help one.** Verified, ready PRs sit unmerged while
  their branches keep growing — so the freeze *manufactures* the same deep-lane
  problem across the whole fleet while solving it nowhere.
- **The deep lane is usually a moving target too.** In that case the lane was
  still authoring new migrations *while* rebasing. Freezing trunk cannot converge
  a rebase when the branch is also advancing — and trunk was the only end the
  orchestrator could even control.
- **It rewards the behaviour that caused it.** A lane that never stops to land
  learns that the queue will wait for it.

**The remedy is always at the lane, and it is two things:**

- **The lane freezes ITSELF.** No new substeps, no new commits that are not part
  of getting the PR mergeable. Rebase, resolve, verify, land — *then* resume
  building. A branch that stops moving converges against a trunk that does not.
- **Land smaller batches.** Depth is what makes a rebase painful. A lane that
  opens a PR every few substeps never reaches the state where reconciliation
  becomes a project of its own. If a rebase is already large, split it: land the
  uncontroversial majority, leave the conflicted files for a small follow-up.
  That beats one enormous PR that keeps missing the window.

**Standing rule, no exceptions: the queue never stops for a lane.** A PR that is
not mergeable waits its turn while everything else lands. Slowing the integrator
is never the remedy for a lane that cannot keep up — and if you find yourself
constructing an argument for why this particular case is special, that argument
is wrong.

## A live goal outranks your messages — to change what a helper does, change the GOAL

Helpers driven by a standing goal will keep executing that goal. A message
telling them to do something else competes with it and usually loses, because
the goal re-asserts itself on the next turn while the message is a one-off.

The tell is a helper that acknowledges an instruction and then visibly continues
the old work — same task list, same in-progress item, no change in what it is
building. Santa sent one lane three increasingly firm messages to stop building
and land its PR; the lane kept building, because its goal said in as many words
*take the next substep, then immediately take the next one, do not stop to ask
permission*. The instruction was not being ignored — it was being outvoted by
Santa's own earlier instruction.

**So when the objective changes, replace the goal, not the conversation.** Clear
the input, set a new goal that states the new objective as the whole objective,
and let the old one go. Keep the constraints that still apply, but do not leave
the superseded directive in place hoping a message overrides it.

**And read this as a diagnostic about yourself.** If a helper is not doing what
you asked twice, check what you told it to do *persistently* before concluding
it is misbehaving. The conflict is usually between two of your own instructions,
and only one of them is still visible to you.

## Slash commands sent to a Claude helper MUST use bracketed paste, or they arrive mangled

Claude's TUI pops a slash-command picker the moment a `/` is typed, and that
picker **consumes the next several keystrokes as filter input**. So a goal sent
with `tmux send-keys -l '/goal Do the thing'` arrives as `l Do the thing` — the
`/goa` is eaten, and what lands is a plain message that happens to start with a
stray letter.

**This fails silently and looks like disobedience.** The helper receives a
perfectly reasonable-sounding message, acts on it once, and then reverts to its
*previous* goal on the next turn — because no new goal was ever set. Santa spent
an hour concluding a lane was ignoring instructions, then found the queued text
began `l Land PR #622` and understood that every `/goal` sent that session had
been silently downgraded to a message.

**Always send a slash command as bracketed paste:**

```sh
printf '%s' '/goal …' | tmux load-buffer -b g -
tmux paste-buffer -p -b g -t <session>
tmux delete-buffer -b g
sleep 1.5
tmux send-keys -t <session> Enter
```

`paste-buffer -p` wraps the text in bracketed-paste markers, which the TUI
treats as paste data rather than routing through the picker, so the whole string
lands as one input line.

**Then verify it registered.** The pane echoes `Goal set: …` on success. If you
see your text with a leading fragment instead, the picker ate it. A goal you
believe is active but is not is worse than no goal: the helper keeps executing
something you replaced hours ago, and every message you send fights it.

**Related timing trap:** a busy helper shows `Press up to edit queued messages`
and processes input only at turn boundaries. With turns running twenty-plus
minutes, direction lands late — so sending three increasingly firm messages just
builds a deeper queue. Check whether input is queued before concluding anything
about compliance.

## The integrator's queue is stale by construction — make re-listing a command, not a habit

An integrator gates one PR at a time, and a full gate takes fifteen to twenty
minutes. Meanwhile every lane keeps pushing. So whatever the integrator believed
about the queue when it started is wrong by the time it finishes — not
occasionally, but *every single cycle*.

The failure has one shape and it repeats: the integrator checks the PR it was
already thinking about, finds it blocked or conflicting, and concludes "no merge
work available" while two other PRs sit open. One fleet's integrator did this
five separate times in a night, each time after being told to re-list.

**Telling it to re-list does not work, because the whole problem is that it
believes it already knows.** Replace the habit with a literal command it runs as
the first action of every cycle, before any reasoning about what to do:

```
gh pr list --repo <owner>/<repo> --json number,headRefName,mergeable \
  --jq '.[]|"#\(.number) \(.headRefName) \(.mergeable)"'
```

Then work that output top to bottom. The instruction is *do not carry a queue in
your head between cycles* — and the reason, which makes it stick, is that four
lanes push while it gates one PR.

**Santa's tell:** an integrator reporting "nothing to do" while `gh pr list`
shows open PRs. Check the real queue yourself before accepting an idle report;
idle is sometimes correct, but "idle because I did not look" is the common case.

## Whatever is being reconciled must hold still — in BOTH directions

Two failure modes with one cause, and a fleet will hit both:

**The lane cannot converge because trunk moves.** A deep branch finishes a
rebase; another PR lands; the rebase is invalid. Repeat. *Remedy: the lane
freezes itself, rebases, lands, then resumes — and lands smaller batches so it
never gets deep enough for this to bite. Never freeze trunk.*

**The integrator cannot converge because the lane moves.** The integrator
completes a gate run on a PR; the lane pushes again; the run is invalid. Repeat.
One fleet's integrator verified the *fifth consecutive tip* of one PR without
ever merging it, while six mergeable PRs queued behind. *Remedy: a branch handed
to the integrator is frozen until it merges or comes back.*

The second one is easy to miss because everyone looks busy and productive — the
lane is genuinely classifying and pushing, the integrator is genuinely gating.
Nothing is idle and nothing lands.

**State the freeze rule to the lanes explicitly, at briefing time.** Left
unstated, a lane that keeps pushing to its open PR is doing exactly what a lane
is supposed to do, and will keep doing it. Frame it as the same class of error
as merging its own PR: *the branch is the integrator's while it is being gated.*
The lane keeps working — classifying, committing locally, running scoped checks
— it just holds the push until the PR lands.

**Santa's tell:** an integrator reporting a tip number ("the fifth tip", "the
third head") rather than a result. That phrasing means it has re-verified the
same PR repeatedly, which only happens when the branch is moving underneath it.

## Separate "land smaller" from "ask me what to work on" — helpers conflate them

Telling a helper its last PR was too big is normal and useful feedback. But it
is easy to hear as *"check with me before choosing work"*, and a conscientious
helper will start asking which task to take next — which is the opposite of what
you wanted, and costs more than the oversized PR did.

One lane spent sixteen minutes deciding whether to ask Santa which substep to
pick, after being told its previous batch had grown too large. Its own reasoning
had already selected correctly and needed no confirmation.

**State the two separately and keep them separate:**

- **Landing cadence is a rule**: open a PR every few units of work, never once
  per session. This is Santa's to set, because only Santa sees the integration
  queue and the cost of a deep rebase.
- **Task selection is the lane's**: it holds the phase context and knows what is
  mechanical versus what needs design. Santa choosing substeps is both slower
  and worse-informed.

When correcting size, say explicitly which one you are talking about — *"this is
about how often you land, not about what you pick"* — because the helper cannot
tell from the correction alone, and the cautious reading is the wrong one.

**The general form:** any feedback that sounds like "you overstepped" invites a
helper to narrow its autonomy in whatever direction it guesses. Name the axis
you meant, or you will get caution in the wrong dimension.

## Never restore a shared file wholesale from an older base — it silently reverts other lanes

A lane rebasing its work will sometimes reach for a wholesale restore of a file
from its own older base, to recover edits it made there. On a file only that
lane touches, this is fine. On a **shared** file it is data loss: the restore
says *my version is authoritative for this entire file*, and on anything several
lanes edit — the master plan, a word list, an allow-list, a generated corpus —
that statement is false by construction. Another lane's concurrent addition
disappears with no conflict, no warning, and nothing in the diff that looks
wrong unless you read it closely.

One fleet hit this twice in a session, on two different shared files. The second
time was caught only because an unrelated corpus test happened to fail on the
lane's branch while passing on clean trunk — luck, not design.

**The rule: reapply your own edits as targeted changes onto the current file.**
Take the file at current trunk, make your specific additions, done. Never
`restore`/`checkout` the whole file from an older revision when more than one
lane can touch it.

**Santa's angle:** shared files are the fleet's collision surface, and they are
predictable — the ledger, the allow-lists, the generated inventories. Name them
explicitly at briefing time and attach this rule to them, rather than waiting
for a lane to discover it. And when a lane reports "I fixed my rebase by
restoring X", ask what else was in X.

## A merged PR's branch is DONE — pushing to it strands the commit invisibly

After a PR merges, its branch still exists and still accepts pushes. A helper
that adds "one more small thing" to that branch produces a commit with **no path
to trunk**: the PR is closed, nothing will carry it, and the push succeeded so
nothing looks wrong from the lane's side.

One fleet lost a documentation commit this way — and the commit being stranded
was the one recording a *different* data-loss trap. Both errors have the same
root: acting on a stale belief about the state of a branch.

**The rule for helpers: once your PR merges, that branch is finished forever.**
New work goes on a new branch with a new PR, or onto whatever branch you are
currently working. Never push to a merged branch, even for a one-line follow-up.

**Santa's detection, because the lane cannot see it:**

```
git rev-list --count trunk..<branch>          # commits not in trunk
git merge-base --is-ancestor <branch> trunk   # fails => something is stranded
```

Run it over branches whose PRs recently merged, not just active lanes. The
signal a helper gives you is a report mentioning a PR number you know has
already landed — "pushed to #672" when #672 merged an hour ago is the tell, and
it is worth checking every time rather than assuming they meant a new PR.

## Count each lane's IN-FLIGHT branches — more than two is a stall forming

A productive lane will happily accumulate branches: one PR conflicting after
trunk moved, another awaiting a rebase, a stray commit on a merged branch, and a
fresh branch for whatever it is building now. Each one individually looks fine.
Together they are an evening quietly not landing.

One lane reached four: two conflicting PRs carrying real, ticked substeps, one
stranded commit with no PR at all, and a new branch it had just started. From
inside the lane nothing was wrong — it was busy and productive the whole time.

**Santa counts branches per lane, because the lane counts only the one it is in.**

```
for b in <lane's branches>; do git rev-list --count trunk..$b; done
```

**The ordering rule to give them: finish before starting.** Work that is nearly
landed is worth more than work that is nearly started, because merging is what
takes it out of risk. So clear the backlog cheapest-first — recover any stranded
commit, rebase the smallest conflicting PR, then the next — and only then return
to new work.

**Give them a threshold, not just an instruction:** more than two branches in
flight means stop and land. A number they can check themselves survives longer
than a judgement they have to make while deep in something else.

## ONE PUSH PER PR — the only branch-freeze rule a lane can enforce without Santa

A lane that keeps pushing to its open PR while the integrator gates it destroys
the gate run, every time. Three lanes did this in one night on one fleet, each
costing a full re-verification while other PRs queued behind.

**Two rules that do not work, and why:**

- *"Freeze the branch once handed over."* The lane cannot tell when the
  integrator starts gating, so it either freezes too early (idling) or not at
  all.
- *"Push freely; freeze when Santa says."* A gate run is fifteen to twenty
  minutes and Santa's poll cycle is ten, so the notice reliably arrives after
  the run is already lost. Santa is structurally too slow to be in this loop.

**The rule that works: one push per PR.** Push the batch, leave the branch
alone, accumulate the next batch locally, and push it after the PR merges — onto
the next PR. A lane always knows whether it has already pushed to the branch it
is on, so it needs no signal from anyone.

**The trade is deliberate and desirable**: more, smaller PRs rather than fewer
that keep growing. That is the same direction as every other cadence rule, and
it is what prevents a lane reaching the depth where a rebase becomes a project
of its own.

**Santa's residual job** is only to say when a PR has merged, which is cheap and
already part of the status sweep.

## "Hold your push" reads as "stop working" — say both halves every time

A lane told to hold its push will often stop entirely. Two lanes on one fleet
did it within an hour of each other, both reporting the hold correctly and then
sitting idle for twenty-plus minutes.

It is not a comprehension failure, it is an under-specified instruction. "Do not
push" names the thing to stop and says nothing about what continues, and the
cautious reading of an unnamed remainder is to stop that too.

**Always state both halves, explicitly:**

```
HOLD = do not push to that branch
KEEP = keep taking work, committing locally, running scoped checks
```

And give the reason, because it makes the shape obvious: the rule exists to
spend **one gate run per batch instead of three**, not to park a lane while the
integrator works. A lane that idles during every hold costs more than the
duplicated gate runs the rule was written to prevent.

**Santa's tell:** a lane whose last message correctly acknowledges the hold, and
whose process count is zero. Acknowledgement is not activity — check the build
processes, not the acknowledgement.

## A ratchet reaching zero is a CLAIM — check what the zero was made of

When a helper is working a debt ratchet toward zero, the pressure of the target
quietly reshapes the work. The honest routes to zero are: fix the thing, or
record a real reason why it stays. A third route always exists and always
looks like the second — **annotate the outstanding work with a reason that
describes it accurately, and suppress it anyway.**

One lane reported an entire section at 0/0. Asked what the zero was made of, it
answered honestly: of 38 sites, 16 were genuinely exempt, 5 were blocked by a
real technical blocker, and **17 were convertible with no blocker at all** —
annotated with reasons that said, in plain words, *"should fold into the domain
type… not yet converted… reopen at the next conversion pass"*. Every word true.
The disposition wrong.

**That shape is more dangerous than a false reason.** A false reason gets caught
by anyone who reads it. A *true* reason attached to the wrong disposition reads
as considered, survives review, and leaves the ratchet asserting completion over
work nobody has done.

**So when a section reports zero, ask what the zero is made of** — the split, by
category, before accepting the number. The question is cheap and it is the only
thing that distinguishes a finished section from a suppressed one.

**And say the rule out loud when setting the target:** zero means every site is
*fixed*, *genuinely exempt*, or *blocked by a real blocker*. "Outstanding but
annotated" is not a fourth category. A lane that knows the definition will not
reach for the third route, because it can see it does not qualify.

The correct outcome here was a section reporting **12 entries still open**, not
zero — and that is the more valuable artifact.

## Autocompact can silently fail — a frozen context is a wedge, not a pause

Long-running helpers normally compact themselves and continue. Sometimes one
does not: it sits at the compaction threshold accepting input — its context
ticks up when you message it — while never generating and never compacting.
Zero build processes, no output, indefinitely.

**Do not treat "leave compaction alone" as absolute.** That rule exists because
killing or compacting a helper mid-work destroys real progress, and it is right
for that case. It is wrong for a helper that has stopped entirely. One fleet lost
an hour of a lane's time because Santa had recorded the rule without its
exception.

**Distinguish them by evidence, not by the rule:**

- *Compacting or thinking* — context still moving, a progress indicator present,
  or build processes running. Leave it.
- *Wedged* — the same context number for tens of minutes, zero processes, no
  output, and it still accepts input without acting on it.

**The clincher is a sibling.** If another helper crossed the same context range
in the same session and compacted cleanly, the frozen one is session-specific,
not a threshold problem. That comparison converts a guess into a finding.

**Santa's move, once the wedge is established, is to send the compaction command
directly** — the evidence above is what licenses it. Sitting on a dead lane
waiting for permission costs more than the command does, and the rule that
protects a *working* helper does not apply to one that has stopped.

Send it as a slash command via bracketed paste, never plain keystrokes: the
TUI's slash-picker consumes the first characters and the command arrives
mangled. Confirm it took by looking for the compaction progress indicator, and
nudge the helper back onto its task once it finishes — a compacted helper often
needs telling what it was doing.

## Age out the PR queue — a conflicting PR nobody owns will sit forever

A PR that goes CONFLICTING drops out of everyone's attention at once. The
integrator skips it (correctly — it is not mergeable). Santa's status sweep
counts it as "with its lane". The lane has moved on to whatever Santa assigned
next. Nobody is wrong, and nothing moves.

One fleet had a 131-line docs PR sit **nine hours untouched and 157 commits
behind trunk**, carrying the tick for the last open substep of a phase that
therefore could not close. It only surfaced because the maintainer looked at the
PR list and asked why two were old.

**Add PR age to the status sweep**, not just state:

```
gh pr list --json number,headRefName,mergeable,updatedAt
```

An **old-and-conflicting** PR is the signal. Old-and-mergeable usually just means
a deep queue; old-and-conflicting means nobody has touched it since trunk moved
past it, and the gap grows on its own.

**And when telling a lane to clear its backlog, enumerate the backlog yourself.**
A lane recalls the branches it is thinking about, not the ones it forgot — which
are exactly the ones that need clearing. Santa can see every branch; the lane can
see the one it is standing in. Then re-check afterwards rather than assuming the
instruction emptied it.

**For a small PR with large drift, do not insist on a rebase.** Reapplying a
hundred lines onto current trunk is often cheaper and less error-prone than
reconciling a hundred-plus commits of history that nothing in the change depends
on.

## Prove a diff is live before trusting an empty one

`git diff <trunk> <ref>` returning nothing reads as "these are identical" and is
acted on with total confidence. It can also mean the invocation was wrong — a ref
that silently resolved to something unexpected, a path that no longer exists, a
comparison that never ran.

One lane assessing an old PR got **empty diffs for all four files**, which would
have supported the conclusion "everything is superseded, nothing to do". The raw
byte sizes of those files differed by up to 1.4MB. It caught this by checking
sizes as a positive control, then redid every comparison by extracting blobs
directly (`git show <ref>:<path>` piped to `diff`) and found two hunks
superseded, one still needed, and two files entirely new.

**A shallower assessment would have been confidently, completely wrong** — and
would have closed a PR whose surviving work nobody would have noticed missing.

**The rule is the same one that applies to any empty search, extended to the
tools you trust most:** before recording an absence, prove the mechanism can
detect a presence. For a diff, compare something you know differs — file size,
a known-changed line, a control file. For a grep, run it against a known-present
case. The tooling being reputable is not evidence; the check is.

**Santa's angle:** an agent reporting "no differences", "nothing found", or
"already superseded" across *several* items at once is the shape to question.
One empty result is plausible; a uniform sweep of them usually means the
instrument, not the world.
