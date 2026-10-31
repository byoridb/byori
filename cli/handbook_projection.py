"""Bounded memo of projections created from fresh originals.

An optional authenticated store can hydrate a fresh process. Persistence is an
explicit post-publication step, never an effect of a read-only projection pass.
Caller-visible dictionaries are copies; generated artifacts are not memo inputs.
"""

import copy
import hashlib
import json
import threading
from collections import OrderedDict, deque


MAX_SCOPES = 8
MAX_BYTES = 8 * 1024 * 1024
PROJECTION_VERSION = "2"


def _encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


class ProjectionMemo:
    def __init__(self, max_scopes=MAX_SCOPES, max_bytes=MAX_BYTES):
        self._scopes = OrderedDict()
        self._lock = threading.RLock()
        self._max_scopes = max_scopes
        self._max_bytes = max_bytes

    def clear(self):
        with self._lock:
            self._scopes.clear()

    def project(self, scope, inputs, relationships, projector, *, clean=False, cache=None):
        """Project changed units/reverse dependencies and copy safe unchanged units.

        `inputs` are complete per-source projection inputs freshly assembled by
        the compiler, not persisted evidence. `projector` is compiler-owned code.
        A failed pass never replaces the previous complete memo entry.
        """
        with self._lock:
            keys = {key: hashlib.sha256(_encoded(value)).hexdigest() for key, value in inputs.items()}
            prior = None if clean else self._scopes.get(scope)
            durable = False
            if prior is None and not clean and cache is not None and self._max_scopes > 0 and self._max_bytes > 0:
                try:
                    restored = cache.load()
                except (OSError, ValueError, TypeError, RuntimeError, RecursionError):
                    restored = None
                if restored is not None and len(_encoded(restored)) <= self._max_bytes:
                    prior = {**restored, "edges": [tuple(edge) for edge in restored["edges"]]}
                    durable = True
            old_keys = prior["keys"] if prior else {}
            changed = {key for key in set(keys) | set(old_keys) if keys.get(key) != old_keys.get(key)}
            edges = sorted({(item["source"], item["relation"], item["target"]) for item in relationships})
            old_edges = prior["edges"] if prior else []
            # Removing an edge must invalidate its owner too, even if the target
            # is no longer in the new graph. Both graph snapshots matter.
            for source, _relation, _target in set(edges) ^ set(old_edges):
                changed.add(source)
            reverse = {}
            for source, _relation, target in set(edges) | set(old_edges):
                reverse.setdefault(target, set()).add(source)
            affected = set(changed)
            pending = deque(sorted(changed))
            while pending:
                for dependent in sorted(reverse.get(pending.popleft(), ())):
                    if dependent not in affected:
                        affected.add(dependent)
                        pending.append(dependent)
            units = {}
            projected = reused = 0
            for key in sorted(inputs):
                if prior and key not in affected and key in prior["units"]:
                    units[key] = prior["units"][key]
                    reused += 1
                else:
                    # Neither caller input nor output shares mutable state with
                    # the trusted cache after this invocation.
                    units[key] = copy.deepcopy(projector(copy.deepcopy(inputs[key])))
                    projected += 1
            entry = {"keys": keys, "edges": edges, "units": units}
            size = len(_encoded(entry))
            if not clean and size <= self._max_bytes and self._max_scopes > 0:
                self._scopes.pop(scope, None)
                self._scopes[scope] = {**entry, "bytes": size}
                while (len(self._scopes) > self._max_scopes
                       or sum(item["bytes"] for item in self._scopes.values()) > self._max_bytes):
                    self._scopes.popitem(last=False)
            elif not clean:
                self._scopes.pop(scope, None)
            return copy.deepcopy(units), {
                "mode": "clean" if clean else "durable" if durable else "process-local",
                "projected_sources": projected, "reused_sources": reused,
                "removed_sources": len(set(old_keys) - set(keys)),
                "affected_sources": len(set(inputs) & affected),
            }

    def persist(self, scope, cache):
        """Persist only compiler-produced state after its publication succeeds."""
        with self._lock:
            entry = self._scopes.get(scope)
            if entry is None:
                return False
            return cache.save(copy.deepcopy({key: entry[key] for key in ("keys", "edges", "units")}))


MEMO = ProjectionMemo()
