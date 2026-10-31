# Reviewed legacy-memory capture

This is the KC-01 storage-source adapter, not completion of the KC-04 database backup/migration
gate. It preserves observed original memory bodies in the existing append-only record journal.
The engine remains intact and authoritative for data not captured here. Never relabel a bounded
query/export or two equal reads as a transactional backup, and never delete absent graph records.

## User flow and API

`byori handbook memory [path] [--record TYPE=NAME ...] [--json]` previews local installed ByoriDB
memory. `--apply --expected-digest <review_digest>` repeats the observation and applies only the
reviewed result. No automatic capture on project selection, build, read, sync or connection.

Python entry point in `cli/handbook_memory.py`:

```python
capture_memory(root, *, selection=None, apply=False, expected_digest=None, client_factory=None)
```

Selection is `None` for a bounded all-type observation, or a nonempty list of dictionaries with
exactly `type` and `name`. Names remain exact; legacy notes need not use typed canonical prefixes.
Typed names still require their type prefix. At most 200 selected/observed records, 2,000 links
and 1 MiB normalized compiler input. Over-limit or incomplete responses fail, never truncate into
an apparently complete capture. A selected missing/duplicate identity fails.

The optional test `client_factory(canonical_root)` returns a context manager yielding an object
with `space`, `endpoint`, and `query(ngql) -> {results, row_count}`. It is a read-only boundary;
production uses bounded local HTTP session/query/logout, never the writer/bootstrap MCP path.
Public results contain `schema_version`, `state` (`preview`/`imported`), `project_root`,
`review_digest`, `base_revision`, `record_count`, `new_records`, `changed_records`,
`unchanged_records`, `retained_records`, `withheld_records`, and safe normalized `records` for
review. Apply additionally returns `revision` and `changed`. No credential or raw transport error
is returned. Capture does not build/publish a handbook or change host/service configuration.

## Observation and consent

Resolve the canonical checkout and its registry/derived memory space, ignoring ambient global
memory-space overrides. Use only an explicitly configured loopback HTTP endpoint in this first
adapter; reject remote/userinfo/query/redirect/proxy credential forwarding. Load only the existing
private regular runtime env file, never execute it or a source-provided command. One login,
read-only USE/schema read/queries, one bounded logout. No auth retries, migrations or repair.

Read typed nodes in deterministic VID order and their bounded incident links. Repeat the complete
selected observation once; differing nodes/links fail with retry guidance. Even equal observations
are explicitly **best-effort observations**, not MVCC or complete-history snapshots. Preserve
stored VID strings, exact bodies, legacy kind/lifecycle/resolved fields, recorded timestamp and
raw normalized links. Do not reinterpret DB insertion time as source event time.

Review digest binds canonical project/checkout, engine namespace/endpoint, selection, observed
content/links (including withheld-content digests) and existing journal revision. Apply requires
that digest and optimistic journal revision; stale consent or a concurrent journal change cannot
write. Validate the fully merged snapshot before any filesystem write. Preview is read-only.

Secret-like observations are withheld from preview and import, counted without printing content.
Existing records never disappear because of an omission, selection change, empty graph, filter,
failure or secret detection. An explicit later retraction is a separate operation; capture is not
authoritative synchronization of the whole graph.

## Preservation and compiler meaning

Merge by exact original `(type, name, vid)`. Only records previously owned by this adapter in the
same engine namespace may be updated automatically after review. Refuse collisions with
caller-accepted records, changed namespace or ambiguous canonical identities. Preserve all other
records byte-for-byte in meaning. Unchanged reviewed captures are no-ops.

Capture preserves raw lifecycle in metadata while its verification state stays `unverified`.
Legacy graph nodes carry no trustworthy checkout applicability: default newly captured records
to checkout scope, with that limitation visible in provenance. Translate only explicit supported
relations with unambiguous observed endpoints into `metadata.handbook`; preserve other/dangling
relationships as raw metadata, not invented causal claims or current policy. Legacy opaque note
names are valid original identities but are not eligible targets of typed handbook declarations.

The existing journal retains immutable prior snapshots and activates one revision. Never consume
generated handbook/cache content as a source, overwrite graph records, delete old snapshots,
change credentials, update/restart the engine, or mutate a user's instruction files.

## Verification

Use isolated fake HTTP engines and temporary Git repositories: no live writes/service changes.
Test preview filesystem invariance; authenticated read-only requests and logout; body/VID/timestamp/
kind/state/edge preservation; secret withholding; opaque legacy names; namespace/checkouts;
missing/duplicate/overflow/malformed/partial/error responses; observation and journal races;
stale review; no deletion of unseen records; no overwriting manual records; no-op capture; and
capture -> compiler -> change capture -> stale old generation -> rebuild. A main-agent read-only
observation may verify the installed engine path without importing into the real project.

Full original-graph backup/restore, physical storage consistency, historical versions, actual host
consumption and a public release remain separate unfinished gates.
