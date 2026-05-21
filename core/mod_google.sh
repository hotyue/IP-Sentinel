#!/bin/bash

# ==========================================================
# 脚本名称: mod_google.sh (Google 业务逻辑模块 - 动态锚点版)
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

# 容错机制：如果父进程没有传递 log 函数，则本地定义一个作为 fallback (v3.4.0 引入版本探针)
if ! type log >/dev/null 2>&1; then
    log() {
        # [v3.4.0 核心] 提取当前配置中的版本锚点
        local local_ver="${AGENT_VERSION:-未知}"
        
        # 保证日志目录存在
        mkdir -p "${INSTALL_DIR}/logs"
    
        # 日志格式注入 [版本号] 追踪标识
        local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$2" "$1" "$REGION_CODE" "$3")
        # [时区对齐] 强制无视本地时区，以绝对 UTC 时间写入日志
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "${INSTALL_DIR}/logs/sentinel.log"

        # 强制推送到 Systemd Journal (如果系统支持)
        if command -v logger >/dev/null 2>&1; then
            logger -t ip-sentinel "$core_msg"
        else
            # 降级输出到 stdout，让 Systemd 捕获
            echo "$core_msg"
        fi
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

STATE_DIR="${INSTALL_DIR}/state"
BOT_RISK_FILE="${STATE_DIR}/bot_risk.json"
SEARCH_QUOTA_FILE="${STATE_DIR}/google_search_quota.json"
SEARCH_DAILY_QUOTA="${GOOGLE_SEARCH_DAILY_QUOTA:-2}"
BOT_RISK_COOLDOWN_HOURS="${BOT_RISK_COOLDOWN_HOURS:-72}"

# --- [工具函数] ---
utc_now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

utc_now_epoch() {
    date -u +%s
}

epoch_to_utc_iso() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

write_bot_risk_file() {
    local reason=$1
    local http_status=${2:-""}
    local target_url=${3:-""}
    local now_epoch expires_epoch now_iso expires_iso
    now_epoch=$(utc_now_epoch)
    expires_epoch=$((now_epoch + BOT_RISK_COOLDOWN_HOURS * 3600))
    now_iso=$(utc_now_iso)
    expires_iso=$(epoch_to_utc_iso "$expires_epoch")

    jq -n \
        --arg reason "$reason" \
        --arg http_status "$http_status" \
        --arg target_url "$target_url" \
        --arg detected_at "$now_iso" \
        --arg expires_at "$expires_iso" \
        --argjson expires_at_epoch "$expires_epoch" \
        --argjson cooldown_hours "$BOT_RISK_COOLDOWN_HOURS" \
        '{
            active: true,
            reason: $reason,
            http_status: $http_status,
            target_url: $target_url,
            detected_at: $detected_at,
            expires_at: $expires_at,
            expires_at_epoch: $expires_at_epoch,
            cooldown_hours: $cooldown_hours
        }' > "${BOT_RISK_FILE}.tmp" && mv "${BOT_RISK_FILE}.tmp" "$BOT_RISK_FILE"
}

clear_expired_bot_risk() {
    [ -f "$BOT_RISK_FILE" ] || return 1

    local active expires_at_epoch
    active=$(jq -r '.active // false' "$BOT_RISK_FILE" 2>/dev/null)
    expires_at_epoch=$(jq -r '.expires_at_epoch // 0' "$BOT_RISK_FILE" 2>/dev/null)

    if [ "$active" = "true" ] && [ "$expires_at_epoch" -le "$(utc_now_epoch)" ]; then
        jq --arg cleared_at "$(utc_now_iso)" \
            '.active = false | .cleared_at = $cleared_at' \
            "$BOT_RISK_FILE" > "${BOT_RISK_FILE}.tmp" && mv "${BOT_RISK_FILE}.tmp" "$BOT_RISK_FILE"
    fi
}

bot_risk_active() {
    clear_expired_bot_risk
    [ -f "$BOT_RISK_FILE" ] || return 1

    local active expires_at_epoch
    active=$(jq -r '.active // false' "$BOT_RISK_FILE" 2>/dev/null)
    expires_at_epoch=$(jq -r '.expires_at_epoch // 0' "$BOT_RISK_FILE" 2>/dev/null)

    [ "$active" = "true" ] && [ "$expires_at_epoch" -gt "$(utc_now_epoch)" ]
}

quota_date_today() {
    date -u '+%Y-%m-%d'
}

