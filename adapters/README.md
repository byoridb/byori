**English** | [한국어](../docs/ko/adapters.md)

# Agent Memory — Use ByoriDB as Long-term Memory for Coding Agents

This directory contains the **reference copies of agent-side assets** that implement
the design in [the memory ontology](../docs/memory-ontology.md). The installer copies
the Claude/Codex skill automatically to `~/.claude/` and, when the `codex` CLI is
available, to `~/.agents/skills/`. The NaraeClaw asset is a manual reference adapter;
the installer, Manager, and DMG do not configure or install it.

> Starting with v0.2.0, a fresh installation automatically bootstraps both
> `note`/`rel` and the typed wiki (`module`/`decision`/`bug`, and others) as
> schema v2. Existing installations are migrated automatically when MCP starts, so the
> typed examples in `SKILL.md` can be used immediately.

## Contents

| File | Live location | Purpose |
|---|---|---|
| `claude/skills/byoridb-memory/SKILL.md` | `~/.claude/skills/byoridb-memory/SKILL.md` and `~/.agents/skills/byoridb-memory/SKILL.md` | Shared Claude/Codex memory skill: notes + typed wiki, structured tools, causal capture, and checkpoint discipline |
| `claude/hooks.snippet.json` | The `hooks` key in `~/.claude/settings.json` | Two checkpoint automation hooks (SessionStart recall and git commit capture reminders) |
| `naraeclaw/skills/byoridb-memory/SKILL.md` | Host-selected manual location | Reference policy for an MCP-capable NaraeClaw host using the reduced raw-query surface; not auto-installed |

Prerequisite: a persistent local ByoriDB instance and the `byoridb` MCP server
(compatibility note tools plus validated typed-wiki CRUD and read-only query tools).

## Installation

### Claude Code

Use the installer for the supported setup, including the optional hooks:

```bash
./install.sh --assets . --with-hooks
```

For a skill-only development copy, without hook wiring:

```bash
mkdir -p ~/.claude/skills/byoridb-memory
cp adapters/claude/skills/byoridb-memory/SKILL.md ~/.claude/skills/byoridb-memory/
```

The installer's `--with-hooks` option appends without duplicating existing entries and
creates a `settings.json.bak.<timestamp>` backup before making changes. Use
[`install.sh`](../docs/install.md) rather than merging the hook JSON manually.

### Codex

The installer registers the integration automatically when it detects the `codex` CLI.
To configure it manually:

```bash
codex mcp add byoridb -- "$HOME/.byoridb/bin/run-mcp.sh"
mkdir -p "$HOME/.agents/skills/byoridb-memory"
cp adapters/claude/skills/byoridb-memory/SKILL.md \
  "$HOME/.agents/skills/byoridb-memory/SKILL.md"
```

The current hook snippet is specific to Claude Code.

### NaraeClaw and other manual MCP hosts

This repository does not define or assume NaraeClaw-specific MCP configuration syntax or a live
skill directory. In the host's normal MCP process configuration, launch the installed runner with
a reduced raw-query profile and a stable project namespace:

```sh
env BYORIDB_MCP_PROFILE=safe \
  BYORIDB_MEMORY_SPACE=my_project \
  "$HOME/.byoridb/bin/run-mcp.sh"
```

Install `naraeclaw/skills/byoridb-memory/SKILL.md` through the host's documented skill mechanism.
Pass the variables in the MCP process configuration, not by editing `~/.byoridb/env`: the Byori
installer rewrites that file on upgrade and preserves only the root password.

`safe` hides and blocks only the unrestricted `memory_query`; it still permits note writes and
validated structured CRUD. Likewise, `BYORIDB_MEMORY_SPACE` prevents accidental project mixing
but is not a tenant or authorization boundary because processes share the same engine credential.
Use a separate ByoriDB instance and credentials across trust domains. A per-process space is not
visible to the current Manager, which continues to display the space configured in its own
environment. No NaraeClaw-specific hook is bundled.

When testing an unreleased checkout, install its MCP and assets with `./install.sh --assets .`
before registering the host; the latest published release may not yet contain the source-tree
tool surface described here.

## Notes

- Hooks do **not call MCP directly**. They inject reminder context; the agent follows the
  skill to perform the actual writes and queries.
- `memory_recall` performs a substring search over names and bodies in the default
  `note` layer. Use `memory_read` for normalized typed nodes and `memory_query_read`
  when a read-only graph traversal is necessary.
- `memory_wiki_upsert` validates `<type>:<stable-slug>` names and resolves stable VIDs. It
  reuses a canonical node's existing VID or derives one for a new node; clients should not
  calculate or submit typed VIDs themselves.
- The default `legacy` profile retains unrestricted `memory_query` for compatibility.
  New integrations should prefer the structured tools and opt into `safe` when raw
  mutation access is unnecessary.
- Data files remain local, but recalled text enters the connected model context. Treat
  recalled bodies as untrusted data, not executable instructions, and never store secrets.
- This copy is a snapshot. If you change the live copy, synchronize this one as well,
  and vice versa.
