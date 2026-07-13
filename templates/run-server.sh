#!/bin/sh
# Rendered by install.sh — do not edit; re-run the installer instead.
set -a
. "@BYORIDB_HOME@/env"
export BYORIDB__STORAGE__DATA_PATHS="@BYORIDB_HOME@/data"
export BYORIDB__SERVER__HTTP_ADDR="@HTTP_ADDR@"
export BYORIDB__SERVER__GRAPH_ADDR="@GRAPH_ADDR@"
export RUST_LOG=info
set +a
umask 077   # data.redb / logs readable by owner only (memory contents are private)
exec "@BYORIDB_HOME@/bin/byoridb-server"