current_search_quota_count() {
    local today stored_day stored_count
    today=$(quota_date_today)

    if [ -f "$SEARCH_QUOTA_FILE" ]; then
        stored_day=$(jq -r '.date // ""' "$SEARCH_QUOTA_FILE" 2>/dev/null)
        stored_count=$(jq -r '.count // 0' "$SEARCH_QUOTA_FILE" 2>/dev/null)
        if [ "$stored_day" = "$today" ]; then
            echo "$stored_count"
            return
        fi
    fi

    echo 0
}

write_search_quota_count() {
    local new_count=$1
    jq -n \
        --arg date "$(quota_date_today)" \
        --arg updated_at "$(utc_now_iso)" \
        --argjson count "$new_count" \
        --argjson limit "$SEARCH_DAILY_QUOTA" \
        '{
            date: $date,
            count: $count,
            limit: $limit,
            updated_at: $updated_at
        }' > "${SEARCH_QUOTA_FILE}.tmp" && mv "${SEARCH_QUOTA_FILE}.tmp" "$SEARCH_QUOTA_FILE"
}

can_run_search() {
    [ "$(current_search_quota_count)" -lt "$SEARCH_DAILY_QUOTA" ]
}

consume_search_quota() {
    local current_count next_count
    current_count=$(current_search_quota_count)
    next_count=$((current_count + 1))
    write_search_quota_count "$next_count"
    log "$MODULE_NAME" "INFO " "Google Search 配额已使用 ${next_count}/${SEARCH_DAILY_QUOTA} 次。"
}

response_triggers_bot_risk() {
    local http_code=$1
    local response_file=$2
    local target_url=$3

    if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
        write_bot_risk_file "http_${http_code}" "$http_code" "$target_url"
        return 0
    fi

    if [ -f "$response_file" ] && grep -Eiq 'captcha|recaptcha|unusual traffic|sorry/index|verify you are not a robot|our systems have detected unusual traffic' "$response_file"; then
        write_bot_risk_file "captcha_or_unusual_traffic" "$http_code" "$target_url"
        return 0
    fi

    return 1
}

get_random_coord() {
    local base=$1
    local range=$2 
    local offset=$(awk "BEGIN {print ( ( ($RANDOM % ($range * 2)) - $range ) / 10000 )}")
    awk "BEGIN {print ($base + $offset)}"
}

# --- [环境初始化] ---
# [v3.3.1修改] 优先读取对外公网面孔作为哈希种子，兼容 NAT 机的空 BIND_IP
CURRENT_IP="${PUBLIC_IP:-${BIND_IP:-Unknown}}"

