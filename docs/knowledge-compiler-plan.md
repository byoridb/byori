**English** | [한국어](ko/knowledge-compiler-plan.md)

# Byori project handbook — development plan

**2026-09-12: paused, not completed.** The owner reopened product strategy from
first principles. The active experiment is [dependency-context reuse](dependency-context-pilot.md).
The gates below preserve the prior implementation history; they do not require
continuing the app-first plan before the new hypothesis can be tested.

Accepted direction: **2026-09-11**. Product and implementation ownership: the repository
maintainer, working with coding agents; the two repositories do not imply two engineering teams.

Status: **implementation authorized on 2026-09-11; KC-01 in progress, later gates not passed.**
The owner subsequently requested supervised implementation and independent verification with
appropriate agent/model allocation. Existing components are reuse candidates, not completed new
milestones. Deployment, deletion, a new background job and a repository-wide rewrite remain outside
this authorization unless separately requested. See the execution checkpoint below.

## 1. Outcome and scope

Byori builds and keeps an AI-readable project handbook current. The customer-facing promise is
“Stop explaining your project over and over,” not “operate a graph database.”

```text
Trusted project + selected sources + accepted checkpoints
    → source-backed records and dependency graph
    → short versioned handbook + on-demand evidence
    → Claude Code / Codex in the user's existing workflow
    → source change → affected records rebuilt → updated handbook
```

Originals and accepted records survive; graph projections and handbooks are rebuildable outputs.
The app becomes the place to connect a project, inspect the handbook, connect an agent, and
understand update failures. [Product](../PRODUCT.md) is authoritative for product scope;
[Design](../DESIGN.md) governs the target manager and the retained legacy UI.

### Release boundary

| Must ship | Deferred until evidence justifies it |
|---|---|
| Project selection, bounded sources, source-backed preview | Complete GitHub issue/PR body ingestion and other connectors |
| Short handbook, citations, unresolved/stale states | Open-ended conversational knowledge extraction |
| Verified Claude Code and Codex session delivery | More agents and a general agent orchestration layer |
| Change-driven refresh, manual refresh, offline-readable output | Continuous model summarization and autonomous policy changes |
| Reversible connection/install, recoverable migration | Immediate DB rewrite, repository merger, legacy data deletion |

Model-assisted editing is optional, after the deterministic loop. It must not block first-value
testing. Do not invent market-size or reach estimates while the owner is the only confirmed user.

## 2. Implementation sequence

Dates are not promised. Work proceeds in one active milestone at a time; reserve roughly one
day in five for tests, integration, and defects. Re-estimate after KC-01 and each completed slice.
If effort grows, cut connectors, AI editing, and visual polish—not preservation or provenance.
The owner accepts each gate before the next release boundary.

| ID | Deliverable | Dependency | Completion gate | State |
|---|---|---|---|---|
| KC-00 | Product, design boundary, plan, roadmap | Owner decision | Documents agree; old priority explicitly superseded | Documented |
| KC-01 | Source/record contract and deterministic preview | KC-00 | One project produces a bounded, source-linked handbook; repeat build stable | In progress; prototype under verification |
| KC-02 | New-session delivery and explicit rebuild | KC-01 | Claude Code and Codex consume it; source change updates next session's context | Adapter groundwork only; gate not passed |
| KC-03 | Safe automatic incremental compilation | KC-02 | No-change builds make no model calls; stale/race/offline tests pass | Consent-gated refresh and authenticated cross-invocation projection reuse implemented; host/offline and product-value gates pending |
| KC-04 | Small manager and one reliable runtime setup | KC-02, KC-03 | First-use flow needs no DB administration; migration/rollback drill passes | Native UI prototype; runtime/migration gate not passed |
| KC-05 | Optional model-assisted editing | KC-03 | Quality improves within a disclosed cost limit; no unsupported policy promotion | Deferred, optional |
| KC-06 | Comparative pilot and release decision | KC-04; KC-05 only if included | Safety gates pass; repeat-use value appears against realistic baselines | Not started |

**First internal demo: KC-01 + KC-02. First public pilot: KC-01–KC-04 + KC-06.** KC-05 is not on
the critical path. Safety tests start in KC-01; KC-06 is not a late substitute for testing.

### KC-01 — Compile one useful handbook

Deliver in three reviewable changes:

1. **Contract and fixtures.** Define project/checkout identity, source bounds, accepted-record
   fields, build version, claim states, artifact ownership, and publication boundary. Add a small
   repository fixture with a decision, replacement, revert without a reason, pitfall, and document
   change. Capture baseline tasks before tuning.
