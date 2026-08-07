#!/usr/bin/env bash
# Rendered by install.sh. The CLI reads its Byori home env file itself only
# when a command needs ByoriDB access, so this launcher never exports secrets.
set -euo pipefail

export BYORIDB_HOME="@BYORIDB_HOME@"
exec "@PYTHON@" "@BYORIDB_HOME@/bin/byori.py" "$@"
