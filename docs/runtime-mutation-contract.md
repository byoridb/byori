# Runtime mutation ownership — installation/recovery work

This implements the accepted plan's single lifecycle-owner boundary. It is not a full data
backup, installed-service drill or complete KC-04 claim. Existing runtime and user data survive.

## Shared lease

All new app install/start/stop/restart operations and the standalone installer cooperate on
`<canonical BYORIDB_HOME>/.runtime-mutation.lock`. A lease is an OS `flock` on a private, regular,
single-link, current-user-owned mode-0600 file. The runtime root must be a real mode-0700 directory, never
`/`, the home directory itself, or a symlink. Refuse unsafe roots/files without truncating or
chmod-repairing them. Never delete/recreate the lock path; that would split lock ownership.
Busy is an explicit retriable error, not permission to continue. No PID/status file establishes
liveness and no stale-lock deletion is needed. Check the open descriptor still matches its path.

The native caller holds its lease from before its snapshot until final verification or rollback
has finished, including cancellation cleanup. Actor reentrancy cannot admit a second mutation.
The runner transfers a duplicate of the exact locked open-file description to child descriptor
**9** only when explicitly requested by `CommandSpec.runtimeLeaseFileDescriptor`. Ordinary child
processes do not inherit it (`CLOEXEC`). Duplicates must not collide with stdio/output pipe setup;
invalid descriptors fail rather than silently launching without the lease.

The installer accepts an explicitly inherited descriptor via `BYORI_RUNTIME_LEASE_FD=9` only
after validating its regular-file identity against the selected lock path, current user, mode,
link count and successful nonblocking flock on that same open description. Otherwise it opens
its own descriptor 9 without truncation and acquires the same lock. The flag alone never bypasses
ownership. It remains alive in the invoking shell for the complete mutation. Descriptor 9 also
survives the app's download pipe; stdin is not used to transport the lease. Release closes a
descriptor without `LOCK_UN`, so a child's exit does not unlock its parent's verification work.
The standalone installer's long-lived background engine receives neither FD 9 nor its flag.

Root/lock preflight occurs before version probing, download, service commands or runtime file
replacement. Creating an absent private runtime root/lock is the sole permitted pre-lease write.
Tests use temporary homes and fake service/download commands, never the user's installation.
Legacy installers without this protocol cannot cooperate; do not claim protection against them,
an arbitrary same-user writer, or raw manual launchctl/systemctl commands.

## Recovery boundary

The app's runtime snapshot and restore must include `engine.json` with `bin`, MCP, env and the
launchd configuration. Validate the complete snapshot before removing or replacing any live
destination. Revalidate the entire byte/mode inventory and data boundary after the awaited stop
operation. Require an absent launchd job and unoccupied configured engine ports before replacement;
a successful bootout request alone is insufficient. A missing/corrupt snapshot is a recovery error,
not a partially restored success.
This is runtime preservation, not an engine-data backup. Data, logs and project originals are
outside rollback deletion targets.

If an engine replacement may have opened existing/new data, an old executable alone is not a
safe rollback. Without a validated consistent data backup or explicit compatibility guarantee,
refuse that rollback, retain the runtime snapshot, and report recovery required; do not silently
run the previous engine on possibly migrated data. Same-engine asset restoration remains possible.

App-driven runtime installation must not mutate user agent profiles or hooks: explicit per-host
connection remains a separate reviewed action. Standalone installer defaults remain documented
and compatible. Atomic engine-manifest replacement prevents a torn identity file.

## Evidence required

- Real OS lock contention between processes; release after exit; unsafe path/file rejection.
- Real runner descriptor transfer and cancellation; an absent/invalid inherited FD cannot bypass.
- Real installer fixture stops before download or service mutation when busy.
- Native install/start/stop/restart are covered, including actor reentrancy and rollback duration.
- Manifest and runtime bytes restore together on safe failure; incomplete snapshots and potentially
  migrated data fail without destructive rollback. No-op/read-only status does not acquire a writer.
- Existing installer flags, command runner behavior, core strict-concurrency build and regression
  suites remain compatible. Full data restoration, unified installer rollback and signed bundles
remain separately unpassed until exercised at their actual scope.

## Verification isolation

Temporary HOME does not isolate launchd's actual-UID domain. A self-test previously used the real
command runner and standard service label in an installer-cancellation fixture; it could stop the
developer's actual engine. The [diagnosis](local-engine-diagnosis-2026-09-12.md) records the matching
execution/shutdown timing and attribution limit. That fixture now has a unique test label and a
deny-by-default command runner permitting only its exact synthetic installer. Service/listener
commands are stubbed. No live service test is implied by this coverage.