2. **Source adapter.** Reuse `cli/archaeology.py` for Git/document signals and read existing memory
   through a narrow storage adapter. Preserve locators and original accepted checkpoint bodies.
   Do not assume every revert is a resolved bug or every ADR is an active decision.
3. **Deterministic compiler.** Add a shared module under `cli/` for normalize → select → render →
   validate → publish. Keep extraction and rendering independently testable. Extend `byori init`
   without breaking current flags/JSON contracts; new refresh commands/output need explicit
   versioning. Preview/dry-run does not modify agent configuration. Candidate output location:
   `.byori/handbook.md`; finalize ownership and ignore behavior before making it a public interface.

Handbook v1 contains purpose, important modules, supported decisions/constraints, pitfalls, and
open questions. Every substantive claim has a record ID and source locator; absent evidence is
labelled, not invented. Prioritize a small current-source preview; make older-history enrichment
explicit and resumable. Report truncation and exclusions.

Gate: the same snapshot/compiler version produces byte-stable deterministic output; fixture
claims are supported or explicitly qualified; source text is not executed; missing sources,
secrets, conflicts, and a small context budget are tested. No model account is required. Do not
promise that all repositories contain enough evidence for a useful handbook.

### KC-02 — Prove that agents actually receive it

1. Verify supported startup/instruction mechanisms for the tested Claude Code and Codex versions.
   Record compatibility tests and choose one route per host. MCP registration alone is not
   auto-loading; do not assume identical instruction files or hooks. If reliable automatic
   delivery is unavailable, expose that limitation and fail the automatic-delivery gate instead
   of calling a manual step automatic.
2. Add connection preview, scoped managed insertion/reference, backup, and exact disconnect
   restoration. Never replace user-owned `CLAUDE.md`, `AGENTS.md`, settings, or other instructions.
   Detect conflicting/manual edits to managed areas and request review.
3. Deliver the bounded handbook and generation/scope at startup; use existing MCP reads for
   detail. Add a small read-only generation-aware entry point only if needed, not a competing
   memory API. Generated text is reference context and cannot overrule user policy.
4. Update distributed Memory Skills and MCP instructions together: originals/accepted records
   stay authoritative; compiler-owned read-only handbooks are allowed derived views. Do not create
   an independently maintained host-memory copy. Retain structured checkpoint capture.

Gate: a fresh process of each agent receives the expected generation without a per-session manual
recall request. The fixture agent identifies a constraint and opens its source. Change the source,
explicitly rebuild, then verify replacement delivery to a new session. Connect/disconnect preserves
pre-existing user content. Use isolated test profiles and authorized model access; no test may
silently edit the developer's real agent configuration.

### KC-03 — Keep it current safely

1. Share a coordinator across app/CLI/MCP. Hash selected inputs and accepted-record revisions;
   debounce changes, deduplicate jobs, and rebuild affected dependencies. Begin with explicit
   refresh and startup freshness checks; enable background refresh with visible consent and
   configurable bounds. Do not run a constantly active model loop.
2. Version builds by project, checkout identity, Git/dirty snapshot digest, source policy, record
   revision, schema/compiler version, and model/prompt versions if used. Exclude concurrent builds
   per checkout and coordinate project-wide accepted-record writes.
3. Stage immutable generations, validate, then activate at one publication boundary. Handbook
   and detailed evidence must resolve to the same generation. Recheck input snapshot before
   activation: an older job cannot replace a newer build. Several independent file renames do
   not constitute atomic publication.
4. Separate dirty, building, current, failed, and excluded/retracted states from engine health
   and delivery status. Keep last-known-good output readable with its snapshot/stale warning on
   ordinary failure. Withhold wrong-checkout and retracted/sensitive output; offline operation
   does not permit unsafe fallback.

Gate: unchanged sources cause no model calls; interruption leaves a complete old or new generation;
linked checkouts do not exchange experimental facts; branch switches and dirty edits invalidate
the old view; retry/cancel/rollback are idempotent. An allowed published handbook remains readable
without engine login. Incomplete dependency tracking cannot silently report a partial build current.

### KC-04 — Package one small product

1. Evolve project-registration/empty-context UI into **Connect project → Preview handbook →
   Connect agent**. Main content is the handbook, not a graph canvas. Show evidence, unresolved
   items, last successful snapshot, build state, and retry. Label “configured” and “last verified
   delivery” separately. Check keyboard/VoiceOver, light/dark, empty, large, offline, and failed states.
2. Reuse SwiftUI and `ManagerService`; call the same compiler/coordinator as CLI/MCP. Preserve
   `byori init` and project identity compatibility. First value requires no terminal session,
   worktree, port, graph-space name, or database password.
