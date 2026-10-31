# Knowledge projection and selection — implementation slice

This extends the existing handbook and refresh contracts; it does not replace the release gates.
Originals stay authoritative. All source excerpts and declarations remain unverified as current
policy. No model, live graph migration, host-profile change or background service is involved.

## Explicit declarations

Accepted checkpoint records may contain `metadata.handbook` with only these optional keys:
`module_paths`, `conditions`, `depends_on`, `affects`, `conflicts_with`, `supersedes`.
Paths and conditions are bounded strings; relation targets are canonical record names present
unambiguously in this selected original snapshot. Paths describe what the source declares, not
verified module behavior. Conditions are shown verbatim. Declaration presence is not confidence.
Unknown fields, malformed values or unresolved/ambiguous explicit targets fail closed. Module
dependency cycles are valid bounded graph components; supersession cycles are refused. Conflict
declarations are displayed as unresolved statements, never resolved by recency or a hash.
Self-conflicts are invalid. Conditions and paths reject control/format characters, unpaired
surrogates and Unicode line/paragraph separators, including tabs/newlines. Module paths are literal
POSIX-relative paths: no empty/dot/parent segments, backslashes, colons, glob characters or surrounding
whitespace. Valid Unicode is preserved verbatim; names are not normalized, expanded or opened.

The pure `handbook_knowledge.annotate_sources(sources)` receives already scoped, sensitive-filtered
source dictionaries. Checkpoint source metadata includes `name`, `type` and optionally `handbook`.
It returns `declarations` keyed by source ID, source-to-source `relationships` with explicit
`relation`, `warnings`, and `coverage`. All six normalized lists are present per declaration.
`affects` explicitly links a decision or bug to a module. It is a source declaration, not inferred
impact analysis; its target contributes to conservative projection invalidation.
Limits: 16 entries per field, 1024 UTF-8 bytes per path/condition, 256 characters per canonical
target, 200 declared checkpoint sources. Errors use `KnowledgeError(ValueError)` and never echo
source bodies or sensitive values. Other record metadata remains in originals, not projected here.

## Projection and rendering

Per-source projections keep complete source sections and their evidence anchors, source-declared
lifecycle/conditions, and explicit dependencies. Final rendering is globally budgeted and gives
overview, declared modules, qualified decisions, pitfalls, documentation and change history a turn
before letting one long document use the whole budget. A conflict/supersession component is shown
with both sides and their conditions or withheld as one oversized component; never silently pick
one rule. Absence of declared module/conflict coverage is reported as unknown coverage.
An empty or heading-only counterpart also withholds the entire related component. Evidence lists
the source IDs and reason under `projection_omissions`; originals and explicit edges are retained.
`knowledge_coverage` counts the sensitive-filtered input snapshot, not the visible output. The
handbook labels these counts accordingly. Markdown code fences must match character and length;
status lines or headings inside example code do not become declared policy or separate sections.

Incremental correctness means the result is byte-identical to clean projection/rendering of the
same originals and policy. Changed input or declared dependencies invalidate the reverse affected
closure; final budgeted rendering still reruns. Fresh originals are always recollected. Untrusted
on-disk units must not be reused merely because their self-reported digests agree. An in-process
memo can trust projections produced in the current process or entries authenticated as coming from
the same compiler implementation, scope and private local key, then matched to fresh input hashes.
See the [durable projection contract](handbook-durable-projection-contract.md) for its threat model
and storage bounds. Do not call a full recomputation plus relabeled counters an incremental optimization.

Generation identity includes the new compiler/projection version. Publication retains the same
single activation point, consent serialization, source revalidation and original-record guards.
Runtime diagnostics are outside generation identity/evidence so clean and incremental artifacts
remain identical. Preview/read-only operations do not write a cache or modify configuration.

The implemented compiler is `1.2.0`, projection version `2`. `compile_handbook` accepts optional
`clean_projection=True` and a caller-owned `projection_stats={}` for internal verification. Default
build output is unchanged by cache warmth. The memo is bounded to eight scopes and 8 MiB of encoded
entries, uses isolated copies and serializes concurrent access. Changed/removed inputs and typed
edge changes invalidate the reverse closure over both old and new graphs; cycles terminate.
Fresh processes may hydrate from a valid private cache created after successful publication; no
cache means a genuine cold pass. `--clean` preview/build bypasses both caches and does not seed them,
including publication revalidation. Final source collection, declaration validation, budget selection,
rendering and publication checks still run. CLI build diagnostics count actual projection/reuse
operations across named passes, not unique-source cardinality; they remain outside evidence and
generation identity. A loaded-code fingerprint (including projection helpers and Python version)
prevents a running old process from labelling its units with files replaced later on disk.

## Verification

Freeze small real-Git fixtures before tuning: a large overview plus module/condition/pitfall,
opposed decisions with explicit conflict, supersession, a revert without a cause, and a later
source edit. Check selected meaning and qualifications, not only matching evidence tokens.
Also test no inferred conflict from lexical disagreement, unresolved/ambiguous targets, cycles,
secrets, cross-checkout scope, budget omissions, cache tamper, source/record deletion and all
existing refresh cancellation/publication races. These do not prove real-host or pilot outcomes.
