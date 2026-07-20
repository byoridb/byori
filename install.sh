#!/usr/bin/env bash
# Byori — local agent memory installer.
# Sets up a local ByoriDB engine + MCP server + Claude Code skill so ByoriDB
# becomes Claude Code's persistent memory. macOS / Linux x86_64. Windows unsupported.
#
#   curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
#
# Options: --with-hooks --tag vX.Y.Z --engine-tag vX.Y.Z --uninstall
#          --binary PATH --assets DIR --no-service --no-claude
#   --tag        pins the byori asset version (default: latest byori release)
#   --engine-tag overrides the ByoriDB engine release to install
# Env:     BYORIDB_HOME (~/.byoridb) BYORIDB_HTTP_PORT (19669) BYORIDB_GRAPH_PORT (9669)
#          BYORIDB_LABEL (com.byoridb.local)
set -euo pipefail

ASSET_REPO="byoridb/byori"        # install.sh / MCP / skill / templates
ENGINE_REPO="byoridb/byoridb"     # byoridb-server binary releases
ENGINE_TAG_DEFAULT="v0.3.3"       # engine version this byori version is tested against
BYORIDB_HOME="${BYORIDB_HOME:-$HOME/.byoridb}"
HTTP_PORT="${BYORIDB_HTTP_PORT:-19669}"
GRAPH_PORT="${BYORIDB_GRAPH_PORT:-9669}"
LABEL="${BYORIDB_LABEL:-com.byoridb.local}"
HTTP_ADDR="127.0.0.1:${HTTP_PORT}"
GRAPH_ADDR="127.0.0.1:${GRAPH_PORT}"
SKILL_DIR="${HOME}/.claude/skills/byoridb-memory"

TAG=""; ENGINE_TAG="${BYORI_ENGINE_TAG:-$ENGINE_TAG_DEFAULT}"
WITH_HOOKS=0; UNINSTALL=0; BINARY=""; ASSETS=""; NO_SERVICE=0; NO_CLAUDE=0

c_blue=$'\033[34m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
warn() { printf '%s!  %s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --with-hooks) WITH_HOOKS=1 ;;
    --uninstall)  UNINSTALL=1 ;;
    --no-service) NO_SERVICE=1 ;;
    --no-claude)  NO_CLAUDE=1 ;;
    --tag)        TAG="${2:-}"; shift ;;
    --engine-tag) ENGINE_TAG="${2:-}"; shift ;;
    --binary)     BINARY="${2:-}"; shift ;;
    --assets)     ASSETS="${2:-}"; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

OS="$(uname -s)"
case "$OS" in Darwin) SERVICE=launchd ;; Linux) SERVICE=systemd ;; *) die "unsupported OS: $OS (macOS/Linux only)" ;; esac

# ---- uninstall -------------------------------------------------------------
uninstall() {
  log "uninstalling ByoriDB local memory substrate"
  if [ "$SERVICE" = launchd ]; then
    plist="${HOME}/Library/LaunchAgents/${LABEL}.plist"
    [ -f "$plist" ] && { launchctl unload -w "$plist" 2>/dev/null || true; rm -f "$plist"; }
  else
    systemctl --user disable --now "${LABEL}.service" 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/${LABEL}.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  command -v claude >/dev/null 2>&1 && claude mcp remove byoridb -s user 2>/dev/null || true
  rm -rf "$SKILL_DIR"
  if [ -d "$BYORIDB_HOME/data" ]; then
    printf 'delete data at %s? [y/N] ' "$BYORIDB_HOME/data"; read -r ans </dev/tty || ans=n
    case "$ans" in y|Y) rm -rf "$BYORIDB_HOME";; *) warn "kept data; removed only bin/scripts"; rm -rf "$BYORIDB_HOME/bin" "$BYORIDB_HOME/byoridb_mcp.py";; esac
  else
    rm -rf "$BYORIDB_HOME"
  fi
  log "uninstalled."
  exit 0
}
[ "$UNINSTALL" = 1 ] && uninstall

# ---- install ---------------------------------------------------------------
need curl; need tar; need python3
PYTHON="$(command -v python3)"

detect_target() {
  local arch; arch="$(uname -m)"
  case "$OS/$arch" in
    Darwin/arm64)        echo aarch64-apple-darwin ;;
    Darwin/x86_64)       echo x86_64-apple-darwin ;;
    Linux/x86_64)        echo x86_64-unknown-linux-gnu ;;
    *) die "no prebuilt binary for $OS/$arch — build from source (cargo build --release --bin byoridb-server)" ;;
  esac
}

