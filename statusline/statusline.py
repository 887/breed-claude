#!/usr/bin/env python3
"""Claude Code status line: model | dir | jj change | context | burn rate | weekly quota."""
import json
import os
import subprocess
import sys
import time
from datetime import datetime

C = {
    "reset": "\033[0m",
    "dim": "\033[2m",
    "grey": "\033[38;5;245m",
    "blue": "\033[38;5;75m",
    "cyan": "\033[38;5;80m",
    "green": "\033[38;5;114m",
    "yellow": "\033[38;5;179m",
    "red": "\033[38;5;203m",
    "mag": "\033[38;5;176m",
}


def ctx_window(model_id: str) -> int:
    """Context window in tokens, from the model id.

    The `[1m]` suffix is an explicit marker, but the Claude 5 family carries a
    1M window without needing it — reporting 200k for a bare `claude-sonnet-5`
    renders a healthy session as >100% full, which reads as a wedged agent.
    """
    if "[1m]" in model_id or "1m" in model_id.split("-")[-1]:
        return 1_000_000
    if "sonnet-5" in model_id or "opus-5" in model_id:
        return 1_000_000
    return 200_000


def ctx_samples(transcript: str):
    """(epoch_seconds, context_tokens) for assistant turns in the transcript tail."""
    if not transcript or not os.path.exists(transcript):
        return []
    try:
        with open(transcript, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            chunk = min(size, 2_000_000)
            fh.seek(size - chunk)
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []

    out = []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        usage = (rec.get("message") or {}).get("usage")
        if not isinstance(usage, dict) or usage.get("input_tokens") is None:
            continue
        total = (
            usage.get("input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("output_tokens", 0)
        )
        ts = rec.get("timestamp")
        when = None
        if isinstance(ts, str):
            try:
                when = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except ValueError:
                when = None
        out.append((when, total))
    return out


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def fmt_until(epoch) -> str:
    """Coarse time-until, e.g. '3d 4h' / '4h' / '25m'."""
    if not isinstance(epoch, (int, float)):
        return ""
    secs = epoch - time.time()
    if secs <= 0:
        return "now"
    days, rem = divmod(int(secs), 86400)
    hours, rem = divmod(rem, 3600)
    mins = rem // 60
    if days:
        return f"{days}d {hours}h" if hours else f"{days}d"
    if hours:
        return f"{hours}h"
    return f"{max(mins, 1)}m"


def weekly_quota(data):
    """Consumed share of the weekly (7-day) subscription budget, plus reset ETA."""
    week = (data.get("rate_limits") or {}).get("seven_day")
    if not isinstance(week, dict):
        return None
    used = week.get("used_percentage")
    if not isinstance(used, (int, float)):
        return None
    return min(100.0, max(0.0, used)), fmt_until(week.get("resets_at"))


def jj_bits(cwd: str):
    """Current change id + nearest bookmark. Never snapshots the working copy."""

    def run(rev: str, template: str) -> str:
        try:
            out = subprocess.run(
                ["jj", "log", "-r", rev, "--no-graph", "--ignore-working-copy",
                 "--color", "never", "-T", template],
                cwd=cwd, capture_output=True, text=True, timeout=2.0,
            )
            return out.stdout.strip() if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            return ""

    change = run("@", 'change_id.shortest(8)')
    if not change:
        return None
    bookmark = run("heads(::@ & bookmarks())", 'bookmarks.join(",") ++ "\n"').splitlines()
    return change, (bookmark[0] if bookmark else "")


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}

    model = data.get("model") or {}
    model_id = model.get("id", "")
    name = model.get("display_name") or model_id or "claude"

    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    parts = [f"{C['mag']}{name}{C['reset']}", f"{C['blue']}{os.path.basename(cwd)}{C['reset']}"]

    jb = jj_bits(cwd)
    if jb:
        change, bookmark = jb
        label = f"{C['yellow']}{change}{C['reset']}"
        if bookmark:
            label += f"{C['grey']} {bookmark}{C['reset']}"
        parts.append(label)

    samples = ctx_samples(data.get("transcript_path", ""))
    if samples:
        used = samples[-1][1]
        window = ctx_window(model_id)
        pct = used / window * 100
        col = C["green"] if pct < 50 else C["yellow"] if pct < 80 else C["red"]
        parts.append(
            f"{col}ctx {fmt_tokens(used)}/{fmt_tokens(window)} ({pct:.0f}%){C['reset']}"
        )

    quota = weekly_quota(data)
    if quota:
        used_pct, resets = quota
        col = C["green"] if used_pct < 60 else C["yellow"] if used_pct < 85 else C["red"]
        seg = f"{col}wk {used_pct:.0f}% used{C['reset']}"
        if resets:
            seg += f"{C['grey']} ↻{resets}{C['reset']}"
        parts.append(seg)

    sep = f" {C['dim']}│{C['reset']} "
    print(sep.join(parts))


if __name__ == "__main__":
    main()
