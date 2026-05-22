#!/bin/bash

set -euo pipefail

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行 install.sh"
    exit 1
fi

source "$CONFIG_FILE"

STATE_DIR="${INSTALL_DIR}/state"
LOG_DIR="${INSTALL_DIR}/logs"
RUNNER_V2_LOG="${LOG_DIR}/runner_v2.log"
PREFLIGHT_FILE="${STATE_DIR}/preflight-last.json"
PROBE_BEFORE_FILE="${STATE_DIR}/probe-before.json"
PROBE_AFTER_FILE="${STATE_DIR}/probe-after.json"

mkdir -p "$STATE_DIR" "$LOG_DIR"

DRY_RUN="false"
NO_JITTER="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --no-jitter)
            NO_JITTER="true"
            shift
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

exec 201>"/tmp/ip_sentinel_geoanchor_v2.lock"
if ! flock -n 201; then
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] runner_v2 lock busy, skipping" >> "$RUNNER_V2_LOG"
    exit 0
fi

log() {
    local level=$1
    local msg=$2
    local local_ver="${AGENT_VERSION:-未知}"
    local line="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [v${local_ver}] [${level}] [RunnerV2] [${REGION_CODE}] ${msg}"
    echo "$line" >> "$RUNNER_V2_LOG"
    echo "$line" >> "$LOG_FILE"
    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$line"
    fi
}

PYTHON_BIN="python3"
if [ -n "${GEOANCHOR_VENV:-}" ] && [ -x "${GEOANCHOR_VENV}/bin/python" ]; then
    PYTHON_BIN="${GEOANCHOR_VENV}/bin/python"
fi

export IP_SENTINEL_CONFIG="$CONFIG_FILE"
export IP_SENTINEL_INSTALL_DIR="$INSTALL_DIR"

if [ "$NO_JITTER" != "true" ] && [ -z "${RUNNER_V2_NO_JITTER:-}" ] && [ ! -t 1 ]; then
    JITTER_TIME=$((RANDOM % 180))
    log "INFO " "后台唤醒，进入 runner_v2 随机削峰休眠 ${JITTER_TIME} 秒。"
    sleep "$JITTER_TIME"
fi

dry_run_payload() {
    local state_json action_json
    state_json=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" get-state --json)
    action_json=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" next-action --json)
    jq -n \
        --argjson state "$state_json" \
        --argjson next_action "$action_json" \
        '{
            ok: true,
            dry_run: true,
            state: $state,
            next_action: $next_action
        }'
}

run_action() {
    local action=$1
    local action_output=""
    local action_status=0

    case "$action" in
        anchor_browser)
            set +e
            action_output=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_anchor_browser.py" --mode auto 2>&1)
            action_status=$?
            set -e
            ;;
        local_trust)
            set +e
            action_output=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_local_trust.py" --mode auto 2>&1)
            action_status=$?
            set -e
            ;;
        probe_only|cooldown|idle)
            jq -n --arg action "$action" '{ok: true, skipped: true, action: $action}'
            return 0
            ;;
        *)
            jq -n --arg action "$action" '{ok: false, action: $action, error: "unknown_action"}'
            return 0
            ;;
    esac

    if printf '%s' "$action_output" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$action_output"
    else
        jq -n \
            --arg action "$action" \
            --arg output "$action_output" \
            --argjson exit_code "$action_status" \
            '{ok: false, action: $action, exit_code: $exit_code, output: $output}'
    fi

    return 0
}

if [ "$DRY_RUN" = "true" ]; then
    log "INFO " "执行 runner_v2 dry-run。"
    dry_run_payload
    exit 0
fi

log "INFO " "runner_v2 开始执行反馈式闭环调度。"

PREFLIGHT_JSON=$(bash "${INSTALL_DIR}/core/preflight.sh")
printf '%s\n' "$PREFLIGHT_JSON" > "$PREFLIGHT_FILE"
PREFLIGHT_OK=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ok // false' 2>/dev/null)
PREFLIGHT_STATE=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.state_hint // "UNKNOWN"' 2>/dev/null)

