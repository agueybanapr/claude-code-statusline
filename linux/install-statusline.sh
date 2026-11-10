#!/usr/bin/env bash
# Installs the custom Claude Code status line into ~/.claude.
# Backs up any existing settings.json and keeps all your other settings.
set -euo pipefail

command -v python3 >/dev/null || { echo "python3 not found. Install it and run this again." >&2; exit 1; }
mkdir -p "$HOME/.claude"

# Check settings first so a bad file leaves everything untouched.
python3 -I - <<'PY'  # -I: never import modules from the current folder
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(path):
    try:
        with open(path) as f:
            if not isinstance(json.load(f), dict):
                raise ValueError("top level is not an object")
    except ValueError as e:
        sys.exit(f"{path} is not valid JSON ({e}). Nothing was changed.")
PY

cat > "$HOME/.claude/statusline.py" <<'STATUSLINE_PY'
#!/usr/bin/env python3
"""Claude Code status line (standard library only).

Example output:
Opus 5.5 | ███░░░░░░░ 42% ⧗ 12 min | 73%↑ 1:48 | libs/Dress-Code | 🌿 rule-fixes | 📁 scratch
"""
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

# Settings you may want to change
BAR_WIDTH = 12
MAX_BRANCH = 40               # longer branch names are shortened with …
MIN_CACHE_TOKENS = 10_000      # hide the countdown when less than this is cached
DEFAULT_CACHE_TTL = 300        # used if the transcript does not reveal the TTL
AHEAD_MARGIN = 3               # percentage points before showing the ↑
SCRATCH_DIRS = ("scratch", ".scratch")  # relative to the project root
TAIL_BYTES = 512 * 1024        # how much of the transcript to scan

LIMITS_FILE = Path.home() / ".claude" / "statusline-limits.json"

WINDOWS = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}

RESET, DIM = "\033[0m", "\033[2m"
GREEN, YELLOW, RED = "\033[32m", "\033[33m", "\033[31m"

# (filled, unfilled) 24-bit colors for the context bar
BAR_GREEN = ("\033[38;2;110;224;138m", "\033[38;2;64;140;86m")
BAR_YELLOW = ("\033[38;2;240;205;100m", "\033[38;2;150;126;60m")
BAR_RED = ("\033[38;2;240;105;95m", "\033[38;2;150;66;60m")


CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def paint(text, color):
    return f"{color}{text}{RESET}"


def clean(text, limit=None):
    """Drop control characters (terminal escapes) and shorten long text with …"""
    text = CONTROL_CHARS.sub("", str(text))
    return text if limit is None or len(text) <= limit else text[: limit - 1] + "…"


def level(pct):
    return GREEN if pct < 50 else YELLOW if pct < 80 else RED


def link(text, path):
    url = "file://" + quote(str(path))
    return f"\033]8;;{url}\a{text}\033]8;;\a"


