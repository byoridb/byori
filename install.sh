#!/usr/bin/env bash
# Byori — local workspace runtime installer.
# Sets up ByoriDB, MCP, the `byori` CLI, and Claude/Codex Skills that provide
# shared project knowledge across coding-agent sessions. macOS / Linux x86_64.
# Windows unsupported.
#
#   curl -fsSL https://github.com/byoridb/byori/releases/latest/download/install.sh | bash
#
# Options: --no-hooks --tag vX.Y.Z --engine-tag vX.Y.Z|latest --uninstall
#          --binary PATH --assets DIR --no-service --no-claude --no-codex
#   --no-hooks   skip the Claude checkpoint hooks (installed by default: they are
#                what makes the memory graph present in a session instead of
#                something the agent has to remember to look for). Its own axis:
#                --no-claude skips MCP registration and skills, not these, because
#                the app-driven install passes --no-claude and its users are the
#                ones who need the reminder. Pass both to leave ~/.claude alone.
#   --tag        pins the byori asset version (default: latest byori release)
#   --engine-tag ByoriDB engine release to install: a tag, or `latest` to resolve
#                the newest engine release (default: the validated pinned tag)
# Env:     BYORIDB_HOME (~/.byoridb) BYORIDB_HTTP_PORT (19669) BYORIDB_GRAPH_PORT (9669)
#          BYORIDB_LABEL (com.byoridb.local)
set -euo pipefail

ASSET_REPO="byoridb/byori"        # install.sh / MCP / skill / templates
ENGINE_REPO="byoridb/byoridb"     # byoridb-server binary releases
ENGINE_TAG_DEFAULT="v0.4.0"       # engine version this byori version is tested against,
                                  # and the fallback when `latest` cannot be resolved
BYORIDB_HOME="${BYORIDB_HOME:-$HOME/.byoridb}"
HTTP_PORT="${BYORIDB_HTTP_PORT:-19669}"
GRAPH_PORT="${BYORIDB_GRAPH_PORT:-9669}"
LABEL="${BYORIDB_LABEL:-com.byoridb.local}"
HTTP_ADDR="127.0.0.1:${HTTP_PORT}"
GRAPH_ADDR="127.0.0.1:${GRAPH_PORT}"
CLAUDE_SKILLS_ROOT="${HOME}/.claude/skills"
CODEX_SKILLS_ROOT="${HOME}/.agents/skills"
MEMORY_SKILL_NAME="byoridb-memory"
DESIGN_SKILL_NAME="byori-design"

TAG=""; ENGINE_TAG="${BYORI_ENGINE_TAG:-$ENGINE_TAG_DEFAULT}"
WITH_HOOKS=1; UNINSTALL=0; BINARY=""; ASSETS=""; NO_SERVICE=0; NO_CLAUDE=0; NO_CODEX=0

c_blue=$'\033[34m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
warn() { printf '%s!  %s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --with-hooks) WITH_HOOKS=1 ;;   # accepted for compatibility; now the default
    --no-hooks)   WITH_HOOKS=0 ;;
    --uninstall)  UNINSTALL=1 ;;
    --no-service) NO_SERVICE=1 ;;
    --no-claude)  NO_CLAUDE=1 ;;
    --no-codex)   NO_CODEX=1 ;;
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
  log "uninstalling the ByoriDB runtime and agent integrations"
  if [ "$SERVICE" = launchd ]; then
    plist="${HOME}/Library/LaunchAgents/${LABEL}.plist"
    [ -f "$plist" ] && { launchctl unload -w "$plist" 2>/dev/null || true; rm -f "$plist"; }
  else
    systemctl --user disable --now "${LABEL}.service" 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/${LABEL}.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  command -v claude >/dev/null 2>&1 && claude mcp remove byoridb -s user 2>/dev/null || true
  command -v codex >/dev/null 2>&1 && codex mcp remove byoridb 2>/dev/null || true
  rm -rf \
    "$CLAUDE_SKILLS_ROOT/$MEMORY_SKILL_NAME" \
    "$CLAUDE_SKILLS_ROOT/$DESIGN_SKILL_NAME" \
    "$CODEX_SKILLS_ROOT/$MEMORY_SKILL_NAME" \
    "$CODEX_SKILLS_ROOT/$DESIGN_SKILL_NAME"
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

