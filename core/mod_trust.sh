#!/bin/bash

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

[ -f "$CONFIG_FILE" ] || exit 1
source "$CONFIG_FILE"

PYTHON_BIN="python3"
if [ -n "${GEOANCHOR_VENV:-}" ] && [ -x "${GEOANCHOR_VENV}/bin/python" ]; then
    PYTHON_BIN="${GEOANCHOR_VENV}/bin/python"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "mod_local_trust.py requires python3" >&2
    exit 1
fi

if [ ! -f "${INSTALL_DIR}/core/mod_local_trust.py" ]; then
    echo "mod_local_trust.py is missing" >&2
    exit 1
fi

exec "$PYTHON_BIN" "${INSTALL_DIR}/core/mod_local_trust.py" "$@"