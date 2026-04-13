#!/bin/bash

# ==========================================================
# 脚本名称: tg_report.sh (Telegram 每日战报模块 V6.0 动态拼装版)
# 核心功能: 适配 Feature Flag 架构，按需展示 Google/Trust 独立统计数据
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# 1. 加载配置并自检
if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

# 2. 节点元数据抓取 (v3.2.2 协议自适应与多级容灾版)
NODE_NAME=$(hostname | cut -c 1-15)

# --- [防线 1: 底层路由锁定与协议自适应] ---
CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    CURL_BIND_OPT="--interface $BIND_IP"
    if [[ "$BIND_IP" == *":"* ]]; then
        DYNAMIC_IP_PREF="-6"
    elif [[ "$BIND_IP" == *"."* ]]; then
        DYNAMIC_IP_PREF="-4"
    fi
fi

# 多节点容灾探测出口 IP (注入协议自适应)
CURRENT_IP=$( (curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/ip || curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
# 强制兜底：如果所有外部 API 都挂了，直接使用本地强行锁定的 BIND_IP
[ -z "$CURRENT_IP" ] && CURRENT_IP="$BIND_IP"

# 为可能获取到的 IPv6 自动添加方括号护甲
[[ "$CURRENT_IP" == *":"* ]] && [[ "$CURRENT_IP" != *"["* ]] && CURRENT_IP="[${CURRENT_IP}]"

# --- [防线 2: 多级 ISP 容灾探针链路] ---
ISP_INFO=""

# 探针 A: 纯文本 API (免 jq，极速稳定)
ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ipinfo.io/org 2>/dev/null)

# 探针 B: 备用纯文本 API
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ip-api.com/line/?fields=isp 2>/dev/null)
fi

# 探针 C: 原版的 JSON API (需要 jq 兜底)
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    if command -v jq &> /dev/null; then
        ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/geoip | jq -r '.organization' 2>/dev/null)
    fi
fi

# --- [防线 3: 数据清洗 (遵循底层共识原则)] ---
# 剔除 ipinfo 返回的开头 AS 号 (例如 "AS137535 JT TELECOM" -> "JT TELECOM")
ISP_INFO=$(echo "$ISP_INFO" | sed -E 's/^AS[0-9]+ //')

# 最终兜底判断
[ -z "$ISP_INFO" ] || [ "$ISP_INFO" == "null" ] && ISP_INFO="未知 ISP"

if [[ "$ISP_INFO" == *"Cloudflare"* ]]; then
    IP_TYPE="Cloudflare Warp 🛰️"
else
    IP_TYPE="$ISP_INFO 🏠"
fi

# 动态国旗
case "$REGION_CODE" in
    "JP") FLAG="🇯🇵" ;;
    "US") FLAG="🇺🇸" ;;
    "DE") FLAG="🇩🇪" ;;
    "SG") FLAG="🇸🇬" ;;
    "HK") FLAG="🇭🇰" ;;
    "GB"|"UK") FLAG="🇬🇧" ;;
    *) FLAG="🌐" ;;
esac

# 3. 截取过去 24 小时的日志
LOG_CONTENT=$(find "$LOG_FILE" -mtime -1 -exec cat {} \; 2>/dev/null)

if [ -z "$LOG_CONTENT" ]; then
    read -r -d '' MSG <<EOT
🛑 **[IP-Sentinel] 告警：节点异常**
----------------------------
📍 **节点名称**: \`${NODE_NAME}\`
⚠️ **警告**: 过去 24 小时无运行日志！
🛠️ **建议**: 节点可能刚部署完毕，请在面板手动执行一次养护动作。
EOT
else
    # ==========================================
    # 4. 动态模块数据分析 (核心升级)
    # ==========================================
    
    # 提取最近一次运行的快照 (智能识别所属模块)
    LAST_LOG_LINE=$(echo "$LOG_CONTENT" | grep "\[SCORE\]" | tail -n 1)
    LAST_TIME=$(echo "$LAST_LOG_LINE" | awk '{print $1,$2}' | tr -d '[]')
    LAST_MOD=$(echo "$LAST_LOG_LINE" | awk '{print $4}' | tr -d '[]')
    LAST_SCORE=$(echo "$LAST_LOG_LINE" | awk -F'自检结论: ' '{print $2}')

    # 开始组装战报头部
    MSG="📊 **IP-Sentinel 每日简报 (${FLAG} ${REGION_NAME})**
----------------------------
📍 **节点名称**: \`${NODE_NAME}\`
📡 **出口 IP**: \`${CURRENT_IP}\`
🛡️ **IP 属性**: ${IP_TYPE}"

    # --- [分析块 1: Google 纠偏模块] ---
    if [ "$ENABLE_GOOGLE" == "true" ]; then
        GOOGLE_LOGS=$(echo "$LOG_CONTENT" | grep "\[Google")
        G_TOTAL=$(echo "$GOOGLE_LOGS" | grep "\[START\]" -c)
        G_SUCCESS=$(echo "$GOOGLE_LOGS" | grep "✅" -c)
        G_FAILED=$(echo "$GOOGLE_LOGS" | grep "❌" -c)
        G_WARN=$(echo "$GOOGLE_LOGS" | grep "⚠️" -c)
        
        G_RATE="0.0"
        [ "$G_TOTAL" -gt 0 ] && G_RATE=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_TOTAL)*100}")

        MSG="$MSG

🎯 **[Google 区域纠偏]**
🚀 执行总数: ${G_TOTAL} 次 (胜率: **${G_RATE}%**)
✅ 成功: ${G_SUCCESS} | ❌ 送中: ${G_FAILED} | ⚠️ 警告: ${G_WARN}"
    fi

    # --- [分析块 2: IP 信用净化模块] ---
    if [ "$ENABLE_TRUST" == "true" ]; then
        TRUST_LOGS=$(echo "$LOG_CONTENT" | grep "\[Trust")
        T_TOTAL=$(echo "$TRUST_LOGS" | grep "\[START\]" -c)
        T_SUCCESS=$(echo "$TRUST_LOGS" | grep "✅" -c)
        T_FAILED=$(echo "$TRUST_LOGS" | grep "❌" -c)
        
        T_RATE="0.0"
        [ "$T_TOTAL" -gt 0 ] && T_RATE=$(awk "BEGIN {printf \"%.1f\", ($T_SUCCESS/$T_TOTAL)*100}")

        MSG="$MSG

🔰 **[IP 信用净化]**
🚀 净化总数: ${T_TOTAL} 轮 (成功率: **${T_RATE}%**)
✅ 成功注入: ${T_SUCCESS} | ❌ 访问受阻: ${T_FAILED}"
    fi

    # 组装战报尾部 (最近快照)
    MSG="$MSG

🕒 **最近执行快照 [${LAST_MOD:-"System"}]:**
时间: ${LAST_TIME:-"暂无数据"}
结论: ${LAST_SCORE:-"暂无数据"}
----------------------------
💡 哨兵正在后台默默守护您的资产。"

fi

# 5. 调用 API 推送 (接入安全网关)
RESPONSE=$(curl -s -m 10 -X POST "${TG_API_URL}" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${MSG}" \
    -d "parse_mode=Markdown")

if [[ "$RESPONSE" != *"\"ok\":true"* ]]; then
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >> "${INSTALL_DIR}/logs/error.log"
else
    echo "✅ 战报推送成功！"
fi