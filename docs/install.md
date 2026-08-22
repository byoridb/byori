**English** | [한국어](ko/install.md)

# Byori — Installation and Management

Install the local runtime that gives Byori projects a **shared durable knowledge graph** across
Claude Code, Codex, and other MCP-capable sessions. The installer sets up the database server,
MCP server, compatibility multi-CLI coordinator, and Byori Skills together.
If the
`claude` or `codex` CLI is available, it also registers the MCP server and installs
the skills automatically (use `--no-claude` or `--no-codex` to skip either integration).

## One-line install

```sh
curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
```

> Supports macOS (Apple Silicon and Intel) and Linux x86_64. Windows is not supported.
> Requirements: `curl`, `tar`, and `python3` (to run the MCP server). If the Claude
> Code CLI is installed, the installer registers the MCP server automatically.

## Byori macOS app

The shell installer installs ByoriDB, MCP assets, and the compatibility CLI; it does
not copy an app into `/Applications`. Install the app from the
[latest release](https://github.com/byoridb/byori/releases/latest): open
`Byori-<version>-universal.dmg` and drag **Byori** into Applications. That DMG is signed
with a Developer ID Application certificate, notarized by Apple, and stapled, so it opens
without a Gatekeeper exception; one universal build covers Apple Silicon and Intel and
requires macOS 13 or later. Afterwards the app installs its own updates from
**Settings → Setup Overview**, verifying each release's signature and notarization first.

ByoriDB can also be installed from the app itself, in **Settings → ByoriDB**, which uses the
assets bundled in the app and downloads a compatible engine release.

A repository build writes the same public artifacts to `dist/Byori.app` and
`dist/Byori-<version>-<arch>.dmg`; the app bundle executable is `Byori`.

The app's main workspace follows **Project → Source Tree/Worktree → Task → Session**.
The user chooses one coding agent and model for each session. Settings supports agent,
Skill, MCP, ByoriDB, and diagnostic administration; it is not the primary workspace.
All source trees/worktrees, tasks, sessions, and agent choices in one project share that
project's ByoriDB knowledge graph through the Context inspector.

## What gets installed

| Component | Location | Purpose |
|---|---|---|
| `byoridb-server` (+`byoridb-cli`) | `~/.byoridb/bin/` | Local ByoriDB (gRPC 9669 / HTTP 19669, bound to `127.0.0.1`) |
| `byori` + `byori.py` | `~/.byoridb/bin/` | Dependency-free coordinator for provider discovery, trusted project registration, parallel Claude/Codex runs, and local run inspection. The installer does not add this directory to `PATH` |
| `byoridb_mcp.py` | `~/.byoridb/` | Exposes compatibility note tools plus validated typed-wiki CRUD, export, and read-only query tools over stdio. The default `safe` profile omits unrestricted `memory_query`. Writer profiles bootstrap and migrate the configured space to schema v2 (`note`/`rel` + typed wiki); `readonly` only validates that version |
| Persistent service | launchd `com.byoridb.local` (macOS) / systemd --user (Linux) | launchd uses `RunAtLoad` + `KeepAlive`; the systemd user unit is attached to `default.target` and uses `Restart=always` |
| `env` | `~/.byoridb/env` (chmod 600) | Randomly generated root password |
| Memory Skill | `~/.claude/skills/byoridb-memory/SKILL.md` | Policy for what to remember, when to remember it, and when to recall it |
| Design Skill | `~/.claude/skills/byori-design/` | Product and UX/UI continuity across repository artifacts and Byori memory |
| Data | `~/.byoridb/data/` | redb files (local only) |

## Options

```sh
install.sh [--no-hooks] [--tag vX.Y.Z] [--engine-tag vX.Y.Z|latest] [--uninstall]
           [--binary PATH] [--assets DIR] [--no-service] [--no-claude] [--no-codex]
```

- `--no-hooks` — skips the checkpoint hooks in `~/.claude/settings.json`. **They are
  installed by default**: a memory an agent has to remember to look for loses to one
  already in its context, and every host that ships a file-based memory loads that
  index automatically. Without the hooks the graph stays connected and empty.
  The merge appends to the existing `SessionStart`/`PreToolUse` arrays and skips hooks
  that are already present, so reruns are idempotent; before changing the file it
  creates a `settings.json.bak.<timestamp>` backup. Requires `jq`.
  Its own axis: `--no-claude` skips MCP registration and skills, not the hooks,
  because the app-driven install passes `--no-claude` and its users are the ones who
  need the reminder. Pass both to leave `~/.claude` untouched.
- `--tag` — pins the version of Byori assets (MCP, skill, and templates). The default
  is the latest Byori release.
- `--engine-tag` — which ByoriDB engine release to install. The default is the pinned
  engine version verified with this Byori release. Pass `latest` to resolve the newest
  engine release instead, which is what the macOS app's install button does; when that
  lookup fails — no network, or a GitHub API rate limit — the pinned version is installed
  and the run says so.
- `--uninstall` — stops and unregisters the service, unregisters the Claude/Codex
  MCP integration, and removes both Byori skills. **You are prompted to keep or delete the data.**
  Orchestration records and worktrees under `~/.byori` are preserved because they may contain
  unmerged user changes.
- `--binary PATH` — uses a local `byoridb-server` binary instead of downloading one.
- `--assets DIR` — reads the CLI, mcp.py, templates, and the skills from a local repository
  checkout (`DIR`) instead of downloading them.
- `--no-service` — runs a background process for the current session without
  registering a launchd/systemd service.
- `--no-claude` — skips Claude MCP registration and skills and hook installation.
- `--no-codex` — skips Codex MCP registration and skills installation.

Installer environment variables: `BYORIDB_HOME` (default: `~/.byoridb`),
`BYORIDB_HTTP_PORT` (default: 19669), `BYORIDB_GRAPH_PORT` (default: 9669),
`BYORIDB_LABEL` (default: `com.byoridb.local`), and `BYORI_ENGINE_TAG` (default: the
pinned compatible engine tag; accepts `latest` as well).
Reinstallation preserves either the current `BYORIDB_ROOT_PASSWORD` or the legacy
`BYORIDB_PASSWORD` value. Completion requires authenticated session creation with that
credential; an unauthenticated `/health` response alone is not accepted because a stale
ByoriDB process may already own the port.
For an isolated test:
`BYORIDB_HOME=/tmp/bt BYORIDB_HTTP_PORT=29669 BYORIDB_GRAPH_PORT=29670 ./install.sh --binary … --assets …`

## Foreground multi-CLI compatibility path

The installer deliberately does not create a global symlink. Add its bin directory to the current
shell or invoke the full path:

```sh
export PATH="$HOME/.byoridb/bin:$PATH"
byori provider list

cd /path/to/a/git/repository
byori project add .
byori run --agent claude --agent codex "implement the requested change"
byori runs list
```

This early `byori run` coordinator is a separate prototype and compatibility path; it can fan
one prompt out to multiple workers and does not define the macOS app's session model. Git is
additionally required for orchestration. The MVP supports Claude Code and Codex and uses
every installed supported provider when `--agent` is omitted. `byori project add . [--space SPACE]`
is the explicit trust boundary for noninteractive workers. The default run mode rejects a dirty
repository, creates a branch and managed worktree for each worker, and leaves every result in place
without merging or deleting it. A single worker may opt into the current working tree, including
existing changes, with `--in-place`.

Operational JSON, the raw prompt, provider logs, advisory locks, and worktrees live under
`BYORI_HOME` (default `~/.byori`). Only bounded recall context and coordinator-owned project/task
checkpoints cross the ByoriDB boundary. Use `--no-memory` to skip coordinator recall injection and
checkpoints; workers still receive the project space and `readonly` profile so a globally
registered MCP cannot fall back to `legacy`. See
[multi-CLI orchestration](orchestration.md) for the command surface, `--allow-shell`, timeouts,
run inspection, data locations, and security model.

## MCP profiles and memory spaces

The installer writes `BYORIDB_MCP_PROFILE=safe` for automatically registered Claude and Codex
integrations. This removes the unrestricted raw-nGQL `memory_query` tool from both discovery and
dispatch. An existing user can explicitly opt into `BYORIDB_MCP_PROFILE=legacy` for compatibility,
but that grants the connected agent unrestricted queries. The safe profile is a reduced raw-query
surface, **not a read-only server**.
`memory_remember`, `memory_wiki_upsert`, `memory_link`, and `memory_delete` can still write.
`BYORIDB_MCP_PROFILE=readonly` exposes only `memory_recall`, `memory_query_read`, `memory_read`,
and `memory_export`; the orchestrator gives this profile to workers and keeps writes in the
coordinator.

Profiles filter MCP tools; they are not authorization boundaries or process sandboxes. A
`readonly` process performs only login, `USE <space>`, and a schema-version read during startup,
and fails if a writer has not already prepared the space at the current version. It still has the
configured engine credential. Use separate instances and credentials across trust domains.

`BYORIDB_MEMORY_SPACE` overrides the logical memory namespace and must match
`^[A-Za-z_][A-Za-z0-9_]{0,63}$`. Unset, the server resolves the space from the project — see
[Memory space](#memory-space). All spaces use the same engine credential, so a space keeps projects
from mixing but is not an authorization or tenant boundary. Use separate instances and credentials
across trust domains.

Pass both variables in each separately configured MCP client's process configuration. The default
installer persists the safe profile in `~/.byoridb/env`; on reinstall or upgrade it rewrites that
file, preserves only `BYORIDB_ROOT_PASSWORD`, and restores the safe default. It deliberately does
not write `BYORIDB_MEMORY_SPACE` there: one value in a file shared by every project is how memory
stopped being per project in the first place.

### Memory space

A memory space belongs to a project, and every component resolves it the same way:

1. **`BYORIDB_MEMORY_SPACE`**, when set — an explicit override. The macOS app passes the selected
   project's space this way, so a session it launches in a task worktree needs no discovery.
2. **The project registry** (`~/.byori/projects.json`), keyed by canonical project root. A
   registered project keeps the name it already has, including names assigned before they were
   derived.
3. **Derived from the project root**, when the project is not registered.

There is no shared default. A directory nobody registered gets its own space rather than a bucket
shared with every other project. Before this, only the macOS app passed a space and everything else
fell back to a single `claude_memory` space, so which project's memory a session saw depended on
which launcher started it.

The project directory is `CLAUDE_PROJECT_DIR` when the host exports it, otherwise the working
directory. A linked Git worktree resolves to its **main** worktree: byori runs tasks in worktrees of
one project, and a space per checkout would scatter that project's memory across every task it ever
ran. A worktree explicitly registered as a project in its own right still wins.

The derived name is `byori_<slug>_<digest>`:

- `<slug>`: the root's directory name, lowercased, with runs of non-alphanumerics collapsed to `_`,
  leading and trailing `_` removed, `p_` prefixed when it does not start with a letter, cut to 36
  characters, then trailing `_` removed again. A name with nothing ASCII-alphanumeric becomes
  `project`.
- `<digest>`: the first 8 hex characters of `sha256(<canonical root path>)`.

It is derived from the path rather than from the project's id so any component can recompute it from
the repository alone — losing `~/.byori/projects.json` must not orphan a project's memory. Because
of that, moving a repository changes its derived name; register the project (or pass the space
explicitly) if you need the name to survive a move. Registering a second project whose derived name
collides with an existing one is refused rather than silently merging two projects' graphs.

One spec, three implementations: `_memory_space_for_root` in `mcp/byoridb_mcp.py`,
`memory_space_for_root` in `cli/byori.py`, and `defaultMemorySpace` in the macOS app's
`WorkspacePersistence.swift`. The same vectors are asserted in `tests/test_memory_space.py` and
`WorkspacePersistenceTests.swift`.

#### Memories written before spaces were per project

Sessions that predate this all wrote into one `claude_memory` space, which therefore holds several
unrelated projects side by side. That data is intact but is not read from a project space, and it is
not migrated automatically: deciding which rows belong to which project is a judgement call. When
the space still exists, the MCP server says so on startup. Copy what belongs to a project with:

```sh
# what would move
scripts/migrate-legacy-memory.py --name-prefix module:my-project

# move it, into the space resolved for the current project
scripts/migrate-legacy-memory.py --name-prefix module:my-project --apply
```

The source space is never modified — rows are copied, not moved. The destination must already
exist: start an agent session in the project once and its MCP server bootstraps it.

### MCP server lifetime

The server exits when stdin closes, which is the normal signal that its host is gone, and on
`SIGTERM` or `SIGHUP` — each logging why it exited. On the way out it signs out of ByoriDB with
`DELETE /api/v1/session` rather than leaving the session for its 24-hour TTL. The exit line names
the session and the outcome, so a session that does outlive its process — an engine that was
already gone, or one older than 0.4.0 without that route — stays traceable to the process that
held it.

Some hosts keep a server's stdin open for the lifetime of the host process rather than for the
conversation that needed it, which leaves servers resident with a live parent. Set
`BYORIDB_MCP_IDLE_TIMEOUT` to a number of seconds (minimum 60) to have such a server exit after
that much inactivity. It is unset by default: a host is free to keep an idle server open, and
exiting under one that still expects it would be reported as a failed MCP server rather than as
the reclaimed process it is.

## Management

```sh
curl -s localhost:19669/health          # Status
claude mcp list                         # Verify that byoridb is ✔ Connected
tail -f ~/.byoridb/logs/server.err      # Logs
# Stop/start on macOS
launchctl unload -w ~/Library/LaunchAgents/com.byoridb.local.plist
launchctl load -w ~/Library/LaunchAgents/com.byoridb.local.plist
# Linux (when using the default BYORIDB_LABEL)
systemctl --user stop com.byoridb.local.service
systemctl --user start com.byoridb.local.service
```

## Connecting Codex

When the installer detects the `codex` CLI, it automatically registers the stdio MCP
server and installs both Byori skills under `~/.agents/skills/`. `--uninstall` removes
the MCP registration and skills, and `--no-codex` skips them. Restart Codex, then verify the connection with
`codex mcp list`. Claude hooks are not installed for Codex.

If you used `--no-codex` or want to connect Codex later, register it manually:

```sh
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.agents/skills/byoridb-memory"
cp "$HOME/.claude/skills/byoridb-memory/SKILL.md" \
  "$HOME/.agents/skills/byoridb-memory/SKILL.md"
mkdir -p "$HOME/.agents/skills/byori-design"
cp -R "$HOME/.claude/skills/byori-design/." \
  "$HOME/.agents/skills/byori-design/"
codex mcp list
```

To remove the manual integration:

```sh
codex mcp remove byoridb
rm -rf "$HOME/.agents/skills/byoridb-memory" "$HOME/.agents/skills/byori-design"
```

## Connecting NaraeClaw or another manual MCP host

The installer and Byori macOS app currently configure only Claude Code and Codex. They do not know a
NaraeClaw-specific configuration format or skill directory. In a compatible host's MCP process
configuration, use the installed runner as follows, then install the reference policy at
`adapters/naraeclaw/skills/byoridb-memory/SKILL.md` through that host's documented mechanism:

```sh
env BYORIDB_MCP_PROFILE=safe \
  BYORIDB_MEMORY_SPACE=my_project \
  "$HOME/.byoridb/bin/run-mcp.sh"
```

No NaraeClaw hook is bundled. A space configured only in another host is not automatically
discovered by the Byori macOS app; its Context inspector uses the selected registered project's
ByoriDB space. When testing the source tree before a release contains these tools, first install
it with `./install.sh --assets .`.

## Limitations

- The MCP server provides actual data tools, not reminders. The `byoridb-memory` skill
  defines **whether and what to remember**; `byori-design` coordinates product/design work
  but does not replace repository artifacts.
- `safe` blocks only unrestricted raw nGQL. Treat structured delete/link operations as writes and
  require the same user-intent checks you would use in `legacy`.
- `readonly` blocks mutation tools but is not an authentication sandbox. Its startup schema check
  is read-only and fails fast instead of bootstrapping or migrating a stale space.
- Schema bootstrap (v2: `note`/`rel` + typed wiki) is an additive migration. Check the
  applied version in the `byori:schema-version` note.
- `memory_export` is a bounded inspection API, not a transactional backup snapshot; deep pages
  can shift even without concurrent writes and should not be used as a complete restore source.
- Hooks do not capture data directly; they remind the agent to create a checkpoint.
- The current/history dual write is not atomic, and writing again within the same
  millisecond can collide with a history key (a bitemporal v1 limitation).
- Byori is intended for a local single node. It is unrelated to distributed or
  production deployments.
