#!/bin/bash

# ==========================================================
# 脚本名称: mod_trust.sh (IP 信用净化模块 V3.1.4 拓扑自适应版)
# 核心功能: 动态扫描本地 LBS 冷数据，提取权威白名单，执行流量净化
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
UA_FILE="${INSTALL_DIR}/data/user_agents.txt"
# 你的 GitHub 仓库 Raw 数据直链前缀
REPO_RAW_URL="https://raw.githubusercontent.com/Seameee/IP-Sentinel/main"
# 临时改为私库地址用于测试
# REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"

# 1. 基础环境校验
[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

REGION=${REGION_CODE:-"US"}
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# 2. 动态获取配置 (V3 拓扑自适应与兜底)
# 利用 find 穿透多级子目录，自动抓取安装时落地的那份专属 json 文件
REGION_JSON_FILE=$(find "${INSTALL_DIR}/data/regions" -name "*.json" 2>/dev/null | head -n 1)

# 兼容旧节点兜底：如果本地真没找到 json，回退到拉取云端通用大区配置
if [ -z "$REGION_JSON_FILE" ] || [ ! -f "$REGION_JSON_FILE" ]; then
    REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${REGION}.json"
    mkdir -p "${INSTALL_DIR}/data/regions"
    curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/data/regions/${REGION}.json" -o "$REGION_JSON_FILE"
fi

# 使用 jq 将 json 中的网址数组安全地读入 Bash 数组
if [ -f "$REGION_JSON_FILE" ]; then
    mapfile -t TRUST_URLS < <(jq -r '.trust_module.white_urls[]' "$REGION_JSON_FILE" 2>/dev/null)
fi

# 兜底：如果仓库挂了或者解析失败，提供国际通用白名单
if [ ${#TRUST_URLS[@]} -eq 0 ]; then
    TRUST_URLS=("https://en.wikipedia.org/wiki/Special:Random" "https://www.apple.com/" "https://www.microsoft.com/")
fi

# 3. 日志规范化
log_msg() {
    local TYPE=$1
    local MSG=$2
    local TIME=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIME] [$TYPE] [Trust  ] [$REGION] $MSG" | tee -a "$LOG_FILE"
}

# 4. 锁定单次会话指纹
# -----------------------------------------------------------
# [V3.1.5] 哈希锚定法 (Hash-Seeded Persona) 
# 利用 IP 算力固定 3 个永久化专属指纹，破除僵尸网络同质化特征
# -----------------------------------------------------------
if [ -f "$UA_FILE" ]; then
    mapfile -t UA_POOL < <(grep -v '^$' "$UA_FILE")
    TOTAL_UA=${#UA_POOL[@]}
    
    if [ "$TOTAL_UA" -gt 0 ]; then
        # 以本地锁定的公网 IP (BIND_IP) 为种子计算 CRC32 哈希值
        # 🛡️ [安全修复] 命令注入防护：确保IP只包含合法字符
        SAFE_BIND_IP=$(echo "${BIND_IP:-127.0.0.1}" | tr -cd 'a-zA-Z0-9.:\[\]')
        SEED=$(echo -n "$SAFE_BIND_IP" | cksum | awk '{print $1}')
        
        # 利用确定的种子，在全球 4000 的库中，计算出本机的 3 个绝对专属坐标
        IDX1=$(( SEED % TOTAL_UA ))
        IDX2=$(( (SEED * 17) % TOTAL_UA ))
        IDX3=$(( (SEED * 31) % TOTAL_UA ))
        
        # 将专属坐标映射为专属设备库
        MY_UA_POOL=("${UA_POOL[$IDX1]}" "${UA_POOL[$IDX2]}" "${UA_POOL[$IDX3]}")
        
        # 本次会话从这 3 台专属设备中随机挑选 1 台 (模拟真实的家庭多设备环境)
        CURRENT_UA=${MY_UA_POOL[$RANDOM % 3]}
    else
        # 兜底容错
        CURRENT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    fi
else
    CURRENT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
fi

# ==========================================
# 🚀 净化行动开始
# ==========================================
log_msg "START" "========== 启动区域 IP 信用净化会话 =========="
log_msg "INFO " "已载入 [${REGION}] 区域白名单，配置库条目: ${#TRUST_URLS[@]} 个"
log_msg "INFO " "已锁定本地伪装指纹: $(echo $CURRENT_UA | cut -d' ' -f1-2)..."

# -----------------------------------------------------------
# [V3.2.1 热修复] 网络锚定与协议自适应构建 
# 强制 curl 绑定网卡，并自动匹配 IPv4/v6 协议，杜绝 curl 冲突报错
# -----------------------------------------------------------
CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}" # 默认提取用户配置

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    CURL_BIND_OPT="--interface $BIND_IP"
    # 智能探测：带冒号为 V6，带点号为 V4
    if [[ "$BIND_IP" == *":"* ]]; then
        DYNAMIC_IP_PREF="-6"
        log_msg "INFO " "底层路由锁定: 绑定 IPv6 出口及协议 ($BIND_IP)"
    elif [[ "$BIND_IP" == *"."* ]]; then
        DYNAMIC_IP_PREF="-4"
        log_msg "INFO " "底层路由锁定: 绑定 IPv4 出口及协议 ($BIND_IP)"
    fi
fi

STEP_COUNT=$((RANDOM % 4 + 3))
SUCCESS_INJECT=0

for ((i=1; i<=STEP_COUNT; i++)); do
    # 随机抽取本地区域权威网址
    TARGET_URL=${TRUST_URLS[$RANDOM % ${#TRUST_URLS[@]}]}
    
    # [v3.0.1修复] 注入高权重流量时，强制从绑定的 IPv4 或 IPv6 隧道出网
    # [V3.2.1 热修复] 注入 $CURL_BIND_OPT 与 $DYNAMIC_IP_PREF 协议自适应
    HTTP_CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -A "$CURRENT_UA" \
        -H "Accept: text/html,application/xhtml+xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Sec-Fetch-Dest: document" \
        -H "Sec-Fetch-Mode: navigate" \
        -H "Upgrade-Insecure-Requests: 1" \
        --compressed \
        -s -o /dev/null -w "%{http_code}" -m 15 "$TARGET_URL")

    # 扩大 HTTP 状态码容错区间：包含所有 20x (如亚马逊的 202) 和 30x 重定向
    if [[ "$HTTP_CODE" =~ ^(20[0-9]|30[1-8])$ ]]; then
        log_msg "EXEC " "动作[$i/$STEP_COUNT]完成 | 状态: $HTTP_CODE | 注入: $TARGET_URL"
        ((SUCCESS_INJECT++))
    else
        log_msg "EXEC " "动作[$i/$STEP_COUNT]异常 | 状态: $HTTP_CODE | 阻拦: $TARGET_URL"
    fi

    if [ $i -lt $STEP_COUNT ]; then
        SLEEP_TIME=$((RANDOM % 76 + 45))
        log_msg "WAIT " "正在浏览本地高权重页面，模拟停留 $SLEEP_TIME 秒..."
        sleep $SLEEP_TIME
    fi
done

# ==========================================
# 📊 结论判定与输出
# ==========================================
if [ "$SUCCESS_INJECT" -ge $((STEP_COUNT / 2)) ]; then
    log_msg "SCORE" "自检结论: ✅ 信用净化完成 (已成功注入 $SUCCESS_INJECT 条无害流量)"
else
    log_msg "SCORE" "自检结论: ❌ 净化受阻 (部分站点拦截或网络超时)"
fi

log_msg "END  " "========== 会话结束，释放进程 =========="
log_msg "INFO " "系统级调度完毕，信任因子持续积累中..."