# `--engine-tag latest` asks for the newest engine release instead of the tag this
# byori version was validated against, so the engine stops waiting on a byori
# release to move forward. Unlike the asset tag this never aborts the install: the
# API is rate limited for unauthenticated callers and may be unreachable, and an
# install that lands the validated engine is still a correct install.
resolve_engine_tag() {
  if curl -fsSL "https://api.github.com/repos/${ENGINE_REPO}/releases/latest" \
      -o "$WORK/engine-rel.json"; then
    awk -F'"' '/"tag_name"/{print $4; exit}' "$WORK/engine-rel.json"
  fi
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
if [ "$ENGINE_TAG" = latest ]; then
  resolved_engine_tag="$(resolve_engine_tag)"
  if [ -n "$resolved_engine_tag" ]; then
    ENGINE_TAG="$resolved_engine_tag"
    log "latest engine release: $ENGINE_TAG"
  else
    ENGINE_TAG="$ENGINE_TAG_DEFAULT"
    warn "could not resolve the latest engine release; using $ENGINE_TAG"
  fi
fi
# Both tags are interpolated into download URLs, and the engine tag is recorded
# in the engine manifest. Keep them to a charset that cannot alter either.
for candidate in "$TAG" "$ENGINE_TAG"; do
  case "$candidate" in
    "") ;;
    *[!A-Za-z0-9._+-]*) die "invalid tag: $candidate" ;;
  esac
done
mkdir -p "$BYORIDB_HOME/bin" "$BYORIDB_HOME/data" "$BYORIDB_HOME/logs"
chmod 700 "$BYORIDB_HOME" "$BYORIDB_HOME/data" "$BYORIDB_HOME/logs" 2>/dev/null || true
# Resolve and validate every Byori-owned asset before replacing the live runtime.
# This keeps a failed download/render/compile from leaving mixed MCP/CLI versions.
[ -z "$TAG" ] && [ -z "$ASSETS" ] && { TAG="$(resolve_tag)"; [ -n "$TAG" ] || die "could not resolve latest byori release tag"; }
get "mcp/byoridb_mcp.py" "$WORK/byoridb_mcp.py"
get "cli/byori.py" "$WORK/byori.py"
# byori.py imports this from beside itself; `byori init` is broken without it.
get "cli/archaeology.py" "$WORK/archaeology.py"
get "cli/doctor.py" "$WORK/doctor.py"
get "templates/run-server.sh" "$WORK/run-server.sh"
get "templates/run-mcp.sh" "$WORK/run-mcp.sh"
get "templates/run-byori.sh" "$WORK/run-byori.sh"
get "adapters/claude/skills/byoridb-memory/SKILL.md" "$WORK/byoridb-memory.SKILL.md"
get "adapters/claude/skills/byori-design/SKILL.md" "$WORK/byori-design.SKILL.md"
get "adapters/claude/skills/byori-design/agents/openai.yaml" "$WORK/byori-design.openai.yaml"
if [ "$SERVICE" = launchd ]; then
  get "templates/com.byoridb.local.plist" "$WORK/service.template"
else
  get "templates/byoridb-local.service" "$WORK/service.template"
fi
if [ "$WITH_HOOKS" = 1 ]; then
  get "adapters/claude/hooks.snippet.json" "$WORK/hooks.json"
  "$PYTHON" -m json.tool "$WORK/hooks.json" >/dev/null
fi
render "$WORK/run-server.sh" "$WORK/run-server.rendered.sh"
render "$WORK/run-mcp.sh" "$WORK/run-mcp.rendered.sh"
render "$WORK/run-byori.sh" "$WORK/run-byori.rendered.sh"
"$PYTHON" -m py_compile "$WORK/byoridb_mcp.py" "$WORK/byori.py" "$WORK/archaeology.py" "$WORK/doctor.py"
bash -n "$WORK/run-server.rendered.sh" "$WORK/run-mcp.rendered.sh" \
  "$WORK/run-byori.rendered.sh"

# 1) stage and install the engine binary (from ENGINE_REPO at the resolved ENGINE_TAG)
mkdir -p "$WORK/engine"
if [ -n "$BINARY" ]; then
  log "using local binary: $BINARY"
  cp "$BINARY" "$WORK/engine/byoridb-server"
