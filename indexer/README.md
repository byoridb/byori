# Byori Rust code indexer

`byori-indexer` statically indexes a local Git checkout. It parses Python,
Swift, JavaScript (including JSX), TypeScript (including TSX), and Rust with
Tree-sitter. It does not invoke a model, build the project, execute repository
code, or send source to a hosted service.

Requires Rust 1.90 or later and a C compiler to build the bundled grammars:

```sh
cargo build --release --locked --manifest-path indexer/Cargo.toml
indexer/target/release/byori-indexer index --root /path/to/repo
```

The binary writes one JSON object to stdout. `--cache-dir PATH` sets the
rebuildable parse cache; otherwise it uses `$BYORI_HOME/code-cache` or
`~/.byori/code-cache`. `--no-cache` disables both cache reads and writes.
Only changed source contents are reparsed, but every run reconstructs the
complete current graph, so deletions and renames cannot retain stale edges.
`--version` prints both the binary and analysis contract versions.

## Contract

The JSON `format_version` is 1. It contains:

- `root`: canonical checkout root, not the shared Git common directory.
- `checkout_id`: the first 16 hex characters of SHA-256 of the UTF-8 root.
- `revision`: current HEAD or an empty string for an unborn repository.
- `snapshot_id`: SHA-256 of the analysis version, checkout, revision, files,
  symbols, references and diagnostics. Cache counters do not change it.
- `files`: `{id, path, language, hash}`. Paths are relative, `id` is `file:<path>`,
  and `hash` is SHA-256 of source contents.
- `symbols`: `{id, name, qualified_name, kind, file, start_line, end_line}`.
  Locations are one-based, with an inclusive end line. Symbol IDs include the
  relative path, byte offset and enclosing qualified name; they are identities
  within a snapshot, not semantic identities across code edits.
- `references`: `{source, target, kind, name, file, line, resolution}`.
  Kinds are `calls` and `imports`. `source` names a symbol or file;
  `target` is a symbol/file ID only when resolved, otherwise `null`.
- `diagnostics`: `{file, message}` for syntax recovery and skipped source.
- `stats`: file, parsed/cached file, symbol and resolved/unresolved reference counts.

Byori's Python integration publishes this snapshot into ByoriDB and exposes
bounded MCP search, callers, callees and impact traversal. The Rust process is
an analyzer: database credentials and engine session handling stay in the
existing ByoriDB bridge.

## Accuracy boundary

Definitions are syntax facts. Call resolution is intentionally narrower than
parsing support: unambiguous lexical functions and explicit relative named
imports (Python and ES modules) can resolve. CommonJS literal relative
`require` bindings resolve namespace calls, destructured aliases, and explicit
`exports`/`module.exports` function bindings. Shadowed `require` and reassigned
module objects remain unresolved. Rust `mod` declarations resolve file edges;
explicit `crate`/`self`/`super` paths and grouped `use` aliases follow declared
modules, withholding private cross-module functions. There is no arbitrary project-wide
same-name lookup. Parameters, local assignments, ambiguous declarations,
non-exported ES functions, and ambiguous file extensions prevent resolution.

Object/method dispatch, Rust trait dispatch and macros, Swift overloads, external crate names, Python absolute-package imports, JS/TS path aliases,
dynamic module loaders and computed exports remain unresolved where static
syntax alone does not establish the target. Rust macro token trees are not treated as expanded executable code.
Recovered calls in a file with syntax errors remain unresolved. Related tests
are graph-based candidates, not coverage guarantees. No LSP is run yet.

The scan uses Git's tracked and untracked, non-ignored file list. Source and
parent-directory symlinks, generated/dependency directories, non-UTF-8 sources,
and files over 2 MiB are skipped. Unsupported formats are outside the snapshot.
The index is a point-in-time best effort; a concurrent editor can change a file
after it was read. Source hashes let consumers check freshness.

## Validation

```sh
cargo test --locked --manifest-path indexer/Cargo.toml
cargo clippy --locked --manifest-path indexer/Cargo.toml --all-targets -- -D warnings
```

Third-party license notices are included in `THIRD_PARTY_NOTICES.md`. The two
files under `licenses/` come from the exact upstream tags because those crates
omit their top-level license file from the crates.io archive:

- https://github.com/tree-sitter/tree-sitter/blob/v0.25.10/LICENSE
- https://github.com/tree-sitter/tree-sitter-typescript/blob/v0.23.2/LICENSE
