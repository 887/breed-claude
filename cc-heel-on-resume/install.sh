#!/usr/bin/env bash
# install.sh — symlink cc-heel-on-resume into ~/.config/systemd/user/ and
# ~/.local/bin/, daemon-reload, enable + start the service.
#
# Idempotent: safe to re-run. Existing symlinks are replaced; pre-existing
# regular files at the target paths are also replaced (a backup is made
# alongside with a `.bak.<timestamp>` suffix). The repo stays the source of
# truth — every install on every machine points back into a checkout of
# breed-claude/cc-heel-on-resume/.
#
# Usage:
#   cd ~/.claude/skills/breed-claude   (or wherever you cloned)
#   ./cc-heel-on-resume/install.sh
#
# Or invoke the absolute path; the script derives its own source directory
# regardless of the working directory.

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LOCAL_BIN_DIR="$HOME/.local/bin"

UNIT_NAME="cc-heel-on-resume.service"
WATCHER_NAME="cc-heel-watcher"
HEEL_NAME="cc-heel-all"

UNIT_SRC="$SRC_DIR/$UNIT_NAME"
WATCHER_SRC="$SRC_DIR/$WATCHER_NAME"
HEEL_SRC="$SRC_DIR/$HEEL_NAME"

UNIT_DST="$SYSTEMD_USER_DIR/$UNIT_NAME"
WATCHER_DST="$LOCAL_BIN_DIR/$WATCHER_NAME"
HEEL_DST="$LOCAL_BIN_DIR/$HEEL_NAME"

# --- preflight -----------------------------------------------------------

for f in "$UNIT_SRC" "$WATCHER_SRC" "$HEEL_SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "missing source file: $f" >&2
    exit 1
  fi
done

if ! command -v systemctl >/dev/null; then
  echo "systemctl not found — this script requires systemd" >&2
  exit 1
fi

if ! command -v gdbus >/dev/null; then
  echo "warn: gdbus not found on PATH — the watcher needs it at runtime" >&2
  echo "      install the 'glib2' (or distro equivalent) package" >&2
fi

# --- ensure exec bits on the scripts in the repo -------------------------

chmod +x "$WATCHER_SRC" "$HEEL_SRC"

# --- mkdirs --------------------------------------------------------------

mkdir -p "$SYSTEMD_USER_DIR" "$LOCAL_BIN_DIR"

# --- symlink with backup of any pre-existing regular file ---------------

link_in() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    ln -sfn "$src" "$dst"
    echo "  relinked: $dst -> $src"
  elif [[ -e "$dst" ]]; then
    local backup="$dst.bak.$(date +%s)"
    mv "$dst" "$backup"
    ln -s "$src" "$dst"
    echo "  backed up existing $dst -> $backup; symlinked: $dst -> $src"
  else
    ln -s "$src" "$dst"
    echo "  symlinked: $dst -> $src"
  fi
}

echo "Installing symlinks..."
link_in "$UNIT_SRC" "$UNIT_DST"
link_in "$WATCHER_SRC" "$WATCHER_DST"
link_in "$HEEL_SRC" "$HEEL_DST"

# --- daemon-reload + enable --now ----------------------------------------

echo "Reloading user systemd manager configuration..."
systemctl --user daemon-reload

echo "Enabling and starting $UNIT_NAME..."
systemctl --user enable --now "$UNIT_NAME"

# --- report --------------------------------------------------------------

state="$(systemctl --user is-active "$UNIT_NAME" || true)"
enabled="$(systemctl --user is-enabled "$UNIT_NAME" || true)"

echo
echo "Done. State: active=$state enabled=$enabled"
echo
echo "Verify with:"
echo "  systemctl --user status $UNIT_NAME"
echo "  journalctl -t cc-heel-watcher --since '1 hour ago' --no-pager"
echo
echo "Suspend + wake the machine once to confirm the resume signal is caught."
echo "You should see a 'pre-sleep signal' line at suspend and a 'resume detected,"
echo "invoking heel' line at wake in the journal."
