#!/bin/sh
# Rendered by install.sh — do not edit; re-run the installer instead.
set -a
. "@BYORIDB_HOME@/env"
set +a
exec "@PYTHON@" "@BYORIDB_HOME@/byoridb_mcp.py"