3. Give runtime lifecycle one owner behind app/installer entry points. Pin a tested app/CLI/MCP/
   schema/engine bundle, verify signed assets, serialize update/restart, and restore complete
   version/manifest state on rollback. Extend doctor for source access, builds, stale output, and
   adapter health. Installation failures must remain visible.
4. Perform migration below before demoting legacy workspace entry points. Code removal is a
   separate scoped change, not a demo prerequisite.

Gate: a fresh test account can install, select a fixture project, inspect useful content, connect
either supported agent, and recover from failed build/update. Verify inherited macOS signing and
both architectures. Keep Linux CLI compatibility without a new Linux GUI. Installation tests use
isolated homes/ports/data, never the developer's live engine.

### KC-05 — Optional AI editor, not a truth generator

Use a provider-neutral interface with one explicitly chosen supported provider for the first trial.
First settle credentials/permission, outbound text preview, budget accounting, timeout, and cancel.
Do not assume a Claude/Codex subscription can be reused.

The model sees bounded original evidence/accepted records and proposes structured claims with
source IDs, conditions, and conflicts. Merge duplicates only when meaning, scope, and supporting
evidence agree. Never derive truth solely from previous summaries. Validate schema, source support,
scope, and prohibited content. Structural checks do not prove semantic support; uncertain proposals
stay review items. Promoting new behavioral rules requires explicit acceptance.

Gate: held-out tasks improve over KC-03 without critical factual regression; hard build/project
limits work; rejected output leaves the last safe build intact; no change means no model request.
If there is no demonstrated gain, do not ship this phase.

### KC-06 — Test the hypothesis and decide to release

Dogfood Byori and ByoriDB as separate projects, then recruit five external developers for a scoped
pilot with consent and no automatic telemetry. Ask for three fresh sessions and one source-change
cycle each. Record failed and repeated corrections, not just successful demos. Five users give
directional learning, not statistical proof.

Run the evaluation below and publish limitations. After safety and repeat-use value are shown,
release manager/CLI/MCP as one compatible bundle. Remove legacy code only after preservation and
recovery verification. If the handbook does not beat maintained Markdown on effort or freshness,
improve the loop or reduce scope before building cloud/team infrastructure.

## 3. Shared technical contract

### Sources and records

- Select tracked docs, bounded Git history/metadata, existing accepted Byori memories, and explicit
  checkpoints. A PR number is a reference, not proof that its remote body was fetched. Network
  ingestion needs separate consent and a later adapter.
- Resolve symlinks/canonical roots and enforce selected-root bounds. Deny secrets/`.env`, ignored
  private paths, generated outputs, and raw transcripts by default. Never execute document text
  or print credentials during diagnostics.
- Record fields: stable ID, kind, body, source locator/content digest, project/checkout scope,
  source event time, recorded time, last verification snapshot, claim state, and relationships.
  States: `supported`, `inferred`, `conflicted`, `superseded`, `unverified`, with documented meanings.
  “Supported” is claim-level, not merely “a SHA string was found.”
- Source event time differs from DB insertion time: importing an old commit today does not create
  an authentic past DB snapshot. Full bitemporal query expansion is not an MVP prerequisite;
  application metadata must preserve these distinctions.
- Before treating graph projections as disposable, preserve graph-only accepted records in an
  authoritative recoverable source journal. Source exclusion invalidates derived outputs; actual
  deletion also needs a retention/backup policy, not just a UI hide.

### Output and storage

Use a narrow adapter over the existing ByoriDB contract. Proposed boundaries: source adapters,
record normalizer/store, compiler/validator, generation store, coordinator, host adapters. These
are modules, not new services. Only the coordinator publishes generations; memory tools can still
record accepted checkpoints and trigger invalidation.

Keep a configurable short-context budget, stable ordering, per-claim references, generation ID,
and on-demand detail. Make omitted sections/low coverage visible. Detect edits to generated files
and offer them as source corrections; do not silently ingest or overwrite manual edits.

Finalize file layout and single-generation activation in KC-01 before KC-02 host wiring relies
on them. KC-03 strengthens concurrency and invalidation without breaking that interface. Retain
original data across schema changes. No wholesale language rewrite, distributed graph, new query
language, or second database is assumed.

## 4. Repository work map and dependencies

