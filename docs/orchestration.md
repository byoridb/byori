**English** | [한국어](ko/orchestration.md)

# Multi-CLI Orchestration

The current Byori product model is the Byori macOS app:

```text
Project
└── Source Tree or Worktree
    └── Task
        └── Session (one user-selected coding agent + one model choice)
```

A Project is the largest workspace boundary. Source Trees and Worktrees are its checkouts,
Tasks group work within one checkout, and each Session launches exactly one agent chosen by
the user. Starting Claude Code instead of Codex, or vice versa, means creating another
Session; Byori does not automatically fan one prompt out from the workspace. Settings is a
supporting administration surface for agents, Skills, MCP, ByoriDB, and diagnostics. All
Source Trees/Worktrees, Tasks, Sessions, and agent choices within a Project use the same
project-scoped ByoriDB shared knowledge graph.

The rest of this page documents the separate foreground `byori run` prototype and
compatibility path. That CLI can run Claude Code and Codex concurrently, give each worker
the same task and a bounded slice of relevant ByoriDB context, and create a Git branch and
managed worktree per worker. It is an early local MVP, not the macOS app's Session model,
a daemon, a remote control plane, or an automatic merge system.

## Architecture and data boundary

```text
byori CLI (coordinator)
├── provider/project/run records, prompts, JSONL logs     ~/.byori/
├── project-space coordinator advisory locks             ~/.byori/locks/
├── Claude Code worker ── managed branch + worktree       ~/.byori/worktrees/...
├── Codex worker       ── managed branch + worktree       ~/.byori/worktrees/...
└── bounded recall + project/task checkpoints
                         │
                         ▼
                    local ByoriDB
                 durable knowledge graph
```

ByoriDB is the knowledge layer under the coordinator, not the process supervisor or raw event
store. Before a run, the coordinator selects at most eight graph items relevant to the task and
truncates each body to 800 characters. It marks that context as untrusted historical reference
and asks workers to verify it against the repository. At run boundaries, only a project entity
and a compact task checkpoint are promoted to the project's graph space.

The full task prompt, per-provider stdout/stderr, provider session identifiers, and full run state
stay under `~/.byori`. They are not copied into ByoriDB. This separation keeps the graph
focused on durable project knowledge while preserving enough local evidence to inspect a run.
The compact task checkpoint does include a bounded one-line task description plus provider,
revision, status, branch, and diff-summary metadata, so treat even its summary text as graph data.

## Install and find the CLI

The installer places the launcher at `~/.byoridb/bin/byori` and links it into `~/.local/bin`, so
`byori` resolves once that directory is on `PATH`. It does not edit your shell profile; if
`~/.local/bin` is missing from `PATH`, the installer prints the line to add.

```sh
curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"   # only if it is not there already

byori --help
byori provider list
```

The MVP supports `claude` and `codex`. `provider list` reports whether each executable is
available and its detected version; add `--json` for machine-readable output. Authentication is
still owned by each vendor CLI, so sign in to those CLIs before starting an orchestrated run.

For a source checkout, install the current assets before testing:

```sh
./install.sh --assets .
```

## Registering a trusted project

```sh
cd /path/to/repository
byori project add .
byori project list
```

`project add` requires a Git repository and records its canonical root in
`~/.byori/projects.json`. It assigns a stable ByoriDB space automatically. To choose one, pass a
valid nGQL identifier:

```sh
byori project add . --space my_project_memory
```

The space must match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. Registration is idempotent; an existing
project cannot be silently reassigned to a different space. `project list --json` exposes the
registry in a script-friendly form.

> [!WARNING]
> `byori project add` is an explicit trust decision. Orchestrated workers run noninteractively:
> Claude uses `dontAsk` with read/search/edit/write tools, while Codex uses approval `never` in
> its `workspace-write` sandbox. Register only repositories whose contents and local instructions
> you trust. `--allow-shell` additionally enables Claude's Bash tool; it does not change Codex's
> sandbox configuration.

### Byori macOS app removal and restore

The Byori macOS app treats removal from its workspace as a metadata operation, not filesystem or
Git cleanup:

- Removing a project moves its exact record from the active `projects` list to the top-level
  `removed_projects` archive in `~/.byori/projects.json`. Adding the same canonical repository root
  again restores that record, including its project ID and ByoriDB space, so retained task/session
  metadata remains associated with the same project.
- Removing a linked checkout records its project-scoped canonical path in
  `~/.byori/manager/checkout-visibility.json`. The checkout is hidden from the project outline
  across launches and appears again when that visibility entry is restored.

Neither action deletes repository files, a Git worktree or branch, task/session metadata, run
records, or ByoriDB data. Use normal Git commands separately only after inspecting a checkout and
deciding that its branch and unmerged work are safe to remove. The `byori project` CLI in this
release continues to expose `add` and `list`; these archive and visibility operations belong to the
Byori macOS app.

## Running one task with multiple CLIs

