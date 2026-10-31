Source scope: Byori `566b8b355f12e8db271e43f2e203555daccbaed5` (“B”) and ByoriDB `a5c6223a4fd9346dc94860580e4bd1c95961ef5c` (“D”). Citations below use these commit aliases.

### Query recovery policy

Implement the existing Python policy as a bounded operation:

1. If the local session ID is absent, log in first. Store the returned ID unchanged; successful login clears remembered space.
2. For an ordinary statement, when bootstrap is ready and the session is not known to be in the configured space, send `USE <space>` before the statement. Include this pin request inside the same error-handling boundary.
3. Classify the first query-or-pin HTTP failure:
   - Any `401`: session-loss recovery, regardless of body code.
   - `400`: recover only if the decoded entire body contains `session`, case-insensitively.
   - Every `403`, and other failures: surface the error without re-login. `auth` alone is not a recovery marker.
4. Recover once: **login → `USE <space>` → replace the original payload’s `session_id` → replay the original statement**. Preserve its other fields.
5. Do not recurse. A recovery pin/replay HTTP failure—including another `401`—becomes `RuntimeError`; a failed recovery login propagates. The bound is one recovery login and at most one original-statement replay per `_raw_query`, in addition to a possible initial login. This does not establish safe replay of arbitrary writes.

[B:mcp/byoridb_mcp.py:448–467, 501–525, 551–617]

Self-pinning exceptions are a standalone `USE` matching the client’s identifier regex, and statements matching its `CREATE SPACE` prefix. They skip automatic pinning, including the recovery pin. Bootstrap skips the initial automatic pin until ready and explicitly sequences `CREATE SPACE`, `USE`, schema creation, another `USE`, and migration. Ordinary recovery still pins even before readiness. Successful standalone `USE` records its target; potentially redirecting compound statements invalidate remembered space before submission.

[B:mcp/byoridb_mcp.py:528–548, 565–615, 716–727]

### Permission failures: reconcile the contradiction

Byori’s contract and MCP docstring claim query `403 PERMISSION_DENIED`. **That is not the pinned server implementation.** Both query handlers map `SessionNotFound` to `401 SESSION_EXPIRED` and all other service errors to `400 QUERY_ERROR`. ByoriDB’s API table explicitly includes authorization failures under `400`.

[D:byoridb-graph/src/server.rs:396–406, 448–457; D:book/src/reference/api.md:194–205; B:docs/engine-contract.md:93–110; B:mcp/byoridb_mcp.py:504–519]

Missing auth roles or graph session state produce `SessionNotFound`; permission-check errors remove graph session state and produce the same error. A live permission denial instead produces `AuthFailed`, hence `400 QUERY_ERROR`, not query `403`. Therefore, surface live permission denials without re-authentication unless the legacy substring heuristic accidentally matches. That heuristic is not structured error classification and can misclassify unrelated bodies. Claims about older releases remain compatibility intent, not independently verified behavior.

[D:byoridb-graph/src/service.rs:210–222, 397–414; B:mcp/byoridb_mcp.py:517–525]

### Failed fresh login

Do not apply query-`401` recovery to login. Python converts login `401`/`403` into `LoginRefused`; initial or recovery refusal propagates, and writer bootstrap clears the local ID and stops. Login `429` becomes `LoginThrottled`, not immediate query recovery. Writer bootstrap separately permits two throttle waits, refusing waits above 75 seconds, alongside its 30-attempt startup budget.

[B:mcp/byoridb_mcp.py:122–124, 448–460, 571–572, 597–599, 706–749]

The pinned server maps **every authentication error** to generic `401 AUTH_FAILED` with “Invalid credentials.” This cannot distinguish wrong credentials, disabled/locked accounts, or other authentication failures. Client handling of `403`/`429` does not prove this server emits them.

[D:byoridb-graph/src/server.rs:298–311]

### ID precision and endpoint boundaries

Preserve decimal-string session IDs through JSON decoding, storage, payload replacement, and header construction; never convert through floating point or JavaScript `Number`. Server output serializes `i64` as strings; query input accepts strings and integers. Python uses `json.loads`/`json.dumps` and stores the returned value unchanged. However, the server’s unsigned-number visitor casts `u64` to `i64`; these sources do not establish robust out-of-range validation.

[D:byoridb-graph/src/server.rs:563–600; B:mcp/byoridb_mcp.py:370–376, 461–464, 575–603]

`/api/v1/query/json` shares query execution and `401`/`400` mapping, so the query classification can transfer, with endpoint-specific response parsing. Its errors are JSON text; oversized queries return a plain-string `413`, unlike `/query`’s JSON `413 QUERY_TOO_LARGE`.

[D:byoridb-graph/src/server.rs:350–360, 412–457]

Logout/diagnostics do not inherit query recovery: header authentication uses `401 AUTH_REQUIRED`; diagnostics denies live non-admins with `403 FORBIDDEN`. Python logout clears local state and handles failures best-effort without login.

[D:byoridb-graph/src/server.rs:227–270, 323–337; B:mcp/byoridb_mcp.py:471–498]

Unresolved: documentation/server drift and deployed compatibility. These are committed-source conclusions only. The lifecycle test asserts query → pin → replay, but was not executed here. Nothing inspected identifies the installed engine, proves release inclusion, or certifies runtime behavior.

[B:tests/test_mcp_lifecycle.py:536–554]