PROBE_BEFORE_JSON=""
STATE_BEFORE_JSON=""
ACTION_JSON=""
ACTION_RESULT_JSON=""
PROBE_AFTER_JSON=""
STATE_AFTER_JSON=""
ACTION_NAME=""

if [ "$PREFLIGHT_OK" != "true" ]; then
    log "WARN " "Preflight 未通过，状态提示 ${PREFLIGHT_STATE}，仅执行轻量 probe。"
    "$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" set-state "$PREFLIGHT_STATE" --reason preflight_failed >/dev/null
    PROBE_BEFORE_JSON=$(bash "${INSTALL_DIR}/core/mod_probe.sh" --light --json)
    printf '%s\n' "$PROBE_BEFORE_JSON" > "$PROBE_BEFORE_FILE"
    "$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" update-from-probe "$PROBE_BEFORE_FILE" >/dev/null
    STATE_AFTER_JSON=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" get-state --json)
    jq -n \
        --argjson preflight "$PREFLIGHT_JSON" \
        --argjson probe_before "$PROBE_BEFORE_JSON" \
        --argjson state_after "$STATE_AFTER_JSON" \
        '{
            ok: true,
            preflight: $preflight,
            probe_before: $probe_before,
            action: "probe_only",
            state_after: $state_after
        }'
    exit 0
fi

PROBE_BEFORE_JSON=$(bash "${INSTALL_DIR}/core/mod_probe.sh" --json)
printf '%s\n' "$PROBE_BEFORE_JSON" > "$PROBE_BEFORE_FILE"
"$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" update-from-probe "$PROBE_BEFORE_FILE" >/dev/null
STATE_BEFORE_JSON=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" get-state --json)
ACTION_JSON=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" next-action --json)
ACTION_NAME=$(printf '%s' "$ACTION_JSON" | jq -r '.action')

if [ "${GEOANCHOR_ROLLOUT_MODE:-normal}" = "conservative" ] && { [ "$ACTION_NAME" = "anchor_browser" ] || [ "$ACTION_NAME" = "local_trust" ]; }; then
    log "WARN " "灰度阶段处于 conservative 模式，已将动作 ${ACTION_NAME} 降级为 probe_only。"
    ACTION_NAME="probe_only"
    ACTION_JSON=$(jq -n --arg action "$ACTION_NAME" --arg reason "rollout_conservative_mode" '{action: $action, reason: $reason}')
fi

log "INFO " "状态机给出的下一步动作: ${ACTION_NAME}"
ACTION_RESULT_JSON=$(run_action "$ACTION_NAME")

if [ "$ACTION_NAME" = "anchor_browser" ] || [ "$ACTION_NAME" = "local_trust" ] || [ "$ACTION_NAME" = "probe_only" ]; then
    PROBE_AFTER_JSON=$(bash "${INSTALL_DIR}/core/mod_probe.sh" --json)
    printf '%s\n' "$PROBE_AFTER_JSON" > "$PROBE_AFTER_FILE"
    "$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" update-from-probe "$PROBE_AFTER_FILE" >/dev/null
fi

STATE_AFTER_JSON=$("$PYTHON_BIN" "${INSTALL_DIR}/core/mod_state.py" get-state --json)

log "INFO " "runner_v2 调度完成，动作=${ACTION_NAME}"
jq -n \
    --argjson preflight "$PREFLIGHT_JSON" \
    --argjson probe_before "$PROBE_BEFORE_JSON" \
    --argjson state_before "$STATE_BEFORE_JSON" \
    --argjson next_action "$ACTION_JSON" \
    --argjson action_result "$ACTION_RESULT_JSON" \
    --argjson probe_after "${PROBE_AFTER_JSON:-null}" \
    --argjson state_after "$STATE_AFTER_JSON" \
    '{
        ok: true,
        preflight: $preflight,
        probe_before: $probe_before,
        state_before: $state_before,
        next_action: $next_action,
        action_result: $action_result,
        probe_after: $probe_after,
        state_after: $state_after
    }'
