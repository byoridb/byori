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

## Query from an agent

The existing `byoridb` MCP registration exposes four additional read tools:

| Tool | Purpose |
|---|---|
| `code_status` | Inspect the selected checkout's indexed revision, snapshot, counts, and diagnostics. |
| `code_search` | Find symbols by text, file, or language, with bounded pagination. |
| `code_relations` | Inspect incoming/outgoing `calls` or `imports` for a returned symbol or file ID. |
| `code_impact` | Follow incoming resolved relationships, with bounded depth and result count. |

Use the exact ID returned by search or relationship results; do not synthesize
symbol IDs. Check status before trusting a graph from an earlier working session,
then open the relevant source locations and run appropriate tests. All four tools
are available in `safe`, `legacy`, and `readonly` MCP profiles; indexing is an
explicit CLI operation, not an agent-exposed mutation tool. After upgrading an old
runtime, run a writable-profile session or `byori index` to apply schema v3 before
starting a `readonly` session.

Code indexes are keyed by canonical checkout path, even when multiple worktrees
share a project memory space. A branch or dirty working tree is represented by its
indexed content snapshot and recorded Git revision. Queries default to the MCP
process's current checkout; `checkout_id` explicitly selects another indexed
checkout in the same project space. A moved checkout needs a new index.

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
This version does not infer decision-to-symbol links or add a code-explorer screen
to the native app.

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
and restart the agent session to discover the new `code_*` tools. Project analysis
does not silently replace that runtime or restart running services.
