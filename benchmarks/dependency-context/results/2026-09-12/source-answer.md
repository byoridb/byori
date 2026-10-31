The policy must be endpoint-specific. Byori’s documented 403/429 contract is not fully implemented by the indexed ByoriDB HTTP handlers.

Citations below use **B = Byori `566b8b355f12e8db271e43f2e203555daccbaed5`** and **D = ByoriDB `a5c6223a4fd9346dc94860580e4bd1c95961ef5c`**.

### Query recovery

Implement this bounded sequence for the Python MCP:

1. If no local session ID exists, log in.
2. Before a normal, ready-state query, ensure the session is pinned to the configured project space. Put this pin request inside the same error-handling boundary as the query.
3. Classify a failed pin/query as recoverable only for HTTP **401**, or legacy HTTP **400 whose body contains `session`, case-insensitively**. Do not use `auth` as a recovery marker.
4. Recover once: **fresh login → `USE <configured space>` → replay the original query with the new session ID**, preserving its other payload fields.
5. If the recovery pin or replay fails, surface the error; do not recursively recover. Query **403**, ordinary **400**, and **413** must not trigger login.

This is the implemented `_raw_query` policy, including normalization of the second HTTP failure to `RuntimeError`. The bound is one recovery login and one replay per `_raw_query` invocation, not a global bootstrap bound. (`B:mcp/byoridb_mcp.py:501–525,557–617`; `B:docs/engine-contract.md:98–110`)

**Permission contradiction:** Byori describes 403/`PERMISSION_DENIED`, but D’s service returns `AuthFailed` for insufficient roles/permissions; the HTTP handler maps every non-`SessionNotFound` service error to **400/`QUERY_ERROR`**. Those denials do not remove the session, so surface them without login. The Python legacy rule correctly avoids retrying “Authentication failed: Permission denied” merely because it contains `auth`. (`D:byoridb-graph/src/service.rs:377–414`; `D:byoridb-graph/src/server.rs:396–407`)

### Pinning and bootstrap exceptions

An exact standalone `USE` and a leading `CREATE SPACE` are exempt from automatic pre-pinning and recovery pinning. Bootstrap also skips ordinary pre-pinning until `ready`; it explicitly creates the space, selects it, creates schema, selects it again, and migrates. Recovery of other statements still pins even before `ready`. (`B:mcp/byoridb_mcp.py:528–531,571–615,716–727`)

Successful standalone `USE` records its selected space. Potential embedded `USE` or uncertain parsing invalidates pin knowledge before submission, so subsequent scoped statements re-pin. Readonly startup only logs in, selects the existing space, and checks schema; it must not create or migrate it. (`B:mcp/byoridb_mcp.py:534–548,584–594,678–705`)

### Failed fresh logins

Classify login failures at `_login`, separately from query failures:

- **401/403:** terminal `LoginRefused`; never retry those credentials automatically, including during recovery or bootstrap.
- **429:** `LoginThrottled`; ordinary query recovery propagates it without another login. Writer bootstrap allows at most **two waits**, each advertised wait at most **75 seconds**, sleeping `wait + 1`. Parse nonnegative numeric `Retry-After`, then body “Retry in …s”, otherwise default to **60 seconds**. Throttle waits do not consume the separate **30-attempt** startup budget. Readonly startup does not wait/retry classified login failures.

(`B:mcp/byoridb_mcp.py:420–467,686–690,706–765`; constants at `122–124`)

However, D’s login handler maps **all authentication errors to 401/`AUTH_FAILED`**, with “Invalid credentials”; it has no 429/`Retry-After` branch. Thus the client cannot distinguish lockout/throttling from bad credentials through this indexed handler. Treat that 401 as terminal; do not promise that waiting guarantees password acceptance. (`D:byoridb-graph/src/server.rs:281–313`)

### IDs and other endpoints

Preserve session IDs exactly: accept decimal strings or integer JSON values, retain the received representation when posting queries, and never round-trip through floating point. Python stores the decoded value unchanged. The engine uses custom ID serialization/deserialization; its source test asserts string responses and string/number request compatibility, but test execution was not established. (`B:docs/engine-contract.md:54–62`; `B:mcp/byoridb_mcp.py:461–467,575,602`; `D:byoridb-graph/src/server.rs:580–600,624–640`)

Do not transfer query rules indiscriminately:

- Login 401 means authentication failure, not session recovery.
- Logout uses `X-ByoriDB-Session-Id`; malformed/missing/dead bearer yields 401/`AUTH_REQUIRED`. Re-login would create a different session, not complete logout of the original.
- Diagnostics uses the same header, returns 401/`AUTH_REQUIRED` for invalid sessions and 403/`FORBIDDEN` for non-admin sessions—not query codes.
- The raw-JSON query handler shares D’s actual mapping: expired/missing session → 401/`SESSION_EXPIRED`; other service failures, including permission denial → 400/`QUERY_ERROR`.

(`D:byoridb-graph/src/server.rs:227–272,316–339,412–458`)

**Unresolved:** writer bootstrap’s broad exception retry can repeat failures beyond the per-query recovery bound. Recovery replay also lacks the first-attempt embedded-`USE` invalidation after re-pinning. These deserve review. (`B:mcp/byoridb_mcp.py:586–603,762–765`)

These conclusions concern indexed source only. They establish neither installed binary provenance nor installed/released behavior, live status responses, or passing tests.