def to_epoch(value):
    """Accept epoch seconds, epoch milliseconds, or an ISO 8601 string."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value / 1000 if value > 1e12 else float(value)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def context_segment(data):
    ctx = data.get("context_window") or {}
    pct = ctx.get("used_percentage")
    if pct is None:
        remaining = ctx.get("remaining_percentage")
        pct = None if remaining is None else 100 - remaining
    pct = float(pct or 0)
    filled = min(BAR_WIDTH, max(1 if pct > 0 else 0, round(pct / 100 * BAR_WIDTH)))
    full, empty = BAR_GREEN if pct < 50 else BAR_YELLOW if pct < 80 else BAR_RED
    bar = paint("█" * filled, full) + paint("╱" * (BAR_WIDTH - filled), empty)
    return f"{bar} {pct:.0f}%"


def read_turns(path):
    """Yield main-thread assistant turns from the end of the transcript."""
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        handle.seek(max(0, size - TAIL_BYTES))
        lines = handle.read().splitlines()
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue  # the first line of the tail may be partial
        usage = (entry.get("message") or {}).get("usage")
        if entry.get("type") == "assistant" and usage and not entry.get("isSidechain"):
            yield entry, usage


def cache_ttl(turns):
    for _, usage in turns:
        created = usage.get("cache_creation") or {}
        if created.get("ephemeral_1h_input_tokens"):
            return 3600
        if created.get("ephemeral_5m_input_tokens"):
            return 300
    return DEFAULT_CACHE_TTL


def cache_segment(data, now):
    path = data.get("transcript_path")
    if not path or not os.path.isfile(path):
        return ""
    turns = list(read_turns(path))
    if not turns:
        return ""
    entry, usage = turns[0]
    cached = (usage.get("cache_read_input_tokens") or 0) + (
        usage.get("cache_creation_input_tokens") or 0
    )
    started = to_epoch(entry.get("timestamp"))
    if cached < MIN_CACHE_TOKENS or started is None:
        return ""
    ttl = cache_ttl(turns)
    left = started + ttl - now
    if left <= 0:
        return paint("⧗ cold", RED)
    color = RED if left < ttl * 0.1 else YELLOW
    label = "<1 min" if left < 60 else f"{int(left // 60)} min"
    return paint(f"⧗ {label}", color)


def format_reset(seconds):
    seconds = max(0, int(seconds))
    hours, remainder = divmod(seconds, 3600)
    if hours >= 24:
        return f"{hours // 24}d {hours % 24}h"
    return f"{hours}:{remainder // 60:02d}"


def current_limits(data, now):
    """Use live limits and save them; before the first reply, use the saved ones."""
    live = data.get("rate_limits")
    if live:
        try:
            temp = LIMITS_FILE.with_name(f"{LIMITS_FILE.name}.{os.getpid()}")
            temp.write_text(json.dumps(live))
            os.replace(temp, LIMITS_FILE)
        except OSError:
            pass
        return live
    try:
        saved = json.loads(LIMITS_FILE.read_text())
    except (OSError, ValueError):
        return {}
    return {
        name: window
        for name, window in saved.items()
        if (to_epoch((window or {}).get("resets_at")) or 0) > now
    }


def plan_segment(data, now):
    limits = current_limits(data, now)
    best = None
    for name, length in WINDOWS.items():
        window = limits.get(name) or {}
        used = window.get("used_percentage")
        if used is not None and (best is None or used > best[0]):
            best = (float(used), to_epoch(window.get("resets_at")), length)
    if best is None:
        return ""
    used, resets_at, length = best
    text = f"{used:.0f}%"
    reset = ""
    if resets_at is not None:
        left = max(0, resets_at - now)
        elapsed = max(0, min(100, (1 - left / length) * 100))
        if used > elapsed + AHEAD_MARGIN:
            text += "↑"
        reset = " " + format_reset(left)
    return paint(text, level(used)) + reset


def project_root(data):
    workspace = data.get("workspace") or {}
    return Path(
        workspace.get("project_dir")
        or workspace.get("current_dir")
        or data.get("cwd")
        or os.getcwd()
    )


def project_segment(root):
    return link(clean("/".join(root.parts[-2:])), root)


def read_branch(git_dir):
    """Return the branch in git_dir/HEAD, or a short commit id if detached."""
    try:
        head = (git_dir / "HEAD").read_text().strip()
    except OSError:
        return ""
    name = head[len("ref: refs/heads/"):] if head.startswith("ref: refs/heads/") else head[:7]
    return clean(name, MAX_BRANCH)


def git_name(data, root):
    """The worktree name in a linked worktree, otherwise the current branch."""
    worktree = data.get("worktree") or {}
    workspace = data.get("workspace") or {}
    name = worktree.get("name") or workspace.get("git_worktree")
    if name:
        return clean(name, MAX_BRANCH)
    for folder in (root, *root.parents):
        marker = folder / ".git"
        if marker.is_dir():
            return read_branch(marker)
        if marker.is_file():
            try:
                target = marker.read_text().strip().split("gitdir:", 1)[-1].strip()
            except OSError:
                return ""
            if "/worktrees/" in target:
                return clean(Path(target).name, MAX_BRANCH)
            return read_branch(folder / target)  # a submodule
    return ""


def scratch_candidates(data, root):
    """Claude's session scratchpad first, then folders in the project."""
    session = data.get("session_id")
    if session and hasattr(os, "getuid"):
        workspace = data.get("workspace") or {}
        starts = {str(root), workspace.get("current_dir"), data.get("cwd")}
        for base in {"/tmp", tempfile.gettempdir()}:
            for start in filter(None, starts):
                project = re.sub(r"[^a-zA-Z0-9]", "-", start)
                yield Path(base, f"claude-{os.getuid()}", project, session, "scratchpad")
    for name in SCRATCH_DIRS:
        yield root / name