else
  url="https://github.com/${ENGINE_REPO}/releases/download/${ENGINE_TAG}/byoridb-${ENGINE_TAG}-${TARGET}.tar.gz"
  log "downloading engine ${ENGINE_TAG}: $url"
  curl -fSL "$url" -o "$WORK/b.tar.gz" || die "download failed (does engine release $ENGINE_TAG have $TARGET?)"
  tar -xzf "$WORK/b.tar.gz" -C "$WORK/engine"
fi
[ -f "$WORK/engine/byoridb-server" ] || die "engine archive is missing byoridb-server"
cp "$WORK/engine/byoridb-server" "$BYORIDB_HOME/bin/byoridb-server"
[ -f "$WORK/engine/byoridb-cli" ] && cp "$WORK/engine/byoridb-cli" "$BYORIDB_HOME/bin/byoridb-cli"
chmod +x "$BYORIDB_HOME/bin/byoridb-server" 2>/dev/null || true
[ -f "$BYORIDB_HOME/bin/byoridb-cli" ] && chmod +x "$BYORIDB_HOME/bin/byoridb-cli"

# 1b) record which engine this is. byoridb-server exposes no --version and
#     ignores its arguments, so without this file identifying an installed
#     engine means running `strings` over the binary.
if command -v shasum >/dev/null 2>&1; then
  engine_sha="$(shasum -a 256 "$BYORIDB_HOME/bin/byoridb-server" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  engine_sha="$(sha256sum "$BYORIDB_HOME/bin/byoridb-server" | awk '{print $1}')"
else
  engine_sha=""
fi
if [ -n "$BINARY" ]; then engine_source="local-binary"; engine_ref=""; else engine_source="$url"; engine_ref="$ENGINE_TAG"; fi
# Written by python rather than a heredoc: the values include a path and a URL,
# and a hand-rolled JSON string is one stray quote away from an unreadable file.
"$PYTHON" -c '
import json, sys
path, tag, target, source, digest, installed_at, binary = sys.argv[1:8]
json.dump(
    {
        "tag": tag,
        "target": target,
        "source": source,
        "binary_path": binary,
        "sha256": digest,
        "installed_at": installed_at,
    },
    open(path, "w"),
    indent=2,
    sort_keys=True,
)
' "$BYORIDB_HOME/engine.json" "$engine_ref" "$TARGET" "$engine_source" "$engine_sha" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BYORIDB_HOME/bin/byoridb-server"
log "recorded engine build: ${engine_ref:-local} (${engine_sha:0:12})"

# 2) MCP server + multi-agent CLI + rendered wrappers
log "installing MCP server + multi-agent CLI + service wrappers"
cp "$WORK/byoridb_mcp.py" "$BYORIDB_HOME/byoridb_mcp.py"
cp "$WORK/byori.py" "$BYORIDB_HOME/bin/byori.py"
cp "$WORK/archaeology.py" "$BYORIDB_HOME/bin/archaeology.py"
cp "$WORK/doctor.py" "$BYORIDB_HOME/bin/doctor.py"
cp "$WORK/run-server.rendered.sh" "$BYORIDB_HOME/bin/run-server.sh"
cp "$WORK/run-mcp.rendered.sh" "$BYORIDB_HOME/bin/run-mcp.sh"
cp "$WORK/run-byori.rendered.sh" "$BYORIDB_HOME/bin/byori"
chmod 644 "$BYORIDB_HOME/bin/byori.py" "$BYORIDB_HOME/bin/archaeology.py" "$BYORIDB_HOME/bin/doctor.py"
chmod +x "$BYORIDB_HOME/bin/run-server.sh" "$BYORIDB_HOME/bin/run-mcp.sh" \
  "$BYORIDB_HOME/bin/byori"