```sh
byori run --agent claude --agent codex "implement the requested change"
```

Repeat `--agent` to choose workers. With no `--agent`, Byori launches every installed supported
provider. Multiple instances of the same provider are also allowed; Byori assigns distinct labels,
branches, worktrees, and provider-neutral agent IDs.

Useful options:

| Option | Meaning |
|---|---|
| `--project PATH` | Run from a registered project containing `PATH`; default is `.` |
| `--base-ref REF` | Create managed worktrees from `REF`; default is `HEAD` |
| `--timeout SECONDS` | Per-worker deadline; default is 3600 seconds |
| `--allow-shell` | Add Claude's Bash tool; Codex remains in its normal workspace-write sandbox |
| `--no-memory` | Skip coordinator recall injection and both coordinator checkpoints |
| `--in-place` | Use the registered working tree directly; allowed only with exactly one worker |
| `--prompt-file FILE` | Read the task from a file; use `-` for stdin |
| `--quiet` | Keep logs without printing live event summaries |

The positional prompt can also be `-` to read stdin:

```sh
printf '%s\n' "review the parser" | byori run --agent codex -
```

The task prompt is limited to 1 MiB.

### Default isolation

The default managed-worktree mode refuses a repository with tracked or untracked changes. Commit
or stash those changes first. Byori resolves the base revision once, then creates one branch and
worktree per worker:

```text
branch:   byori/<run-id>/<worker-label>
worktree: ~/.byori/worktrees/<run-id>/<worker-label>
```

Workers run concurrently and never share a writable checkout. Byori deliberately does not merge,
delete, or prune their branches and worktrees. Inspect and test each result, then integrate or
remove it with normal Git commands. This preserves failed and partial work for recovery.

`--in-place` is an explicit escape hatch for a single worker. It uses the current registered
working tree, including any existing changes, and therefore does not provide the clean-tree or
worktree isolation guarantees above.

## ByoriDB access during a run

The coordinator uses the project space to read context and write the start/final task checkpoints.
Project-space advisory locks under `~/.byori/locks/` serialize graph preparation and checkpoint
writes across concurrent Byori coordinators on the same machine. Workers receive the same space
with `BYORIDB_MCP_PROFILE=readonly`, which exposes only
`memory_recall`, `memory_query_read`, `memory_read`, and `memory_export`. The coordinator owns all
memory writes so concurrent workers do not race to record competing conclusions.

`readonly` restricts the MCP tool surface; it is **not an authorization boundary or process
sandbox**. On startup it performs only login, `USE <space>`, and a schema-version read, failing
fast if the coordinator has not already prepared the current schema. The process still has its
configured engine credential. Advisory locks coordinate Byori processes but do not isolate hostile
clients, so use separate ByoriDB instances and credentials across trust domains.

Use `--no-memory` when the database is unavailable or the coordinator should neither inject
historical context nor record checkpoints. This flag does not unregister MCP servers from a vendor
CLI's persistent configuration. Byori still forces the registered project space and `readonly`
profile into every worker environment, preventing a global ByoriDB registration from falling back
to the writable `legacy` profile. Disable that integration separately if the worker itself must be
prevented from reading memory. The coding CLIs can still send the task and source content to their
configured model providers; Byori's local storage does not change those vendors' data-handling
policies.

## Inspecting runs

```sh
byori runs list
byori runs show <run-id>
```

`runs list --json` returns all local run records. `runs show` prints one state record as JSON,
including worker status, exit code, branch, worktree, log paths, and the before/after Git state.
The raw prompt and logs live beside that record:

```text
~/.byori/runs/<run-id>/
├── state.json
├── prompt.txt
├── <worker>.stdout.jsonl
└── <worker>.stderr.log
```

Each stdout and stderr log is capped at 32 MiB and ends with a truncation marker when that limit
is reached.

Directories and files are created with user-only permissions where the platform allows it, but
they can still contain source fragments, model output, tool events, secrets pasted into a prompt,
or other sensitive information. Review prompts before running them, protect backups of
`~/.byori`, and sanitize records before sharing. Uninstalling ByoriDB does not automatically
delete `~/.byori`, because its worktrees may contain unmerged user changes.

## MVP limitations

- Claude Code and Codex are the only provider adapters.
- Runs stay attached to the invoking terminal; there is no daemon, attach/send command, or remote UI.
- Provider-native resume identifiers are recorded when available, but resume is not exposed yet.
- Byori does not select a winner, compare patches, merge branches, or clean up worktrees.
- Recall uses a bounded lexical ranking over existing graph records; automatic repository
  ingestion and semantic ranking remain future work.

## Design provenance

The provider-neutral run model, lifecycle separation, and isolated-worktree approach were informed
by the public structure of [Paseo](https://github.com/getpaseo/paseo). Paseo is AGPL-3.0; Byori's
Apache-2.0 implementation was written independently as a clean-room adaptation of those public
ideas and does not copy Paseo source code.
