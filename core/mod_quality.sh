#!/bin/bash
# ==========================================================
# IP-Sentinel: 深海声呐 (IP 质量全维异步检测模块 v4.0.0)
# 特性: 结构化 JSON 降维、异步防阻塞、物理网卡死锁精准定向
# ==========================================================

source /opt/ip_sentinel/config.conf

# 1. 提取物理死锁 IP (剔除 IPv6 的中括号，适配第三方脚本)
# 如果 BIND_IP 有值就用 BIND_IP，否则兜底使用 PUBLIC_IP
TARGET_IP=$(echo "${BIND_IP:-$PUBLIC_IP}" | tr -d '[]')
IP_PROTO="${IP_PREF:-4}" # 默认 v4

# 2. 使用原生脚本静默拉取 JSON
# 参数解析: 
# -y: 静默安装依赖
# -j: 输出 JSON 格式
# -4/-6: 强制指定网络协议
# -i: 强制锁定出口 IP (核心防漏包机制)
JSON_DATA=$(timeout 180 bash <(curl -sL https://IP.Check.Place) -y -j -${IP_PROTO} -i "${TARGET_IP}" 2>/dev/null)

if [ -z "$JSON_DATA" ]; then
    curl -s -X POST "${TG_API_URL}" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=❌ *深海声呐探测失败*
📍 节点：\`${NODE_ALIAS}\`
🌐 锁定IP：\`${PUBLIC_IP}\`
⚠️ *未收到回波。检测源超时或 IP (${TARGET_IP}) 路由不可达。*" >/dev/null
    exit 1
fi

# 3. 利用 jq 精准提取战略指标
IP_ADDR=$(echo "$JSON_DATA" | jq -r '.Head.IP // empty')
# 兜底：如果 API 没返回 IP，用我们的
[ -z "$IP_ADDR" ] && IP_ADDR="$PUBLIC_IP"

SCAM_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.SCAMALYTICS // "0"')
FRAUD_RISK=$(echo "$JSON_DATA" | jq -r '.Score.ipapi // "0%"')
USAGE_TYPE=$(echo "$JSON_DATA" | jq -r '.Type.Usage.IPinfo // "Unknown"')

NF_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Netflix.Status // "Unknown"')
NF_REG=$(echo "$JSON_DATA" | jq -r '.Media.Netflix.Region // ""')
GPT_STAT=$(echo "$JSON_DATA" | jq -r '.Media.ChatGPT.Status // "Unknown"')
GPT_REG=$(echo "$JSON_DATA" | jq -r '.Media.ChatGPT.Region // ""')

DNS_BLACK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Blacklisted // "0"')
DNS_MARK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Marked // "0"')

# 4. 组装 Markdown 战报
REPORT="🎯 *深海声呐 - IP 质量探测报告*
📍 节点别名：\`${NODE_ALIAS}\`
🌐 探测地址：\`${IP_ADDR}\`

*🛡️ 欺诈与信用评估*
• **Scamalytics 分数：** \`${SCAM_SCORE}/100\`
• **ipapi 风险率：** \`${FRAUD_RISK}\`
• **IP 属性类别：** \`${USAGE_TYPE}\`

*🎬 流媒体与 AI 解锁*
• **Netflix：** \`${NF_STAT}\` ${NF_REG}
• **ChatGPT：** \`${GPT_STAT}\` ${GPT_REG}

*✉️ 黑名单污染度*
• **严重黑名单：** \`${DNS_BLACK}\` 个
• **轻度标记：** \`${DNS_MARK}\` 个

_👉 [🔍 点击查看完整雷达图谱](https://check.place/${TARGET_IP})_

\`[SYSTEM_REPORT]|QUALITY|${NODE_NAME}|${SCAM_SCORE}|${NF_STAT}\`"

# 5. 直送指挥部
curl -s -X POST "${TG_API_URL}" \
    -d "chat_id=${CHAT_ID}" \
    -d "parse_mode=Markdown" \
    -d "disable_web_page_preview=true" \
    -d "text=${REPORT}" >/dev/null
