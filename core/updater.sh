#!/bin/bash

# ==========================================================
# 脚本名称: updater.sh (IP-Sentinel 养料注入与分频调度中枢 - 动态锚点版)
# 核心功能: 静默更新热数据/LBS、指纹库错峰调度、强制出站死锁、版本无缝继承
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
UA_TIME_FILE="${INSTALL_DIR}/core/.ua_last_update"

# GitHub 仓库 Raw 数据直链前缀
REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为开发地址用于测试
# REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/v3.6.2-rc"

# 1. 加载本地冷数据配置
if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi
source "$CONFIG_FILE"

# 2. 全局日志写入函数 (v3.4.0 引入版本探针)
log() {
    # [v3.4.0 核心] 提取当前配置中的版本锚点
    local local_ver="${AGENT_VERSION:-未知}"
    
    # 保证日志目录存在
    mkdir -p "${INSTALL_DIR}/logs"

    # 日志格式注入 [版本号] 追踪标识
    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$2" "$1" "$REGION_CODE" "$3")
    # [时区对齐] 强制无视本地时区，以绝对 UTC 时间写入日志
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    # 强制推送到 Systemd Journal (如果系统支持)
    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    else
        # 降级输出到 stdout，让 Systemd 捕获
        echo "$core_msg"
    fi
}

log "Updater" "INFO " "========== 触发后台静默 OTA 热数据更新 =========="

# ==========================================================
# 🛡️ 终极护城河：构建强锚定出站的 curl 请求引擎
# ==========================================================
# 基础参数：跟随 install.sh 锁定的协议偏好 (4 或 6)
CURL_CMD="curl -${IP_PREF:-4} -sL"

# 【防坑核心】如果用户配置了死锁锚点，必须强制绑定网卡，杜绝流量溢出！
if [ -n "$BIND_IP" ]; then
    # curl 的 --interface 参数不支持带方括号的 IPv6 地址，必须强行脱壳
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    # [v3.6.3 容错层补丁] 探测网卡存活状态，防止 IP 漂移导致永久断网
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        log "Updater" "WARN " "检测到绑定的出口 IP ($RAW_BIND_IP) 已丢失，自动退回默认路由！"
    else
        CURL_CMD="$CURL_CMD --interface $RAW_BIND_IP"
    fi
fi

# ==========================================================
# 3. 容灾机制拉取 UA 指纹池 (V3.3.0 引入 30 天错峰防惊群逻辑)
# ==========================================================
NOW=$(date +%s)
LAST_UPDATE=0

# 读取上一次更新的时间戳
if [ -f "$UA_TIME_FILE" ]; then
    # tr -d 清除可能存在的换行或回车符，防止算术崩溃
    LAST_UPDATE=$(cat "$UA_TIME_FILE" | tr -d '\r\n')
fi

# 校验数据合法性，防崩溃
if ! [[ "$LAST_UPDATE" =~ ^[0-9]+$ ]]; then
    LAST_UPDATE=0
fi

DIFF=$((NOW - LAST_UPDATE))

# 距离上次拉取超过 30 天 (2592000 秒)，才执行下载
if [ "$DIFF" -ge 2592000 ] || [ "$LAST_UPDATE" -eq 0 ]; then
    TMP_UA="/tmp/ip_sentinel_ua.txt"
    # 使用重装升级后的 CURL_CMD
    $CURL_CMD "${REPO_RAW_URL}/data/user_agents.txt" -o "$TMP_UA"
    
    if [ -s "$TMP_UA" ]; then
        mv "$TMP_UA" "${INSTALL_DIR}/data/user_agents.txt"
        echo "$NOW" > "$UA_TIME_FILE"
        log "Updater" "INFO " "✅ 设备指纹池 (User-Agents) 30天错峰滚动更新成功"
    else
        log "Updater" "WARN " "❌ UA 池拉取失败，保留本地旧数据防崩溃"
        rm -f "$TMP_UA"
    fi
else
    DAYS_LEFT=$(((2592000 - DIFF) / 86400))
    log "Updater" "INFO " "⏳ 设备指纹池处于 30 天静默期 (剩余约 ${DAYS_LEFT} 天)，跳过拉取"
fi

# ==========================================================
# 4. 容灾机制拉取当地最新搜索词库 (每日高频拉取，保证活体新鲜度)
# ==========================================================
TMP_KW="/tmp/ip_sentinel_kw.txt"
$CURL_CMD "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "$TMP_KW"

if [ -s "$TMP_KW" ]; then
    mv "$TMP_KW" "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"
    log "Updater" "INFO " "✅ 区域搜索词库 (kw_${REGION_CODE}) 每日同步成功"
else
    log "Updater" "WARN " "❌ 搜索词库拉取失败，保留本地旧数据防崩溃"
    rm -f "$TMP_KW"
fi

# ==========================================================
# 5. 自适应拉取本地 LBS 专属 JSON 规则库 (每日同步)
# ==========================================================
REGION_JSON_FILE=$(find "${INSTALL_DIR}/data/regions" -name "*.json" 2>/dev/null | head -n 1)

if [ -n "$REGION_JSON_FILE" ] && [ -f "$REGION_JSON_FILE" ]; then
    REL_PATH=${REGION_JSON_FILE#*${INSTALL_DIR}/}
    TMP_JSON="/tmp/ip_sentinel_region.json"
    
    $CURL_CMD "${REPO_RAW_URL}/${REL_PATH}" -o "$TMP_JSON"
    
    if [ -s "$TMP_JSON" ]; then
        mv "$TMP_JSON" "$REGION_JSON_FILE"
        log "Updater" "INFO " "✅ 核心战区规则库 ($REL_PATH) 每日同步成功"
    else
        log "Updater" "WARN " "❌ 战区规则库拉取失败，保留本地旧数据"
        rm -f "$TMP_JSON"
    fi
fi

# ==========================================================
# 5.5. 容灾更新深海声呐底层探针 (彻底消除第三方 RCE 依赖)
# ==========================================================
TMP_PROBE="/tmp/ip_sentinel_probe.sh"
$CURL_CMD "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" -o "$TMP_PROBE"
if [ -s "$TMP_PROBE" ]; then
    mv "$TMP_PROBE" "${INSTALL_DIR}/core/ip_probe.sh"
    chmod +x "${INSTALL_DIR}/core/ip_probe.sh"
    log "Updater" "INFO " "✅ 深海声呐底层探针 (ip_probe.sh) 源文件安全对齐"
fi

# ==========================================================
# 6. 日志防满瘦身机制 (保留最近 2000 行)
# ==========================================================
if [ -f "$LOG_FILE" ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "Updater" "INFO " "🧹 系统日志已完成定期清理瘦身 (保留最新 2000 行)"
fi

log "Updater" "INFO " "========== OTA 养料注入与系统维护结束 =========="