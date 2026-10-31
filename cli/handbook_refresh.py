"""Consent-gated project refresh shared by CLI, manager and MCP.

No daemon, model or engine calls. Existing compiler publication is the only
activation path. Locks prove contention; old status files never prove activity.
"""

import contextlib
import json
import os
import pathlib
import re
import stat
import time
import unicodedata
import uuid

import handbook


SCHEMA_VERSION = 1
MAX_CONFIG_BYTES = 256 * 1024
DEFAULT_LIMITS = {"max_commits": 100, "max_files": 60, "max_file_bytes": 65536,
                  "max_total_bytes": 1048576, "exclude_paths": []}
LIMIT_CEILINGS = {"max_commits": 1000, "max_files": 200, "max_file_bytes": 524288,
                  "max_total_bytes": 2097152}
_UNSET = object()


class RefreshError(handbook.HandbookError):
    """A configuration or reconciliation failure without unsafe fallback."""


class RefreshConflict(RefreshError):
    """A reviewed configuration changed before the requested mutation."""


def _scope(root):
    snapshot = handbook.collect_sources(pathlib.Path(root), max_commits=0, max_files=0)
    return {"project_root": snapshot["project_root"], "checkout_id": snapshot["checkout_id"]}


def normalize_limits(values):
    if not isinstance(values, dict) or set(values) - set(DEFAULT_LIMITS):
        raise RefreshError("unsupported refresh source limits")
    result = {**DEFAULT_LIMITS, **values}
    for key, ceiling in LIMIT_CEILINGS.items():
        value = result[key]
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= ceiling:
            raise RefreshError("%s must be between 0 and %d" % (key, ceiling))
    excludes = result["exclude_paths"]
    if not isinstance(excludes, (list, tuple)) or len(excludes) > 64:
        raise RefreshError("exclude_paths must be a bounded list of project-relative paths")
    for value in excludes:
        if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 1024:
            raise RefreshError("invalid excluded path")
        if handbook._sensitive(value):
            raise RefreshError("excluded path contains a sensitive value; it cannot be copied into configuration")
        plain = value[:-1] if value.endswith("/") else value
        if (value.startswith("/") or not plain or any(part in {"", ".", ".."} for part in plain.split("/"))
                or any(char in value for char in "\\*?[]") or any(unicodedata.category(char) == "Cc" for char in value)):
            raise RefreshError("excluded paths must be exact relative files or directory prefixes")
    result["exclude_paths"] = sorted(set(excludes))
    return result


def _configuration(scope, enabled=False, debounce_ms=300, source_limits=None, max_chars=12000):
    if not isinstance(enabled, bool):
        raise RefreshError("enabled must be a boolean")
    if isinstance(debounce_ms, bool) or not isinstance(debounce_ms, int) or not 0 <= debounce_ms <= 2000:
        raise RefreshError("debounce_ms must be between 0 and 2000")
    if isinstance(max_chars, bool) or not isinstance(max_chars, int) or not 2048 <= max_chars <= 64000:
        raise RefreshError("max_chars must be between 2048 and 64000")
    return {"schema_version": SCHEMA_VERSION, **scope, "enabled": enabled,
            "debounce_ms": debounce_ms, "source_limits": normalize_limits({} if source_limits is None else source_limits),
            "max_chars": max_chars}


def _read_config(scope):
    try:
        with handbook._storage(pathlib.Path(scope["project_root"])) as fd:
            raw = handbook._read(fd, "refresh.json", MAX_CONFIG_BYTES)
    except FileNotFoundError:
        raw = None
    if raw is None:
        return {**_configuration(scope), "change_id": None, "revision": None}
    try:
        data = json.loads(raw)
        fields = set(_configuration(scope)) | {"revision", "change_id"}
        if not isinstance(data, dict) or set(data) != fields or data["schema_version"] != SCHEMA_VERSION:
            raise ValueError("unsupported refresh configuration")
        if any(data[key] != value for key, value in scope.items()):
            raise ValueError("refresh configuration belongs to another checkout")
        normalized = _configuration(scope, data["enabled"], data["debounce_ms"], data["source_limits"], data["max_chars"])
        if not isinstance(data["change_id"], str) or not re.fullmatch(r"[a-f0-9]{32}", data["change_id"]):
            raise ValueError("invalid refresh mutation identity")
        normalized["change_id"] = data["change_id"]
        if data != {**normalized, "revision": handbook._digest(handbook._json(normalized))}:
            raise ValueError("refresh configuration was modified")
        return data
    except (ValueError, TypeError, KeyError) as exc:
        raise RefreshError("refresh configuration is invalid or belongs to another checkout; review it explicitly") from exc


