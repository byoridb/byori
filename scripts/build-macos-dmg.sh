#!/usr/bin/env bash
# Build, bundle, sign, and package Byori Manager for macOS.
set -Eeuo pipefail

IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

PRODUCT_NAME="ByoriManager"
APP_NAME="Byori Manager.app"
BUNDLE_IDENTIFIER="io.byoridb.manager"
PACKAGE_DIR="${PACKAGE_DIR:-${REPO_ROOT}/manager/macos}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/dist}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
ARCH="${ARCH:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SDK_PATH="${SDK_PATH:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

usage() {
  cat <<'EOF'
Usage: scripts/build-macos-dmg.sh [options]

Build the SwiftPM executable product ByoriManager, wrap it in a signed .app,
and create a compressed DMG containing the app and an Applications symlink.

Options:
  --version VERSION       Release version (or set VERSION; default: git tag)
  --build-number NUMBER   CFBundleVersion (or set BUILD_NUMBER)
  --arch ARCH             arm64, x86_64, or universal (or set ARCH)
  --universal             Shorthand for --arch universal
  --sign IDENTITY         codesign identity (or set SIGN_IDENTITY; default: -)
  --sdk PATH              macOS SDK override (or set SDK_PATH)
  --notary-profile NAME   notarytool keychain profile; notarize and staple DMG
  --package-dir DIR       Directory containing Package.swift
  --output-dir DIR        Destination for .app and .dmg (default: ./dist)
  -h, --help              Show this help

Examples:
  VERSION=0.2.0 scripts/build-macos-dmg.sh
  scripts/build-macos-dmg.sh --version 0.2.0 --universal
  scripts/build-macos-dmg.sh --sign 'Developer ID Application: Example (TEAMID)'
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      need_value "$@"
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      need_value "$@"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --arch)
      need_value "$@"
      ARCH="$2"
      shift 2
      ;;
    --universal)
      ARCH="universal"
      shift
      ;;
    --sign)
      need_value "$@"
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --sdk)
      need_value "$@"
      SDK_PATH="$2"
      shift 2
      ;;
    --notary-profile)
      need_value "$@"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --package-dir)
      need_value "$@"
      PACKAGE_DIR="$2"
      shift 2
      ;;
    --output-dir)
      need_value "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "macOS is required to build the app and DMG"

case "$ARCH" in
  aarch64) ARCH="arm64" ;;
  arm64|x86_64|universal) ;;
  *) die "unsupported architecture: $ARCH (expected arm64, x86_64, or universal)" ;;
esac

if [ -z "$VERSION" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || true)"
  fi
  if [[ ! "${VERSION:-}" =~ ^v?[0-9]+(\.[0-9]+){0,2}([-+][0-9A-Za-z.-]+)?$ ]]; then
    VERSION="0.0.0-dev.${VERSION:-local}"
  fi
fi

case "$VERSION" in
  v*) VERSION="${VERSION#v}" ;;
esac
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}([-+][0-9A-Za-z.-]+)?$ ]] || \
  die "VERSION must look like 1.2.3 or 1.2.3-beta.1 (got: $VERSION)"
MARKETING_VERSION="${VERSION%%[-+]*}"

if [ -z "$BUILD_NUMBER" ]; then
  if command -v git >/dev/null 2>&1; then
    BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || true)"
  fi
  BUILD_NUMBER="${BUILD_NUMBER:-1}"
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "BUILD_NUMBER must contain one to three dot-separated integers"

[ -f "$PACKAGE_DIR/Package.swift" ] || die "Package.swift not found in $PACKAGE_DIR"
[ -f "$REPO_ROOT/install.sh" ] || die "missing installer: install.sh"
[ -f "$REPO_ROOT/mcp/byoridb_mcp.py" ] || die "missing MCP bridge: mcp/byoridb_mcp.py"
[ -d "$REPO_ROOT/templates" ] || die "missing templates directory"
[ -f "$REPO_ROOT/adapters/claude/skills/byoridb-memory/SKILL.md" ] || \
  die "missing Claude skill: adapters/claude/skills/byoridb-memory/SKILL.md"
[ -f "$REPO_ROOT/adapters/claude/hooks.snippet.json" ] || \
  die "missing Claude hooks snippet"

for tool in codesign ditto hdiutil install lipo plutil sed xattr xcrun; do
  need "$tool"
