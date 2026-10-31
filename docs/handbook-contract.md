# Project handbook contract v1

Implementation contract for KC-01/KC-02. Product direction remains in [PRODUCT.md](../PRODUCT.md);
milestone completion is tracked in the [development plan](knowledge-compiler-plan.md). This
contract describes a first implementation, not proof of all launch gates.

## Ownership and public entry points

- `cli/handbook_sources.py`: local source adapter; `collect_sources(root, **limits)` reads only.
- `cli/handbook.py`: deterministic compilation, immutable generations and verified reads.
- `cli/handbook_knowledge.py`: bounded, explicit source-declared modules, conditions and relations.
- `cli/handbook_projection.py`: bounded projection memo and reverse-dependency invalidation.
- `cli/handbook_projection_cache.py`: optional authenticated, per-checkout Git-metadata cache;
  successful publication alone may persist it. No daemon. See the [projection contract](handbook-projection-contract.md)
  and [durable reuse boundary](handbook-durable-projection-contract.md).
- `cli/handbook_records.py`: explicit original-record snapshot journal, separate from generated
  evidence. This is not an automatic graph export, complete engine backup, or destructive migration.
- `cli/handbook_delivery.py`: explicitly managed project-scoped host references, not user-level
  configuration or independently maintained knowledge copies.
- `cli/handbook_refresh.py`: scoped consent, source bounds/exclusions and the shared bounded
  refresh coordinator. See the separate [refresh contract](handbook-refresh-contract.md).
- `cli/byori.py`: CLI integration; app/MCP integration must reuse these functions, not duplicate
  compilation or publication logic.

