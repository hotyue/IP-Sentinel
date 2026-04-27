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

# --- [工具函数] ---
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

# --- [行为循环模拟] ---
for ((i=1; i<=TOTAL_ACTIONS; i++)); do
    # 模拟真实移动设备拿在手里时的 GPS 信号微抖动 (范围约 10 米)
    ACTION_LAT=$(get_random_coord $SESSION_BASE_LAT 1)
    ACTION_LON=$(get_random_coord $SESSION_BASE_LON 1)
    
    # 随机抽取一个符合当地特征的热点搜索词
    RAND_KEY=${KEYWORDS[$RANDOM % ${#KEYWORDS[@]}]}
    ENCODED_KEY=$(echo "$RAND_KEY" | jq -sRr @uri)
    
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

# --- [结果纠偏自检 (V4.0.3 终极真理版: 穿透 Google 真实 GeoIP 数据库)] ---
# 彻底抛弃不可靠的前端 URL 重定向判定 (解决 Issue #35 和 #14 的假阳性问题)
# 战术揭秘：Google 与 YouTube 共享绝对一致的底层 GeoIP 库。
# 我们直接抓取 YouTube 源码内部的 "GL" (Geo-Location) 环境变量，拿到 Google 视角的 2 位国家代码！

log "$MODULE_NAME" "INFO " "正在穿透获取 Google 底层真实 GeoIP 锚点..."
YT_HTML=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -m 15 -s -L https://www.youtube.com)

# 精准正则提取 "GL":"XX" 中的两位字母 (完美兼容所有老旧系统环境)
REAL_REGION=$(echo "$YT_HTML" | grep -o '"GL":"[A-Za-z]\{2\}"' | head -n 1 | cut -d'"' -f4 | tr 'a-z' 'A-Z')

if [ -z "$REAL_REGION" ]; then
    STATUS="🚨 探针失效 (网络阻断，或已被 Google 验证码/5秒盾拦截)"
else
    # [基准对齐] 提取配置大区 (兼容州级穿透，如 US-TX -> US)，并修正英国的 ISO 标准代码
    TARGET_CC="${REGION_CODE%%-*}"
    [ "$TARGET_CC" == "UK" ] && TARGET_CC="GB"
    
    # 终极审判逻辑
    if [ "$REAL_REGION" == "CN" ]; then
        STATUS="❌ 严重高危！IP 已被 Google 判定为中国大陆 (送中)！"
    elif [ "$REAL_REGION" == "$TARGET_CC" ]; then
        STATUS="✅ 目标区域达成 (底层真实锚定: $REAL_REGION)"
    else
        STATUS="⚠️ 区域发生漂移！目标 $TARGET_CC，实际归属 $REAL_REGION (跨区送医/送美)"
    fi
fi

log "$MODULE_NAME" "SCORE" "自检结论: $STATUS"
log "$MODULE_NAME" "END  " "========== 会话结束，释放进程 =========="