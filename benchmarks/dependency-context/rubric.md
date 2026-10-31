# Byori Python MCP session recovery — curated correctness rubric

Manual committed-source review for the bounded dependency-context pilot, not
product strategy, a test execution record, or a release/runtime certification.
Use the same question and these eight criteria for every evaluation arm.
Score each criterion 1 only if every stated requirement is met, otherwise 0;
record supporting citations and the specific omission/contradiction. Maximum 8.
An explicit refusal to infer unsupported runtime/version behavior is correct.

## Source bindings and citation notation

The sibling `session-recovery.json` binds five complete normal Git blobs by
SHA-256 (not hashes of excerpts). Its claims have one-based inclusive evidence
ranges, each at most 100 lines. Citation abbreviations below expand as follows:

- `mcp`: Byori `566b8b355f12e8db271e43f2e203555daccbaed5`,
  `mcp/byoridb_mcp.py`.
- `lifecycle`: the same Byori commit, `tests/test_mcp_lifecycle.py`.
- `server`: ByoriDB `a5c6223a4fd9346dc94860580e4bd1c95961ef5c`,
  `byoridb-graph/src/server.rs`.
- `service`: the same ByoriDB commit, `byoridb-graph/src/service.rs`.
- `api`: the same ByoriDB commit, `book/src/reference/api.md`.

## Eight checkable criteria

1. **Pinned query error contract, including the documentation conflict.**
   Identify `SessionNotFound -> 401 SESSION_EXPIRED` and other service errors
   `-> 400 QUERY_ERROR` (`server:396-406`). A live-session RBAC denial returns
   `AuthFailed`; a permission-check error instead returns `SessionNotFound`
   (`service:397-414`). State that `api:198-200` agrees with the server, while
   the query `403 PERMISSION_DENIED` description in `mcp:504-509` and
   `lifecycle:131-134` is not this pinned server's mapping. Do not present that
   version-labelled description as installed/released fact.

2. **Query 401 recovery order and space restoration.**
   Describe query/pin 401 -> fresh login -> `USE SPACE` -> replace session ID
   -> retry the original ordinary statement. Login clears remembered space
   (`mcp:464-467`); `_pin_space` actually posts USE (`mcp:551-554`). Include
   the initial pin inside the protected block, ready/bootstrap distinction,
   and bare USE/CREATE SPACE exceptions (`mcp:571-603`). Recognize
   `lifecycle:536-554` as a mock assertion of query -> USE -> query, not
   evidence that the sequence ran against an engine.

3. **One recovery, with terminal failures.**
   Bound recovery to one login and at most one original-query replay per
   `_raw_query` invocation. A recovery pin/replay HTTP failure, including
   another 401, becomes RuntimeError without another recovery; a failed
   recovery login propagates (`mcp:595-617`). Distinguish this from bootstrap's
   startup loop and do not promise safe/idempotent replay of arbitrary writes.
   `lifecycle:358-375` asserts conversion of a second HTTP failure to a plain
   error; it does not establish engine restart or write-replay safety.

4. **403 is never session-loss recovery.**
   Say that the client rejects every query 403, even with `session`/`auth` in
   its body, without re-login. Conversely it accepts any query-path 401
   without parsing/requiring the body code (`mcp:521-525,595-598,617`;
   `lifecycle:136-143`). Do not confuse this client classifier with the
   producer query error contract or with diagnostics' real 403 FORBIDDEN.

5. **A failed fresh login is not an expired query.**
   Identify `/api/v1/session` 401 AUTH_FAILED as the pinned server's generic
   authentication failure, not a request to re-login (`server:298-311`). The
   client classifies login 401/403 as LoginRefused (`mcp:448-460`); initial and
   recovery logins propagate refusal (`mcp:571-572,597-599`), and bootstrap
   stops rather than retrying (`mcp:734-738`; assertion `lifecycle:308-319`).
   Explain the second documentation boundary: client 403/429 support and the
   0.4.0+ throttle description in `lifecycle:174-175` do not prove those
   responses in a server whose authenticate-error branch always emits 401.
   Do not infer the underlying credential/lockout cause from generic 401.

6. **Legacy 400 fallback is narrow in status, broad in text.**
   State exactly `code == 400` and `"session" in detail.lower()`; `auth`
   alone is insufficient (`mcp:517-525,595-597`). Cite the auth-denial/syntax
   negatives and Invalid session positive in `lifecycle:145-156` as assertions
   only. Note possible false positives because this searches the whole decoded
   body, not a structured code or an exact invalid-session phrase. Older
   engine/version claims are comment intent, not independently verified here.

7. **Session-ID precision across the HTTP client boundary.**
   Explain decimal-string session output and string/integer query input
   (`server:563-565,574-584,588-600`; `api:155-158`). Preserve the string and
   avoid JavaScript Number/float rounding (`server:555-559`). Show that Python
   uses json.loads/json.dumps, retains the returned session_id, and resends it
   (`mcp:370-376,461-464,575`). Do not generalize to all graph IDs or claim
   range-safe validation: the unsigned visitor uses `v as i64`
   (`server:577-578`), so out-of-range safety is not established.

8. **Endpoint-specific behavior and evidence limits.**
   Distinguish `/query` JSON objects from `/query/json` serialized JSON text;
   both map service session loss to 401 and other errors to 400, but oversized
   `/query` is 413 QUERY_TOO_LARGE and oversized `/query/json` is a plain 413
   string (`server:350-360,383-388,417-424,438-457`; `api:203-206`). Logout/diagnostics
   use the session header and 401 AUTH_REQUIRED; diagnostics returns 403
   FORBIDDEN for a live non-admin (`server:227-240,252-270,323-337`). Do not
   extend query recovery automatically to login, logout, or diagnostics.
   Explicitly scope conclusions to manual review of both pinned commits;
   hashes and test definitions prove neither tests ran nor installed binary,
   released version, deployed compatibility, or semantic correctness.

## Serving and evaluation boundary

At curation, both repository HEADs matched the declared revisions, but the
selected Byori MCP and lifecycle test working-tree files were dirty. Their
working-tree contents are not evidence for this manifest. The real default
inspector **must return needs_review and withhold ALL claim bodies/evidence**
on these inputs; it must not serve the committed claims merely because HEAD
and blob hashes match. Preserve those files and all other collaborators' work.
This records the required boundary, not an assertion that the inspector ran.

A ready-brief evaluation can later use temporary immutable snapshots of the
exact commits with clean selected files. Recheck bindings on each inspection;
a copied brief cannot check freshness. Revision changes and selected-source
changes require review; unrelated dirty files alone do not invalidate bindings.
No relaxed dirty-source bypass, checkout cleanup, engine/process operation,
network call, API/credential action, or source-repository edit is authorized
by this benchmark. No lifecycle tests or runtime probes were run for curation.

Report actual model input/output/cached tokens only if available. File bytes,
evidence lines, characters, and approximate brief size are useful bookkeeping,
not measured tokens or token savings. Record exploration and repair work plus
curation/update cost. One run per arm is a plumbing pilot, not evidence of
superiority over maintained documentation or a completed cross-provider study.
