#!/usr/bin/env python3
"""What Byori checks about itself, and what to run when a check fails.

Every failure this project hit in the field was diagnosable in three commands —
is the engine answering, is its launchd job loaded, does the recorded engine match
the binary — and every one of them cost someone a long detour to find out. So the
three commands ship as one.

The checks are the incidents, in order of how often they bit:

  - disk space: a full disk stopped everything, including the diagnosis
  - engine identity: a failed install left `engine.json` naming a version that was
    no longer on disk (byori#57)
  - service state: a failed update left the job unloaded and the engine down, and
    recovery was a `launchctl bootstrap` nobody would guess (byori#58)
  - endpoint and credential: `/health` can be answered by a stale process that owns
    the port, so the credential is checked too
  - memory space: a space that resolves but is empty is what "connected but unused"
    looks like
  - agent wiring: MCP registration, skills and hooks — the reason the graph went
    unused in other projects

Facts are gathered in one place and judged in pure functions, so the judgement is
testable without a machine in a particular state. Nothing here prints a secret.
"""
import dataclasses
import json
import os
import pathlib
import re
import shutil
import subprocess
from typing import Any, Dict, List, Optional

OK = "ok"
WARN = "warn"
FAIL = "fail"

# Engines before 0.4.0 ignore their arguments, so `--version` would start a server
# against the live data directory. The recorded tag decides whether asking is safe.
VERSION_PROBE_MINIMUM = (0, 4, 0)
# Not anchored: the same expression reads a tag ("v0.4.2") and the binary's own
# answer ("byoridb-server 0.4.2 (commit …)"). Anchoring it to the start meant the
# binary was never parsed, so the version-disagreement check could not fire.
SEMVER = re.compile(r"\bv?(\d+)\.(\d+)\.(\d+)")

DISK_WARN_BYTES = 5 * 1024 ** 3
DISK_FAIL_BYTES = 1 * 1024 ** 3


@dataclasses.dataclass
class Check:
    name: str
    status: str
    detail: str
    fix: Optional[str] = None


