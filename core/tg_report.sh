#!/bin/bash

# ==========================================================
# 脚本名称: tg_report.sh
# 核心功能: 收集并聚合终端特征、提取执行快照、侦测云端版本并生成简报
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATS_SCRIPT="${SCRIPT_DIR}/extract_report_stats.sh"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# --- [基础自检] ---
if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

# ==========================================================
# [防线 1] 并发风暴熔断机制 (60s 冷却池)
# ==========================================================
LOCK_FILE="${INSTALL_DIR}/core/.report_lock"
if [ -f "$LOCK_FILE" ]; then
    LAST_RUN=$(cat "$LOCK_FILE" 2>/dev/null)
    NOW=$(date +%s)
    # 严格校验最后执行时间的合法性，防御密集回调
    if [[ "$LAST_RUN" =~ ^[0-9]+$ ]]; then
        if [ $((NOW - LAST_RUN)) -lt 60 ]; then
            echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [v${AGENT_VERSION:-未知}] [WARN ] [Report ] [SYSTEM] ⚠️ 战报请求过于频繁，触发 60 秒防并发风暴拦截。" >> "${INSTALL_DIR}/logs/sentinel.log"
            exit 0
        fi
    fi
fi
echo $(date +%s) > "$LOCK_FILE"

# ==========================================================
# 1. 节点元数据与双轨身份解析
# ==========================================================
if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"

# ----------------------------------------------------------
# [容灾探针 1] 底层路由锁定与多节点出口 IP 嗅探
# ----------------------------------------------------------
CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        CURL_BIND_OPT=""
    else
        CURL_BIND_OPT="--interface $BIND_IP"
        if [[ "$BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="-6"
        elif [[ "$BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="-4"
        fi
    fi
fi

# 结合协议自适应进行外部 IP 回显探测
CURRENT_IP=$( (curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/ip || curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
# 强制兜底逻辑：网络完全阻断时回退使用配置文件锚点
[ -z "$CURRENT_IP" ] && CURRENT_IP="${PUBLIC_IP:-$BIND_IP}"

# 为 IPv6 环境追加方括号安全护甲
[[ "$CURRENT_IP" == *":"* ]] && [[ "$CURRENT_IP" != *"["* ]] && CURRENT_IP="[${CURRENT_IP}]"

# ----------------------------------------------------------
# [容灾探针 2] 多级 ISP 情报探测链路
# ----------------------------------------------------------
ISP_INFO=""

# 优先级 A: 高吞吐极速纯文本接口
ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ipinfo.io/org 2>/dev/null)

# 优先级 B: 备用纯文本接口
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ip-api.com/line/?fields=isp 2>/dev/null)
fi

# 优先级 C: 需构建环境依赖的 JSON 接口
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    if command -v jq &> /dev/null; then
        ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/geoip | jq -r '.organization' 2>/dev/null)
    fi
fi

# 数据清洗过滤与类型渲染
ISP_INFO=$(echo "$ISP_INFO" | sed -E 's/^AS[0-9]+ //')
[ -z "$ISP_INFO" ] || [ "$ISP_INFO" == "null" ] && ISP_INFO="未知 ISP"

if [[ "$ISP_INFO" == *"Cloudflare"* ]]; then
    IP_TYPE="Cloudflare Warp 🛰️"
else
    IP_TYPE="$ISP_INFO 🏠"
fi

# [全视界旗帜引擎] 动态国旗渲染装配
BASE_CC="${REGION_CODE%%-*}"
case "$BASE_CC" in
    US) FLAG="🇺🇸" ;; JP) FLAG="🇯🇵" ;; HK) FLAG="🇭🇰" ;; TW) FLAG="🇹🇼" ;; SG) FLAG="🇸🇬" ;;
    UK|GB) FLAG="🇬🇧" ;; DE) FLAG="🇩🇪" ;; FR) FLAG="🇫🇷" ;; NL) FLAG="🇳🇱" ;; CA) FLAG="🇨🇦" ;;
    AU) FLAG="🇦🇺" ;; KR) FLAG="🇰🇷" ;; IN) FLAG="🇮🇳" ;; BR) FLAG="🇧🇷" ;; RU) FLAG="🇷🇺" ;;
    CH) FLAG="🇨🇭" ;; SE) FLAG="🇸🇪" ;; NO) FLAG="🇳🇴" ;; DK) FLAG="🇩🇰" ;; FI) FLAG="🇫🇮" ;;
    IT) FLAG="🇮🇹" ;; ES) FLAG="🇪🇸" ;; PT) FLAG="🇵🇹" ;; IE) FLAG="🇮🇪" ;; PL) FLAG="🇵🇱" ;;
    AT) FLAG="🇦🇹" ;; BE) FLAG="🇧🇪" ;; TR) FLAG="🇹🇷" ;; ZA) FLAG="🇿🇦" ;; AE) FLAG="🇦🇪" ;;
    MY) FLAG="🇲🇾" ;; ID) FLAG="🇮🇩" ;; VN) FLAG="🇻🇳" ;; TH) FLAG="🇹🇭" ;; PH) FLAG="🇵🇭" ;;
    NZ) FLAG="🇳🇿" ;; AR) FLAG="🇦🇷" ;; CL) FLAG="🇨🇱" ;; MX) FLAG="🇲🇽" ;; IL) FLAG="🇮🇱" ;;
    SA) FLAG="🇸🇦" ;; EG) FLAG="🇪🇬" ;; NG) FLAG="🇳🇬" ;; KE) FLAG="🇰🇪" ;; RO) FLAG="🇷🇴" ;;
    BG) FLAG="🇧🇬" ;; CZ) FLAG="🇨🇿" ;; HU) FLAG="🇭🇺" ;; GR) FLAG="🇬🇷" ;; UA) FLAG="🇺🇦" ;;
    MO) FLAG="🇲🇴" ;; KH) FLAG="🇰🇭" ;; MM) FLAG="🇲🇲" ;; LA) FLAG="🇱🇦" ;;
    MN) FLAG="🇲🇳" ;; NP) FLAG="🇳🇵" ;; BD) FLAG="🇧🇩" ;;
    *) FLAG="🌐" ;;