# 3) env: preserve the root secret across reinstalls (including the legacy
#    BYORIDB_PASSWORD key) so an existing data directory remains accessible.
#    Always rewrite derived endpoint/user so server and clients stay aligned.
pw=""
credential_state="generated"
if [ -f "$BYORIDB_HOME/env" ]; then
  pw="$(sed -n 's/^BYORIDB_ROOT_PASSWORD=//p' "$BYORIDB_HOME/env" | sed -n '1p')"
  [ -n "$pw" ] || pw="$(sed -n 's/^BYORIDB_PASSWORD=//p' "$BYORIDB_HOME/env" | sed -n '1p')"
  [ -z "$pw" ] || credential_state="preserved"
fi
[ -n "$pw" ] || pw="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
umask 177
cat > "$BYORIDB_HOME/env" <<EOF
BYORIDB_ROOT_PASSWORD=${pw}
BYORIDB_HTTP=http://${HTTP_ADDR}
BYORIDB_USER=root
BYORIDB_MCP_PROFILE=safe
EOF
umask 022
chmod 600 "$BYORIDB_HOME/env"
log "wrote $BYORIDB_HOME/env (secret ${credential_state}; endpoint=http://${HTTP_ADDR})"

# 4) service (always-on)
start_service() {
  if [ "$SERVICE" = launchd ]; then
    plist="${HOME}/Library/LaunchAgents/${LABEL}.plist"
    cp "$WORK/service.template" "$WORK/svc.plist"
    mkdir -p "${HOME}/Library/LaunchAgents"; render "$WORK/svc.plist" "$plist"
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load -w "$plist"
  else
    unit="${HOME}/.config/systemd/user/${LABEL}.service"
    cp "$WORK/service.template" "$WORK/svc.service"
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

# Health is intentionally unauthenticated and can be served by a stale process
# that already owns the port. Prove that the configured credential reaches the
# same server before reporting success or wiring MCP clients. Repeat with closed
# connections to make a duplicate listener much less likely to pass by chance.
auth_request="$WORK/session-request.json"
auth_response="$WORK/session-response.json"
printf '%s' "$pw" | "$PYTHON" -c \
  'import json, sys; print(json.dumps({"username": "root", "password": sys.stdin.read()}))' \
  > "$auth_request"
for auth_attempt in 1 2 3; do
  auth_status="$(curl -sS -o "$auth_response" -w '%{http_code}' \
    -H 'Content-Type: application/json' -H 'Connection: close' \
    --data-binary "@$auth_request" "http://${HTTP_ADDR}/api/v1/session" || true)"
  case "$auth_status" in
    2??) ;;
    401|403)
      die "server is healthy but rejected the installed credential — another ByoriDB process may own ${HTTP_ADDR}, or the data credential does not match"
      ;;
    *)
      die "server health passed but authenticated session verification failed (HTTP ${auth_status:-unavailable})"
      ;;
  esac
  if ! session_id="$("$PYTHON" - "$auth_response" <<'PY'
import json
import sys

try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))["session_id"]
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
value = str(value)
if not value.isdigit():
    raise SystemExit(1)
print(value)
PY
  )"; then
    die "server returned an invalid authenticated session response"
  fi
  curl -fsS -X DELETE -H 'Connection: close' \
    "http://${HTTP_ADDR}/api/v1/session/${session_id}" >/dev/null 2>&1 || true
done
rm -f "$auth_request" "$auth_response"
log "server credential verified"

# 6) register MCP server with Claude Code
if [ "$NO_CLAUDE" = 1 ]; then
  warn "skipping Claude Code wiring (--no-claude): MCP registration + skills install"
elif command -v claude >/dev/null 2>&1; then
  claude mcp remove byoridb -s user >/dev/null 2>&1 || true
  claude mcp add byoridb -s user -- "$BYORIDB_HOME/bin/run-mcp.sh" && log "registered MCP server 'byoridb' (user scope)"
else
  warn "claude CLI not found — register manually: claude mcp add byoridb -s user -- $BYORIDB_HOME/bin/run-mcp.sh"
fi

# 7) skills
if [ "$NO_CLAUDE" != 1 ]; then
  log "installing skills -> $CLAUDE_SKILLS_ROOT"
  mkdir -p \
    "$CLAUDE_SKILLS_ROOT/$MEMORY_SKILL_NAME" \
    "$CLAUDE_SKILLS_ROOT/$DESIGN_SKILL_NAME/agents"
  cp "$WORK/byoridb-memory.SKILL.md" \
    "$CLAUDE_SKILLS_ROOT/$MEMORY_SKILL_NAME/SKILL.md"
  cp "$WORK/byori-design.SKILL.md" \
    "$CLAUDE_SKILLS_ROOT/$DESIGN_SKILL_NAME/SKILL.md"
  cp "$WORK/byori-design.openai.yaml" \
    "$CLAUDE_SKILLS_ROOT/$DESIGN_SKILL_NAME/agents/openai.yaml"
