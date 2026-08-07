#!/bin/sh
# Rendered by install.sh — do not edit; re-run the installer instead.
# The env file supplies defaults, so a caller-supplied profile has to survive
# sourcing it: orchestrated workers pin BYORIDB_MCP_PROFILE=readonly on the
# child environment and must not be silently restored to the writable default.
caller_profile="${BYORIDB_MCP_PROFILE:-}"
set -a
. "@BYORIDB_HOME@/env"
set +a
if [ -n "$caller_profile" ]; then
  BYORIDB_MCP_PROFILE="$caller_profile"
  export BYORIDB_MCP_PROFILE
fi
unset caller_profile
exec "@PYTHON@" "@BYORIDB_HOME@/byoridb_mcp.py"