Development commands (run the checkout's CLI until a release includes them):

```sh
python3 cli/byori.py handbook preview /path/to/project --json
python3 cli/byori.py handbook build /path/to/project --json
python3 cli/byori.py handbook build /path/to/project --clean --json
python3 cli/byori.py handbook status /path/to/project --json
python3 cli/byori.py handbook show /path/to/project --json
python3 cli/byori.py doctor /path/to/project --handbook-only --json
python3 cli/byori.py handbook refresh-config /path/to/project --json
python3 cli/byori.py handbook refresh-config /path/to/project --enable --json
python3 cli/byori.py handbook sync /path/to/project --json
python3 cli/byori.py handbook refresh /path/to/project --json
python3 cli/byori.py handbook evidence /path/to/project --generation <id> --source <source-id> --json
python3 cli/byori.py handbook connect claude /path/to/project --json
python3 cli/byori.py handbook connect claude /path/to/project --apply --json
python3 cli/byori.py handbook disconnect claude /path/to/project --json
```

`codex` is the other supported connection selector. Connect without `--apply` is a non-mutating
preview. `init --handbook [path]` opts into compilation instead of legacy graph writes; use
`--dry-run --json --limit 100` for a bounded preview. Existing plain `init` behavior stays intact
during migration. These commands do not request a model, stop/start an engine, or silently connect
a host. Connection configured does not mean fresh-session consumption has been verified.

The matching MCP distribution exposes `memory_handbook(expected_generation?, source_id?)` as a read-only
launch-checkout view of the same guarded CLI. It does not log into the engine, accept arbitrary
caller roots, publish, or silently fall back to an old generation. `BYORI_PROJECT_DIR`, then
`CLAUDE_PROJECT_DIR`, then the MCP launch working directory selects its checkout. Pin the expected
generation when carrying a reference across tool calls. A source lookup requires that generation
and returns only the matching original and its claims. The CLI can list source locators without
source bodies; the MCP explicitly withholds evidence exceeding its 512,000-byte context boundary
rather than cutting a condition or silently serving partial evidence. Existing graph tools remain
available; MCP registration alone does not prove startup consumption.
`memory_handbook_refresh()` is a separate potentially mutating entry point, absent in readonly
mode. It honors existing project consent and never enables refresh or expands collection scope.
Both CLI and MCP withhold unverified bodies; neither performs model calls or engine logins.

## Inputs

### Read-only diagnosis

`doctor PATH --handbook-only` checks the selected checkout's source access, guarded snapshot,
coverage, saved refresh bounds and scoped Claude/Codex connection ownership. It never reads
runtime credentials or normal host profiles, authenticates to the engine, repairs a file,
publishes a build, enables refresh, or calls a model. `--space` cannot be combined with this mode.
The legacy default `doctor` remains a runtime diagnostic with its existing probes.

Missing/stale snapshots and unverified host consumption are warnings; unverifiable storage,
source access or managed blocks fail with review guidance. Intentional automatic-refresh-off is
not an error. Configured connections do not prove startup consumption. Diagnostics show counts
and fixed descriptions, not source bodies, raw warnings, credentials or exclusion-path values.
This is not yet unified runtime ownership, installer recovery or real-host delivery verification.

### Selected originals

The collector returns canonical project root, checkout identity, HEAD, snapshot digest, selected
sources, source policy, exclusions and warnings. Source IDs use kind plus locator; content digests
identify revisions. Paths are repository-relative, commit locators use `git:<sha>`.

Original selected document content and commit messages are evidence, never executable instructions.
Default bounds: 100 commits, 60 selected documents, 64 KiB per document, 1 MiB aggregate source text.
Source selection is tracked root README/PRODUCT and Markdown under docs. Secret-like paths,
generated `.byori` content, host instruction files, ignored private content and escaping symlinks
are not inputs. Truncation/exclusion is visible; more collected nodes does not imply more knowledge.

Compilation defaults to a verified local original-record journal when one already exists; it
never discovers or exports graph records automatically. Each publication revalidation reloads it.
An explicit `accepted_records` list can instead supply a caller-owned original snapshot, up to 200
records/1 MiB of UTF-8 JSON. This is not a transactional ByoriDB backup or migration. A record has a
canonical name and original body, with optional scope/provenance metadata. Legacy note names such
as `pref:korean-responses` and decimal-string VIDs are preserved, not renamed to fit typed names.
Explicit `None` disables the input; `[]` means the caller explicitly supplied an empty source.
Once an active generation used supplied records, publication with missing records is refused.
Preserve authoritative originals outside generation cleanup before adding automatic graph capture.

## Derived records

Compiler 1.2.0 emits **attributed excerpts**, not inferred decisions. Whole Markdown heading sections
are quoted with original source IDs and content digests. Even a source document's declared
“accepted” status does not establish current applicability. Every excerpt is `unverified` as
current policy and `verbatim_source_excerpt` as its narrow support type. Every excerpt has a
`derived_from` dependency. Optional `metadata.handbook` declarations add typed source-to-source
relations, not invented causal edges. Oversized sections are omitted whole and
counted; the full selected original remains in evidence unless withheld as sensitive.
Recognized source-declared lifecycle labels accompany each excerpt from that source. Proposed,
superseded and similar labels are explicitly not active rules; an accepted label is not promoted
to verified truth. This is qualification, not cross-document conflict resolution.

Selection gives overview, declared modules, qualified decisions, pitfalls, documentation and
history a turn before filling remaining space. Explicit conflict/supersession components are
presented together or withheld together, including when a counterpart has no usable excerpt.
Input-declaration counts do not imply all those declarations fit in the handbook. Evidence retains
`source_declarations`, `knowledge_coverage` and `projection_omissions` for inspection. Conditions
are repeated verbatim with each excerpt from their declaring record. Markdown example fences
are matched by marker and length; code examples do not provide lifecycle labels.

This conservative v1 does not yet resolve cross-document conflicts, discover complete module
relationships, or validate semantic entailment. Those are required follow-through work, not
capabilities implied by the word “compiler.” Secret-pattern detection withholds whole sources
from both outputs, but is a defense-in-depth filter, not a guarantee of comprehensive detection.

## Generation and publication

```text
<checkout>/.byori/
  compiler.lock
  refresh.json                 ← explicit checkout consent and source policy, absent by default
  refresh-job.lock              ← bounded cooperative refresh serialization
  refresh-policy.lock           ← consent revision/publication ordering
  handbook.md                  ← one active artifact / activation boundary
  generations/<generation-id>/
    handbook.md                ← immutable matching artifact
    evidence.json              ← retained sources, attributed records, dependencies and build identity
  connections/                 ← host adapter's reversible managed-change records
  records/                     ← original source journal; NOT disposable generation output
```

Generation identity includes schema/compiler/projection version, canonical root/checkout, selected source
snapshot, original-record digest/mode and compilation policy. The active handbook's first line
contains the generation ID. Its second line pins the evidence digest; evidence pins the handbook
digest. The evidence digest excludes its own handbook-digest field to avoid a circular hash.
Do not locate evidence by rereading “latest” after reading a handbook.

Compilation is non-mutating. Publication locks the checkout, refuses unknown/manually edited
output, revalidates inputs, writes and fsyncs the generation, rechecks for changed input/output,
then replaces the active handbook once. Retain old referenced generations. Partial pre-activation
generations are never active. Repeated identical publication is a no-op. Storage must use bounded
regular files and no-follow directory descriptors. The lock coordinates cooperative Byori writers,
not arbitrary malicious processes with the user's filesystem permissions.

Generated evidence and connection backups are local outputs, protected from ordinary `git add .`
by an idempotent `/.byori/` entry in Git's local `info/exclude`. Preview does not add this entry;
build/connect does. Preserve pre-existing exclude contents and never rewrite tracked `.gitignore`.
Refuse symlinked exclude paths, conflicting ignore policy, and already-tracked `.byori` output
instead of silently modifying the index. Product-level retention/cleanup UI remains packaging work.

## Read and freshness semantics

`handbook_status` distinguishes `missing`, `current`, `stale`, and `unavailable`. “Current” means
the selected input/build snapshot matches, not that every statement is correct. `read_handbook`
returns no body unless that snapshot and artifact integrity can be verified. This runs without an
engine login or model request. Missing required original records is unavailable, not an empty graph.

A static host file reference can bypass this verification. It must not be described as safe
automatic delivery until a startup gate or equivalent verified path is in place. Engine health,
host configuration, actual context consumption and source freshness are separate facts. The
full plan still requires dependency-scoped incremental compilation, qualified last-known-good
offline behavior, real host tests and complete app/runtime verification. The shared coordinator
implements opt-in reconciliation, not all those release gates.

## Verification responsibilities

Core unit/integration tests own deterministic output, actual Git fixtures, citations, budgets,
no-op publication and CLI compatibility. Independent adversarial tests own tampering, interrupted
publication, manual edits and missing originals. Host tests own managed configuration preservation.
Installed-runtime tests must import only shipped sibling modules outside the repository. No test
may mutate live project memory, credentials, vendor settings, or the developer's engine service.
