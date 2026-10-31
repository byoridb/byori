At these commits, use endpoint-specific, bounded recovery—not a universal “401 means log in again” rule.

Citations below use `B = byori@566b8b355f12e8db271e43f2e203555daccbaed5` and `D = byoridb@a5c6223a4fd9346dc94860580e4bd1c95961ef5c`.

### Python MCP recovery policy

1. **Establish a session and its space separately.** If the local session ID is absent, call `_login()` once. A successful login stores the returned ID unchanged and clears the known space. Before a normal scoped statement, if initialization is ready and the session is not known to be in `SPACE`, issue `USE SPACE`. Include this pin request inside the same recovery boundary as the statement: session loss may first appear on the pin. [B: `mcp/byoridb_mcp.py:448–467,557–598`]

2. **Classify query failures exactly as implemented:**
   - HTTP `401`: recover once, regardless of body.
   - HTTP `400`: recover once only when the decoded error body contains case-insensitive literal `session`.
   - HTTP `403`: surface immediately; never reauthenticate.
   - Other `400`, `413`, and other statuses: surface without session recovery.

   Do **not** use `auth` as a legacy marker: an authorization denial can contain “Authentication failed” without indicating session loss. The `session` fallback is deliberately retained for older engines. [B: `mcp/byoridb_mcp.py:501–525`; `docs/engine-contract.md:98–110`]

3. **Recovery order and bound:** original request/pin failure → one fresh login → `USE SPACE` unless the statement is self-pinning/bootstrap creation → replace the payload’s session ID → replay the original statement once, preserving `read_only`. A failed recovery pin or replay becomes `RuntimeError`; there is no recursive recovery. Thus each `_raw_query` has at most one recovery login and one replay, potentially with a pin between them. A refused fresh login terminates before pin/replay. [B: `mcp/byoridb_mcp.py:595–617`]

4. **Pinning exceptions and invalidation:** a standalone `USE` matching the implementation’s regex, or a statement beginning `CREATE SPACE`, skips automatic pinning. Before readiness, bootstrap also skips the normal pre-statement pin and explicitly orders `CREATE SPACE`, `USE`, schema creation, another `USE`, then migration. Recovery still pins non-exempt statements even during bootstrap. Successful standalone `USE` records its target. A potentially space-changing non-standalone query invalidates the cached space **before sending**, so even a partially executed failure cannot leave a falsely trusted pin. [B: `mcp/byoridb_mcp.py:528–594,600–615,715–727`]

### Fresh login failures and startup budgets

`_login()` converts login `401/403` into `LoginRefused`; `_ensure_ready()` aborts on that type, including when it originates from query recovery. Do not feed rejected credentials into the startup retry loop. Missing `session_id` is also a login failure, but currently raises generic `RuntimeError`, not `LoginRefused`. [B: `mcp/byoridb_mcp.py:448–467,734–738`]

Login `429` is separately classified as `LoginThrottled`. Writer bootstrap permits at most two throttle waits, only for windows ≤75 seconds, sleeping the reported window plus one second. Ordinary startup has 30 attempts with two-second waits; throttle waits do not consume those attempts. Readonly startup performs login, pin, and schema verification without that loop or any schema writes. Recovery itself has no throttle-wait loop. [B: `mcp/byoridb_mcp.py:122–124,420–459,678–716,739–766`]

### Reconcile the engine evidence

Byori’s contract promises query `403/PERMISSION_DENIED`, but **the indexed ByoriDB implementation does not implement that promise**. Both query handlers map only `SessionNotFound` to `401/SESSION_EXPIRED`; every other service error becomes `400/QUERY_ERROR`, agreeing with ByoriDB’s API document. Service permission denials return `AuthFailed` without removing the session; permission-check errors instead remove graph-session state and return `SessionNotFound`. Therefore ordinary permission denials at D are nonrecoverable `400`, not `403`. [B: `docs/engine-contract.md:93–106`; D: `book/src/reference/api.md:194–206`; `byoridb-graph/src/server.rs:390–407,447–457`; `byoridb-graph/src/service.rs:377–414`]

### Endpoint scope and precision

- **Login:** D maps every authentication error to `401/AUTH_FAILED`; this is not a recoverable query-session response, nor evidence of a distinct HTTP `429` throttle interface. [D: `byoridb-graph/src/server.rs:281–313`]
- **Logout:** uses the session header; invalid sessions yield `401/AUTH_REQUIRED`. MCP clears local state and handles logout best-effort, without re-login. [D: `byoridb-graph/src/server.rs:316–339`; B: `mcp/byoridb_mcp.py:479–498`]
- **Diagnostics:** invalid header/session gives `401/AUTH_REQUIRED`; insufficient administrative role gives `403/FORBIDDEN`. Query retry rules do not automatically transfer. [D: `byoridb-graph/src/server.rs:230–278`]
- **Raw `/query/json`:** shares D’s query classification, but returns JSON text errors; oversized queries return plain-text `413`, without a code. [D: `byoridb-graph/src/server.rs:412–457`]

Preserve session IDs as Python `str` or exact `int`, never float. D emits decimal strings and accepts strings/integers; Byori requires echoing the received representation for older numeric artifacts. [D: `byoridb-graph/src/server.rs:563–600`; B: `docs/engine-contract.md:58–62`]

**Unresolved:** writer bootstrap’s generic exception handler can retry surfaced query `RuntimeError`s, including permission failures; the one-recovery bound is per query call, not globally across bootstrap. These sources establish implementation and contract discrepancies—not installed-engine version, deployed behavior, release contents, throttle operation, or successful test execution. [B: `mcp/byoridb_mcp.py:617,750–766`]
