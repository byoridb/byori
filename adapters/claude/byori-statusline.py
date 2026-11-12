#!/usr/bin/env python3
"""Claude Code status line that appends plan usage for Claude and Codex.

    byori-statusline.py                  render: payload on stdin, one status line out
    byori-statusline.py install   --settings PATH --state PATH --command CMD [--refresh N]
    byori-statusline.py uninstall --settings PATH --state PATH

Claude's numbers come from the `rate_limits` object Claude Code itself passes to a
status line (Pro/Max/Ultra only). Codex has no such contract: its numbers are the
last `rate_limits` snapshot Codex wrote to its own session log, so they are as old
as the last Codex turn and may stop parsing when Codex changes that format. Either
source missing just drops that part; rendering never fails the status line.

A status line is a single slot, not a list like hooks. Install therefore keeps the
user's existing statusLine, runs it with the same payload, and prints its output
first. Uninstall puts it back, unless the user has replaced ours since.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

MARKER = "byori-statusline.py"
PREVIOUS_TIMEOUT_SECONDS = 2.0
CODEX_TAIL_BYTES = 512 * 1024
CODEX_RECENT_DAY_DIRECTORIES = 7
SEPARATOR = " │ "


# --- render ---------------------------------------------------------------


def _duration(seconds):
    if seconds < 3600:
        return f"{max(1, int(seconds // 60))}m"
    if seconds < 86400:
        hours, rest = divmod(int(seconds), 3600)
        return f"{hours}h{rest // 60}m" if rest >= 60 else f"{hours}h"
    days, rest = divmod(int(seconds), 86400)
    return f"{days}d{rest // 3600}h" if rest >= 3600 else f"{days}d"


def _window_label(minutes):
    if minutes % 1440 == 0:
        return f"{minutes // 1440}d"
    if minutes % 60 == 0:
        return f"{minutes // 60}h"
    return f"{minutes}m"


def _window(label, used, resets_at, now):
    """One `5h 24% (1h52m)` cell, or None for a window that already reset:
    its percentage describes a period that is over."""
    if not isinstance(used, (int, float)) or not isinstance(resets_at, (int, float)):
        return None
    if resets_at <= now:
        return None
    return f"{label} {round(used)}% ({_duration(resets_at - now)})"


def claude_usage(payload, now):
    limits = payload.get("rate_limits") if isinstance(payload, dict) else None
    if not isinstance(limits, dict):
        return None
    cells = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        window = limits.get(key)
        if isinstance(window, dict):
            cell = _window(label, window.get("used_percentage"), window.get("resets_at"), now)
            if cell:
                cells.append(cell)
    return "Claude " + " · ".join(cells) if cells else None


def _codex_home():
    return pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex")


def _latest_codex_log(home):
    """Newest-written rollout log. Logs live under the day a session started, so a
    long session still writing today sits in an older directory: compare mtimes
    across the last few day directories instead of taking the newest directory."""
    sessions = home / "sessions"
    days = []
    try:
        for year in sorted(sessions.iterdir(), reverse=True):
            for month in sorted(year.iterdir(), reverse=True) if year.is_dir() else ():
                for day in sorted(month.iterdir(), reverse=True) if month.is_dir() else ():
                    if day.is_dir():
                        days.append(day)
                    if len(days) >= CODEX_RECENT_DAY_DIRECTORIES:
                        break
                if len(days) >= CODEX_RECENT_DAY_DIRECTORIES:
                    break
            if len(days) >= CODEX_RECENT_DAY_DIRECTORIES:
                break
    except OSError:
        return None
    newest = None
    for day in days:
        for log in day.glob("rollout-*.jsonl"):
            try:
                mtime = log.stat().st_mtime
            except OSError:
                continue
            if newest is None or mtime > newest[0]:
                newest = (mtime, log)
    return newest[1] if newest else None


def _find_rate_limits(value):
    if isinstance(value, dict):
        limits = value.get("rate_limits")
        if isinstance(limits, dict):
            return limits
        for child in value.values():
            found = _find_rate_limits(child)
            if found:
                return found
    return None


def _last_codex_rate_limits(log):
    try:
        with log.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - CODEX_TAIL_BYTES))
            tail = handle.read()
    except OSError:
        return None
    for line in reversed(tail.splitlines()):
        if b'"rate_limits"' not in line:
            continue
        try:
            found = _find_rate_limits(json.loads(line))
        except ValueError:
            continue  # the first line of a tail can be cut mid-record
        if found:
            return found
    return None


def _credits(credits):
    if not isinstance(credits, dict) or not credits.get("has_credits") or credits.get("unlimited"):
        return None
    try:
        balance = float(credits.get("balance"))
    except (TypeError, ValueError):
        return None
    text = f"{balance:,.0f}" if balance.is_integer() else f"{balance:,.2f}"
    return f"credits {text}"


def codex_usage(now, home=None):
    log = _latest_codex_log(home or _codex_home())
    limits = _last_codex_rate_limits(log) if log else None
    if not limits:
        return None
    cells = []
    for key in ("primary", "secondary"):
        window = limits.get(key)
        if isinstance(window, dict) and isinstance(window.get("window_minutes"), int):
            cell = _window(
                _window_label(window["window_minutes"]),
                window.get("used_percent"),
                window.get("resets_at"),
                now,
            )
            if cell:
                cells.append(cell)
    credits = _credits(limits.get("credits"))
    if credits:
        cells.append(credits)
    return "Codex " + " · ".join(cells) if cells else None


def _previous_command(state_path):
    try:
        previous = json.loads(pathlib.Path(state_path).read_text(encoding="utf-8")).get("previous")
    except (OSError, ValueError, AttributeError):
        return None
    if isinstance(previous, dict) and isinstance(previous.get("command"), str):
        return previous["command"]
    return None


def _run_previous(command, payload_bytes):
    """The user's own status line, fed the same payload. Its output leads; a slow
    or failing one is dropped rather than allowed to blank the whole line."""
    try:
        result = subprocess.run(
            ["/bin/sh", "-c", command],
            input=payload_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=PREVIOUS_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.decode("utf-8", "replace").rstrip("\n")


def render(payload_bytes, state_path, now=None, codex_home=None):
    now = time.time() if now is None else now
    previous = _previous_command(state_path)
    previous_output = _run_previous(previous, payload_bytes) if previous else ""
    try:
        payload = json.loads(payload_bytes or b"{}")
    except ValueError:
        payload = {}
    segments = []
    for part in (claude_usage, lambda _payload, _now: codex_usage(_now, codex_home)):
        try:
            text = part(payload, now)
        except Exception:  # a status line must not die on an unexpected shape
            text = None
        if text:
            segments.append(text)
    ours = SEPARATOR.join(segments)
    if previous_output and ours:
        return previous_output + SEPARATOR + ours
    return previous_output or ours


# --- install / uninstall --------------------------------------------------


def _is_ours(status_line):
    return isinstance(status_line, dict) and MARKER in str(status_line.get("command", ""))


def _read_json(path, default):
    try:
        text = pathlib.Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return default
    return json.loads(text)


def _write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def install(settings_path, state_path, command, refresh):
    settings = _read_json(settings_path, {})
    if not isinstance(settings, dict):
        raise ValueError(f"{settings_path} is not a JSON object")
    current = settings.get("statusLine")
    if _is_ours(current):
        # A re-install: what the state file holds is still the user's original.
        # Re-saving now would record our own line as the thing to restore.
        updated = dict(current)
    else:
        _write_json(state_path, {"previous": current})
        updated = {"type": "command"}
        if isinstance(current, dict) and "padding" in current:
            updated["padding"] = current["padding"]
        updated["refreshInterval"] = (
            current.get("refreshInterval")
            if isinstance(current, dict) and isinstance(current.get("refreshInterval"), int)
            else refresh
        )
    updated["command"] = command
    settings["statusLine"] = updated
    _write_json(settings_path, settings)
    return "updated" if _is_ours(current) else ("wrapped" if current else "installed")


def uninstall(settings_path, state_path):
    state_file = pathlib.Path(state_path)
    try:
        settings = _read_json(settings_path, None)
    except ValueError:
        return "settings unreadable; left alone"
    result = "nothing to restore"
    if isinstance(settings, dict) and _is_ours(settings.get("statusLine")):
        try:
            previous = _read_json(state_file, {}).get("previous")
        except (ValueError, AttributeError):
            previous = None
        if previous is None:
            del settings["statusLine"]
            result = "removed"
        else:
            settings["statusLine"] = previous
            result = "restored"
        _write_json(settings_path, settings)
    elif isinstance(settings, dict) and settings.get("statusLine") is not None:
        result = "statusLine changed since install; left alone"
    try:
        state_file.unlink()
    except FileNotFoundError:
        pass
    return result


def main(argv):
    parser = argparse.ArgumentParser(prog="byori-statusline.py")
    sub = parser.add_subparsers(dest="action")
    for name in ("install", "uninstall"):
        action = sub.add_parser(name)
        action.add_argument("--settings", required=True)
        action.add_argument("--state", required=True)
        if name == "install":
            action.add_argument("--command", required=True)
            action.add_argument("--refresh", type=int, default=60)
    arguments = parser.parse_args(argv)

    if arguments.action == "install":
        print(install(arguments.settings, arguments.state, arguments.command, arguments.refresh))
        return 0
    if arguments.action == "uninstall":
        print(uninstall(arguments.settings, arguments.state))
        return 0

    state = pathlib.Path(__file__).resolve().parent.parent / "statusline.previous.json"
    try:
        line = render(sys.stdin.buffer.read(), state)
    except Exception:
        line = ""
    if line:
        sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
