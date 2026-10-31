# Local engine connection diagnosis — 2026-09-12

## Observed state (KST)

The Byori application process was running, but the engine was not. The configured MCP uses
`~/.byoridb/bin/run-mcp.sh`; its installed environment points to `http://127.0.0.1:19669`.
Both a structured MCP read and a direct, proxy-bypassed health request failed with connection
refused. Neither HTTP port 19669 nor graph port 9669 had a listener. The standard
`com.byoridb.local` job was absent in GUI, user and system launchd domains. Its plist still existed.
This is not an authentication failure or a mismatched MCP endpoint.

The latest engine log ended with SIGTERM and a clean storage checkpoint/shutdown at
**2026-09-11 21:12:02 KST**. No caller identity is recorded in that server log.

## Strongly supported cause, with attribution limit

The current task's execution record contains a real command invocation of
`swift run --skip-build ByoriManagerSelfTest` at **21:11:54.095 KST**, followed by a self-test PASS
at 21:12:39.005. These are tool execution events, not a recalled narrative.

The existing cancellation fixture in `manager/macos/Sources/ByoriManagerSelfTest/main.swift`
created a temporary HOME but constructed `ManagerService` with its real command runner and the
default service label. `ManagerService` addresses launchd by the actual UID and service label,
not the fixture HOME. Its cancellation rollback consequently could execute
`launchctl bootout gui/<uid>/com.byoridb.local` against the developer's installed engine.
The relevant fixture setup predates this work (git blame: `e3981bb9`, 2026-08-07).

The exact dangerous path and the eight-second timing match make the agent's self-test the
likely cause of this shutdown. There is no retained process-level signal audit, so this is not
claimed as conclusive identification of the sender. The earlier “no live service was changed”
verification claims cannot be relied on for runs of that old self-test.

## Correction and verification

The cancellation fixture now uses a unique test service label and a deny-by-default runner.
Only the exact fixture installer may execute as a real child. All launchctl/lsof commands are
synthetic responses; unknown commands are refused. Its runtime root has the private mode now
required by the shared lease. This retains real installer cancellation/rollback coverage without
addressing an installed service. The corrected strict-concurrency self-test passed.

The newly added runtime-recovery unit tests also use recording runners and temporary homes.
Installer black-box tests use an executable allowlist, synthetic engines and network/service
stubs. Do not use temporary HOME alone as proof that a test cannot affect launchd.

No real engine was started, stopped, reinstalled or reconfigured during the initial diagnosis. The first
self-test attempt in this diagnosis failed the private-root lease check before its installer
ran; it did not reach the unsafe rollback. The later passing run used the corrected sandbox.

## Authorized service-only recovery

The user subsequently authorized **starting the existing service only**. Preflight found the
existing v0.4.13 executable intact: its SHA256 matched engine.json, strict code-signature
verification passed, and the existing data directory and private runtime root were present.
The standard job was still absent. Bootstrapping its existing LaunchAgent plist in `gui/501`
started the engine without an installer, update, credential change or data deletion.

HTTP `/health` returned 200, ports 19669/9669 listened on loopback, and this task's actual
ByoriDB MCP successfully read the stored `decision:project-handbook-compiler`. This verifies
the configured wrapper, authentication and project-space read, not just an open TCP port.
After the corrected strict-concurrency native suite (353 tests) and core self-test passed,
the engine retained the same PID and returned health 200. This post-recovery check applies
only to the corrected tests; it does not retract the earlier shutdown attribution limit.

The subsequent full Python regression also passed (641 tests, 612.306s). The engine still had
the same PID, health 200 and a successful structured project-memory read after that run. The
memory skill recorded the incident, the isolation correction and their typed relationship, with
the likely-cause qualification retained in the incident body.

## Orca is independent

The current Codex MCP configuration contains the ByoriDB wrapper, not an Orca MCP dependency.
The Byori runtime/CLI/MCP source search found no Orca dependency. Orca entered the workflow only
because the installed orchestration skill requested its coordination CLI; its automatic
coordinator was bound to an unrelated project. Orca's internal `graph: ready` status is not a
ByoriDB health check.

Per the product owner's instruction, this task no longer uses Orca coordination. Native Codex
workers are used directly. No Orca process, other project's task, global skill or user configuration
was deleted or changed. There was no Orca-to-ByoriDB connection to remove.

An app's visible “running” label is not independent proof of a live engine. The installed UI was
not captured in this diagnosis; an outdated label is a separate suspected refresh defect, not a
visually verified finding here.
