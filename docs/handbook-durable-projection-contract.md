# Cross-invocation projection reuse

This implements the accepted KC-03 requirement without turning a generated handbook into an
authoritative source. It extends the source, projection and publication contracts. No daemon,
model, credential reuse, user host-profile changes or live engine operation is involved.

## Boundary and threat model

Every invocation freshly collects/validates selected originals and explicit checkpoint declarations.
Each per-source cache key hashes the complete semantic projection input. Changed and removed inputs,
plus changed typed edges, invalidate the reverse closure over old and new dependency graphs. Final
budget selection, rendering, generation identity and publication/source-race checks always rerun.

Disk projections are reusable only when their envelope authenticates as compiler-produced state
for the exact canonical root, checkout and compiler/projection implementation identity. Store a
random 32-byte integrity key and one bounded authenticated cache in a private directory under the
checkout's Git metadata directory, never in a tracked working-tree file or a host memory store.
HMAC-SHA256 binds scope and the whole entry (input hashes, typed edges, units). A self-reported SHA
or a valid JSON shape alone is insufficient. Inputs are matched against fresh originals, never
against the cache's own copy of originals. No pickle or source execution.

The key is an internal local-cache integrity key, not an API/authentication credential. It is not
printed, exported to a child environment, or included in a handbook/evidence artifact. This detects
ordinary corruption and working-tree/repository artifact tampering; it does **not** defend against
a malicious process with the same user's access to both the private key and compiler installation.
Selecting an executable-compromised local environment is outside this trust boundary. The graph,
cache and handbook remain disposable derived views, not signed proof that a source claim is true.

## Storage and lifetime

Use `.byori-projection-cache-v1` within the canonical per-checkout Git directory. Require its
directory mode 0700 and file modes 0600, current-user ownership, regular single-link files, no
symlink/special-file traversal and descriptor/path identity agreement. No permission repairs or
stale-lock deletion. Bound the encoded cache to 8 MiB, one entry per checkout. Version/scope/code
identity mismatch, missing/unsafe key, malformed cache, bad HMAC or lock contention is a cache miss,
not a handbook failure. Do not create a new key over existing unverifiable cache data.

Only a successful explicit publication may persist newly compiler-produced projections. Preview,
status, show, evidence and failed/cancelled builds may read an existing valid cache, but must not
create or write one. Serialize cooperative cache writers with a nonblocking private flock; stage,
fsync and atomically replace the cache. Cache-write failure must not undo or misreport an already
successful handbook publication. No cache failure bypasses normal source validation/publication.

`--clean` on preview/build bypasses both process-local and durable projection reuse, including
publication revalidation, and does not seed/replace either cache. It remains a genuine independent
comparison path. Cache warmth must not change handbook bytes, detailed evidence or generation ID.
A corrupt cache can be ignored and replaced only by fresh compiler output on a successful normal
build, within the validated private storage boundary.

## Integration and observations

Keep diagnostics outside deterministic artifacts. Count actual per-source projector invocations,
reused units and invalidated/removed sources; identify whether reuse came from this process or a
verified previous process. Do not label a full recompile as incremental. Public JSON may expose
these as optional build diagnostics, without changing required existing fields or native decoders.
CLI `projection_stats` sums actual projector/reuse operations over named `passes`; counts are not
unique sources across the complete command. Direct `compile_handbook(..., projection_stats={})`
describes one pass. Use `clean_projection=True` on both direct compile and direct publish, or use
the coordinator/CLI `--clean` that propagates it throughout publication. Only a successful normal
publication may set `cache_saved` true. Cache warmth is not an evidence field or generation input.

Installer and DMG staging must carry the new stdlib-only module alongside the compiler. CLI, native
manager and MCP retain the same coordinator/publication path. Do not require users to manage keys,
ports, graph spaces or a new service to use this optimization.

## Required evidence

- Separate fresh processes: first build cold; next build reuses actual projections; source edit
  only reprojects its reverse affected closure; clean/incremental artifacts are exactly equal.
- Delete/exclude/retract a source, change typed edges or lifecycle/conditions, switch branch, and
  use linked checkouts; no stale facts or cross-scope reuse. Cycles terminate.
- Modify payload plus its unkeyed digest, copy another scope/version's cache, damage/truncate key
  or cache, unsafe paths/modes/hardlinks/FIFOs, concurrent writers and interruption: fail to a
  genuine cold computation or skip persistence; no untrusted claim reaches a handbook.
- No cache writes by preview/read-only commands, failures/cancellation or clean builds. Preserve
  existing originals, selected-policy consent and single-generation activation under races.
- Real fixture and bounded repository observations report actual counts/timing and limitations;
  this optimization alone does not prove host consumption, useful semantic compression or pilot value.
