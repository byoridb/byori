#!/usr/bin/env python3
"""Opt-in fresh-session smoke test for Byori handbook host delivery.

This is intentionally outside unit-test discovery. It creates only a temporary
synthetic Git repository and requires separately authenticated, explicitly
marked test profiles. It never copies credentials from a user's normal profile.
"""

import argparse
import contextlib
import json
import os
import pathlib
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "cli" / "byori.py"
PROFILE_MARKER = ".byori-handbook-smoke-profile"
PROFILE_MARKER_BODY = "Byori handbook host smoke profile v1\n"
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
SENSITIVE_AUTH_ENV = {
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    "AWS_DEFAULT_PROFILE",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_SECURITY_TOKEN",
    "AWS_PROFILE",
    "AWS_ROLE_ARN",
    "AWS_ROLE_SESSION_NAME",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AZURE_OPENAI_API_KEY",
    "CODEX_ACCESS_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "OPENAI_API_KEY",
}


class SmokeError(RuntimeError):
    """A safe preflight, host, or assertion failure."""

    def __init__(self, message, *, model_call_attempts=0, call=None):
        super().__init__(message)
        self.model_call_attempts = model_call_attempts
        self.call = call


def _run(argv, *, cwd=None, env=None, timeout=60):
    """Run one foreground process and terminate its group on timeout."""
    process = subprocess.Popen(
        [str(value) for value in argv],
        cwd=str(cwd) if cwd else None,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        raise SmokeError("process timed out: %s" % argv[0]) from exc
    if len(stdout) > MAX_OUTPUT_BYTES or len(stderr) > MAX_OUTPUT_BYTES:
        raise SmokeError("host output exceeded the 4 MiB safety bound")
    return process.returncode, stdout, stderr


def _text(data):
    return data.decode("utf-8", errors="replace")


def _version(binary):
    code, stdout, stderr = _run([binary, "--version"], timeout=15)
    if code:
        raise SmokeError("%s --version failed" % binary)
    return (_text(stdout or stderr).strip().splitlines() or ["unknown"])[0][:200]


def _git(repo, *arguments):
    code, stdout, stderr = _run(
        ["git", "-c", "core.hooksPath=/dev/null", "-C", repo, *arguments], timeout=30
    )
    if code:
        raise SmokeError("synthetic Git command failed: %s" % _text(stderr).strip()[:300])
    return _text(stdout).strip()


def _build(repo):
    code, stdout, stderr = _run(
        [sys.executable, "-B", CLI, "handbook", "build", repo, "--json"],
        cwd=repo,
        timeout=60,
    )
    if code:
        raise SmokeError("synthetic handbook build failed: %s" % _text(stderr).strip()[:500])
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise SmokeError("synthetic handbook build returned invalid JSON") from exc
    generation = result.get("generation")
    if not isinstance(generation, str) or not re.fullmatch(r"[a-f0-9]{64}", generation):
        raise SmokeError("synthetic handbook build omitted a valid generation")
    return generation


def _connect(repo, host):
    code, stdout, stderr = _run(
        [
            sys.executable,
            "-B",
            CLI,
            "handbook",
            "connect",
            host,
            repo,
            "--apply",
            "--json",
        ],
        cwd=repo,
        timeout=60,
    )
    if code:
        raise SmokeError("synthetic %s connection failed: %s" % (host, _text(stderr)[:500]))
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise SmokeError("synthetic %s connection returned invalid JSON" % host) from exc
    if result.get("status") != "configured" or result.get("verification") != "unverified":
        raise SmokeError("synthetic %s connection reported an unsafe status" % host)


def _write_wrapper(bin_dir):
    bin_dir.mkdir(mode=0o700)
    wrapper = bin_dir / "byori"
    wrapper.write_text(
        "#!/bin/sh\nexec %s -B %s \"$@\"\n"
        % (shlex.quote(sys.executable), shlex.quote(str(CLI))),
        encoding="utf-8",
    )
    wrapper.chmod(0o700)
    return wrapper


def _profile(path_value, host):
    if not path_value:
        raise SmokeError("%s requires an explicitly provisioned isolated profile" % host)
    path = pathlib.Path(path_value).expanduser()
    try:
        info = path.lstat()
    except OSError as exc:
        raise SmokeError("%s isolated profile does not exist" % host) from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SmokeError("%s isolated profile must be a real directory" % host)
    path = path.resolve(strict=True)
    real_default = pathlib.Path.home() / (".codex" if host == "codex" else ".claude")
    real_default = real_default.resolve(strict=False)
    if path == real_default or real_default in path.parents:
        raise SmokeError("refusing to use the real %s profile" % host)
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise SmokeError("%s isolated profile must not be accessible to group or other" % host)
    marker = path / PROFILE_MARKER
    try:
        marker_info = marker.lstat()
        marker_body = marker.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SmokeError("%s isolated profile lacks the required marker" % host) from exc
    if stat.S_ISLNK(marker_info.st_mode) or not stat.S_ISREG(marker_info.st_mode):
        raise SmokeError("%s isolated profile marker is unsafe" % host)
    if marker_body != PROFILE_MARKER_BODY:
        raise SmokeError("%s isolated profile marker has the wrong version" % host)
    if host == "codex":
        auth = path / "auth.json"
        try:
            auth_info = auth.lstat()
        except OSError as exc:
            raise SmokeError("Codex test profile has no dedicated auth.json") from exc
        if (
            stat.S_ISLNK(auth_info.st_mode)
            or not stat.S_ISREG(auth_info.st_mode)
            or stat.S_IMODE(auth_info.st_mode) & 0o077
        ):
            raise SmokeError("Codex test profile auth.json is unsafe or not private")
    return path


def _base_environment(bin_dir, isolated_home):
    environment = os.environ.copy()
    for name in SENSITIVE_AUTH_ENV:
        environment.pop(name, None)
    environment["PATH"] = str(bin_dir) + os.pathsep + environment.get("PATH", "")
    environment["HOME"] = str(isolated_home)
    environment["XDG_CACHE_HOME"] = str(isolated_home / ".cache")
    environment["XDG_CONFIG_HOME"] = str(isolated_home / ".config")
    environment["XDG_DATA_HOME"] = str(isolated_home / ".local" / "share")
    environment["NO_COLOR"] = "1"
    return environment


def _auth_status(host, binary, profile, environment):
    env = environment.copy()
    if host == "codex":
        env["CODEX_HOME"] = str(profile)
        argv = [binary, "login", "status"]
    else:
        env["CLAUDE_CONFIG_DIR"] = str(profile)
        # Prevent implicit fallback to a person's normal AWS credential files.
        env["AWS_CONFIG_FILE"] = str(profile / "aws" / "config")
        env["AWS_SHARED_CREDENTIALS_FILE"] = str(profile / "aws" / "credentials")
        env["AWS_EC2_METADATA_DISABLED"] = "true"
        argv = [binary, "auth", "status", "--json"]
    code, stdout, _stderr = _run(argv, env=env, timeout=20)
    if host == "codex":
        logged_in = code == 0 and "logged in" in _text(stdout).lower()
        details = {"logged_in": logged_in, "auth_method": "profile"}
    else:
        try:
            raw = json.loads(stdout)
        except json.JSONDecodeError:
            raw = {}
        details = {
            "logged_in": code == 0 and raw.get("loggedIn") is True,
            "auth_method": raw.get("authMethod"),
            "api_provider": raw.get("apiProvider"),
        }
    if not details["logged_in"]:
        raise SmokeError("%s isolated profile is not authenticated" % host)
    return env, details


def _json_events(stdout):
    events = []
    for line in _text(stdout).splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            events.append(value)
    return events


def _is_guard_command(command):
    if not isinstance(command, str):
        return False
    try:
        return shlex.split(command) == ["byori", "handbook", "sync", "."]
    except ValueError:
        return False


def _claude_bash_commands(value):
    if isinstance(value, dict):
        if value.get("type") == "tool_use" and value.get("name") == "Bash":
            tool_input = value.get("input")
            if isinstance(tool_input, dict):
                yield tool_input.get("command")
        for child in value.values():
            yield from _claude_bash_commands(child)
    elif isinstance(value, list):
        for child in value:
            yield from _claude_bash_commands(child)


def _guard_was_run(host, events):
    if host == "claude":
        return any(_is_guard_command(command) for command in _claude_bash_commands(events))
    for event in events:
        if event.get("type") not in {"item.started", "item.completed"}:
            continue
        item = event.get("item")
        if (
            isinstance(item, dict)
            and item.get("type") == "command_execution"
            and _is_guard_command(item.get("command"))
        ):
            return True
    return False


def _final_response(host, events):
    if host == "claude":
        results = [event.get("result") for event in events if event.get("type") == "result"]
        return next((value for value in reversed(results) if isinstance(value, str)), None)
    messages = []
    for event in events:
        if event.get("type") != "item.completed":
            continue
        item = event.get("item")
        if isinstance(item, dict) and item.get("type") == "agent_message":
            for key in ("text", "content"):
                if isinstance(item.get(key), str):
                    messages.append(item[key])
    return messages[-1] if messages else None


def _response_object(text):
    if not isinstance(text, str):
        raise SmokeError("host did not return a final text response")
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*|\s*```$", "", stripped, flags=re.IGNORECASE)
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise SmokeError("host final response was not one JSON object") from exc
    if not isinstance(value, dict) or set(value) != {"generation", "constraint"}:
        raise SmokeError("host final response did not have the exact required keys")
    return value


def _reported_model(host, events):
    if host == "claude":
        for event in events:
            if event.get("type") == "system" and isinstance(event.get("model"), str):
                return event["model"]
            message = event.get("message")
            if (
                event.get("type") == "assistant"
                and isinstance(message, dict)
                and isinstance(message.get("model"), str)
            ):
                return message["model"]
    for event in events:
        for key, value in event.items():
            if key in {"model", "model_name"} and isinstance(value, str):
                return value
    return None


def _reported_cost(host, events):
    if host == "claude":
        for event in reversed(events):
            value = event.get("total_cost_usd")
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return value
    return None


def _host_argv(host, binary, repo, model, prompt, max_budget_usd):
    if host == "codex":
        return [
            binary,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--sandbox",
            "read-only",
            "--ask-for-approval",
            "never",
            "--json",
            "--color",
            "never",
            "--cd",
            repo,
            "--model",
            model,
            prompt,
        ]
    return [
        binary,
        "--print",
        "--input-format",
        "text",
        "--output-format",
        "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--no-chrome",
        "--setting-sources",
        "project",
        "--strict-mcp-config",
        "--mcp-config",
        '{"mcpServers":{}}',
        "--disable-slash-commands",
        "--permission-mode",
        "manual",
        "--permission-prompts",
        "none",
        "--tools",
        "Bash",
        "--allowedTools",
        "Bash(byori handbook sync .)",
        "--max-budget-usd",
        str(max_budget_usd),
        "--model",
        model,
        prompt,
    ]


def _call_host(host, binary, repo, model, env, generation, constraint, timeout, budget):
    prompt = (
        "Return only one JSON object with keys generation and constraint, using the current "
        "project context made available automatically at session startup. If that context is "
        "unavailable, return null values. Do not inspect repository files unless project startup "
        "instructions direct you to do so."
    )
    argv = _host_argv(host, binary, repo, model, prompt, budget)
    try:
        code, stdout, stderr = _run(argv, cwd=repo, env=env, timeout=timeout)
    except SmokeError as exc:
        raise SmokeError(
            str(exc),
            model_call_attempts=1,
            call={"host": host, "requested_model": model, "outcome": "unknown"},
        ) from exc
    events = _json_events(stdout)
    reported_cost = _reported_cost(host, events)
    call_details = {
        "host": host,
        "requested_model": model,
        "reported_model": _reported_model(host, events),
        "reported_cost_usd": reported_cost,
        "cost_availability": (
            "reported" if reported_cost is not None else "not reported by CLI"
        ),
    }

    def fail(message):
        raise SmokeError(message, model_call_attempts=1, call=call_details)

    if code:
        detail = _text(stderr).strip().splitlines()
        fail("%s model call failed: %s" % (host, (detail or ["no detail"])[-1][:500]))
    if not _guard_was_run(host, events):
        fail("%s did not invoke the guarded `byori handbook sync .` command" % host)
    try:
        response = _response_object(_final_response(host, events))
    except SmokeError as exc:
        fail("%s: %s" % (host, exc))
    if response != {"generation": generation, "constraint": constraint}:
        fail("%s returned the wrong generation or synthetic constraint" % host)
    return {
        "generation": generation,
        "constraint": constraint,
        "guarded_sync_observed": True,
        **call_details,
    }


def _fixture(repo, nonce):
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    _git(repo, "config", "user.name", "Byori host smoke")
    _git(repo, "config", "user.email", "smoke@example.invalid")
    constraint = "Synthetic batch ceiling A-%s is seven." % nonce
    (repo / "README.md").write_text(
        "# Synthetic handbook delivery fixture\n\n"
        "This repository contains generated test text only.\n\n"
        "## Constraint\n\n%s\n" % constraint,
        encoding="utf-8",
    )
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "Add synthetic constraint A")
    return constraint


def _replace_constraint(repo, old, nonce):
    new = "Synthetic batch ceiling B-%s is three." % nonce
    readme = repo / "README.md"
    text = readme.read_text(encoding="utf-8")
    if old not in text:
        raise SmokeError("synthetic constraint A disappeared before update")
    readme.write_text(text.replace(old, new), encoding="utf-8")
    return new


def _preflight_summary(args):
    selected = args.hosts
    versions = {}
    for host in selected:
        binary = args.codex_binary if host == "codex" else args.claude_binary
        versions[host] = _version(binary)
    return {
        "schema_version": 1,
        "status": "preflight-only",
        "model_calls": 0,
        "hosts": selected,
        "versions": versions,
        "next": (
            "Provision private marked test profiles, authenticate them explicitly, then "
            "rerun with "
            "--run-models --confirm-isolated-auth and explicit model names."
        ),
    }


def run(args):
    if not args.run_models:
        return _preflight_summary(args)
    if not args.confirm_isolated_auth:
        raise SmokeError("--run-models requires --confirm-isolated-auth")

    profiles = {}
    models = {}
    binaries = {"codex": args.codex_binary, "claude": args.claude_binary}
    for host in args.hosts:
        profile_value = args.codex_home if host == "codex" else args.claude_config_dir
        model = args.codex_model if host == "codex" else args.claude_model
        if not model:
            raise SmokeError("%s requires an explicit model name" % host)
        profiles[host] = _profile(profile_value, host)
        models[host] = model

    with tempfile.TemporaryDirectory(prefix="byori-handbook-host-smoke-") as temporary:
        base = pathlib.Path(temporary)
        repo = base / "synthetic-project"
        bin_dir = base / "bin"
        isolated_home = base / "home"
        isolated_home.mkdir(mode=0o700)
        _write_wrapper(bin_dir)
        nonce = uuid.uuid4().hex[:12]
        constraint_a = _fixture(repo, nonce)
        generation_a = _build(repo)
        for host in args.hosts:
            _connect(repo, host)

        environments = {}
        auth = {}
        base_env = _base_environment(bin_dir, isolated_home)
        for host in args.hosts:
            environments[host], auth[host] = _auth_status(
                host, binaries[host], profiles[host], base_env
            )

        results = {
            host: {
                "version": _version(binaries[host]),
                "auth": auth[host],
                "calls": [],
            }
            for host in args.hosts
        }
        completed_attempts = 0
        for host in args.hosts:
            try:
                result = _call_host(
                    host, binaries[host], repo, models[host], environments[host],
                    generation_a, constraint_a, args.timeout, args.claude_max_budget_usd,
                )
            except SmokeError as exc:
                exc.model_call_attempts += completed_attempts
                raise
            completed_attempts += 1
            results[host]["calls"].append(result)

        try:
            constraint_b = _replace_constraint(repo, constraint_a, nonce)
            generation_b = _build(repo)
            if generation_b == generation_a:
                raise SmokeError("source edit did not produce a new handbook generation")
        except SmokeError as exc:
            exc.model_call_attempts += completed_attempts
            raise
        for host in args.hosts:
            try:
                result = _call_host(
                    host, binaries[host], repo, models[host], environments[host],
                    generation_b, constraint_b, args.timeout, args.claude_max_budget_usd,
                )
            except SmokeError as exc:
                exc.model_call_attempts += completed_attempts
                raise
            completed_attempts += 1
            results[host]["calls"].append(result)

        return {
            "schema_version": 1,
            "status": "passed",
            "model_calls": 2 * len(args.hosts),
            "synthetic_only": True,
            "fresh_sessions": True,
            "hosts": results,
            "kc02_complete": False,
        }


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--hosts",
        nargs="+",
        choices=("codex", "claude"),
        default=["codex", "claude"],
    )
    parser.add_argument(
        "--run-models",
        action="store_true",
        help="make at most two fresh model calls per selected host",
    )
    parser.add_argument(
        "--confirm-isolated-auth",
        action="store_true",
        help=(
            "confirm the supplied profiles are disposable test-only profiles with "
            "authorized credentials"
        ),
    )
    parser.add_argument("--codex-home")
    parser.add_argument("--claude-config-dir")
    parser.add_argument("--codex-model")
    parser.add_argument("--claude-model")
    parser.add_argument("--codex-binary", default="codex")
    parser.add_argument("--claude-binary", default="claude")
    parser.add_argument("--claude-max-budget-usd", type=float, default=0.25)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args(argv)
    if len(set(args.hosts)) != len(args.hosts):
        parser.error("--hosts must not contain duplicates")
    if not 30 <= args.timeout <= 300:
        parser.error("--timeout must be between 30 and 300 seconds")
    if not 0 < args.claude_max_budget_usd <= 1:
        parser.error("--claude-max-budget-usd must be greater than 0 and at most 1")
    return args


def main(argv=None):
    try:
        result = run(parse_args(argv))
    except SmokeError as exc:
        result = {
            "schema_version": 1,
            "status": "blocked",
            "reason": str(exc),
            "model_call_attempts": exc.model_call_attempts,
        }
        if exc.call is not None:
            result["last_call"] = exc.call
        print(json.dumps(result))
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
