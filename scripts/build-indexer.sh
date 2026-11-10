#!/usr/bin/env bash
# Build the locked Rust indexer and collect the licenses shipped with its crates.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET=""
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target|--output)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "$1 requires a value" >&2; exit 2; }
      if [ "$1" = --target ]; then TARGET="$2"; else OUTPUT="$2"; fi
      shift 2 ;;
    -h|--help)
      echo "Usage: scripts/build-indexer.sh [--target RUST_TRIPLE] [--output BINARY_PATH]"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v cargo >/dev/null || { echo "Rust/Cargo is required to build the indexer" >&2; exit 1; }
INDEXER_TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/indexer/target}"
mkdir -p "$INDEXER_TARGET_DIR"
INDEXER_TARGET_DIR="$(cd "$INDEXER_TARGET_DIR" && pwd -P)"
if [ -n "$TARGET" ]; then
  cargo build --locked --release --manifest-path "$REPO_ROOT/indexer/Cargo.toml" \
    --target-dir "$INDEXER_TARGET_DIR" --target "$TARGET"
  BUILT="$INDEXER_TARGET_DIR/$TARGET/release/byori-indexer"
else
  cargo build --locked --release --manifest-path "$REPO_ROOT/indexer/Cargo.toml" \
    --target-dir "$INDEXER_TARGET_DIR"
  BUILT="$INDEXER_TARGET_DIR/release/byori-indexer"
fi
if [ -n "$OUTPUT" ]; then
  mkdir -p "$(dirname "$OUTPUT")"
  install -m 755 "$BUILT" "$OUTPUT"
else
  OUTPUT="$BUILT"
fi
LICENSE_OUTPUT="$(dirname "$OUTPUT")/THIRD_PARTY_LICENSES.txt"
cargo metadata --locked --format-version 1 --manifest-path "$REPO_ROOT/indexer/Cargo.toml" \
  | python3 "$SCRIPT_DIR/indexer-licenses.py" "$LICENSE_OUTPUT"
echo "Built $OUTPUT"