| Area | Starting points | Planned responsibility |
|---|---|---|
| Sources/CLI | `cli/archaeology.py`, `cli/byori.py` (`ProjectRegistry`, `MemoryWriter`, `command_init`) | Safe extraction, identity, shared compiler entry points |
| Memory | `mcp/byoridb_mcp.py`, `docs/memory-ontology.md` | Accepted records, evidence semantics, generation-aware reads, compatibility |
| Host delivery | `adapters/`, `install.sh`, MCP instructions | Managed setup/startup, derived-view policy, disconnect restoration |
| App | `manager/macos/Sources/ByoriManager/` and `ByoriManagerCore/` | Handbook UX, shared build status, runtime coordinator |
| Diagnostics/release | `cli/doctor.py`, `scripts/`, `.github/workflows/` | Compatibility, migration/rollback, new checks |
| Engine (separate repository) | `byoridb/byoridb`, [engine contract](engine-contract.md) | Demonstrated storage/query/integrity needs only |
| Validation | `tests/`, macOS tests, `benchmarks/why.py` | Compiler/adapter/recovery coverage and fair task benchmark |

The maintainer owns all dependencies. Before KC-01, validate the pinned engine contract and isolate
any blocking operation with a minimal reproduction. Before KC-02, prove both startup mechanisms.
Before KC-04, restore a copy and recheck previously reported rollback-manifest/service-ownership
failures; historical issues are not assumed still open or fixed. If engine work is needed, file
an upstream issue and add a contract test before coordinated release. Never silently switch
production storage engines to evade a blocker.

## 5. Migration, rollback, and consolidation

1. **Inventory:** exact project IDs/roots/spaces, engine/schema versions, configurations, user
   instruction files, and legacy task/session metadata. Do not expose secrets.
2. **Back up and restore a copy:** include graph data, graph-only accepted records, registries,
   source policy, runtime/config manifests, and adapter originals. Coordinate a consistent backup
   with the storage owner. Bounded `memory_export` is diagnostic, not a full backup.
3. **Import without rewriting history:** preserve IDs, locators, and bodies. Mark unsupported legacy
   claims `unverified`; do not reinterpret them as accepted policy.
4. **Parallel preview:** on isolated copied data, build projections and compare canonical IDs,
   counts, and selected knowledge. Owner reviews the handbook; working setup stays active.
5. **Switch reversibly:** activate the verified generation and explicitly approved host edits.
   Rollback restores runtime metadata/config and previous safe output, retaining new original
   records for later replay.
6. **Retire separately:** demote legacy UI only after the new flow works. Delete named obsolete
   code/assets in a later reviewed change. Memories, repositories, branches/worktrees, credentials,
   and task/session data are not deletion targets of the strategy decision.

No destructive migration/service tests on live ByoriDB. Use isolated homes, ports, and data copies.
An old handbook is not a source backup.

## 6. Validation and release gates

### Automated coverage

- Evidence: absent reasons, dead locators, renamed docs, conflicting ADRs, reverts, supersession,
  unsupported model claims, checkpoint-only knowledge.
- Boundaries: secrets, symlink escapes, prompt injection, output feedback loops, same-named repos,
  linked worktrees, dirty checkouts, large/truncated input.
- Lifecycle: determinism/no-op, dependency invalidation, source changes mid-build, concurrent publish,
  crash, cancel, offline engine, retraction, rollback.
- Delivery: fresh agent process, generation/scope, pre-existing config, edited managed files,
  upgrade/disconnect, unsupported startup mechanism.
- Compatibility: Python/MCP/pinned-engine smoke, Swift tests/self-test/strict concurrency, and
  packaging/signatures as affected. Compiler tests use fixtures by default.

### Fair comparison

Freeze sources/questions before tuning. Use several repositories with decisions, replacements,
and meaningful changes. Fix agent/model, source horizon, tool access, and task budget; randomize
order and repeat runs:

1. Agent plus current repo/docs/Git, without prebuilt Byori context.
2. Same sources plus a manually maintained short Markdown handbook; include creation/update effort.
3. Byori with the same context budget, counting ingestion/editing/update/inference costs.

Score correctness, actual source support, qualifications, obsolete-rule use, task outcome, user
correction/preparation time, first-use latency, and total cost. Include historical questions and
present-day coding tasks. Keep held-out questions/post-change snapshots out of tuning; publish
failures. Ablate graph traversal against a linear record index to justify internal complexity.
The historical Redis 8/8 vs empty-graph 0/8 test is not this comparative benchmark.

### Provisional targets — not measured results

- Zero observed secret disclosures, cross-checkout leaks, destructive config/data loss, or critical
  unsupported rules in the release safety suite. Any occurrence blocks release; passing finite
  tests is not proof of universal absence.
- All published fixture claims have resolvable provenance and pass support/qualification review.
- A declared small-repo fixture yields a useful no-model preview within 60 seconds on the recorded
  test machine; measure cold/warm setup separately and re-scope if unrealistic.
- A new session after source change gets the rebuilt generation or an explicit stale/unavailable
  warning, never silent “current” status for old context.
