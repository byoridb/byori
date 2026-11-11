**English** | [한국어](ko/code-index.md)

# Source code index

Byori's Rust indexer parses Python, Swift, JavaScript/JSX, TypeScript/TSX, and Rust
with Tree-sitter. It records files, definitions, imports, and calls in the project's
ByoriDB space. Agents can query that structure through the existing ByoriDB MCP
server. Parsing, indexing, and graph lookup do not call an LLM.

## Build and use

The app's **Analyze project** action and `byori init .` run both Git-history import
and the Rust source indexer. Source analysis also runs when no history memories
are found. `byori init --skip-code` explicitly requests history only; `byori index`
refreshes source structure only. `--dry-run` on either command analyzes without
writing to ByoriDB. Analysis is a one-shot operation unless `index --watch` is used.

Release installers and macOS app bundles include the native indexer. For a source
checkout, install Rust and a C compiler, then build the locked dependencies:

```bash
scripts/build-indexer.sh
python3 cli/byori.py index . --dry-run --json
python3 cli/byori.py index .
```

The dry run analyzes source without writing to ByoriDB. The write command uses the
same runtime credentials and project-space resolution as `byori init`. The engine
must be running. To install this checkout's complete runtime:

```bash
./install.sh --assets .
```

Once installed, `byori index .` refreshes the index. `--indexer PATH` selects a
particular binary, and `BYORI_INDEXER` provides the corresponding environment
override. For continuous updates while the command is running:

```bash
byori index . --watch --interval 5
```

This is foreground polling; interrupt it with Ctrl-C. It does not install a
background service. Files with unchanged content reuse the local parse cache;
deleted and renamed files disappear from the next published snapshot. `--no-cache`
forces parsing again. Cache files are rebuildable analysis artifacts, not a second
authoritative project-memory store.

The underlying binary can be used independently:

```bash
indexer/target/release/byori-indexer index --root . --cache-dir /tmp/byori-index-cache
```

It writes one JSON document to stdout and diagnostics to stderr. It reads tracked
and non-ignored untracked files in a Git checkout, skips symlinks and excluded
build/vendor directories, and reports unsupported or invalid source as applicable.
It never installs or executes a project's dependencies.

## Browse in the app

Select a project or source tree, then open **Context → 코드 인덱스 보기**. The project row
menu offers the same browser for its primary checkout. The wide browser reads the saved
ByoriDB snapshot, so results remain available after restarting the app; the local engine
must be running. Opening the browser does not run the indexer.

The header shows the exact checkout, analysis date, revision, file/symbol totals, resolved
and unresolved references, languages, and diagnostics. Language counts appear when the
snapshot contains them; older snapshots still show their language coverage. Search the
file or symbol list, filter by language, and load additional pages as needed. Select a
symbol for callers/callees, or a file for imports/dependents. Change impact follows only
resolved static relations within the displayed limits.

Opening the browser and **Refresh** reload the saved snapshot and perform one bounded
comparison with the current checkout. **최신 상태 확인** repeats that comparison without
indexing. **Analyze** runs history and source analysis for
the checkout displayed in this browser, including linked worktrees. Source previews read
the current file at the indexed line, without editing it. Edits after the displayed check time
can still make old line positions differ from current source. If another process publishes a snapshot while browsing, the browser clears stale
selection/detail instead of combining snapshots.

The same saved data can be read without starting an MCP session:

```bash
byori code status . --json
byori code verify . --json
byori code files . --language rust --json
byori code symbols . --query parse --json
```

## Query from an agent

The existing `byoridb` MCP registration exposes these code read tools:

| Tool | Purpose |
|---|---|
| `code_status` | Inspect the selected checkout's indexed revision, snapshot, counts, and diagnostics. |
| `code_verify` | Compare indexed file hashes with the current checkout, reporting complete/incomplete freshness separately from semantic validity. |
| `code_search` | Find symbols by text, file, or language, with bounded pagination. |
| `code_relations` | Inspect incoming/outgoing `calls` or `imports` for a returned symbol or file ID. |
| `code_impact` | Follow incoming resolved relationships, with bounded depth and result count. |

Use the exact ID returned by search or relationship results; do not synthesize
symbol IDs. Check status before trusting a graph from an earlier working session,
then use `code_verify`, open the relevant source locations, and run appropriate tests. These tools
are available in `safe`, `legacy`, and `readonly` MCP profiles; indexing is an
explicit CLI operation, not an agent-exposed mutation tool. After upgrading an old
runtime, run a writable-profile session or `byori index` to prepare the current schema before
starting a `readonly` session.

