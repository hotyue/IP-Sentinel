#!/bin/bash

set -euo pipefail

INSTALL_DIR="${IP_SENTINEL_INSTALL_DIR:-/opt/ip_sentinel}"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
BACKUP_ROOT="${IP_SENTINEL_BACKUP_DIR:-${INSTALL_DIR}/backups}"
SYSTEMD_DIR="${IP_SENTINEL_SYSTEMD_DIR:-/etc/systemd/system}"
CRONTAB_FILE="${IP_SENTINEL_CRONTAB_FILE:-}"
SCHEDULER_FILE="${IP_SENTINEL_SCHEDULER_FILE:-${INSTALL_DIR}/core/sentinel_scheduler.sh}"
FORCE_NO_SYSTEMD="${IP_SENTINEL_FORCE_NO_SYSTEMD:-0}"

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
BACKUP_DIR="${BACKUP_ROOT}/geoanchor-rollback-${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

if [ -d "${INSTALL_DIR}/state" ]; then
    cp -R "${INSTALL_DIR}/state" "${BACKUP_DIR}/state"
fi
if [ -d "${INSTALL_DIR}/profiles" ]; then
    cp -R "${INSTALL_DIR}/profiles" "${BACKUP_DIR}/profiles"
fi

if [ -f "$CONFIG_FILE" ]; then
    if grep -q "^GEOANCHOR_ROLLOUT_MODE=" "$CONFIG_FILE"; then
        sed -i 's/^GEOANCHOR_ROLLOUT_MODE=.*/GEOANCHOR_ROLLOUT_MODE="normal"/' "$CONFIG_FILE"
    else
        echo 'GEOANCHOR_ROLLOUT_MODE="normal"' >> "$CONFIG_FILE"
    fi
fi

ROLLED_BACK_WITH="manual"
if [ "$FORCE_NO_SYSTEMD" != "1" ] && command -v systemctl >/dev/null 2>&1 && [ -f "${SYSTEMD_DIR}/ip-sentinel-runner.service" ]; then
    systemctl stop ip-sentinel-runner.timer ip-sentinel-runner.service >/dev/null 2>&1 || true
    sed -i "s#ExecStart=/bin/bash ${INSTALL_DIR}/core/runner_v2.sh#ExecStart=/bin/bash ${INSTALL_DIR}/core/runner.sh#g" "${SYSTEMD_DIR}/ip-sentinel-runner.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now ip-sentinel-runner.timer >/dev/null 2>&1 || true
    ROLLED_BACK_WITH="systemd"
else
    if [ -f "$SCHEDULER_FILE" ]; then
        sed -i "s#runner_v2.sh#runner.sh#g" "$SCHEDULER_FILE"
    fi

    if [ -n "$CRONTAB_FILE" ] && [ -f "$CRONTAB_FILE" ]; then
        sed -i "s#runner_v2.sh#runner.sh#g" "$CRONTAB_FILE"
    elif command -v crontab >/dev/null 2>&1; then
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | sed 's#runner_v2.sh#runner.sh#g' > "$TMP_CRON" || true
        crontab "$TMP_CRON" >/dev/null 2>&1 || true
        rm -f "$TMP_CRON"
    fi
    ROLLED_BACK_WITH="cron_or_scheduler"
fi

jq -n \
    --arg backup_dir "$BACKUP_DIR" \
    --arg method "$ROLLED_BACK_WITH" \
    '{
        ok: true,
        backup_dir: $backup_dir,
        method: $method,
        preserved: ["state", "profiles", "logs"]
    }'
