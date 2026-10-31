# Handbook host compatibility — v1

Research date: **2026-09-11**. This note records the behavior used by the v1
project-scoped connection adapter. It is a compatibility snapshot, not evidence that KC-02's
fresh-session delivery gate has passed.

**Support status: configured / startup consumption unverified.** The adapter can safely own and
remove a bounded project instruction block. It does not yet prove that a host ran the freshness
guard or received a current handbook in a new session.

## Observed versions and sources

Local, read-only checks found:

- Claude Code `2.1.266`. Its `--help` says normal sessions auto-discover `CLAUDE.md`; `--bare`
  disables that discovery and `--safe-mode` disables customizations.
- Codex CLI `0.153.4`. Its top-level `--help` exposes project selection with `--cd`, but does not
  itself document instruction-file discovery.

Official host documentation supplies the startup contract:

- [Claude Code memory documentation](https://code.claude.com/docs/en/memory) says a project-root
  `CLAUDE.md` is loaded at the start of a session. It also documents `@path` imports and says those
  imports are expanded into launch context.
- [Codex AGENTS.md documentation](https://developers.openai.com/codex/guides/agents-md)
  says Codex builds its instruction chain once per run, searches from the project root toward the
  working directory, and uses at most one instruction file per directory. At one directory,
  `AGENTS.override.md` takes precedence over `AGENTS.md`. The documented combined default limit is
  32 KiB.

No model session, credential, user profile, or global host configuration was used for this check.

Before a mutating connection creates `.byori/connections`, it invokes the compiler's output
protection gate. That gate requires a Git project, refuses already-tracked `.byori` paths and unsafe
Git exclude symlinks, and adds `/.byori/` only to the repository-local `.git/info/exclude`. It does
not edit tracked `.gitignore`. This is required because connection backups and generation evidence
can contain original source material even though connection metadata itself contains only bounded
hashes, names, timestamps, and state.

## v1 mechanism

| Host | Managed project file | Selected reference behavior | Configuration caveats |
|---|---|---|---|
| Claude Code | `CLAUDE.md` | The short managed block directs one `byori handbook sync .` request at the beginning of every project task, before substantive work. | A direct `@.byori/handbook.md` import is supported by Claude, but v1 intentionally does not use it because expansion bypasses Byori's current/stale/unavailable check. `--bare` and `--safe-mode` can disable discovery, and the `byori` CLI must be on the host's `PATH`. |
| Codex | `AGENTS.md` | The same short managed block directs one guarded startup read before substantive work. | Codex documents no Markdown import equivalent. A non-empty root `AGENTS.override.md` would hide root `AGENTS.md`, so v1 refuses a new connection in that case. Instruction-size truncation can still prevent discovery, and the `byori` CLI must be on the host's `PATH`. |

`byori handbook sync .` honors the project's existing automatic-refresh setting, which is off by
default. Enabled projects use the shared bounded coordinator; disabled projects perform the same
guarded read as `byori handbook show .`. Neither connection nor a session request enables refresh.
The API returns a body only when
`handbook_status` reports `current`; otherwise it returns no body. The generated handbook remains a
derived artifact, not a second maintained memory store. Its source excerpts are untrusted reference
data and must not be executed or treated as host instructions.

The managed block explicitly prohibits reading the raw `.byori/handbook.md` as a fallback when the
guard reports missing, stale, or unavailable, and prohibits enabling/widening refresh without the
user's request. Existing exact legacy read-only blocks remain readable and disconnectable; explicit
disconnect/reconnect adopts the new block. They are never silently upgraded. This makes the
intended startup behavior explicit without claiming the host consumed or followed it.

The connection record's `configured` status means only that Byori owns an intact, hashed block and
private backup in that repository. `startup_consumption` remains `unverified`. It does not mean the
host discovered the file, ran the guard, received a current generation, or followed the reference.

## Work still required for KC-02

The current mechanism is a managed project instruction, not a host-controlled startup hook. The
shared coordinator now handles consent, scoped validation, bounded rebuild and exclusion withholding,
but that does not prove a host discovers or executes it. The release path still needs to:

1. validate project and checkout identity at startup;
2. rebuild or explicitly report stale/unavailable before exposing handbook text;
3. prevent retracted or newly excluded material from falling back to the static file;
4. pass fresh-process tests for each supported host/version using isolated profiles and explicitly
   authorized model access; and
5. prove the expected generation and a cited constraint reached the new session, then repeat after
   a source change and explicit rebuild.

Until those tests pass, neither the presence of `CLAUDE.md`/`AGENTS.md` nor a successful connection
operation is evidence of safe automatic startup ingestion, and KC-02 must remain incomplete.

## Fresh-session smoke harness

`tests/smoke_handbook_hosts.py` is an opt-in real-host harness and is intentionally excluded from
unit-test discovery. It creates a temporary Git repository containing random synthetic text only,
builds generation A, connects the selected hosts, and starts one new non-persistent session per
host. The neutral task asks for the generation and constraint available from startup context; it
does not name the handbook or recall command. The harness also requires host event output to show
an actual `byori handbook sync .` invocation (with refresh disabled in the current read-only smoke). It then edits the synthetic source, builds generation
B, and repeats with one more fresh session. A successful run makes exactly two model calls per
selected host; a failed run stops immediately, so the hard limit remains two. There are no retries,
no background jobs, and no real project source. Failure output records the number of host-call
attempts and any model/cost metadata emitted before the failure.

Safety harness flags preserve normal safety boundaries:

- Codex uses `exec --ephemeral --ignore-user-config`, a read-only sandbox, and an
  approval policy that cannot escalate. Authentication must live in the supplied test
  `CODEX_HOME`; ambient API-key variables are removed.
- Claude uses `--no-session-persistence`, project-only setting sources, an empty strict MCP set,
  and only the explicitly allowed `Bash(byori handbook sync .)` tool. It does not use `--bare`,
  `--safe-mode`, or bypass-permission flags because those would either disable `CLAUDE.md` or evade
  the behavior under test. Ambient API-key variables and normal AWS credential paths are removed.
- Both host processes receive a temporary `HOME` and temporary XDG paths, preventing fallback to
  normal per-user files. AWS environment credentials and container/instance metadata discovery are
  also disabled; a Claude Bedrock test can use only the dedicated AWS files named below.
- Both profiles must be real private directories outside the normal profile trees, must contain a regular marker named
  `.byori-handbook-smoke-profile` with the exact body `Byori handbook host smoke profile v1`, and
  cannot be the normal `~/.codex` or `~/.claude` directory. Codex additionally requires a private
  profile-local `auth.json`. The harness never reads or copies credential contents.

The isolation choices follow official documentation: Codex supports
[`--ephemeral` and `--ignore-user-config`](https://learn.chatgpt.com/docs/non-interactive-mode),
while Claude documents [`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars) and
[`--no-session-persistence`](https://code.claude.com/docs/en/sessions). Claude's project-only
setting source still loads the project `CLAUDE.md`, as described in its
[system-prompt documentation](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts).

### 2026-09-11 preflight result

The installed CLIs are Codex `0.153.4` and Claude Code `2.1.266`. Read-only checks found the normal
Codex installation logged in through ChatGPT with eligible account usage, and the normal Claude
installation logged in through a third-party Bedrock provider. Blank temporary profiles were not
authenticated for either host. No model call was made, no model name was tested, and model cost was
zero. The normal profiles were not reused because doing so would mix the test with user instructions
or provider configuration.

The exact remaining prerequisite is to provision separate private profile directories, add the
marker above, and authenticate each profile deliberately. For Codex, log in with `CODEX_HOME` set
to the test directory and verify that it creates a private profile-local `auth.json`. For Claude,
log in with `CLAUDE_CONFIG_DIR` set to the test directory. A Bedrock test must use dedicated AWS
configuration and credentials under that test directory's `aws/` subdirectory; do not copy a normal
credential file without separate authorization.

After that explicit setup, run:

```sh
python3 tests/smoke_handbook_hosts.py \
  --run-models --confirm-isolated-auth \
  --codex-home /path/to/private-test-codex-profile \
  --claude-config-dir /path/to/private-test-claude-profile \
  --codex-model exact-authorized-model \
  --claude-model exact-authorized-model
```

The report distinguishes requested and host-reported model names and records monetary cost only
when the CLI reports it. A successful harness run is narrow compatibility evidence, not sufficient
on its own to mark KC-02 complete.