# -----------------------------------------------------------
# [V3.1.5] 哈希锚定法 (Hash-Seeded Persona) 
# 利用 IP 算力固定 3 个永久化专属指纹，破除僵尸网络同质化特征
# -----------------------------------------------------------
TOTAL_UA=${#UA_POOL[@]}
if [ "$TOTAL_UA" -gt 0 ]; then
    # 1. 以本地锁定的公网 IP 为种子，计算固定不变的 CRC32 哈希值
    SEED=$(echo -n "$CURRENT_IP" | cksum | awk '{print $1}')
    
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

# 【核心升级】随机决定本次上网深度 (5 - 8 个复合动作，配合高频长效拉伸)
TOTAL_ACTIONS=$((5 + RANDOM % 4))

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
    # [v3.6.3 容错层补丁] 探测物理网卡/虚拟 IP 存活状态
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        log "$MODULE_NAME" "WARN " "检测到配置的出口 IP ($RAW_BIND_IP) 已丢失，自动降级为系统默认路由出网！"
        CURL_BIND_OPT=""
    else
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
fi

ensure_state_dir
if [ ! -f "$BOT_RISK_FILE" ]; then
    jq -n --arg updated_at "$(utc_now_iso)" '{active: false, reason: null, updated_at: $updated_at}' > "$BOT_RISK_FILE"
fi

if bot_risk_active; then
    BOT_RISK_UNTIL=$(jq -r '.expires_at // ""' "$BOT_RISK_FILE" 2>/dev/null)
    log "$MODULE_NAME" "WARN " "检测到 BOT_RISK 冷却中，暂停全部 Google 行为，冷却截止: ${BOT_RISK_UNTIL:-未知}"
    exit 0
fi

# --- [行为循环模拟] ---
SEARCH_ENABLED="true"
if ! can_run_search; then
    SEARCH_ENABLED="false"
    log "$MODULE_NAME" "WARN " "Google Search 当日配额已耗尽 (${SEARCH_DAILY_QUOTA} 次)，本轮只执行非 Search 行为。"
fi

for ((i=1; i<=TOTAL_ACTIONS; i++)); do
    # 模拟真实移动设备拿在手里时的 GPS 信号微抖动 (范围约 10 米)
    ACTION_LAT=$(get_random_coord $SESSION_BASE_LAT 1)
    ACTION_LON=$(get_random_coord $SESSION_BASE_LON 1)
    
    # 随机抽取一个符合当地特征的热点搜索词
    RAND_KEY=${KEYWORDS[$RANDOM % ${#KEYWORDS[@]}]}
    ENCODED_KEY=$(echo "$RAND_KEY" | jq -sRr @uri)
    
    # 随机选择一种上网行为
    ACTION_TYPE=$((1 + RANDOM % 4))
    if [ "$SEARCH_ENABLED" != "true" ] && [ "$ACTION_TYPE" -eq 1 ]; then
        ACTION_TYPE=$((2 + RANDOM % 3))
    fi
    
    # [V3.2.1 热修复] 注入 $CURL_BIND_OPT 与 $DYNAMIC_IP_PREF 协议自适应
    case $ACTION_TYPE in
        1) # 搜索行为
            SEARCH_URL="https://www.google.com/search?q=${ENCODED_KEY}&${LANG_PARAMS}"
            SEARCH_BODY=$(mktemp)
            consume_search_quota
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L -o "$SEARCH_BODY" -w "%{http_code}" -A "$SESSION_UA" \
                 "$SEARCH_URL")
            if response_triggers_bot_risk "$CODE" "$SEARCH_BODY" "$SEARCH_URL"; then
                rm -f "$SEARCH_BODY"
                log "$MODULE_NAME" "WARN " "Google Search 命中风控信号，已写入 BOT_RISK 并立即结束本轮会话。"
                exit 0
            fi
            rm -f "$SEARCH_BODY"
            if ! can_run_search; then
                SEARCH_ENABLED="false"
            fi
            ;;
        2) # 浏览本土新闻
            NEWS_URL="https://news.google.com/home?${LANG_PARAMS}"
            NEWS_BODY=$(mktemp)
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L -o "$NEWS_BODY" -w "%{http_code}" -A "$SESSION_UA" \
                 "$NEWS_URL")
            if response_triggers_bot_risk "$CODE" "$NEWS_BODY" "$NEWS_URL"; then
                rm -f "$NEWS_BODY"
                log "$MODULE_NAME" "WARN " "Google News 命中风控信号，已写入 BOT_RISK 并立即结束本轮会话。"
                exit 0
            fi
            rm -f "$NEWS_BODY"
            ;;
        3) # 地图坐标查询
            MAPS_URL="https://www.google.com/maps/search/${ENCODED_KEY}/@${ACTION_LAT},${ACTION_LON},17z?${LANG_PARAMS}"
            MAPS_BODY=$(mktemp)
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L -o "$MAPS_BODY" -w "%{http_code}" -A "$SESSION_UA" \
                 "$MAPS_URL")
            if response_triggers_bot_risk "$CODE" "$MAPS_BODY" "$MAPS_URL"; then
                rm -f "$MAPS_BODY"
                log "$MODULE_NAME" "WARN " "Google Maps 命中风控信号，已写入 BOT_RISK 并立即结束本轮会话。"
                exit 0
            fi
            rm -f "$MAPS_BODY"
            ;;
        4) # 触发移动端系统底层位置检测像素
            CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 10 -s -o /dev/null -w "%{http_code}" -A "$SESSION_UA" \
                 "https://connectivitycheck.gstatic.com/generate_204")
            ;;
    esac
    
    log "$MODULE_NAME" "EXEC " "动作[$i/$TOTAL_ACTIONS]完成 | HTTP状态: $CODE | 抖动坐标: $ACTION_LAT, $ACTION_LON"
    
    # 【核心升级】行为拉伸：每次动作后强制休眠 90 - 120 秒
    # 结合动作总数，总耗时将稳定在 10 分钟 到 20 分钟之间
    if [ $i -lt $TOTAL_ACTIONS ]; then
        # 【时间收敛修复】休眠控制在 45-75 秒，防止跨周期重叠导致进程被强杀
        SLEEP_TIME=$((45 + RANDOM % 31))
        log "$MODULE_NAME" "WAIT " "阅读当前页面内容，模拟停留 $SLEEP_TIME 秒..."
        sleep $SLEEP_TIME
    fi
done

# --- [结果纠偏自检 (V4.0.9 终极三核雷达: URL跳转 + Premium + Music)] ---
# 战术揭秘：汲取开源社区顶级探针的精髓！
# 1. 传统 URL 跳转探测：捕捉 www.google.com 底层 302 重定向域名的真实归属。
# 2. YT Premium 深度探测：提取核心 contentRegion 变量，并强匹配 www.google.cn 送中特征。
# 3. 严格一致性校验：任何一端出现非预期偏移，立即判定为漂移，彻底消除虚假“成功”。