def read_config(root):
    """Read a scoped setting, returning disabled defaults without creating files."""
    try:
        return _read_config(_scope(root))
    except (OSError, handbook.SourceError) as exc:
        raise RefreshError("refresh configuration cannot be verified") from exc


@contextlib.contextmanager
def _lock(fd, name, wait_timeout, cancelled=None):
    handle = handbook._open_lock(fd, name)
    try:
        if not stat.S_ISREG(os.fstat(handle).st_mode):
            raise RefreshError("refresh lock is not a regular file")
        handbook._acquire_lock(handle, wait_timeout, cancelled)
        yield
    finally:
        os.close(handle)


def configure_refresh(root, enabled, *, expected_revision=_UNSET, source_limits=None,
                      max_chars=None, debounce_ms=None, wait_timeout=2.0):
    """Explicit setting change; preserves unspecified bounds and uses optional CAS."""
    scope = _scope(root)
    root = pathlib.Path(scope["project_root"])
    if expected_revision is not _UNSET and expected_revision is not None and (
            not isinstance(expected_revision, str) or not re.fullmatch(r"[a-f0-9]{64}", expected_revision)):
        raise RefreshError("expected_revision must be a configuration hash or None")
    # Validate requested values before the first filesystem mutation.
    initial = _read_config(scope)
    requested = _configuration(scope, enabled,
        initial["debounce_ms"] if debounce_ms is None else debounce_ms,
        initial["source_limits"] if source_limits is None else source_limits,
        initial["max_chars"] if max_chars is None else max_chars)
    # Validate serialized expansion (e.g. quotes in excluded paths), not merely
    # per-path lengths. Never install a policy our own bounded reader rejects.
    candidate = {**requested, "change_id": "0" * 32, "revision": "0" * 64}
    if len((handbook._json(candidate) + "\n").encode("utf-8")) > MAX_CONFIG_BYTES:
        raise RefreshError("refresh configuration exceeds the safe serialized size limit")
    handbook.protect_outputs(root, lock_timeout=wait_timeout)
    with handbook._storage(root, True) as fd:
        with _lock(fd, "refresh-policy.lock", wait_timeout):
            current = _read_config(scope)
            if expected_revision is not _UNSET and current["revision"] != expected_revision:
                raise RefreshConflict("refresh settings changed; inspect them before retrying")
            if current["revision"] != initial["revision"]:
                raise RefreshConflict("refresh settings changed while preparing the update")
            if current["revision"] is not None and all(current[key] == value for key, value in requested.items()):
                return current
            # A content hash alone permits enable→disable→enable to resurrect
            # a cancelled job. Every actual mutation gets a distinct identity.
            requested["change_id"] = uuid.uuid4().hex
            result = {**requested, "revision": handbook._digest(handbook._json(requested))}
            handbook._atomic(fd, "refresh.json", handbook._json(result) + "\n")
            return result


def output_policy_matches(root, policy):
    """Used by all guarded reads, even when automatic refresh is turned off."""
    config = read_config(root)
    if config["revision"] is None:
        return True
    return (normalize_limits(policy["source_limits"]) == config["source_limits"]
            and policy["max_chars"] == config["max_chars"])


def compile_project_handbook(root, *, publish=False, max_commits=None, max_files=None,
                             max_chars=None, wait_timeout=2.0, cancelled=None,
                             clean_projection=False, projection_stats=None):
    """Preview/manual build also honor exclusions; they cannot widen saved policy.

    A preview never acquires a write lock or creates storage. A manual publication
    shares the policy→compiler lock order so settings cannot change mid-activation.
    """
    handbook._check_cancel(cancelled)
    config = read_config(root)
    root = pathlib.Path(config["project_root"])
    limits = dict(config["source_limits"])
    characters = config["max_chars"]
    for key, value in (("max_commits", max_commits), ("max_files", max_files), ("max_chars", max_chars)):
        if value is None:
            continue
        selected = characters if key == "max_chars" else limits[key]
        if config["revision"] is not None and value != selected:
            raise RefreshError("explicit %s conflicts with selected project policy; review refresh settings first" % key)
        if key == "max_chars":
            characters = value
        else:
            limits[key] = value
    if not isinstance(clean_projection, bool) or (projection_stats is not None and not isinstance(projection_stats, dict)):
        raise RefreshError("invalid projection diagnostics request")
    statistics = {}
    built = handbook.compile_handbook(root, max_chars=characters, **limits,
                                     clean_projection=clean_projection, projection_stats=statistics)
    if projection_stats is not None:
        projection_stats.clear()
    handbook._projection_observation(projection_stats, "initial_compile", statistics)
    handbook._check_cancel(cancelled)
    if read_config(root)["revision"] != config["revision"]:
        raise RefreshConflict("selected project policy changed during compilation")
    if not publish:
        return built
    handbook.protect_outputs(root, lock_timeout=wait_timeout, cancelled=cancelled)
    with handbook._storage(root, True) as fd:
        with _lock(fd, "refresh-policy.lock", wait_timeout, cancelled):
            if read_config(root)["revision"] != config["revision"]:
                raise RefreshConflict("selected project policy changed before publication")
            return handbook.publish_handbook(built, lock_timeout=wait_timeout, cancelled=cancelled,
                                            clean_projection=clean_projection, projection_stats=projection_stats)