def scratch_segment(data, root):
    for folder in scratch_candidates(data, root):
        try:
            if folder.is_dir() and any(folder.iterdir()):
                return link("📁 scratch", folder)
        except OSError:
            pass
    return ""


def main():
    data = json.load(sys.stdin)
    now = time.time()
    root = project_root(data)

    context = context_segment(data)
    cache = cache_segment(data, now)
    git = git_name(data, root)
    segments = [
        (data.get("model") or {}).get("display_name", "Claude"),
        f"{context} {cache}".rstrip(),
        plan_segment(data, now),
        project_segment(root),
        f"🌿 {git}" if git else "",
        scratch_segment(data, root),
    ]
    print(" | ".join(segment for segment in segments if segment))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # keep the bar alive and show what went wrong
        print(f"statusline error: {error}")
STATUSLINE_PY
chmod +x "$HOME/.claude/statusline.py"

python3 -I - <<'PY'  # -I: never import modules from the current folder
import json, os, shutil, stat, time
path = os.path.realpath(os.path.expanduser("~/.claude/settings.json"))
settings = {}
mode = 0o600  # a new settings file is private; an existing one keeps its permissions
if os.path.exists(path):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    with open(path) as f:
        settings = json.load(f)
    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print("Backed up settings to", backup)
    if settings.get("statusLine"):
        print("Replacing your existing statusLine setting (it is in the backup).")
settings["statusLine"] = {
    "type": "command",
    "command": "python3 ~/.claude/statusline.py",
    "refreshInterval": 30,
}
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
os.fchmod(fd, mode)  # also covers a leftover .tmp file from an earlier run
with os.fdopen(fd, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY

echo
echo "Sample of a full session, using made-up data, in your own terminal:"
echo
python3 -I - <<'PY'  # -I: never import modules from the current folder
import json, os, subprocess, tempfile, time
from datetime import datetime, timezone
now = time.time()
with tempfile.TemporaryDirectory() as tmp:
    project = os.path.join(tmp, "libs", "Dress-Code")
    os.makedirs(os.path.join(project, "scratch"))
    open(os.path.join(project, "scratch", "notes.txt"), "w").close()
    transcript = os.path.join(tmp, "t.jsonl")
    stamp = datetime.fromtimestamp(now - 47.5 * 60, timezone.utc).isoformat()
    usage = {"cache_read_input_tokens": 90000, "cache_creation_input_tokens": 4000,
             "cache_creation": {"ephemeral_1h_input_tokens": 4000}}
    with open(transcript, "w") as f:
        f.write(json.dumps({"type": "assistant", "timestamp": stamp, "message": {"usage": usage}}) + "\n")
    sample = {"model": {"display_name": "Opus 5.5"}, "workspace": {"project_dir": project},
              "worktree": {"name": "rule-fixes"}, "transcript_path": transcript,
              "context_window": {"used_percentage": 42},
              "rate_limits": {"five_hour": {"used_percentage": 73, "resets_at": int(now + 6510)}}}
    script = os.path.expanduser("~/.claude/statusline.py")
    # A throwaway HOME keeps the made-up limits out of your saved ones.
    subprocess.run(["python3", script], input=json.dumps(sample).encode(), check=True, env={**os.environ, "HOME": tmp})
PY
echo
echo "Done. Use /restart in Claude Code to load it."
