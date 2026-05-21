#!/bin/bash

# ==========================================================
# 脚本名称: runner.sh (IP-Sentinel 主控调度引擎 - 动态锚点版)
# 核心功能: 防并发延迟启动、功能开关(Feature Flag)自适应、多模块概率轮盘调度
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# 1. 检查并加载本地冷数据配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行 install.sh"
    exit 1
fi
source "$CONFIG_FILE"

STATE_DIR="${INSTALL_DIR}/state"
BOT_RISK_FILE="${STATE_DIR}/bot_risk.json"
PREFLIGHT_FILE="${STATE_DIR}/preflight-last.json"
GEO_STATE_FILE="${STATE_DIR}/geo_state.json"

# ================== [新增: 文件排他锁，防止并发重入引发内存雪崩] ==================
exec 200>"/tmp/ip_sentinel_runner.lock"
if ! flock -n 200; then
    echo "[$(date)] ⚠️ 上一轮巡逻任务尚未结束，本次触发自动取消。" >> "$LOG_FILE"
    exit 0
fi
# ==================================================================================

# 2. 全局日志写入函数 (导出给子进程共享使用，v3.4.0 引入版本探针)
log() {
    local module=$1
    local level=$2
    local msg=$3
    # [v3.4.0 核心] 提取当前配置中的版本锚点
    local local_ver="${AGENT_VERSION:-未知}"
    
    # 保证日志目录存在
    mkdir -p "${INSTALL_DIR}/logs"
    
    # 日志格式注入 [版本号] 追踪标识
    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$level" "$module" "$REGION_CODE" "$msg")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    # 强制推送到 Systemd Journal (如果系统支持)
    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    else
        # 降级输出到 stdout，让 Systemd 捕获
        echo "$core_msg"
    fi
}
export -f log
export CONFIG_FILE INSTALL_DIR

bot_risk_active() {
    [ -f "$BOT_RISK_FILE" ] || return 1

    local active expires_at_epoch
    active=$(jq -r '.active // false' "$BOT_RISK_FILE" 2>/dev/null)
    expires_at_epoch=$(jq -r '.expires_at_epoch // 0' "$BOT_RISK_FILE" 2>/dev/null)

    [ "$active" = "true" ] && [ "$expires_at_epoch" -gt "$(date -u +%s)" ]
}

update_geo_state_from_preflight() {
    local state_hint=$1
    local preflight_payload=$2

    printf '%s\n' "$preflight_payload" | jq \
        --arg current_state "$state_hint" \
        --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{
            current_state: $current_state,
            updated_at: $updated_at,
            last_preflight_ok: .ok,
            last_preflight: .
        }' > "$GEO_STATE_FILE"
}

# 3. 防僵尸网络特征 (Cron Jitter) - 核心隐蔽逻辑
# 配合每 20 分钟的调度周期，将随机休眠控制在 0 到 180 秒内，彻底打散全球并发请求
if [ -t 1 ]; then
    log "SYSTEM" "INFO " "💻 检测到人工终端干预，跳过静默休眠，立即执行任务！"
else
    JITTER_TIME=$((RANDOM % 180))
    log "SYSTEM" "INFO " "⏱️ 主控引擎由后台唤醒，进入防并发随机休眠状态: ${JITTER_TIME} 秒..."
    sleep $JITTER_TIME
fi

# 4. 唤醒并读取功能开关，执行智能调度 (Feature Flag)
log "SYSTEM" "INFO" "休眠结束，开始计算本轮任务轮盘..."
mkdir -p "$STATE_DIR"

if [ -x "${INSTALL_DIR}/core/preflight.sh" ]; then
    PREFLIGHT_JSON=$(bash "${INSTALL_DIR}/core/preflight.sh")
    printf '%s\n' "$PREFLIGHT_JSON" > "$PREFLIGHT_FILE"
    PREFLIGHT_OK=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.ok // false' 2>/dev/null)
    PREFLIGHT_STATE=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.state_hint // "UNKNOWN"' 2>/dev/null)
    update_geo_state_from_preflight "$PREFLIGHT_STATE" "$PREFLIGHT_JSON"

    if [ "$PREFLIGHT_OK" != "true" ]; then
        PREFLIGHT_ERRORS=$(printf '%s' "$PREFLIGHT_JSON" | jq -r '.errors | join("; ")' 2>/dev/null)
        log "SYSTEM" "WARN" "Preflight 未通过，当前状态写入 ${PREFLIGHT_STATE}，本轮主动跳过所有养护行为。原因: ${PREFLIGHT_ERRORS:-未知}"
        exit 0
    fi
else
    log "SYSTEM" "WARN" "未发现 preflight.sh，继续沿用旧版调度路径。"
fi

TARGET_MOD=""
MOD_NAME=""
GOOGLE_ALLOWED="$ENABLE_GOOGLE"

if [ "$ENABLE_GOOGLE" == "true" ] && bot_risk_active; then
    GOOGLE_ALLOWED="false"
    BOT_RISK_UNTIL=$(jq -r '.expires_at // ""' "$BOT_RISK_FILE" 2>/dev/null)
    log "SYSTEM" "WARN" "检测到 BOT_RISK 冷却中，自动跳过 Google 模块，冷却截止: ${BOT_RISK_UNTIL:-未知}"
fi

# 智能轮盘赌算法
if [ "$GOOGLE_ALLOWED" == "true" ] && [ "$ENABLE_TRUST" == "true" ]; then
    # 双管齐下: 70% 概率跑 Google 稳固定位，30% 概率跑 Trust 洗刷风控分
    ROLL=$((RANDOM % 100 + 1))
    if [ $ROLL -le 70 ]; then
        TARGET_MOD="mod_google.sh"
        MOD_NAME="Google 区域纠偏"
    else
        TARGET_MOD="mod_trust.sh"
        MOD_NAME="IP 信用净化"
    fi
elif [ "$GOOGLE_ALLOWED" == "true" ]; then
    TARGET_MOD="mod_google.sh"
    MOD_NAME="Google 区域纠偏"
elif [ "$ENABLE_TRUST" == "true" ]; then
    TARGET_MOD="mod_trust.sh"
    MOD_NAME="IP 信用净化"
else
    if [ "$ENABLE_GOOGLE" == "true" ] && [ "$GOOGLE_ALLOWED" != "true" ]; then
        log "SYSTEM" "WARN" "Google 模块处于 BOT_RISK 冷却状态，且没有可运行的其他模块，跳过本轮执行。"
    else
        log "SYSTEM" "WARN" "节点未开启任何养护模块，跳过本轮执行。"
    fi
    exit 0
fi

# 5. 拉起选定的业务模块
if [ -n "$TARGET_MOD" ] && [ -x "${INSTALL_DIR}/core/${TARGET_MOD}" ]; then
    log "SYSTEM" "INFO" "命中触发条件，加载并执行子模块: ${MOD_NAME}"
    # 核心降耗逻辑：使用 nice -n 19 赋予进程最低 CPU 优先级，绝不抢占 VPS 正常业务的资源
    # [安全修复] 注入 200>&-，强行关闭子进程对排他锁的继承权！防止子进程假死导致全局死锁
    nice -n 19 bash "${INSTALL_DIR}/core/${TARGET_MOD}" 200>&-
else
    log "SYSTEM" "ERROR" "配置了模块 ${MOD_NAME}，但未找到对应的可执行脚本: ${TARGET_MOD}"
fi

log "SYSTEM" "INFO" "本轮所有模块调度完毕，哨兵继续隐蔽待命。"