def _run(argv, timeout=15):
    try:
        result = subprocess.run(
            list(argv), check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, errors="replace", timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def parse_version(text):
    match = SEMVER.search(text.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


# ---- judgements (pure) -------------------------------------------------------

def check_disk(free_bytes, path):
    gigabytes = (free_bytes or 0) / 1024 ** 3
    if free_bytes is None:
        return Check("disk", WARN, "could not read free space for %s" % path)
    if free_bytes < DISK_FAIL_BYTES:
        return Check(
            "disk", FAIL,
            "%.1f GB free on %s — the engine writes here, and a full disk loses "
            "writes and stops diagnosis" % (gigabytes, path),
            "free space, then check the engine log for redb errors",
        )
    if free_bytes < DISK_WARN_BYTES:
        return Check("disk", WARN, "%.1f GB free on %s" % (gigabytes, path))
    return Check("disk", OK, "%.0f GB free on %s" % (gigabytes, path))


def check_engine_identity(manifest, binary_exists, binary_sha, reported_version, probe_skipped_reason):
    """Does the engine on disk match what was recorded for it?"""
    if not binary_exists:
        return Check(
            "engine binary", FAIL, "no engine binary is installed",
            "byori install, or the app's ByoriDB page",
        )
    if not manifest:
        return Check(
            "engine identity", WARN,
            "no engine.json, so the installed build is only identifiable by asking "
            "the binary",
        )
    recorded_tag = manifest.get("tag") or "unrecorded"
    recorded_sha = (manifest.get("sha256") or "")[:12]
    actual_sha = (binary_sha or "")[:12]
    if recorded_sha and actual_sha and recorded_sha != actual_sha:
        return Check(
            "engine identity", FAIL,
            "engine.json records %s (%s) but the binary on disk is %s%s — a rolled "
            "back install leaves the manifest lying (byori#57)"
            % (recorded_tag, recorded_sha, actual_sha,
               "" if not reported_version else ", which reports %s" % reported_version),
            "reinstall so the record and the binary agree",
        )
    if reported_version and recorded_tag != "unrecorded":
        recorded = parse_version(recorded_tag)
        reported = parse_version(reported_version)
        if recorded and reported and recorded != reported:
            return Check(
                "engine identity", FAIL,
                "engine.json records %s but the binary reports %s"
                % (recorded_tag, reported_version),
                "reinstall so the record and the binary agree",
            )
    detail = "%s (%s)" % (recorded_tag, actual_sha or "sha unknown")
    if reported_version:
        detail += ", binary agrees"
    elif probe_skipped_reason:
        detail += ", not asked: %s" % probe_skipped_reason
    return Check("engine identity", OK, detail)


def check_service(loaded, label, target, service_kind):
    if loaded:
        return Check("service", OK, "%s is loaded" % label)
    if service_kind == "launchd":
        return Check(
            "service", FAIL,
            "%s is not loaded, so nothing restarts the engine" % label,
            "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/%s.plist" % label,
        )
    return Check(
        "service", FAIL, "%s is not enabled" % label,
        "systemctl --user enable --now %s.service" % label,
    )


def check_endpoint(healthy, endpoint, port_owner):
    if healthy:
        return Check("endpoint", OK, "%s answers /health" % endpoint)
    detail = "%s does not answer /health" % endpoint
    if port_owner:
        detail += " and %s owns the port" % port_owner
    return Check(
        "endpoint", FAIL, detail,
        "start the service (see above), then: tail -20 %s"
        % "~/.byoridb/logs/server.log",
    )


def check_credential(status, endpoint):
    if status == "ok":
        return Check("credential", OK, "the configured credential authenticates")
    if status == "unreachable":
        return Check("credential", WARN, "not checked: %s is not answering" % endpoint)
    if status == "locked":
        return Check(
            "credential", FAIL,
            "the engine refused the configured credential; concurrent logins can "
            "lock the account for about a minute (byoridb#90)",
            "wait a minute and re-run; if it persists, reinstall to rewrite the env",
        )
    return Check(
        "credential", FAIL,
        "the engine refused the configured credential — /health alone can be "
        "answered by another process that owns the port",
        "check that ~/.byoridb/env belongs to the running engine's data directory",
    )


def check_memory_space(space, node_count, reachable):
    if not reachable:
        return Check("memory space", WARN, "not checked: the engine is not answering")
    if node_count is None:
        return Check("memory space", WARN, "%s: could not count memories" % space)
    if node_count == 0:
        return Check(
            "memory space", WARN,
            "%s holds no memories — for a project with history that usually means "
            "the knowledge is in another store" % space,
            "byori init  (build the graph from this repository's history)",
        )
    return Check("memory space", OK, "%s holds %d memories" % (space, node_count))


def check_agent_wiring(mcp_registered, skills, hooks_present):
    missing = []
    if not mcp_registered:
        missing.append("MCP server not registered")
    absent_skills = [name for name, present in sorted(skills.items()) if not present]
    if absent_skills:
        missing.append("skills missing: %s" % ", ".join(absent_skills))
    if not hooks_present:
        missing.append("checkpoint hooks absent")
    if not missing:
        return Check("agent wiring", OK, "MCP registered, skills installed, hooks present")
    return Check(
        "agent wiring", WARN,
        "; ".join(missing) + " — an agent that is not told about the graph writes "
        "somewhere else instead",
        "reinstall to wire it up (hooks are installed by default)",
    )


def check_prerequisites(found):
    required = [name for name in ("git", "python3") if not found.get(name)]
    optional = [name for name in ("tmux", "jq") if not found.get(name)]
    if required:
        return Check(
            "prerequisites", FAIL, "missing: %s" % ", ".join(required),
            "install %s" % " and ".join(required),
        )
    if optional:
        return Check(
            "prerequisites", WARN,
            "missing: %s (tmux keeps sessions alive across app restarts; jq installs "
            "the hooks)" % ", ".join(optional),
            "brew install %s" % " ".join(optional),
        )
    return Check("prerequisites", OK, "git, python3, tmux, jq")


# ---- gathering (I/O) ---------------------------------------------------------

def gather(byoridb_home, byori_home, space, http, service_label, service_kind,
           env_values, project_root=None):
    facts: Dict[str, Any] = {}
    binary = byoridb_home / "bin" / "byoridb-server"
    facts["binary_exists"] = binary.is_file()
    facts["binary_sha"] = _sha256(binary) if facts["binary_exists"] else ""

    manifest = {}
    manifest_path = byoridb_home / "engine.json"
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            manifest = {}
    facts["manifest"] = manifest

    # Asking the binary is gated on the recorded tag: an older engine ignores
    # arguments and would start a server against the live data directory.
    facts["reported_version"] = None
    facts["probe_skipped_reason"] = None
    recorded = parse_version(manifest.get("tag") or "")
    if not facts["binary_exists"]:
        facts["probe_skipped_reason"] = "no binary"
    elif recorded is None:
        facts["probe_skipped_reason"] = "no recorded version to gate the probe"
    elif recorded < VERSION_PROBE_MINIMUM:
        facts["probe_skipped_reason"] = (
            "engines before 0.4.0 ignore --version and would start a server")
    else:
        code, output = _run([str(binary), "--version"], timeout=20)
        if code == 0:
            facts["reported_version"] = output.strip().splitlines()[0] if output.strip() else None

    usage = None
    try:
        usage = shutil.disk_usage(str(byoridb_home if byoridb_home.exists() else pathlib.Path.home()))
    except OSError:
        usage = None
    facts["free_bytes"] = usage.free if usage else None
    facts["disk_path"] = str(byoridb_home)

    if service_kind == "launchd":
        target = "gui/%d/%s" % (os.getuid(), service_label)
        code, _ = _run(["/bin/launchctl", "print", target])
        facts["service_loaded"] = code == 0
    else:
        target = "%s.service" % service_label
        code, output = _run(["systemctl", "--user", "is-active", target])
        facts["service_loaded"] = code == 0 and "active" in output
    facts["service_target"] = target

    facts["healthy"] = _http_status(http + "/health") == 200
    facts["port_owner"] = None
    if not facts["healthy"]:
        facts["port_owner"] = _port_owner(http)

    facts["credential"] = "unreachable"
    facts["node_count"] = None
    if facts["healthy"]:
        facts["credential"], facts["node_count"] = _authenticated_probe(http, env_values, space)

    facts["mcp_registered"] = _mcp_registered()
    facts["skills"] = {
        name: (pathlib.Path.home() / ".claude" / "skills" / name / "SKILL.md").is_file()
        for name in ("byoridb-memory", "byori-design")
    }
    facts["hooks_present"] = _hooks_present()
    facts["prerequisites"] = {
        name: shutil.which(name) is not None for name in ("git", "python3", "tmux", "jq")
    }
    facts["space"] = space
    facts["project_root"] = str(project_root) if project_root else None
    return facts


def _sha256(path):
    import hashlib

    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def _http_status(url, timeout=3):
    import urllib.error
    import urllib.request

    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except Exception:  # noqa: BLE001 - unreachable is an answer, not a crash
        return None


def _port_owner(http):
    match = re.search(r":(\d+)$", http.rstrip("/"))
    if not match or not shutil.which("lsof"):
        return None
    code, output = _run(["lsof", "-nP", "-iTCP:%s" % match.group(1), "-sTCP:LISTEN"])
    if code != 0:
        return None
    for line in output.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2:
            return "%s (pid %s)" % (parts[0], parts[1])
    return None


def _authenticated_probe(http, env_values, space):
    """Log in and count the space's memories. The secret is never printed."""
    import urllib.error
    import urllib.request

    password = env_values.get("BYORIDB_ROOT_PASSWORD") or env_values.get("BYORIDB_PASSWORD")
    if not password:
        return "no-credential", None
    user = env_values.get("BYORIDB_USER", "root")
    try:
        request = urllib.request.Request(
            http + "/api/v1/session",
            data=json.dumps({"username": user, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            session = json.loads(response.read().decode() or "{}").get("session_id")
    except urllib.error.HTTPError as error:
        return ("locked" if error.code in (401, 403) else "refused"), None
    except Exception:  # noqa: BLE001
        return "unreachable", None
    if not session:
        return "refused", None

    def query(statement):
        try:
            request = urllib.request.Request(
                http + "/api/v1/query",
                data=json.dumps({"session_id": session, "query": statement}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode() or "{}")
        except Exception:  # noqa: BLE001
            return None

    count = None
    if query("USE %s" % space) is not None:
        body = query("MATCH (n) RETURN count(n) AS total")
        rows = (body or {}).get("results") or []
        if rows:
            try:
                count = int(rows[0].get("total", 0))
            except (TypeError, ValueError):
                count = None
        else:
            count = 0
    return "ok", count


def _mcp_registered():
    if shutil.which("claude"):
        code, output = _run(["claude", "mcp", "list"], timeout=30)
        if code == 0:
            return "byoridb" in output
    configuration = pathlib.Path.home() / ".claude.json"
    if configuration.is_file():
        try:
            return "byoridb" in configuration.read_text(encoding="utf-8")
        except OSError:
            return False
    return False


def _hooks_present():
    settings = pathlib.Path.home() / ".claude" / "settings.json"
    if not settings.is_file():
        return False
    try:
        document = json.loads(settings.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    for entries in (document.get("hooks") or {}).values():
        for entry in entries if isinstance(entries, list) else []:
            for hook in entry.get("hooks", []) if isinstance(entry, dict) else []:
                if "byoridb" in str(hook.get("command", "")):
                    return True
    return False


def judge(facts) -> List[Check]:
    """Every check, in the order the failures matter."""
    return [
        check_disk(facts["free_bytes"], facts["disk_path"]),
        check_engine_identity(
            facts["manifest"], facts["binary_exists"], facts["binary_sha"],
            facts["reported_version"], facts["probe_skipped_reason"],
        ),
        check_service(
            facts["service_loaded"], facts.get("service_label", "com.byoridb.local"),
            facts["service_target"], facts.get("service_kind", "launchd"),
        ),
        check_endpoint(facts["healthy"], facts["http"], facts["port_owner"]),
        check_credential(facts["credential"], facts["http"]),
        check_memory_space(facts["space"], facts["node_count"], facts["healthy"]),
        check_agent_wiring(facts["mcp_registered"], facts["skills"], facts["hooks_present"]),
        check_prerequisites(facts["prerequisites"]),
    ]


def worst(checks):
    if any(check.status == FAIL for check in checks):
        return FAIL
    if any(check.status == WARN for check in checks):
        return WARN
    return OK
