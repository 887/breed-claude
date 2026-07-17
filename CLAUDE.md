# breed-claude — agent guide

This repo is a user-level Claude Code **skills collection** at
`~/.claude/skills/breed-claude/`, with its own git remote
(`git@github.com:887/breed-claude.git`). It ships **three sibling skills** plus a
companion service:

1. **`breed-claude`** (repo root `SKILL.md`) — recipes for **BREED** (spawn a fresh
   Claude in a tmux session with a personality preloaded) and **HEEL** (recover a spawn
   whose remote-control bridge has gone idle), plus RESUME / PACK-* pack operations.
2. **`breed-codex/SKILL.md`** — the Codex counterpart: spawn and drive headless `codex`
   agents in tmux (BREED-CODEX / SEND / GOAL / REINIT / DONE-FILE / KILL-RESTART).
3. **`santaing/SKILL.md`** — the multi-agent orchestration *policy*: run a dynamic fleet
   of tmux agents as "Santa + little helpers", Santa owning checkout/pushes/gate,
   helpers only implementing + running the cheap check. Composes 1 and 2. Fully
   repo-/VCS-/build-tool-agnostic — no project name is hardwired.
4. A companion systemd user service in `cc-heel-on-resume/` — runs `heel` automatically
   on every wake-from-suspend.

Each skill dir has its own `SKILL.md` (the source of truth for that skill's recipes)
and `README.md` (user-facing intro). This file (`CLAUDE.md`) covers **operating on the
repo itself** — installing the auto-heel service, editing the scripts, the gotchas you
can't infer from reading the code.

**Each skill is symlinked into `~/.claude/skills/` independently** — the repo root as
`breed-claude`, and `breed-codex/` + `santaing/` as their own entries — so Claude Code
discovers all three as separate invocable skills. When adding a new skill dir here,
symlink it in and it becomes invocable.

## Layout

```
breed-claude/
├── SKILL.md                              # BREED + HEEL + RESUME + PACK-* (breed-claude skill)
├── README.md                             # collection intro + breed-claude
├── CLAUDE.md                             # this file
├── breed-codex/                          # the Codex-agent skill
│   ├── SKILL.md
│   └── README.md
├── santaing/                             # the fleet-orchestration skill
│   ├── SKILL.md
│   └── README.md
└── cc-heel-on-resume/                    # companion systemd user service
    ├── cc-heel-on-resume.service         # systemd unit (Type=simple, Restart=always)
    ├── cc-heel-watcher                   # gdbus listener for PrepareForSleep
    ├── cc-heel-all                       # the heel-everyone script
    └── install.sh                        # symlink-and-enable installer
```

## Setting up auto-heel-on-resume on a fresh machine

If the user mentions wanting their spawns to auto-reconnect on resume — or
asks for "the heel-on-resume thing", "auto-heel", "the systemd service",
etc. — the install path is one command:

```bash
~/.claude/skills/breed-claude/cc-heel-on-resume/install.sh
```

The script:

1. Symlinks the unit file into `~/.config/systemd/user/cc-heel-on-resume.service`.
2. Symlinks `cc-heel-watcher` and `cc-heel-all` into `~/.local/bin/`.
3. Runs `systemctl --user daemon-reload`.
4. Runs `systemctl --user enable --now cc-heel-on-resume.service`.

Idempotent: safe to re-run. Existing symlinks are replaced; pre-existing
regular files at the target paths are backed up to `<path>.bak.<timestamp>`
before being replaced.

### Verifying it landed

```bash
systemctl --user is-active cc-heel-on-resume.service     # → active
systemctl --user is-enabled cc-heel-on-resume.service    # → enabled
journalctl -t cc-heel-watcher --since '1 hour ago' --no-pager
```

The journal should show `watcher up; tracking
org.freedesktop.login1.Manager.PrepareForSleep` after the install. Ask the
user to suspend + wake the machine once; the journal then gains a
`pre-sleep signal, nothing to do` line (at suspend) and a `resume detected,
invoking heel` line (at wake).

## Gotchas

- **`gdbus monitor`, not `dbus-monitor`.** The original watcher used
  `dbus-monitor`, which calls
  `org.freedesktop.DBus.Monitoring.BecomeMonitor` — privileged, AccessDenied
  for unprivileged users, falls back to deprecated `AddMatch eavesdrop=true`.
  The current watcher uses `gdbus monitor`, which subscribes via a normal
  client `AddMatch`. PrepareForSleep is a broadcast signal so no special
  privilege is needed. **Don't regress this**; if you're rewriting for a
  different distro, keep gdbus.

- **Network settle is mandatory.** `cc-heel-all` sleeps
  `$CC_HEEL_SETTLE_SECONDS` (default 8) at the top, before doing anything,
  because resume + DHCP/wifi reassociation can easily take 5+ seconds. Tune
  via env var if your network comes up faster/slower; don't drop the sleep
  entirely — Claude has nowhere to dial until the link is back.

- **Heel-detection rule.** A `claude` pid is "broken bridge" iff it holds
  zero `ESTABLISHED` outbound TCP sockets. Healthy pids hold at least one
  (the remote-control websocket and/or in-flight model requests). Any pane
  whose claude pid has a live socket is left untouched — heel is
  non-destructive.

- **Heel keys.** `cc-heel-all` fires `Esc → Ctrl-U → /remote-control →
  Enter` into the pane. `SKILL.md`'s manual heel recipe uses `Esc → cc →
  /remote-control → Enter` (vim-style line-clear instead of readline-style).
  Both work; if you change one, consider whether to align the other.

- **Logs land under a tag, not the unit.** Both helper scripts use
  `logger -t <name>`, so events go to the system journal under those tags.
  Use `journalctl -t cc-heel-watcher` and `journalctl -t cc-heel-all`, not
  `journalctl --user -u cc-heel-on-resume.service` (the latter only shows
  systemd-level start/stop, not the watcher's own resume-detected events).

- **Symlinks point at this repo; `git pull` is enough to update.** All
  three system paths (the unit file plus the two helper scripts) are
  symlinks into `cc-heel-on-resume/`. After a `git pull` here, run
  `systemctl --user restart cc-heel-on-resume.service` to pick up new
  watcher content. No re-install needed unless file *names* change.

- **Hardening.** The unit runs with `ProtectSystem=strict
  ProtectHome=read-only`, `PrivateTmp=true`, `NoNewPrivileges=true`, plus
  `ReadWritePaths=%t %h/.local/bin`. If a future change makes the scripts
  touch a new path, update `ReadWritePaths` in the unit file or the
  service won't be able to write there.

## Hard rule for Claude

**Don't copy scripts into system paths — symlink them.** The repo is the
source of truth. Copies break the propagation invariant: every install on
every machine should point back at a checkout of this repo so `git pull`
suffices to update behavior. `install.sh` already does the right thing;
don't reinvent it inline.

**Don't edit the symlinked files via their system paths.** If you find
yourself about to edit
`~/.config/systemd/user/cc-heel-on-resume.service` — stop. Edit
`cc-heel-on-resume/cc-heel-on-resume.service` in this repo instead. The
symlink will reflect the change immediately; commit it here so future
installs on other machines pick it up.

**`SKILL.md` is the contract for BREED + HEEL behavior.** When changing
how a spawned Claude is launched or recovered, the SKILL.md recipe stays
the source of truth — `cc-heel-all`'s implementation is the *automated*
form of the manual HEEL recipe and should track it. If you diverge them,
document the divergence here.
