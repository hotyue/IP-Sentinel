#!/bin/bash

# ==========================================================
# 脚本名称: mod_google.sh (Google 业务逻辑模块)
# 核心功能: 执行坐标微抖动、模拟真实阅读时长、会话行为拉伸
# ==========================================================

MODULE_NAME="Google"
CONFIG_FILE="/opt/ip_sentinel/config.conf"

# 1. 加载冷数据配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "配置文件丢失！退出执行。"
    exit 1
fi

# 容错机制：如果父进程没有传递 log 函数，则本地定义一个作为 fallback
if ! type log >/dev/null 2>&1; then
    log() {
        mkdir -p "${INSTALL_DIR}/logs"
        printf "[$(date '+%Y-%m-%d %H:%M:%S')] [%-5s] [%-7s] [%s] %s\n" "$2" "$1" "$REGION_CODE" "$3" >> "${INSTALL_DIR}/logs/sentinel.log"
    }
fi

log "$MODULE_NAME" "START" "========== 唤醒网络模拟器 [区域: $REGION_NAME] =========="

# 2. 动态加载热数据 (设备指纹池 和 专属搜索词库)
UA_FILE="${INSTALL_DIR}/data/user_agents.txt"
KW_FILE="${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"

if [ ! -f "$UA_FILE" ] || [ ! -f "$KW_FILE" ]; then
    log "$MODULE_NAME" "ERROR" "热数据缺失，请检查 data 目录。放弃本次执行。"
    exit 1
fi

# 将文本按行读取到数组中 (并自动过滤空行)
mapfile -t UA_POOL < <(grep -v '^$' "$UA_FILE")
mapfile -t KEYWORDS < <(grep -v '^$' "$KW_FILE")

# --- [工具函数] ---
get_random_coord() {
    local base=$1
    local range=$2 
    local offset=$(awk "BEGIN {print ( ( ($RANDOM % ($range * 2)) - $range ) / 10000 )}")
    awk "BEGIN {print ($base + $offset)}"
}

# --- [环境初始化] ---
# [v3.0.2修复] 直接读取系统已锁定的锚点 IP，彻底杜绝“获取IP失败”及隧道偏移
CURRENT_IP="${BIND_IP:-Unknown}"

# -----------------------------------------------------------
# [V3.1.5] 哈希锚定法 (Hash-Seeded Persona) 
# 利用 IP 算力固定 3 个永久化专属指纹，破除僵尸网络同质化特征
# -----------------------------------------------------------
TOTAL_UA=${#UA_POOL[@]}
if [ "$TOTAL_UA" -gt 0 ]; then
    # 1. 以本地锁定的公网 IP 为种子，计算固定不变的 CRC32 哈希值
    # 🛡️ [安全修复] 命令注入防护：确保IP只包含合法字符
    SAFE_IP=$(echo "$CURRENT_IP" | tr -cd 'a-zA-Z0-9.:\[\]')
    SEED=$(echo -n "$SAFE_IP" | cksum | awk '{print $1}')
    
    # 2. 利用确定的种子和质数乘数，在全球 4000 的库中计算出本机的 3 个绝对专属坐标
    IDX1=$(( SEED % TOTAL_UA ))
    IDX2=$(( (SEED * 17) % TOTAL_UA ))
    IDX3=$(( (SEED * 31) % TOTAL_UA ))
    
    # 3. 将绝对坐标映射为该节点的“专属设备库”
    MY_UA_POOL=("${UA_POOL[$IDX1]}" "${UA_POOL[$IDX2]}" "${UA_POOL[$IDX3]}")
    
    # 4. 本次会话从这 3 台专属设备中随机挑选 1 台进行模拟
    SESSION_UA=${MY_UA_POOL[$RANDOM % 3]}
else
    # 兜底容错机制
    SESSION_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
fi
# 位置锁定：在基准点(比如东京新宿)附近 3 公里内随机生成本次上网的“固定咖啡馆”坐标
SESSION_BASE_LAT=$(get_random_coord $BASE_LAT 270)
SESSION_BASE_LON=$(get_random_coord $BASE_LON 270)

# 【核心升级】随机决定本次上网深度 (6 - 10 个复合动作，配合高频长效拉伸)
TOTAL_ACTIONS=$((6 + RANDOM % 5))

log "$MODULE_NAME" "INFO " "当前出网 IP: $CURRENT_IP"
log "$MODULE_NAME" "INFO " "设备指纹锁定: ${SESSION_UA:0:45}..."
log "$MODULE_NAME" "INFO " "虚拟驻留坐标: $SESSION_BASE_LAT, $SESSION_BASE_LON"

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
        log "$MODULE_NAME" "INFO " "底层路由锁定: 绑定 IPv6 出口及协议 ($BIND_IP)"
    elif [[ "$BIND_IP" == *"."* ]]; then
        DYNAMIC_IP_PREF="-4"
        log "$MODULE_NAME" "INFO " "底层路由锁定: 绑定 IPv4 出口及协议 ($BIND_IP)"
    fi
fi

# --- [行为循环模拟] ---
for ((i=1; i<=TOTAL_ACTIONS; i++)); do
    # 模拟真实移动设备拿在手里时的 GPS 信号微抖动 (范围约 10 米)
    ACTION_LAT=$(get_random_coord $SESSION_BASE_LAT 1)
    ACTION_LON=$(get_random_coord $SESSION_BASE_LON 1)
    
    # 随机抽取一个符合当地特征的热点搜索词
    RAND_KEY=${KEYWORDS[$RANDOM % ${#KEYWORDS[@]}]}
    # 🛡️ [安全修复] 命令注入防护：过滤搜索词中的危险字符
    SAFE_KEY=$(echo "$RAND_KEY" | tr -cd 'a-zA-Z0-9\u4e00-\u9fa5\s\-_')
    ENCODED_KEY=$(echo "$SAFE_KEY" | jq -sRr @uri)
    
    # 随机选择一种上网行为
    ACTION_TYPE=$((1 + RANDOM % 4))
    
    # [V3.2.1 热修复] 注入 $CURL_BIND_OPT 与 $DYNAMIC_IP_PREF 协议自适应
    case $ACTION_TYPE in
        1) # 搜索行为
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://www.google.com/search?q=${ENCODED_KEY}&${LANG_PARAMS}")
            ;;
        2) # 浏览本土新闻
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://news.google.com/home?${LANG_PARAMS}")
            ;;
        3) # 地图坐标查询
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://www.google.com/maps/search/$${ENCODED_KEY}/@${ACTION_LAT},${ACTION_LON},17z?${LANG_PARAMS}")
            ;;
        4) # 触发移动端系统底层位置检测像素
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 10 -s -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://connectivitycheck.gstatic.com/generate_204")
            ;;
    esac
    
    log "$MODULE_NAME" "EXEC " "动作[$i/$TOTAL_ACTIONS]完成 | HTTP状态: $CODE | 抖动坐标: $ACTION_LAT, $ACTION_LON"
    
    # 【核心升级】行为拉伸：每次动作后强制休眠 90 - 150 秒
    # 结合动作总数，总耗时将稳定在 10 分钟 到 25 分钟之间
    if [ $i -lt $TOTAL_ACTIONS ]; then
        SLEEP_TIME=$((90 + RANDOM % 61))
        log "$MODULE_NAME" "WAIT " "阅读当前页面内容，模拟停留 $SLEEP_TIME 秒..."
        sleep $SLEEP_TIME
    fi