Code indexes are keyed by canonical checkout path, even when multiple worktrees
share a project memory space. A branch or dirty working tree is represented by its
indexed content snapshot and recorded Git revision. Queries default to the MCP
process's current checkout; `checkout_id` explicitly selects another indexed
checkout in the same project space. A moved checkout needs a new index.
`code_verify` can verify only the process's actual checkout: it does not accept an arbitrary
filesystem root and refuses to verify a different checkout ID.

## Source freshness

Verification returns `current`, `changed`, or `not_checked`, plus a completion flag and check
time. It compares hashes of Git-tracked and non-ignored untracked supported source files,
including additions and removals. A dirty tree can be current if its bytes match the saved
analysis; matching HEAD alone never establishes freshness. Git revision changes are reported
separately. Changed counts and up to 20 sample paths are shown in the app.

The pass is bounded to 10,000 candidate/indexed files, 64 MiB of source reads, a 4 MiB path
inventory, and an eight-second local verification budget. It follows the Rust indexer's
eligibility rules: excluded build/vendor directories, symbolic links, files over 2 MiB, and
non-UTF-8 source are not indexed. Removing a file from that eligible set is a removal from the
saved index. No source or repository fsmonitor hook is executed. Inventory and file metadata
are checked again to catch edits during the pass; a concurrent snapshot publication invalidates
the result. Limits, unavailable files, and races produce `not_checked`, never an inferred
`current`. Database connectivity can add its ordinary transport timeout.

This checks source-byte freshness at one time, not code correctness, a decision's continuing
validity, dependency behavior, or runtime coverage. It neither rewrites the graph nor starts a
background watcher. Reanalysis is explicit, and a failed reanalysis leaves the previous published
snapshot available.

## Accuracy and storage

Parsing a language is not equivalent to compiler-level name resolution. The first
version resolves only relationships it can establish conservatively. Dynamic
receivers, ambiguous names, Rust macro expansion and trait dispatch, dependency
package internals, and other unsupported bindings remain unresolved. An unresolved
reference is reported as such; an empty incoming-call result is not proof that a
symbol has no callers. There is no LSP enrichment, runtime coverage collection,
automatic test selection, or semantic/vector ranking in this version.

Definitions retain their source file and line range. Hashes bind the graph to the
indexed files. Immutable snapshot records and relationships are written first;
the checkout's active snapshot pointer is published last. Failed writes therefore
leave the previous complete snapshot active. Old snapshots and interrupted-write
records are retained; automatic database garbage collection is not implemented.
Parse caching reduces repeated AST work, but publishing a changed graph still
writes a complete snapshot. Plan disk capacity accordingly for large repositories.

The code schema is additive and separate from notes and the typed memory wiki.
Existing decisions and causal memory remain available through `memory_*` tools.
This version does not infer decision-to-symbol links. The native code browser keeps
source structure separate from the existing decision/history Context records.

## Distribution

`scripts/build-indexer.sh --target <Rust target> --output <path>` builds a native
binary and writes dependency license texts beside it. Install the requested Rust
target before cross-compiling. Universal macOS app builds require both
`aarch64-apple-darwin` and `x86_64-apple-darwin`; the packager combines and signs the
indexer before signing the app. Release archives are provided for those two macOS
targets and `x86_64-unknown-linux-gnu` (built on Ubuntu 24.04).

The online installer verifies the archive against the matching release SHA-256
file. `--assets` uses `bin/byori-indexer` from a bundle or
`indexer/target/release/byori-indexer` from a built source checkout. A missing binary
fails before live runtime replacement, with the build command printed. Use
`--indexer-binary PATH` for another locally built executable.

An updated macOS app uses its bundled CLI, MCP bridge and native indexer for project
analysis, even if the separately installed runtime is older. Existing agent MCP
registrations still launch the installed runtime: update it under **Settings → ByoriDB**
using the engine install/update action (**이미 최신 엔진** can also reinstall/verify the same
release), then sync **byoridb-memory** under **Agents & Skill** and restart/reconnect the agent
session to discover the new `code_*` and memory-policy tools. Updating the app alone does not
replace an already-running agent's MCP process or its installed skill. Project analysis
does not silently replace that runtime or restart running services.