done
SWIFT="$(xcrun --find swift)"
[ -x "$SWIFT" ] || die "Swift toolchain not found; install Xcode Command Line Tools"
if [ -z "$SDK_PATH" ]; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
[ -d "$SDK_PATH" ] || die "SDK path does not exist: $SDK_PATH"
SDK_PATH="$(cd "$SDK_PATH" && pwd -P)"
# Keep this array non-empty: macOS ships Bash 3.2, where expanding an empty
# array under `set -u` aborts with an "unbound variable" error.
SWIFT_SDK_ARGS=(--sdk "$SDK_PATH")
export SDKROOT="$SDK_PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/byori-manager-package.XXXXXX")"
cleanup() {
  if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep compiler caches inside the disposable build root. This avoids depending
# on a writable user cache and makes CI builds easier to isolate.
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$WORK_DIR/swift-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/swiftpm-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE"

APP_BUNDLE="$WORK_DIR/$APP_NAME"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
RUNTIME_DIR="$RESOURCES_DIR/runtime"
mkdir -p "$MACOS_DIR" "$RUNTIME_DIR/mcp" \
  "$RUNTIME_DIR/adapters/claude/skills/byoridb-memory"

build_arch() {
  local target_arch="$1"
  local destination="$2"
  local scratch="$WORK_DIR/swift-$target_arch"
  local bin_dir

  log "Building $PRODUCT_NAME for $target_arch"
  "$SWIFT" build \
    --package-path "$PACKAGE_DIR" \
    --cache-path "$WORK_DIR/swiftpm-cache" \
    --config-path "$WORK_DIR/swiftpm-config" \
    --security-path "$WORK_DIR/swiftpm-security" \
    --scratch-path "$scratch" \
    --disable-sandbox \
    "${SWIFT_SDK_ARGS[@]}" \
    --configuration release \
    --arch "$target_arch" \
    --product "$PRODUCT_NAME"
  bin_dir="$("$SWIFT" build \
    --package-path "$PACKAGE_DIR" \
    --cache-path "$WORK_DIR/swiftpm-cache" \
    --config-path "$WORK_DIR/swiftpm-config" \
    --security-path "$WORK_DIR/swiftpm-security" \
    --scratch-path "$scratch" \
    --disable-sandbox \
    "${SWIFT_SDK_ARGS[@]}" \
    --configuration release \
    --arch "$target_arch" \
    --show-bin-path)"
  [ -x "$bin_dir/$PRODUCT_NAME" ] || die "SwiftPM did not produce $bin_dir/$PRODUCT_NAME"
  install -m 755 "$bin_dir/$PRODUCT_NAME" "$destination"
}

if [ "$ARCH" = "universal" ]; then
  ARM_BINARY="$WORK_DIR/$PRODUCT_NAME-arm64"
  INTEL_BINARY="$WORK_DIR/$PRODUCT_NAME-x86_64"
  build_arch arm64 "$ARM_BINARY"
  build_arch x86_64 "$INTEL_BINARY"
  lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$MACOS_DIR/$PRODUCT_NAME"
  LIPO_ARCHS="$(lipo -archs "$MACOS_DIR/$PRODUCT_NAME")"
  [[ " $LIPO_ARCHS " = *" arm64 "* && " $LIPO_ARCHS " = *" x86_64 "* ]] || \
    die "universal binary validation failed (found: $LIPO_ARCHS)"
  chmod 755 "$MACOS_DIR/$PRODUCT_NAME"
else
  build_arch "$ARCH" "$MACOS_DIR/$PRODUCT_NAME"
fi

log "Copying installer, MCP, templates, and agent resources"
install -m 755 "$REPO_ROOT/install.sh" "$RUNTIME_DIR/install.sh"
install -m 644 "$REPO_ROOT/mcp/byoridb_mcp.py" "$RUNTIME_DIR/mcp/byoridb_mcp.py"
ditto "$REPO_ROOT/templates" "$RUNTIME_DIR/templates"
install -m 644 \
  "$REPO_ROOT/adapters/claude/skills/byoridb-memory/SKILL.md" \
  "$RUNTIME_DIR/adapters/claude/skills/byoridb-memory/SKILL.md"
install -m 644 \
  "$REPO_ROOT/adapters/claude/hooks.snippet.json" \
  "$RUNTIME_DIR/adapters/claude/hooks.snippet.json"
printf '%s\n' "$VERSION" > "$RESOURCES_DIR/VERSION"

INFO_TEMPLATE="$REPO_ROOT/manager/macos/packaging/Info.plist.in"
[ -f "$INFO_TEMPLATE" ] || die "missing Info.plist template: $INFO_TEMPLATE"
sed \
  -e "s|@BUNDLE_IDENTIFIER@|$BUNDLE_IDENTIFIER|g" \
  -e "s|@MARKETING_VERSION@|$MARKETING_VERSION|g" \
  -e "s|@BUILD_NUMBER@|$BUILD_NUMBER|g" \
  "$INFO_TEMPLATE" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

log "Generating native application icon"
ICON_SOURCE="$REPO_ROOT/manager/macos/packaging/generate_icon.swift"
[ -f "$ICON_SOURCE" ] || die "missing icon generator: $ICON_SOURCE"
"$SWIFT" "$ICON_SOURCE" "$RESOURCES_DIR/ByoriManager.icns"
[ -s "$RESOURCES_DIR/ByoriManager.icns" ] || die "icon generator did not create an ICNS file"

log "Signing app with ${SIGN_IDENTITY:-- (ad hoc)}"
xattr -cr "$APP_BUNDLE"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP_BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
DEST_APP="$OUTPUT_DIR/$APP_NAME"
rm -rf "$DEST_APP"
ditto "$APP_BUNDLE" "$DEST_APP"

DMG_STAGE="$WORK_DIR/dmg-root"
mkdir -p "$DMG_STAGE"
ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME"
ln -s /Applications "$DMG_STAGE/Applications"

DMG_NAME="ByoriManager-${VERSION}-${ARCH}.dmg"
TEMP_DMG="$WORK_DIR/$DMG_NAME"
DEST_DMG="$OUTPUT_DIR/$DMG_NAME"
log "Creating compressed DMG"
hdiutil create \
  -volname "Byori Manager" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov \
  "$TEMP_DMG"
[ -s "$TEMP_DMG" ] || die "hdiutil did not create a DMG"
mv -f "$TEMP_DMG" "$DEST_DMG"

if [ "$SIGN_IDENTITY" != "-" ]; then
  log "Signing DMG with $SIGN_IDENTITY"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DEST_DMG"
  codesign --verify --verbose=2 "$DEST_DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  [ "$SIGN_IDENTITY" != "-" ] || die "notarization requires a Developer ID signing identity"
  log "Submitting DMG for notarization"
  xcrun notarytool submit "$DEST_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DEST_DMG"
  xcrun stapler validate "$DEST_DMG"
fi

log "Created $DEST_APP"
log "Created $DEST_DMG"
