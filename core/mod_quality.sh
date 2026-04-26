#!/bin/bash
# ==========================================================
# IP-Sentinel: 深海声呐 (IP 质量全维异步检测模块 v4.0.0)
# ==========================================================

source /opt/ip_sentinel/config.conf

# ==========================================
# 1. 动态网络锚定与协议自适应 (专为多 IP / NAT 架构打造)
# ==========================================
DYNAMIC_IP_PREF="${IP_PREF:-4}"
PROBE_ARGS=("-y" "-j" "-f") # 默认注入: 自动确认、JSON格式、明文无掩码IP

# 强壮正则：支持 V4, V6 以及带有 [] 护甲的 V6 (兼容多 IP 站群机)
if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\[\]\.]+$ ]]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    # 严格探测物理网卡/虚拟 IP 存活状态，防止 IP 漂移导致探针彻底报错
    if ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        # 恢复使用官方原生参数 -i，不再进行徒劳的底层劫持
        PROBE_ARGS+=("-i" "$RAW_BIND_IP")
        
        # 智能识别 V4 / V6，强制覆盖系统默认的 IP_PREF
        if [[ "$RAW_BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="6"
        elif [[ "$RAW_BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="4"
        fi
    fi
fi

# 补齐协议版本参数 (-4 或 -6)
PROBE_ARGS+=("-${DYNAMIC_IP_PREF}")

# 2. 静默拉取原始数据 (智能双重容灾: 官方主干优先防 RCE，短链双栈兜底纯 V6)
PROBE_SCRIPT="/opt/ip_sentinel/core/ip_probe.sh"

# [修复] 采用 -s 检查文件是否大于0字节，防止遗留 0 字节废弃文件
if [ ! -s "$PROBE_SCRIPT" ]; then
    # 🛡️ 首选防线: 从 GitHub 官方拉取，杜绝短链 RCE 劫持风险
    curl -sL -m 10 "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" -o "$PROBE_SCRIPT" 2>/dev/null
    
    # 🚑 容灾防线: 如果拉取失败 (如纯 V6 机器无法解析 GitHub)，回退到 Cloudflare 双栈短链兜底
    if [ ! -s "$PROBE_SCRIPT" ]; then
        curl -sL -m 10 "https://IP.Check.Place" -o "$PROBE_SCRIPT" 2>/dev/null
    fi
    chmod +x "$PROBE_SCRIPT" 2>/dev/null
fi

# 封装打靶与清洗逻辑为函数，便于后续容灾重试
execute_probe() {
    RAW_OUTPUT=$(timeout 180 bash "$PROBE_SCRIPT" "$@" 2>/dev/null)
    JSON_DATA="{${RAW_OUTPUT#*\{}"
    ESC=$(printf '\033')
    JSON_DATA=$(printf "%s" "$JSON_DATA" | sed -e "s/${ESC}\[[0-9;]*[a-zA-Z]//g" -e "s/${ESC}[0-9;]*[a-zA-Z]//g" -e "s/x1b\\[[0-9;]*[a-zA-Z]//g" -e "s/x1b[0-9;]*[a-zA-Z]//g")
    IP_ADDR=$(echo "$JSON_DATA" | jq -r '.Head.IP // empty' 2>/dev/null)
}

# 🚀 首轮实弹打靶 (带有物理网卡 BIND_IP 枷锁)
execute_probe "${PROBE_ARGS[@]}"

# 🚑 [容灾防线] 剥离枷锁抢救机制
# 如果打靶失败 (无 IP 回波)，且身上带着 -i 枷锁，极大概率是复杂路由 (如 WARP) 导致的死锁！
if [ -z "$IP_ADDR" ] && [[ "${PROBE_ARGS[*]}" == *"-i"* ]]; then
    # 卸下 -i 物理枷锁，交由系统内核自主寻找最优路由，进行第二次抢救性探测
    FALLBACK_ARGS=("-y" "-j" "-f" "-${DYNAMIC_IP_PREF}")
    execute_probe "${FALLBACK_ARGS[@]}"
fi

if [ -z "$IP_ADDR" ]; then
    curl -s -X POST "${TG_API_URL}" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=❌ *深海声呐探测失败*
📍 节点：\`${NODE_ALIAS}\`
🌐 锁定IP：\`${PUBLIC_IP}\`
⚠️ *未收到有效回波。检测源超时或数据解析受阻。*" >/dev/null
    exit 1
fi

[ -z "$IP_ADDR" ] && IP_ADDR="$PUBLIC_IP"
ASN=$(echo "$JSON_DATA" | jq -r '.Info.ASN // "Unknown"' 2>/dev/null)
ORG=$(echo "$JSON_DATA" | jq -r '.Info.Organization // "Unknown"' 2>/dev/null)
CITY=$(echo "$JSON_DATA" | jq -r '.Info.City.Name // "Unknown"' 2>/dev/null)
COUNTRY=$(echo "$JSON_DATA" | jq -r '.Info.Region.Name // "Unknown"' 2>/dev/null)
IP_TYPE=$(echo "$JSON_DATA" | jq -r '.Info.Type // "未知属性"' 2>/dev/null)
USAGE_TYPE=$(echo "$JSON_DATA" | jq -r '.Type.Usage.IPinfo // "未知场景"' 2>/dev/null)

# 3. 深度欺诈与信用评估 (各大权威库联查)
SCAM_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.SCAMALYTICS // "0"' 2>/dev/null)
ABUSE_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.AbuseIPDB // "0"' 2>/dev/null)
IPQS_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.IPQS // "0"' 2>/dev/null)
IP2L_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.IP2LOCATION // "0"' 2>/dev/null)
FRAUD_RISK=$(echo "$JSON_DATA" | jq -r '.Score.ipapi // "0%"' 2>/dev/null)

# [修复] 清洗 API 阻断返回的 null 值，保障面板整洁
[ "$SCAM_SCORE" == "null" ] || [ -z "$SCAM_SCORE" ] && SCAM_SCORE="N/A"
[ "$ABUSE_SCORE" == "null" ] || [ -z "$ABUSE_SCORE" ] && ABUSE_SCORE="N/A"
[ "$IPQS_SCORE" == "null" ] || [ -z "$IPQS_SCORE" ] && IPQS_SCORE="N/A"
[ "$IP2L_SCORE" == "null" ] || [ -z "$IP2L_SCORE" ] && IP2L_SCORE="N/A"
[ "$FRAUD_RISK" == "null" ] || [ -z "$FRAUD_RISK" ] && FRAUD_RISK="N/A"

# 代理/VPN 特征探针 (只要有一家认为是代理，就亮黄灯)
IS_PROXY="🟢 干净"
if echo "$JSON_DATA" | jq -e '.Factor.Proxy | to_entries | any(.value == true)' >/dev/null 2>&1 || \
   echo "$JSON_DATA" | jq -e '.Factor.VPN | to_entries | any(.value == true)' >/dev/null 2>&1; then
    IS_PROXY="🟡 疑似代理/VPN"
fi

# 4. 提取流媒体与 AI 解锁指标 (带解锁类型)
parse_media() {
    local status=$(echo "$JSON_DATA" | jq -r ".Media.$1.Status // \"未知\"" 2>/dev/null)
    local reg=$(echo "$JSON_DATA" | jq -r ".Media.$1.Region // \"\"" 2>/dev/null)
    local type=$(echo "$JSON_DATA" | jq -r ".Media.$1.Type // \"\"" 2>/dev/null)
    
    if [[ "$status" == *"解锁"* ]]; then
        echo "🟢 ${reg} (${type})"
    elif [[ "$status" == *"仅"* ]] || [[ "$status" == *"机房"* ]] || [[ "$status" == *"待支持"* ]]; then
        # 捕捉 Netflix "仅自制"、ChatGPT "仅网页"、TikTok "机房" 等半残状态
        echo "🟡 ${status} ${reg}"
    elif [[ "$status" == *"屏蔽"* ]] || [[ "$status" == *"失败"* ]] || [[ "$status" == *"中国"* ]] || [[ "$status" == *"禁"* ]]; then
        # 捕捉 "屏蔽"、"失败"、"禁会员"、"中国"(送中)
        echo "🔴 ${status}"
    else
        echo "⚪ ${status}"
    fi
}

NF_STAT=$(parse_media "Netflix")
YT_STAT=$(parse_media "Youtube")
DP_STAT=$(parse_media "DisneyPlus")
TK_STAT=$(parse_media "TikTok")
GPT_STAT=$(parse_media "ChatGPT")
APV_STAT=$(parse_media "AmazonPrimeVideo")

# 提取原生 JSON 里的原始状态用于底层隐写回传
RAW_NF_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Netflix.Status // "Unknown"' 2>/dev/null)
RAW_YT_REG=$(echo "$JSON_DATA" | jq -r '.Media.Youtube.Region // ""' 2>/dev/null)
RAW_YT_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Youtube.Status // "Unknown"' 2>/dev/null)

# 5. 邮局连通性与黑名单
PORT25=$(echo "$JSON_DATA" | jq -r '.Mail.Port25 // "false"' 2>/dev/null)
[ "$PORT25" == "true" ] && P25_TEXT="✅ 畅通" || P25_TEXT="❌ 封堵"
DNS_BLACK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Blacklisted // "0"' 2>/dev/null)
DNS_MARK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Marked // "0"' 2>/dev/null)

# 6. “送中” 逻辑判定
WARNING_MSG=""
# [修复] 官方 JSON 已经去除了方括号，直接匹配 CN 或者状态包含中国
if [[ "$RAW_YT_REG" == "CN" ]] || [[ "$RAW_YT_STAT" == *"中国"* ]]; then
    # [修复] 采用 Bash 扩展转义 ($'...')，彻底解决直接打印 \n 字符的问题
    WARNING_MSG=$'\n🚨 **[高危] 该节点已被 Google 判定为中国大陆 (送中)！**\n'
fi

# 7. 组装情报级 Markdown 战报
# 提取本地运行态版本与生成时间戳
LOCAL_VER="${AGENT_VERSION:-未知}"
CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
# [核心修复] 抛弃本地残缺配置，直接提取探针刚刚实测拿到的真实出口 IP 拼接链接！
LINK_IP=$(echo "$IP_ADDR" | tr -d '[]')

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
• **IPQS:** \`${IPQS_SCORE}/100\`
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

_👉 [🔍 详细信用图谱直达 (Scamalytics)](https://scamalytics.com/ip/${LINK_IP})_

⏱️ \`${CURRENT_TIME}\` | ⚙️ \`v${LOCAL_VER}\`"

# [修复] 剥离显示层的 N/A，确保传给 Master 趋势数据库的是纯数字 (无效则记为0)
SAFE_SCAM_SCORE=$(echo "$SCAM_SCORE" | tr -cd '0-9')
[ -z "$SAFE_SCAM_SCORE" ] && SAFE_SCAM_SCORE="0"

# [v4.0.2 扩容] 提取 Google(基于YouTube) 和 ChatGPT 的原生状态
RAW_GOOG_STAT="${RAW_YT_REG:-$RAW_YT_STAT}"
[ -z "$RAW_GOOG_STAT" ] && RAW_GOOG_STAT="未知"
RAW_GPT_STAT=$(echo "$JSON_DATA" | jq -r '.Media.ChatGPT.Status // "未知"' 2>/dev/null)

# [修复] 废除会导致中文 UTF-8 字节被劈裂（产生乱码 ）的 awk 暴力截断。
# 原始状态文本极短（如"解锁"、"屏蔽"、"US"），只需洗掉隐形换行符即可安全传输。
S_GOOG=$(echo "$RAW_GOOG_STAT" | tr -d '\n\r ')
S_NF=$(echo "$RAW_NF_STAT" | tr -d '\n\r ')
S_GPT=$(echo "$RAW_GPT_STAT" | tr -d '\n\r ')
CB_DATA="svq|${NODE_NAME}|${SAFE_SCAM_SCORE}|${S_GOOG}|${S_NF}|${S_GPT}"

# 8. 挂载内联键盘并直送指挥部
JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$REPORT" \
  --arg cb "$CB_DATA" \
  --arg cb_manage "manage:${NODE_NAME}" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [
        [{text: "📥 将本次体检录入趋势库", callback_data: $cb}],
        [{text: "⚙️ 调出该节点控制台", callback_data: $cb_manage}]
      ]
    }
  }')

curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" >/dev/null