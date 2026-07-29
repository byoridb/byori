**English** | [한국어](ko/install.md)

# Byori — Installation and Management

Install a local ByoriDB instance as **persistent memory** for Claude Code and MCP clients.
The installer sets up the database server, MCP server, and skill together. If the
`claude` or `codex` CLI is available, it also registers the MCP server and installs
the skill automatically (use `--no-claude` or `--no-codex` to skip either integration).

## One-line install

```sh
curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
```

> Supports macOS (Apple Silicon and Intel) and Linux x86_64. Windows is not supported.
> Requirements: `curl`, `tar`, and `python3` (to run the MCP server). If the Claude
> Code CLI is installed, the installer registers the MCP server automatically.

## What gets installed

| Component | Location | Purpose |
|---|---|---|
| `byoridb-server` (+`byoridb-cli`) | `~/.byoridb/bin/` | Local ByoriDB (gRPC 9669 / HTTP 19669, bound to `127.0.0.1`) |
| `byoridb_mcp.py` | `~/.byoridb/` | Exposes compatibility note tools plus validated typed-wiki CRUD, export, and read-only query tools over stdio. The default `legacy` profile also exposes unrestricted `memory_query`. On startup, it bootstraps and migrates the configured space to schema v2 (`note`/`rel` + typed wiki) |
| Persistent service | launchd `com.byoridb.local` (macOS) / systemd --user (Linux) | launchd uses `RunAtLoad` + `KeepAlive`; the systemd user unit is attached to `default.target` and uses `Restart=always` |
| `env` | `~/.byoridb/env` (chmod 600) | Randomly generated root password |
| Skill | `~/.claude/skills/byoridb-memory/SKILL.md` | Policy for what to remember, when to remember it, and when to recall it |
| Data | `~/.byoridb/data/` | redb files (local only) |

## Options

```sh
install.sh [--with-hooks] [--tag vX.Y.Z] [--engine-tag vX.Y.Z] [--uninstall]
           [--binary PATH] [--assets DIR] [--no-service] [--no-claude] [--no-codex]
```

- `--with-hooks` — adds checkpoint reminder hooks to `~/.claude/settings.json`
  (disabled by default). It appends to the existing `SessionStart`/`PreToolUse`
  arrays and skips hooks that are already present, so reruns are idempotent. Before
  changing the file, it creates a `settings.json.bak.<timestamp>` backup. Requires `jq`.
- `--tag` — pins the version of Byori assets (MCP, skill, and templates). The default
  is the latest Byori release.
- `--engine-tag` — overrides the ByoriDB engine release. The default is the pinned
  engine version verified with this Byori release.
- `--uninstall` — stops and unregisters the service, unregisters the Claude/Codex
  MCP integration, and removes the skill. **You are prompted to keep or delete the data.**
- `--binary PATH` — uses a local `byoridb-server` binary instead of downloading one.
- `--assets DIR` — reads mcp.py, templates, and the skill from a local repository
  checkout (`DIR`) instead of downloading them.
- `--no-service` — runs a background process for the current session without
  registering a launchd/systemd service.
- `--no-claude` — skips Claude MCP registration and skill and hook installation.
- `--no-codex` — skips Codex MCP registration and skill installation.

Installer environment variables: `BYORIDB_HOME` (default: `~/.byoridb`),
`BYORIDB_HTTP_PORT` (default: 19669), `BYORIDB_GRAPH_PORT` (default: 9669),
`BYORIDB_LABEL` (default: `com.byoridb.local`), and `BYORI_ENGINE_TAG` (default: the
pinned compatible engine tag).
For an isolated test:
`BYORIDB_HOME=/tmp/bt BYORIDB_HTTP_PORT=29669 BYORIDB_GRAPH_PORT=29670 ./install.sh --binary … --assets …`

## MCP profiles and memory spaces

The automatically registered Claude and Codex integrations do not set a profile, so they use
`BYORIDB_MCP_PROFILE=legacy`. This exposes all nine tools, including the unrestricted raw-nGQL
`memory_query`, for backward compatibility. `BYORIDB_MCP_PROFILE=safe` removes that one tool from
both discovery and dispatch; it is a reduced raw-query surface, **not a read-only server**.
`memory_remember`, `memory_wiki_upsert`, `memory_link`, and `memory_delete` can still write.

`BYORIDB_MEMORY_SPACE` selects the logical memory namespace (default: `claude_memory`) and must
match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. It prevents accidental project mixing, but all spaces use
the same engine credential, so it is not an authorization or tenant boundary. Use separate
instances and credentials across trust domains.

Pass both variables in each MCP client's process configuration. Do not persist them by editing
`~/.byoridb/env`: on reinstall or upgrade the installer rewrites that file and preserves only
`BYORIDB_ROOT_PASSWORD`.

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
server and installs the skill under `~/.agents/skills/`. `--uninstall` removes both,
and `--no-codex` skips them. Restart Codex, then verify the connection with
`codex mcp list`. Claude hooks are not installed for Codex.

If you used `--no-codex` or want to connect Codex later, register it manually:

```sh
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.agents/skills/byoridb-memory"
cp "$HOME/.claude/skills/byoridb-memory/SKILL.md" \
  "$HOME/.agents/skills/byoridb-memory/SKILL.md"
codex mcp list
```

To remove the manual integration:

```sh
codex mcp remove byoridb
rm -rf "$HOME/.agents/skills/byoridb-memory"
```

## Connecting NaraeClaw or another manual MCP host

The installer and Manager currently configure only Claude Code and Codex. They do not know a
NaraeClaw-specific configuration format or skill directory. In a compatible host's MCP process
configuration, use the installed runner as follows, then install the reference policy at
`adapters/naraeclaw/skills/byoridb-memory/SKILL.md` through that host's documented mechanism:

```sh
env BYORIDB_MCP_PROFILE=safe \
  BYORIDB_MEMORY_SPACE=my_project \
  "$HOME/.byoridb/bin/run-mcp.sh"
```

No NaraeClaw hook is bundled. A process-specific space is also invisible to the current Manager,
which displays only the space from its own environment. When testing the source tree before a
release contains these tools, first install it with `./install.sh --assets .`.

## Limitations

- The MCP server provides actual data tools, not reminders. The `byoridb-memory` skill
  defines **whether and what to remember**.
- `safe` blocks only unrestricted raw nGQL. Treat structured delete/link operations as writes and
  require the same user-intent checks you would use in `legacy`.
- Schema bootstrap (v2: `note`/`rel` + typed wiki) is an additive migration. Check the
  applied version in the `byori:schema-version` note.
- `memory_export` is a bounded inspection API, not a transactional backup snapshot; deep pages
  can shift even without concurrent writes and should not be used as a complete restore source.
- Hooks do not capture data directly; they remind the agent to create a checkpoint.
- The current/history dual write is not atomic, and writing again within the same
  millisecond can collide with a history key (a bitemporal v1 limitation).
- Byori is intended for a local single node. It is unrelated to distributed or
  production deployments.
