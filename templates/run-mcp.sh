#!/bin/sh
# Rendered by install.sh — do not edit; re-run the installer instead.
# The env file supplies defaults, so a caller-supplied value has to survive
# sourcing it:
#   - orchestrated workers pin BYORIDB_MCP_PROFILE=readonly on the child
#     environment and must not be silently restored to the writable default.
#   - a caller that names a memory space names the project. The installer never
#     writes BYORIDB_MEMORY_SPACE to the env file, but a hand-edited one would
#     otherwise put every project back in a single shared space.
caller_profile="${BYORIDB_MCP_PROFILE:-}"
caller_space="${BYORIDB_MEMORY_SPACE:-}"
set -a
. "@BYORIDB_HOME@/env"
set +a
if [ -n "$caller_profile" ]; then
  BYORIDB_MCP_PROFILE="$caller_profile"
  export BYORIDB_MCP_PROFILE
fi
if [ -n "$caller_space" ]; then
  BYORIDB_MEMORY_SPACE="$caller_space"
  export BYORIDB_MEMORY_SPACE
fi
unset caller_profile caller_space
exec "@PYTHON@" "@BYORIDB_HOME@/byoridb_mcp.py"