- At least three of five pilot users voluntarily return over three sessions and a change cycle;
  understand drop-offs rather than counting installations as adoption.
- Target at least 20% less user context-maintenance time than manual Markdown on repeated held-out
  tasks without material correctness/currentness regression. Report raw values/variation; a small
  pilot cannot support a population-level performance claim.

If value targets fail, revisit the loop before widening the audience or adding cloud/team features.
If only model editing fails, omit KC-05. If graph ablation shows no benefit, simplify the internal
layer without abandoning the user-facing handbook.

## 7. First implementation handoff

First slice: **KC-01.1 — contract + deterministic fixture + expected handbook**, followed by
the smallest compiler path in KC-01.2–3. The current contract is [handbook-contract.md](handbook-contract.md).
Do not begin by deleting the app or rewriting ByoriDB. Update milestone states only after tests/
gates pass, and checkpoint accepted/superseded knowledge in ByoriDB.

Writing this plan does not include commit, push, release, host configuration changes, or live
migration. Main pushes can trigger a release here and need explicit release intent.

## 8. Execution checkpoint — 2026-09-11

Use supervised native Codex workers in the shared checkout with disjoint write ownership; no new
worktree. Orca was inspected but its automatic coordinator binding selected an unrelated project
terminal, so no Orca worker was started. That path is not used for this implementation.

| Owner | Model / effort | Write scope |
|---|---|---|
| Coordinator | Current session | Compiler/publication, CLI, packaging, contracts and integration fixes |
| Source worker | `gpt-5.6-sol` / high | `cli/handbook_sources.py`, original-record journal, source/journal tests |
| Delivery worker | `gpt-5.6-sol` / high | `cli/handbook_delivery.py`, host tests/compatibility note |
| Independent verifier | `gpt-6-astra` / high | Adversarial test file; no runtime fixes |
| Native app worker | `gpt-5.6-sol` / high | Swift manager/service/models/views and their tests |

This allocation is an implementation choice, not a claim that one model's self-report proves
completion. Review actual diffs, rerun tests on the integrated tree, and keep the independent
verifier separate from production fixes. Reuse workers for coherent follow-ups; close settled
workers when no follow-up needs them.

Prototype progress: deterministic attributed-source compilation, generation-pinned evidence,
manual-edit/tamper rejection, freshness checks, explicit CLI entry points, local Git exclusion and
sibling-module packaging. MCP reuses the same guarded read and source-evidence path without an
engine login. Shipped skill sources now distinguish originals from compiler-owned derived views.
The native manager previews/builds a handbook and previews/applies/disconnects scoped host blocks;
it withholds old content after an unclassified validation failure. The integrated native test suite
passed 313 tests, the core self-test, and the strict-concurrency warnings-as-errors build on arm64
macOS. Rendered-app behavior, Intel/signing/DMG and real startup consumption are not thereby verified.

The original-record journal is a separate, explicitly imported source store, not generation
evidence or a full engine backup. Its revision invalidates the compiled view; originals survive
derived rebuilds. History limits now reject an append before activation; an exact interrupted
first import can recover without accepting a different orphan. The integrated Python suite passed
356 tests, and the frozen handbook slice passed 130 after the journal changes. Final independent
verification passed 85 adversarial/journal/compiler/MCP tests in 31.023 seconds, including both
history-boundary regressions and interrupted-first-activation recovery. No blockers were found
by those suites; this does not pass the later host/runtime/pilot gates. No live
graph migration has run. A read-only repository probe with 20 commits/20 documents took 0.79 seconds
and rendered 11,727 characters/14 excerpts while omitting 242 sections; that is a bounded latency
observation, not proof of useful selection or a comparative quality result.

Both installed host CLIs can be inspected, but separately authenticated isolated test profiles
are absent. Real-session smoke is prepared but has made zero model calls; configured remains
unverified. Do not reuse/copy live credentials silently to turn this prerequisite into a pass.

Checkpoint recording through the installed ByoriDB Memory Skill was attempted on 2026-09-11,
but its read failed with connection refused. No engine was started or repaired for the task, and
no successful memory write is claimed. This development document records the implementation
checkpoint; the existing accepted product decision was not replaced by a parallel host memory.

Still required before claiming the full objective: graph-only original-record preservation and
source integration, richer useful knowledge/qualification coverage, safe real startup delivery,
dependency-scoped incremental compilation, complete app/installer/rollback validation, comparative task evaluation
and consented external pilot. Static references, quoted excerpts and green unit tests alone do
not discharge these gates. Optional model editing remains deferred, not silently required or done.

## 9. Consent-gated refresh checkpoint — 2026-09-12

