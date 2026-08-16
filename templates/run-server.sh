#!/bin/sh
# Rendered by install.sh — do not edit; re-run the installer instead.
set -a
. "@BYORIDB_HOME@/env"
set +a

# Refuse to start without a root password rather than letting the engine
# generate one. Engine builds before the 2026-08-08 hardening write that
# generated credential into the server log, so a missing value here is how a
# working root password ends up in a world-readable-by-owner log file. The
# installer always writes this key; nothing else guaranteed it was still there.
if [ -z "${BYORIDB_ROOT_PASSWORD:-}" ]; then
  echo "run-server.sh: BYORIDB_ROOT_PASSWORD is empty in @BYORIDB_HOME@/env;" \
       "refusing to start. Re-run the Byori installer to restore it." >&2
  exit 78   # EX_CONFIG
fi

set -a
export BYORIDB__STORAGE__DATA_PATHS="@BYORIDB_HOME@/data"
export BYORIDB__SERVER__HTTP_ADDR="@HTTP_ADDR@"
export BYORIDB__SERVER__GRAPH_ADDR="@GRAPH_ADDR@"
export RUST_LOG=info
set +a
umask 077   # data.redb / logs readable by owner only (memory contents are private)
exec "@BYORIDB_HOME@/bin/byoridb-server"