esac

# ==========================================================
# 2. 行为日志萃取与快照分析
# ==========================================================
LOG_CONTENT=$(tail -n 1000 "$LOG_FILE" 2>/dev/null)

if [ -z "$LOG_CONTENT" ]; then
    read -r -d '' MSG <<EOT
🛑 **[IP-Sentinel] 告警：节点异常**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
⚠️ **警告**: 过去 24 小时无运行日志！
🛠️ **建议**: 节点可能刚部署完毕，请在面板手动执行一次养护动作。
EOT
else
    report_latest_snapshot() {
        printf '%s\n' "$LOG_CONTENT" | awk '$5 == "[SCORE]" && ($6 == "[Google]" || $6 == "[Trust  ]") {line = $0} END {print line}'
    }

    # 抓取末次执行模块的运行态势图
    LAST_LOG_LINE=$(report_latest_snapshot)
    LAST_MOD=$(echo "$LAST_LOG_LINE" | awk '{mod=$6; gsub(/[\[\] ]/, "", mod); print mod}')
    if { [ "$LAST_MOD" == "Google" ] && [ "$ENABLE_GOOGLE" != "true" ]; } || \
       { [ "$LAST_MOD" == "Trust" ] && [ "$ENABLE_TRUST" != "true" ]; }; then
        LAST_LOG_LINE=""
        LAST_MOD=""
    fi
    LAST_TIME=$(echo "$LAST_LOG_LINE" | awk '{ts=$1; sub(/^\[/, "", ts); print ts, $2}')
    LAST_SCORE=$(echo "$LAST_LOG_LINE" | awk '{$1=$2=$3=$4=$5=$6=$7=""; sub(/^ */, ""); print}')

    # START 只表示发起量；SCORE 是结束判据，成功率只按已结束轮次归一化
    if [ ! -r "$STATS_SCRIPT" ] || [ ! -x "$STATS_SCRIPT" ] || [ ! -s "$STATS_SCRIPT" ]; then
        echo "❌ 战报统计组件缺失：$STATS_SCRIPT" >> "${INSTALL_DIR}/logs/error.log"
        exit 1
    fi
    REPORT_UTC_DATE=$(date -u '+%Y-%m-%d')
    STATS=$(printf '%s\n' "$LOG_CONTENT" | "$STATS_SCRIPT" "$REPORT_UTC_DATE")
    read -r G_TOTAL G_ENDED G_SUCCESS G_FAILED G_WARN G_ABORT \
             T_TOTAL T_ENDED T_SUCCESS T_FAILED <<< "${STATS:-}" || true
    : "${G_TOTAL:=0}" "${G_ENDED:=0}" "${G_SUCCESS:=0}" "${G_FAILED:=0}" \
      "${G_WARN:=0}" "${G_ABORT:=0}" "${T_TOTAL:=0}" "${T_ENDED:=0}" \
      "${T_SUCCESS:=0}" "${T_FAILED:=0}"
    [ "$ENABLE_GOOGLE" == "true" ] || { G_TOTAL=0; G_ENDED=0; G_SUCCESS=0; G_FAILED=0; G_WARN=0; G_ABORT=0; }
    [ "$ENABLE_TRUST" == "true" ] || { T_TOTAL=0; T_ENDED=0; T_SUCCESS=0; T_FAILED=0; }

    MSG="📊 **IP-Sentinel 每日简报 (${FLAG} ${REGION_NAME})**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
