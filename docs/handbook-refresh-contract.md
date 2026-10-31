# Handbook refresh contract — implementation slice

KC-03 implementation follows [the development plan](knowledge-compiler-plan.md). This document
defines the coordinator interface for concurrent implementation; it does not assert completion.

## User choice and entry points

Automatic refresh is **off by default**. Enabling it is an explicit project-scoped action.
No launchd job, installed-user configuration, engine restart or model request is needed.
The first implementation runs on a connected session request and while the selected project
is visible in Byori; it is not advertised as a daemon that runs after the app quits.

CLI JSON entry points:

- `handbook refresh-config <root> --json`: read configuration without writing.
- `handbook refresh-config <root> --enable|--disable --json`: explicit change; optional
  `--expected-revision <hash>` is compare-and-swap protection for a previously reviewed setting.
  `--expect-unconfigured` instead asserts that the reviewed checkout had no saved setting.
- `handbook sync <root> --json`: reconcile/read only if refresh is enabled; otherwise a guarded
  ordinary read. It never enables itself. A missing or unsafe source never means an empty source.
- `handbook refresh <root> --json`: one explicit bounded refresh regardless of automatic setting.

Configuration response: `{schema_version:1, enabled:bool, revision:string|null, change_id:string|null,
project_root:string, checkout_id:string, debounce_ms:int, source_limits:object, max_chars:int}`.
Initial settings use the existing 100 commits/60 files/64 KiB per file/1 MiB aggregate/12,000
character bounds and a short quiet interval. Selection includes an explicit `exclude_paths`
list: normalized repository-relative exact files or trailing-slash directory prefixes, not
shell patterns. Updating bounds/exclusions invalidates the old output before another guarded
read can call it current.
The CLI exposes these bounds on `refresh-config`; `--exclude` replaces the exclusion list and
`--clear-exclusions` explicitly clears it. Changes require `--enable` or `--disable`, even when
the enabled state itself stays the same. Preview, manual build and `init --handbook` also use the
saved policy; conflicting explicit bounds are refused instead of silently widening selection.
Preview rechecks the policy revision before returning any source text and never creates storage.

Refresh responses keep the ordinary handbook read fields (`state`, `generation`, `handbook`,
`reason`, coverage) and add `refresh` (`disabled`, `unchanged`, `rebuilt`, `busy`, `cancelled`,
`failed`) plus diagnostic timings/delta counts only when measured. `current` remains a verified
selected snapshot, not proof of policy correctness. A failure never exposes an unverified body.
Busy/abandoned/cancelled state must not be inferred solely from a leftover status file.

## Shared coordinator and locking

`cli/handbook_refresh.py` owns configuration and `refresh_handbook(root, automatic=True, ...)`.
The CLI, app and explicitly mutating MCP entry point reuse it; the existing `memory_handbook`
tool stays read-only, including in the readonly profile.

Use the existing compiler/generation publication, not a second writer implementation. Serialize
cooperative refresh jobs per checkout and make lock waits bounded. Re-read selected input and
original-journal revisions after a quiet interval, retry only a bounded number of source races,
and revalidate once more before the single publication point. No-change requests do not publish
or invoke a model. Preserve the old complete generation on failure or interruption.

Configuration changes use a separate short policy lock. A refresh must hold that lock while
checking the captured policy revision and publishing, so a completed disable operation cannot
be followed by a previous automatic job's publication. Lock order is refresh-job → policy →
compiler; configuration setters do not acquire the refresh-job/compiler lock. Existing manual
builds remain explicit user actions and keep their current compatibility contract.
Each actual configuration mutation has a fresh identity included in its integrity revision;
disable followed by re-enable does not revive an earlier job. Idempotent settings writes retain
the revision. Cancellation is rechecked after guarded reads as well as before publication.

An app refresh task is cancelled when its visible project changes or the window stops showing
that project. Do not retain the old project's body or infer completion from a cancelled task.
The app shows consent, scope, latest verified result and retry independently of agent delivery.
Connection blocks must report that actual host consumption is still unverified until real
isolated-session tests pass.

## Owners and proof

Coordinator/CLI/MCP/contract: main agent. Source bounds/exclusions and efficient Git reads:
source worker. Native controls/lifecycle: app worker. Independent safety tests: verifier.
All work uses the existing checkout and preserves prior edits. Tests use temporary repositories,
homes and synthetic data; never a live engine, host profile or actual project setting.

Test disabled defaults, true no-op, source-change propagation, exclusions/retractions, races,
cooperative processes, bounded busy/cancel, disable during a build, wrong checkout, tamper,
original-journal changes and installed sibling imports. Do not replace the later full incremental,
offline, migration, real-host or pilot gates with these narrower tests.