log "$MODULE_NAME" "INFO " "启动三核交叉验证 (URL跳转 + YT Premium + YT Music) 穿透获取 GeoIP..."

# 核心 1: 传统 URL 跳转探测 (请求 www 才能触发准确跳转)
JUMP_HDR_FILE=$(mktemp)
JUMP_CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 10 -sI -D "$JUMP_HDR_FILE" -o /dev/null -w "%{http_code}" "http://www.google.com/")
if response_triggers_bot_risk "$JUMP_CODE" "$JUMP_HDR_FILE" "http://www.google.com/"; then
    rm -f "$JUMP_HDR_FILE"
    log "$MODULE_NAME" "WARN " "Google Jump 探针命中风控信号，已写入 BOT_RISK 并立即结束本轮会话。"
    exit 0
fi
JUMP_HDR=$(cat "$JUMP_HDR_FILE")
rm -f "$JUMP_HDR_FILE"
JUMP_LOC=$(echo "$JUMP_HDR" | grep -i "^location:" | tr -d '\r\n')
JUMP_GL=""

if [ -z "$JUMP_LOC" ]; then
    # 无跳转 (HTTP 200) 通常意味着原生被定位于 US
    JUMP_GL="US"
elif [[ "$JUMP_LOC" == *".google.cn"* ]] || [[ "$JUMP_LOC" == *"gl=CN"* ]]; then
    JUMP_GL="CN"
elif [[ "$JUMP_LOC" == *"gl="* ]]; then
    JUMP_GL=$(echo "$JUMP_LOC" | grep -o 'gl=[A-Za-z]\{2\}' | head -n 1 | cut -d'=' -f2 | tr 'a-z' 'A-Z')
else
    # 从域名中提取区域后缀 (如 .co.jp -> JP, .com.hk -> HK, .de -> DE)
    JUMP_DOMAIN=$(echo "$JUMP_LOC" | grep -o 'google\.[a-z\.]*' | head -n 1 | sed 's/google\.//')
    case "$JUMP_DOMAIN" in
        "com") JUMP_GL="US" ;;
        "com.hk") JUMP_GL="HK" ;;
        "com.tw") JUMP_GL="TW" ;;
        "co.jp") JUMP_GL="JP" ;;
        "co.uk") JUMP_GL="GB" ;;
        "co.kr") JUMP_GL="KR" ;;
        "co.in") JUMP_GL="IN" ;;
        "co.id") JUMP_GL="ID" ;;
        "co.th") JUMP_GL="TH" ;;
        "com.sg") JUMP_GL="SG" ;;
        "com.my") JUMP_GL="MY" ;;
        "com.au") JUMP_GL="AU" ;;
        "com.br") JUMP_GL="BR" ;;
        "com.mx") JUMP_GL="MX" ;;
        "com.ar") JUMP_GL="AR" ;;
        "co.za") JUMP_GL="ZA" ;;
        "cn") JUMP_GL="CN" ;;
        "") JUMP_GL="" ;;
        *) 
            # 提取标准两字母后缀 (.de, .fr, .nl)
            LAST_EXT=$(echo "$JUMP_DOMAIN" | awk -F'.' '{print $NF}' | tr 'a-z' 'A-Z')
            if [ ${#LAST_EXT} -eq 2 ]; then
                JUMP_GL="$LAST_EXT"
            else
                JUMP_GL="US"
            fi
            ;;
    esac
fi

# 核心 2: YouTube Premium 探测
YT_PR_GL=""
# [修复] 必须带上本轮循环的专属 UA (-A "$SESSION_UA")，防止被 Google CDN 丢进无状态爬虫兜底页
YT_PR_BODY=$(mktemp)
YT_PR_CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 10 -s -L -A "$SESSION_UA" -o "$YT_PR_BODY" -w "%{http_code}" "https://www.youtube.com/premium")
if response_triggers_bot_risk "$YT_PR_CODE" "$YT_PR_BODY" "https://www.youtube.com/premium"; then
    rm -f "$YT_PR_BODY"
    log "$MODULE_NAME" "WARN " "YouTube Premium 探针命中风控信号，已写入 BOT_RISK 并立即结束本轮会话。"
    exit 0
fi
YT_PR_HTML=$(cat "$YT_PR_BODY")
rm -f "$YT_PR_BODY"
if [[ "$YT_PR_HTML" == *"www.google.cn"* ]]; then
    YT_PR_GL="CN"
else
    # 穷举风控变量提取
    YT_PR_GL=$(echo "$YT_PR_HTML" | grep -o '"contentRegion":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')
    [ -z "$YT_PR_GL" ] && YT_PR_GL=$(echo "$YT_PR_HTML" | grep -o '"countryCode":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')
    [ -z "$YT_PR_GL" ] && YT_PR_GL=$(echo "$YT_PR_HTML" | grep -o '"INNERTUBE_CONTEXT_GL":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')
fi

# 核心 3: YouTube Music 探测
YT_MU_GL=""
# [修复] 同样加持 UA 装甲，强行唤出完整版前端框架
YT_MU_BODY=$(mktemp)
YT_MU_CODE=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 10 -s -L -A "$SESSION_UA" -o "$YT_MU_BODY" -w "%{http_code}" "https://music.youtube.com/")
if response_triggers_bot_risk "$YT_MU_CODE" "$YT_MU_BODY" "https://music.youtube.com/"; then
    rm -f "$YT_MU_BODY"
    log "$MODULE_NAME" "WARN " "YouTube Music 探针命中风控信号，已写入 BOT_RISK 并立即结束本轮会话。"
    exit 0