fi

# 8) Codex wiring (MCP + skills; non-fatal — the base install works without it)
if [ "$NO_CODEX" = 1 ]; then
  warn "skipping Codex wiring (--no-codex)"
elif command -v codex >/dev/null 2>&1; then
  codex mcp remove byoridb >/dev/null 2>&1 || true
  if codex mcp add byoridb -- "$BYORIDB_HOME/bin/run-mcp.sh" >/dev/null 2>&1; then
    log "registered MCP server 'byoridb' with Codex"
  else
    warn "codex mcp add failed — register manually: codex mcp add byoridb -- $BYORIDB_HOME/bin/run-mcp.sh"
  fi
  mkdir -p \
    "$CODEX_SKILLS_ROOT/$MEMORY_SKILL_NAME" \
    "$CODEX_SKILLS_ROOT/$DESIGN_SKILL_NAME/agents"
  cp "$WORK/byoridb-memory.SKILL.md" \
    "$CODEX_SKILLS_ROOT/$MEMORY_SKILL_NAME/SKILL.md"
  cp "$WORK/byori-design.SKILL.md" \
    "$CODEX_SKILLS_ROOT/$DESIGN_SKILL_NAME/SKILL.md"
  cp "$WORK/byori-design.openai.yaml" \
    "$CODEX_SKILLS_ROOT/$DESIGN_SKILL_NAME/agents/openai.yaml"
  log "installing skills -> $CODEX_SKILLS_ROOT"
else
  warn "codex CLI not found — skipped Codex wiring (connect later: codex mcp add byoridb -- $BYORIDB_HOME/bin/run-mcp.sh)"
fi

# 9) hooks
#
# On by default. A memory the agent has to remember to look for loses to one that
# is already in its context: hosts ship a file-based memory whose index loads every
# session, so without these hooks the graph stays connected and empty. The merge
# below is additive and idempotent, and it backs the file up first.
if [ "$WITH_HOOKS" = 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    settings="${HOME}/.claude/settings.json"; mkdir -p "${HOME}/.claude"
    [ -f "$settings" ] || echo '{}' > "$settings"
    backup="${settings}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$settings" "$backup"
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

printf '\n%sByoriDB runtime and agent integrations installed.%s\n' "$c_blue" "$c_off"
printf '  home     : %s\n' "$BYORIDB_HOME"
printf '  server   : http://%s  (health: curl -s http://%s/health)\n' "$HTTP_ADDR" "$HTTP_ADDR"
printf '  engine   : %s  (recorded in %s/engine.json)\n' "${engine_ref:-local binary}" "$BYORIDB_HOME"
printf '  mcp      : %s/bin/run-mcp.sh\n' "$BYORIDB_HOME"
printf '  cli      : %s/bin/byori  (try: %s/bin/byori --help)\n' "$BYORIDB_HOME" "$BYORIDB_HOME"
case ":${PATH}:" in
  *":${BYORIDB_HOME}/bin:"*) ;;
  *) printf '  path     : export PATH="%s/bin:$PATH"\n' "$BYORIDB_HOME" ;;
esac
if [ "$NO_CLAUDE" != 1 ]; then
  printf '  skills   : %s/{%s,%s}/   (claude mcp list -> byoridb)\n' \
    "$CLAUDE_SKILLS_ROOT" "$MEMORY_SKILL_NAME" "$DESIGN_SKILL_NAME"
fi
if [ "$NO_CODEX" != 1 ] && command -v codex >/dev/null 2>&1; then
  printf '  codex    : %s/{%s,%s}/   (codex mcp list -> byoridb)\n' \
    "$CODEX_SKILLS_ROOT" "$MEMORY_SKILL_NAME" "$DESIGN_SKILL_NAME"
fi
printf 'Restart your agent CLI so it picks up the MCP server and skills.\n'