The shared coordinator now drives CLI, native manager and the separately mutating MCP refresh
entry point. Automatic refresh remains off by default. The app uses a serial 12-second check only
for the selected, visible project in an active scene; hiding, switching or deactivating cancels it
and withholds the prior body. It is not an installed daemon. New connection blocks request `sync`
once at task start, but actual host consumption remains unverified. Legacy read-only blocks remain
recoverable and require explicit disconnect/reconnect to adopt the new reference.

Saved source bounds/exclusions govern preview, manual build, `init --handbook`, sync and MCP reads.
Explicit conflicting bounds fail rather than widening collection. Reviewed configuration writes
use revisions, including a create-only assertion for a reviewed absent setting. Each actual
mutation has a fresh identity: disable/re-enable cannot resurrect a prior job. Cancellation is
rechecked after guarded reads, policy changes are serialized with publication, and serialized
configuration limits are checked before writes. No-op refresh does not publish or call a model.

Independent tests exposed and then verified fixes for post-read cancellation, disable/re-enable
revision reuse, and an exclusion list larger than its configuration reader allowed. The final
independent suite passed **38 tests in 132.338s**, plus the additive absent-setting CLI CAS test.
The integrated Python baseline passed **419 tests in 441.336s**. Two subsequently added CLI cases
were included in a fresh **14-test refresh suite (77.471s)**; the current tree discovers 421 tests,
which is not a claim that a second full 421-test run occurred. MCP lifecycle tests were also rerun
with `ResourceWarning` treated as an error: **46 passed in 2.284s**, after explicitly closing the
test child-process pipes. The integrated native suite passed **326 tests in 37.111s**, including
temporary-repository decoding of the actual CLI configuration contract.
The arm64 strict-concurrency warnings-as-errors build also passed (29.09s), as did the core
self-test, installer/DMG shell syntax checks and `git diff --check`. These are not rendered UI,
universal binary, notarization, installed-service or rollback drills.

The source worker's 12-commit fixture used two `git cat-file` processes (metadata/content batches),
with strict framing/identity checks and no raw-source disk cache. A local read-only 20-commit,
20-document preview took **0.58s** and still returned 14 excerpts/11,727 characters with 242 omitted
sections. This is a latency observation, not evidence of improved knowledge selection. Host smoke
preflight still made **zero model calls**; no private test authentication was provisioned or copied.

This completes a refresh implementation slice, **not KC-01–KC-04 or the overall goal**. It still
recollects originals and recompiles the selected view; batching Git calls is not dependency-scoped
incremental compilation. Next: improve declared module/condition/conflict coverage without treating
metadata as truth, then add per-input projections whose incremental result is byte-identical to a
clean build. Reused projections must be checked against fresh originals; a hash does not establish
semantic support. Global budgeted rendering still reruns. Real host startup consumption, qualified
last-good/offline behavior, graph-original preservation, unified runtime/install/rollback, rendered
UI and architecture/signing checks, comparative evaluation and consented pilot remain separate gates.

No app or service was launched for this slice; no live project policy, user host profile, graph,
branch/worktree, commit or release was changed. ByoriDB checkpoint access was refused, so no memory
write is claimed. Documentation records implementation progress without replacing the accepted
product decision with another host-memory store.

## 10. Qualified selection and diagnosis checkpoint — 2026-09-12

Compiler 1.1.0 / projection version 2 adds explicit checkpoint declarations for module paths,
conditions, dependencies, affected modules, conflicts and supersession. Typed, unambiguous targets
are required. Module cycles are bounded; supersession cycles and self-conflicts fail closed.
These remain source-declared, unverified statements, not inferred current policy or a new engine
schema. The [projection contract](handbook-projection-contract.md) defines the exact field/type
matrix and bounds. Existing graph records are not automatically imported by this change.

The renderer gives purpose, modules, conditional decisions, pitfalls, documentation and history
coverage before spending the rest of its context budget. Explicit conflict/replacement components
are shown together with their conditions or withheld together; an empty counterpart cannot leave
a one-sided rule. Omission metadata is aggregated by reason and source component, retaining exact
counts and original bodies without overflowing evidence for a dense 48,000-section fixture.
Matched Markdown fences prevent example headings/status lines from being promoted to source
lifecycle labels. Literal Unicode paths/conditions are preserved but unsafe characters and path
shapes are refused. No model calls or unsupported semantic confidence are introduced.

Fresh selected originals are still collected and validated on every pass. A bounded **process-local**
memo reprojects changed/removed inputs and their reverse dependency closure; typed edge changes use
both old and new graph snapshots. Final budget selection, rendering and publication guards rerun.
Clean and warm artifacts are byte-identical. Caller mutations cannot poison the memo, scope/version
identities isolate it, and a failed pass cannot replace the previous complete memo entry. Separate
CLI processes still start cold; durable incremental compilation remains an unpassed gate.

