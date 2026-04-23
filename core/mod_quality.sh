#!/bin/bash
# ==========================================================
# IP-Sentinel: 深海声呐 (IP 质量全维异步检测模块终极情报版)
# ==========================================================

source /opt/ip_sentinel/config.conf

TARGET_IP=$(echo "${BIND_IP:-$PUBLIC_IP}" | tr -d '[]')
IP_PROTO="${IP_PREF:-4}"

# 1. 静默拉取 JSON (剔除头部广告杂音)
JSON_DATA=$(timeout 180 bash <(curl -sL https://IP.Check.Place) -y -j -${IP_PROTO} -i "${TARGET_IP}" 2>/dev/null | sed -n '/^{/,$p')

if [ -z "$JSON_DATA" ] || ! echo "$JSON_DATA" | jq . >/dev/null 2>&1; then
    curl -s -X POST "${TG_API_URL}" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=❌ *深海声呐探测失败*
📍 节点：\`${NODE_ALIAS}\`
🌐 锁定IP：\`${PUBLIC_IP}\`
⚠️ *未收到有效回波。检测源超时或数据解析受阻。*" >/dev/null
    exit 1
fi

# 2. 提取基础物理定位与身份特征
IP_ADDR=$(echo "$JSON_DATA" | jq -r '.Head.IP // empty')
[ -z "$IP_ADDR" ] && IP_ADDR="$PUBLIC_IP"
ASN=$(echo "$JSON_DATA" | jq -r '.Info.ASN // "Unknown"')
ORG=$(echo "$JSON_DATA" | jq -r '.Info.Organization // "Unknown"')
CITY=$(echo "$JSON_DATA" | jq -r '.Info.City.Name // "Unknown"')
COUNTRY=$(echo "$JSON_DATA" | jq -r '.Info.Region.Name // "Unknown"')
IP_TYPE=$(echo "$JSON_DATA" | jq -r '.Info.Type // "未知属性"')
USAGE_TYPE=$(echo "$JSON_DATA" | jq -r '.Type.Usage.IPinfo // "未知场景"')

# 3. 深度欺诈与信用评估 (各大权威库联查)
SCAM_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.SCAMALYTICS // "0"')
ABUSE_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.AbuseIPDB // "0"')
IPQS_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.IPQS // "0"')
IP2L_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.IP2LOCATION // "0"')
FRAUD_RISK=$(echo "$JSON_DATA" | jq -r '.Score.ipapi // "0%"')

# 代理/VPN 特征探针 (只要有一家认为是代理，就亮黄灯)
IS_PROXY="🟢 干净"
if echo "$JSON_DATA" | jq -e '.Factor.Proxy | to_entries | any(.value == true)' >/dev/null 2>&1 || \
   echo "$JSON_DATA" | jq -e '.Factor.VPN | to_entries | any(.value == true)' >/dev/null 2>&1; then
    IS_PROXY="🟡 疑似代理/VPN"
fi

# 4. 提取流媒体与 AI 解锁指标 (带解锁类型)
parse_media() {
    local status=$(echo "$JSON_DATA" | jq -r ".Media.$1.Status // \"未知\"")
    local reg=$(echo "$JSON_DATA" | jq -r ".Media.$1.Region // \"\"")
    local type=$(echo "$JSON_DATA" | jq -r ".Media.$1.Type // \"\"")
    
    if [[ "$status" == *"解锁"* ]]; then
        echo "🟢 $reg ($type)"
    elif [[ "$status" == *"屏蔽"* ]] || [[ "$status" == *"失败"* ]]; then
        echo "🔴 屏蔽"
    else
        echo "⚪ $status"
    fi
}

NF_STAT=$(parse_media "Netflix")
YT_STAT=$(parse_media "Youtube")
DP_STAT=$(parse_media "DisneyPlus")
TK_STAT=$(parse_media "TikTok")
GPT_STAT=$(parse_media "ChatGPT")
APV_STAT=$(parse_media "AmazonPrimeVideo")

# 提取原生 JSON 里的原始状态用于底层隐写回传
RAW_NF_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Netflix.Status // "Unknown"')
RAW_YT_REG=$(echo "$JSON_DATA" | jq -r '.Media.Youtube.Region // ""')
RAW_YT_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Youtube.Status // "Unknown"')

# 5. 邮局连通性与黑名单
PORT25=$(echo "$JSON_DATA" | jq -r '.Mail.Port25 // "false"')
[ "$PORT25" == "true" ] && P25_TEXT="✅ 畅通" || P25_TEXT="❌ 封堵"
DNS_BLACK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Blacklisted // "0"')
DNS_MARK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Marked // "0"')

# 6. “送中” 逻辑判定
WARNING_MSG=""
if [[ "$RAW_YT_REG" == *"[CN]"* ]] || [[ "$RAW_YT_STAT" == *"China"* ]]; then
    WARNING_MSG="%0A🚨 **[高危] 该节点已被 Google 判定为中国大陆 (送中)！**%0A"
fi

# 7. 组装情报级 Markdown 战报
REPORT="🎯 *IP-Sentinel 深海声呐报告*
📍 节点：\`${NODE_ALIAS}\`
🌐 地址：\`${IP_ADDR}\`${WARNING_MSG}

*🏢 物理身份与网络属性*
\`AS${ASN}\` | \`${ORG}\`
**定位:** \`${COUNTRY} - ${CITY}\`
**属性:** \`${IP_TYPE}\` | \`${USAGE_TYPE}\`
**探针:** ${IS_PROXY}

*🛡️ 欺诈雷达 (0为最优)*
• **Scamalytics:** \`${SCAM_SCORE}/100\`
• **AbuseIPDB:** \`${ABUSE_SCORE}/100\`
• **IPQuality:** \`${IPQS_SCORE}/100\`
• **IP2Location:** \`${IP2L_SCORE}/100\`
• **IPAPI 风险率:** \`${FRAUD_RISK}\`

*🎬 核心业务解锁*
• **YouTube:** ${YT_STAT}
• **Netflix:** ${NF_STAT}
• **Disney+:** ${DP_STAT}
• **PrimeVideo:** ${APV_STAT}
• **TikTok:** ${TK_STAT}
• **ChatGPT:** ${GPT_STAT}

*✉️ 邮局与污染度*
• **25 端口出站:** ${P25_TEXT}
• **DNS 污染库:** 严重 \`${DNS_BLACK}\` | 轻微 \`${DNS_MARK}\`

_👉 [🔍 详细信用图谱直达 (Scamalytics)](https://scamalytics.com/ip/${TARGET_IP})_

\`[SYSTEM_REPORT]|QUALITY|${NODE_NAME}|${SCAM_SCORE}|${RAW_NF_STAT}\`"

# 8. 直送指挥部
curl -s -X POST "${TG_API_URL}" \
    -d "chat_id=${CHAT_ID}" \
    -d "parse_mode=Markdown" \
    -d "disable_web_page_preview=true" \
    -d "text=${REPORT}" >/dev/null