done

# --- [结果纠偏自检 (V3.2.1 高精度容错版)] ---
# [V3.2.1 热修复] 探针同样应用 $DYNAMIC_IP_PREF 协议自适应
PROBE_RESULT=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L -o /dev/null -w "%{http_code}|%{url_effective}" https://www.google.com)

# 分离状态码与 URL
PROBE_CODE=$(echo "$PROBE_RESULT" | cut -d'|' -f1)
FINAL_URL=$(echo "$PROBE_RESULT" | cut -d'|' -f2)

# 0. 致命拦截：网络断开、DNS 解析失败或严重超时
if [ "$PROBE_CODE" == "000" ] || [ -z "$FINAL_URL" ]; then
    STATUS="🚨 探针失效 (网络阻断或底层路由异常)"
else
    # 核心战术：精准提取最终 URL 的域名部分
    ACTUAL_DOMAIN=$(echo "$FINAL_URL" | awk -F/ '{print $3}')
    
    # [V3.2.1 优化] 使用通配符 * 剔除任意前缀 (无论是 www.google. 还是 ipv4.google.)
    ACTUAL_SUFFIX=${ACTUAL_DOMAIN#*google.}

    # 1. 优先验证：绝对匹配目标后缀 (彻底杜绝 com 包含于 com.hk 的陷阱)
    if [ "$ACTUAL_SUFFIX" == "$VALID_URL_SUFFIX" ]; then
        STATUS="✅ 目标区域达成 ($ACTUAL_SUFFIX)"

    # 2. 核心拦截：精准捕捉送中特征 (com.hk)
    elif [ "$ACTUAL_SUFFIX" == "com.hk" ]; then
        if [ "$REGION_CODE" == "HK" ]; then
            STATUS="✅ 目标区域达成 (HK 专属 com.hk)"
        else
            STATUS="❌ 严重漂移！判定为送中区 (实际跳往 $ACTUAL_SUFFIX)"
        fi

    # 3. 宽容处理：遵守 Google 无跳转新规 (严格限定必须是纯粹的 com)
    # [视觉优化] 留在 .com 代表 IP 极度纯净未被区域沙盒锁定，计入成功战绩！
    elif [ "$ACTUAL_SUFFIX" == "com" ]; then
        STATUS="✅ 目标区域达成 (免签停留 .com 通用主站)"

    # 4. 跨区漂移：所有预判之外的后缀，全部视为异常
    else
        STATUS="⚠️ 跨区跳板漂移 (当前实际归属: $ACTUAL_SUFFIX)"
    fi
fi

log "$MODULE_NAME" "SCORE" "自检结论: $STATUS"
log "$MODULE_NAME" "END  " "========== 会话结束，释放进程 =========="