`doctor PATH --handbook-only` now diagnoses source access, snapshot state, omissions, consent/bounds
and scoped Claude/Codex connection integrity without engine authentication, runtime-environment
reads, normal host-profile probes or mutation. Off is intentional, missing/stale is a warning,
unverifiable data is a failure, and configured is never labelled consumed. The default legacy
doctor is unchanged. Installed-sibling tests include this entry point and both new compiler modules.

Independent verification passed **44 tests** (24 adversarial, 13 memo, 7 parser; 28.779s wall time),
including meaningful source/condition selection, publication races and fresh-process cold behavior.
The knowledge worker passed 32 contract tests; the diagnostic worker passed 27 new and 27 existing
doctor tests. Main reran installed-runtime packaging (1 test), MCP bridge (5 tests), and the native
suite (**326 tests, 11.730s**, after a 15.69s build). A read-only diagnosis of this repository correctly
reported no published handbook, intentional refresh-off and unverified/unconfigured host delivery;
it did not build, connect or repair anything.

A bounded real-repository observation (20 commits / 20 documents) returned 36 selected sources,
22 excerpts and 234 omitted sections in 11,589 characters. Cold, warm and clean results were exactly
equal; per-source projection counts were 36, 0 and 36 respectively. Times were 0.235s, 0.227s and
0.250s, so this is evidence of correct reuse, not a significant end-to-end speedup or comparative
knowledge-quality gain. The strict-concurrency warnings-as-errors arm64 build passed (15.32s),
the core self-test passed, and 46 MCP lifecycle tests passed with `ResourceWarning` as an error
(1.368s). Shell syntax and diff-whitespace checks passed.

After all runtime and test files were frozen, the final integrated Python run passed **524 tests
in 481.228s**, with no failures, errors or skips. This includes the diagnostic and dense-omission
regressions, not just the earlier 489-test intermediate run. No test process was left running.

The accepted strategy and product scope are unchanged. This is progress toward KC-01/KC-03/KC-04,
not their completion. Real-host startup consumption still requires separately provisioned private
test authentication; graph-original preservation, qualified last-good/offline recovery, cross-run
incremental reuse, unified runtime/install/rollback, rendered UI, architecture/signing checks and
comparative/pilot outcomes remain open. With only about 5 GB free during verification, no new large
DMG/universal build was started. No credentials were copied, service started, production profile
edited, commit pushed or release created. ByoriDB recall/checkpoint remained unavailable; repository
artifacts carry this implementation checkpoint, not a replacement host-memory store.

## 11. Runtime ownership and local connection diagnosis — 2026-09-12

App installation/start/stop/restart and the standalone installer now share a private OS-lifetime
writer lease. Native cancellation and detached rollback retain ownership; explicit FD-9 delegation
supports both bundled scripts and `curl | bash`. Unsafe roots/files, wrong descriptors and busy
writers are refused before mutation. Uninstall preserves the root/lock inode; a long-lived
background engine does not inherit the lease. The manifest is replaced atomically. App-driven
runtime installation skips host hooks as well as MCP/skill wiring, preserving explicit connection.

Runtime snapshots include engine.json and a bounded byte/mode inventory. Incomplete backups fail
before replacement. Restore requires the service and engine ports to be stopped, and rechecks
data and snapshot integrity after the awaited stop. A changed engine with nonempty data is not
automatically rolled back to potentially incompatible bytes. Existing graph data/originals are
not deleted. This is not a consistent database backup or a crash-atomic multi-file restore; those
remain open gates. The [runtime contract](runtime-mutation-contract.md) defines this narrower scope.

Frozen verification: **50 installer tests passed in 236.217s**. The native strict-concurrency /
warnings-as-errors suite passed **353 tests in 15.949s** after the final review fixes. The corrected
core self-test passed (its initial corrected build took 8.91s); shell syntax and diff whitespace
checks passed. Unknown initial service state now aborts before snapshot/installation, and the
inventory snapshot fixture uses a fake health probe and command runner. New coverage uses
real cross-process flock/descriptor transport but fake services, synthetic engines and isolated
homes. An initial installer run had two compatibility expectations corrected and a script-edit/
execution overlap; only the subsequent frozen all-green run is the final installer evidence.