📡 **出口 IP**: \`${CURRENT_IP}\`
🛡️ **IP 属性**: ${IP_TYPE}"

    # 统计 Google 纠偏阵列数据
    if [ "$ENABLE_GOOGLE" == "true" ]; then
        G_RATE="0.0"
        [ "$G_ENDED" -gt 0 ] && G_RATE=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_ENDED)*100}")

        MSG="$MSG

🎯 **[Google 区域纠偏]**
🚀 执行总数: ${G_TOTAL} 次 | 已结束: ${G_ENDED} 次 (成功率: **${G_RATE}%**)
✅ 成功: ${G_SUCCESS} | ❌ 送中: ${G_FAILED} | ⚠️ 警告: ${G_WARN} | 🚨 熔断: ${G_ABORT}"
    fi

    # 统计 Trust 净化阵列数据
    if [ "$ENABLE_TRUST" == "true" ]; then
        T_RATE="0.0"
        [ "$T_ENDED" -gt 0 ] && T_RATE=$(awk "BEGIN {printf \"%.1f\", ($T_SUCCESS/$T_ENDED)*100}")

        MSG="$MSG

🔰 **[IP 信用净化]**
🚀 净化总数: ${T_TOTAL} 轮 | 已结束: ${T_ENDED} 轮 (成功率: **${T_RATE}%**)
✅ 成功注入: ${T_SUCCESS} | ❌ 访问受阻: ${T_FAILED}"
    fi

    # 追加末次快照
    MSG="$MSG

🕒 **最近执行快照:  \`${LAST_MOD:-"System"} \`**
时间: ${LAST_TIME:-"暂无数据"} (UTC)
结论: ${LAST_SCORE:-"暂无数据"}"

fi

# ==========================================================
# 3. 云端版本探针与 OTA 调度模块
# ==========================================================
LOCAL_VER="${AGENT_VERSION:-未知}"
# [时间线对齐] 强制采用绝对 UTC 时间消除多节点的系统偏差
REPORT_UTC_TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
REMOTE_VER=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')

MSG="$MSG
----------------------------
🛡️ **系统引擎状态**
⏱️ 战报生成: \`${REPORT_UTC_TIME}\`"

# 根据云端版本一致性自动渲染更新提示面板
if [ -n "$REMOTE_VER" ]; then
    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
        MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\`
✨ **发现新版本**: \`v${REMOTE_VER}\` (建议更新)
💡 *系统提示：检测到新版引擎，建议通过中枢控制台执行 OTA 热更新！*"
    else
        MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\` (✅已是最新)
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
    fi
else
    MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\`
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
fi

# --- [下发 API 载荷] ---
JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$MSG" \
  --arg cb "manage:${NODE_NAME}" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [[{"text": "⚙️ 调出该节点控制台", "callback_data": $cb}]]
    }
  }')

RESPONSE=$(curl -s -m 10 -X POST "${TG_API_URL}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

if [[ "$RESPONSE" != *"\"ok\":true"* ]]; then
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >> "${INSTALL_DIR}/logs/error.log"
else
    echo "✅ 战报推送成功！"
fi