fi
YT_MU_HTML=$(cat "$YT_MU_BODY")
rm -f "$YT_MU_BODY"
if [[ "$YT_MU_HTML" == *"www.google.cn"* ]]; then
    YT_MU_GL="CN"
else
    # [修复] Music 的核心配置变量是 INNERTUBE_CONTEXT_GL
    YT_MU_GL=$(echo "$YT_MU_HTML" | grep -o '"INNERTUBE_CONTEXT_GL":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')
    [ -z "$YT_MU_GL" ] && YT_MU_GL=$(echo "$YT_MU_HTML" | grep -o '"countryCode":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')
    [ -z "$YT_MU_GL" ] && YT_MU_GL=$(echo "$YT_MU_HTML" | grep -o '"GL":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')
fi

# [基准对齐] 提取配置大区 (兼容州级穿透)，并修正英国的 ISO 代码
TARGET_CC="${REGION_CODE%%-*}"
[ "$TARGET_CC" == "UK" ] && TARGET_CC="GB"

# --- 终极审判逻辑 (以 YouTube 核心业务为主导，兼顾底层雷达权重) ---
IS_CN=0
VALID_PROBES=0

# 1. 扫描所有探针，统计有效性并执行“送中”一票否决
for val in "$JUMP_GL" "$YT_PR_GL" "$YT_MU_GL"; do
    if [ -n "$val" ]; then
        ((VALID_PROBES++))
        [ "$val" == "CN" ] && IS_CN=1
    fi
done

if [ $VALID_PROBES -eq 0 ]; then
    STATUS="🚨 探针失效 (三核全部熔断，可能遭严重风控拦截)"
elif [ $IS_CN -eq 1 ]; then
    STATUS="❌ 严重高危！三核雷达判定 IP 已被中国大陆锁定 (送中)！"
else
    # 2. 评估核心流媒体业务是否达标 (只要 YT_PR 或 YT_MU 其一达标，即视为成功)
    YT_MATCH=0
    [ "$YT_PR_GL" == "$TARGET_CC" ] && YT_MATCH=1
    [ "$YT_MU_GL" == "$TARGET_CC" ] && YT_MATCH=1

    if [ $YT_MATCH -eq 1 ]; then
        # 3. 核心业务达标，进一步评估底层路由权重
        if [ -n "$JUMP_GL" ] && [ "$JUMP_GL" != "$TARGET_CC" ]; then
            # YT 解锁了，但基础跳转 IP 库漂移了 (降级为 ✅，但备注底层漂移)
            STATUS="✅ 目标区域达成 (YT主导成功, Jump副雷达漂移至 ${JUMP_GL}) | Prem: ${YT_PR_GL:-无} | Music: ${YT_MU_GL:-无}"
        else
            # 完美达成
            STATUS="✅ 目标区域达成 (Jump: ${JUMP_GL:-无} | Prem: ${YT_PR_GL:-无} | Music: ${YT_MU_GL:-无})"
        fi
    else
        # YouTube 流媒体核心未能解锁目标区域，宣判漂移
        STATUS="⚠️ 区域发生漂移！目标 $TARGET_CC，实际 (Jump: ${JUMP_GL:-无} | Prem: ${YT_PR_GL:-无} | Music: ${YT_MU_GL:-无})"
    fi
fi

log "$MODULE_NAME" "SCORE" "自检结论: $STATUS"
log "$MODULE_NAME" "END  " "========== 会话结束，释放进程 =========="