The user also asked why memory remained disconnected while Byori appeared running. Diagnosis found
no engine/listeners and no registered standard service, with a matching MCP endpoint. The latest
engine shutdown at Sep 11 21:12:02 KST closely followed this task's 21:11:54 self-test invocation.
The pre-existing self-test cancellation fixture used a real runner with the live service label;
its rollback could stop that service despite a temporary HOME. It is the likely cause, not a
proven signal-sender attribution. This **qualifies earlier claims in this document that self-test
runs could not affect a live service**. The fixture is now deny-by-default and explicitly isolated.
See the [full diagnosis](local-engine-diagnosis-2026-09-12.md). No engine restart or live repair was
performed during this diagnosis.

Per the user's explicit direction, Orca is no longer part of this task's coordination. It is not
a Byori runtime or ByoriDB MCP dependency; native Codex workers are used. Other projects, Orca
processes and global skills/configuration were left untouched. Memory recall remains unavailable
until the actual engine is restored; no graph checkpoint write is claimed. No commit, push,
release, host-profile migration or product-goal completion is implied by this checkpoint.

## 12. Durable projection and authorized engine recovery — 2026-09-12

Compiler 1.2.0 extends the bounded process memo with an authenticated, checkout-local disk cache
in Git metadata. Every invocation still reads selected originals and validates explicit declarations.
Changed/removed semantic inputs and typed edges invalidate the reverse dependency closure over
the old and new graphs. Selection, rendering, evidence identity and publication revalidation are
never skipped. Only a successful normal publication may persist compiler projections; preview,
read-only commands, failed/cancelled builds and `--clean` do not write the cache. Clean mode bypasses
both caches through every publication pass, providing an independent comparison path.

The private 32-byte HMAC key authenticates cache scope and contents, not the truth of source claims.
Malformed/tampered/wrong-scope/busy/unsafe storage becomes a cold computation or skipped persistence.
The key is never a host credential or an artifact. Same-user compromise of the key/compiler is
outside the threat model. A fingerprint of loaded code prevents an old process from labelling its
projections as replacement code installed on disk. The
[durable projection contract](handbook-durable-projection-contract.md) records these limits.

Native Codex workers split implementation (Sol/high) and independent fresh-process verification
(Astra/high); the main agent integrated publication, clean mode, diagnostics and packaging.
The verifier passed 35 integration tests, including actual projector-call instrumentation rather
than counter-only assertions. Its seven-source fixture performed 7 calls on a cold build, 0 on a
fresh-process warm build, and 3 after an affected dependency edit. Full handbook bytes, detailed
evidence and generation matched clean recomputation. Observed times were 503/427/491 ms, with a
161 ms clean preview; these exclude interpreter startup, compare different operation paths, and
are **not a production speedup or semantic-quality result**. The storage worker passed 49 tests;
the process memo suite passed 18. Main verification and remaining limits are recorded below.

Final main-agent regression with implementation/packaging files frozen: **641 Python tests passed
in 612.306s**, including the independent durable integration and storage suites, MCP, refresh,
publication, installer and existing compatibility tests. Shell syntax and diff whitespace checks
passed. The test command and its observed long-lived fixture child exited. The real engine retained
the recovery PID, health 200 and a successful structured MCP read after the full run. Test output
about synthetic zero-memory spaces is not the state of the real project graph.

A main-agent read-only observation on this working repository selected 116 sources and emitted
21 attributed excerpts. Normal cold preview (581.3 ms) and clean preview (677.5 ms) each performed
116 projections and produced identical handbook/evidence/generation. No cache was created/changed
and no handbook was published. This is a bounded real-repository determinism check, **not** a warm
cross-process performance measurement; that evidence remains confined to the isolated fixture.

The user then explicitly authorized starting the existing ByoriDB service. Its existing v0.4.13
binary matched the manifest and passed strict signature verification. Starting the existing plist
restored health 200 and actual MCP project-memory reads. No update, reinstall, credential/host-profile
change or data deletion occurred. The corrected native suite passed **353 tests in 16.729s** and
the core self-test passed; the engine retained its PID and health afterwards. The earlier memory
unavailability in sections 8–11 is historical, not the post-recovery state. The old self-test's
likely role in the original shutdown remains documented with its attribution limit.

The ByoriDB memory skill was used to recall the accepted strategy, record the diagnosed incident
and test-isolation correction with typed links, and add the projection module's durable contract
pointer. A subsequent structured read returned the incident and cause link. Product documents remain
the reviewable milestone record; the graph write is not a claim of automatic graph-to-journal migration.

This closes neither the whole KC-03 gate nor the product goal. Actual host consumption, safe offline
last-good delivery, original-graph preservation/migration, full data/runtime recovery, rendered UI,
architecture/signing validation and comparative pilot results remain required. No commit, push,
release, real host-model call or live-project handbook publication is implied.