def _failed(reason, refresh="failed"):
    return {"state": "unavailable", "reason": reason, "generation": None,
            "handbook": None, "refresh": refresh}


def _quiet(milliseconds, cancelled):
    deadline = time.monotonic() + milliseconds / 1000
    while time.monotonic() < deadline:
        handbook._check_cancel(cancelled)
        time.sleep(min(0.025, max(0, deadline - time.monotonic())))
    handbook._check_cancel(cancelled)


def refresh_handbook(root, *, automatic=True, wait_timeout=2.0, cancelled=None, attempts=2):
    """Return a verified body; reconcile selected sources only with explicit consent.

    automatic=False is an explicit one-shot user refresh, not permission to enable
    future runs. Source races are bounded; the last complete generation survives.
    """
    if not isinstance(automatic, bool) or isinstance(attempts, bool) or not isinstance(attempts, int) or not 1 <= attempts <= 3:
        raise RefreshError("invalid refresh mode or retry bound")
    started = time.monotonic()
    try:
        handbook._check_cancel(cancelled)
        config = read_config(root)
        root = pathlib.Path(config["project_root"])
        previous = handbook.read_handbook(root)
        handbook._check_cancel(cancelled)
        if automatic and not config["enabled"]:
            return {**previous, "refresh": "disabled"}
        if previous["state"] == "current":
            return {**previous, "refresh": "unchanged", "changed": False}
        if previous["state"] == "unavailable":
            return {**previous, "refresh": "failed"}
        handbook.protect_outputs(root, lock_timeout=wait_timeout, cancelled=cancelled)
        with handbook._storage(root, True) as fd:
            with _lock(fd, "refresh-job.lock", wait_timeout, cancelled):
                # Recheck after waiting: another job may already have done the work.
                current = handbook.read_handbook(root)
                handbook._check_cancel(cancelled)
                if current["state"] == "current":
                    return {**current, "refresh": "unchanged", "changed": False}
                if current["state"] == "unavailable":
                    return {**current, "refresh": "failed"}
                for attempt in range(attempts):
                    handbook._check_cancel(cancelled)
                    built = handbook.compile_handbook(root, max_chars=config["max_chars"], **config["source_limits"])
                    _quiet(config["debounce_ms"], cancelled)
                    settled = handbook.compile_handbook(root, max_chars=config["max_chars"], **config["source_limits"])
                    if settled["generation"] != built["generation"]:
                        if attempt + 1 < attempts:
                            continue
                        return _failed("sources did not settle within the refresh bound")
                    with _lock(fd, "refresh-policy.lock", wait_timeout, cancelled):
                        latest = _read_config({key: config[key] for key in ("project_root", "checkout_id")})
                        if latest["revision"] != config["revision"] or (automatic and not latest["enabled"]):
                            return _failed("refresh settings changed before publication", "cancelled")
                        try:
                            published = handbook.publish_handbook(built, lock_timeout=wait_timeout, cancelled=cancelled)
                        except handbook.HandbookError as exc:
                            if "sources changed" in str(exc) and attempt + 1 < attempts:
                                continue
                            raise
                    result = handbook.read_handbook(root)
                    handbook._check_cancel(cancelled)
                    if result["state"] != "current" or result["generation"] != published["generation"]:
                        return _failed("published generation changed before final verification")
                    return {**result, "refresh": "rebuilt" if published["changed"] else "unchanged",
                            "changed": published["changed"], "elapsed_ms": round((time.monotonic() - started) * 1000)}
        return _failed("refresh did not produce a verified generation")
    except handbook.HandbookCancelled as exc:
        return _failed(str(exc), "cancelled")
    except handbook.HandbookBusy as exc:
        return _failed(str(exc), "busy")
    except (handbook.HandbookError, handbook.SourceError, OSError, ValueError) as exc:
        return _failed(str(exc) if isinstance(exc, handbook.HandbookError) else "refresh could not verify its sources or storage")