resolve_tag() {
  [ -n "$TAG" ] && { echo "$TAG"; return; }
  curl -fsSL "https://api.github.com/repos/${ASSET_REPO}/releases/latest" -o "$WORK/rel.json"
  awk -F'"' '/"tag_name"/{print $4; exit}' "$WORK/rel.json"
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# get <repo-relative-path> <dest>: from --assets dir or raw.githubusercontent at TAG
get() {
  if [ -n "$ASSETS" ]; then cp "$ASSETS/$1" "$2"
  else curl -fsSL "https://raw.githubusercontent.com/${ASSET_REPO}/${TAG}/$1" -o "$2"; fi
}

render() { # <src-template> <dest>
  sed -e "s|@BYORIDB_HOME@|${BYORIDB_HOME}|g" \
      -e "s|@HTTP_ADDR@|${HTTP_ADDR}|g" \
      -e "s|@GRAPH_ADDR@|${GRAPH_ADDR}|g" \
      -e "s|@PYTHON@|${PYTHON}|g" \
      -e "s|@LABEL@|${LABEL}|g" \
      "$1" > "$2"
}

TARGET="$(detect_target)"
mkdir -p "$BYORIDB_HOME/bin" "$BYORIDB_HOME/data" "$BYORIDB_HOME/logs"
chmod 700 "$BYORIDB_HOME" "$BYORIDB_HOME/data" "$BYORIDB_HOME/logs" 2>/dev/null || true

# 1) engine binary (from ENGINE_REPO, pinned to the tested ENGINE_TAG)
if [ -n "$BINARY" ]; then
  log "using local binary: $BINARY"
  cp "$BINARY" "$BYORIDB_HOME/bin/byoridb-server"
else
  url="https://github.com/${ENGINE_REPO}/releases/download/${ENGINE_TAG}/byoridb-${ENGINE_TAG}-${TARGET}.tar.gz"
  log "downloading engine ${ENGINE_TAG}: $url"
  curl -fSL "$url" -o "$WORK/b.tar.gz" || die "download failed (does engine release $ENGINE_TAG have $TARGET?)"
  tar -xzf "$WORK/b.tar.gz" -C "$BYORIDB_HOME/bin"
fi
chmod +x "$BYORIDB_HOME/bin/byoridb-server" 2>/dev/null || true
[ -f "$BYORIDB_HOME/bin/byoridb-cli" ] && chmod +x "$BYORIDB_HOME/bin/byoridb-cli"
# TAG (byori asset version) only needed for raw fetches; empty with --assets — fine.
[ -z "$TAG" ] && [ -z "$ASSETS" ] && { TAG="$(resolve_tag)"; [ -n "$TAG" ] || die "could not resolve latest byori release tag"; }

# 2) MCP server + rendered wrappers
log "installing MCP server + service wrappers"
get "mcp/byoridb_mcp.py" "$BYORIDB_HOME/byoridb_mcp.py"
get "templates/run-server.sh" "$WORK/run-server.sh"
get "templates/run-mcp.sh"    "$WORK/run-mcp.sh"
render "$WORK/run-server.sh" "$BYORIDB_HOME/bin/run-server.sh"
render "$WORK/run-mcp.sh"    "$BYORIDB_HOME/bin/run-mcp.sh"
chmod +x "$BYORIDB_HOME/bin/run-server.sh" "$BYORIDB_HOME/bin/run-mcp.sh"

# 3) env: preserve ONLY the root secret across reinstalls (so existing data stays
#    accessible); always rewrite derived endpoint/user, so an upgrade with changed
#    ports keeps the server and the MCP client pointed at the SAME address.
pw=""
[ -f "$BYORIDB_HOME/env" ] && pw="$(sed -n 's/^BYORIDB_ROOT_PASSWORD=//p' "$BYORIDB_HOME/env")"
[ -n "$pw" ] || pw="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
umask 177
cat > "$BYORIDB_HOME/env" <<EOF
BYORIDB_ROOT_PASSWORD=${pw}
BYORIDB_HTTP=http://${HTTP_ADDR}
BYORIDB_USER=root
EOF
umask 022
chmod 600 "$BYORIDB_HOME/env"
log "wrote $BYORIDB_HOME/env (secret preserved; endpoint=http://${HTTP_ADDR})"

# 4) service (always-on)
start_service() {
  if [ "$SERVICE" = launchd ]; then
    plist="${HOME}/Library/LaunchAgents/${LABEL}.plist"
    get "templates/com.byoridb.local.plist" "$WORK/svc.plist"
    mkdir -p "${HOME}/Library/LaunchAgents"; render "$WORK/svc.plist" "$plist"
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load -w "$plist"
  else
    unit="${HOME}/.config/systemd/user/${LABEL}.service"
    get "templates/byoridb-local.service" "$WORK/svc.service"
    mkdir -p "${HOME}/.config/systemd/user"; render "$WORK/svc.service" "$unit"
    systemctl --user daemon-reload
    systemctl --user enable --now "${LABEL}.service"
  fi
}
if [ "$NO_SERVICE" = 1 ]; then
  warn "skipping service registration (--no-service); starting server in background for this session"
  ( "$BYORIDB_HOME/bin/run-server.sh" >"$BYORIDB_HOME/logs/server.log" 2>"$BYORIDB_HOME/logs/server.err" & )
else
  log "registering always-on service ($SERVICE: $LABEL)"
  start_service
fi

# 5) wait for health
log "waiting for server on http://${HTTP_ADDR} ..."
ok=0
for _ in $(seq 1 30); do
  if curl -fsS "http://${HTTP_ADDR}/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] || die "server did not become healthy on http://${HTTP_ADDR} — see $BYORIDB_HOME/logs/server.err (not registering MCP)"
log "server healthy"

# 6) register MCP server with Claude Code
if [ "$NO_CLAUDE" = 1 ]; then
  warn "skipping Claude Code wiring (--no-claude): MCP registration + skill install"
elif command -v claude >/dev/null 2>&1; then
  claude mcp remove byoridb -s user >/dev/null 2>&1 || true
  claude mcp add byoridb -s user -- "$BYORIDB_HOME/bin/run-mcp.sh" && log "registered MCP server 'byoridb' (user scope)"
else
  warn "claude CLI not found — register manually: claude mcp add byoridb -s user -- $BYORIDB_HOME/bin/run-mcp.sh"
fi

# 7) skill
if [ "$NO_CLAUDE" != 1 ]; then
  log "installing skill -> $SKILL_DIR"
  mkdir -p "$SKILL_DIR"
  get "adapters/claude/skills/byoridb-memory/SKILL.md" "$SKILL_DIR/SKILL.md"
fi

# 8) hooks (opt-in)
if [ "$NO_CLAUDE" != 1 ] && [ "$WITH_HOOKS" = 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    settings="${HOME}/.claude/settings.json"; mkdir -p "${HOME}/.claude"
    [ -f "$settings" ] || echo '{}' > "$settings"
    backup="${settings}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$settings" "$backup"
    get "adapters/claude/hooks.snippet.json" "$WORK/hooks.json"
    # Append byori hooks to existing event arrays, skipping entries that are
    # already present — user hooks survive and re-runs stay idempotent.
    jq -s '
      def merge_event($a; $b):
        ($a // []) + [ ($b // [])[] | select(. as $n | any(($a // [])[]; . == $n) | not) ];
      .[0] as $a | .[1] as $b | ($a * $b)
      | .hooks.SessionStart = merge_event($a.hooks.SessionStart; $b.hooks.SessionStart)
      | .hooks.PreToolUse   = merge_event($a.hooks.PreToolUse;   $b.hooks.PreToolUse)
    ' "$settings" "$WORK/hooks.json" > "$WORK/merged.json" && mv "$WORK/merged.json" "$settings"
    log "appended checkpoint hooks into $settings (backup: $backup)"
  else
    warn "jq not found — skipped hooks; install jq and re-run with --with-hooks"
  fi
fi

cat <<EOF

${c_blue}ByoriDB local memory substrate installed.${c_off}
  home     : $BYORIDB_HOME
  server   : http://${HTTP_ADDR}  (health: curl -s http://${HTTP_ADDR}/health)
  mcp      : $BYORIDB_HOME/bin/run-mcp.sh   (claude mcp list -> byoridb)
  skill    : $SKILL_DIR/SKILL.md
Restart Claude Code so it picks up the MCP server and skill.
EOF
