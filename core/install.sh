#!/bin/bash

# ==========================================================
# 脚本名称: install.sh (IP-Sentinel 分布式边缘节点部署脚本 - 动态锚点版)
# 核心功能: 战区分组菜单、模块按需开启、官方机器人一键配置、版本状态机路由
# ==========================================================

# 你的 GitHub 仓库 Raw 数据直链前缀
REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为私库地址用于测试
# REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# [核心: 动态提取 Agent 专属版本锚点 (KV 解析法)]
TARGET_VERSION=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
# 🛡️ 兜底防线：如果网络波动拉取失败，启用内置的安全兜底版本
TARGET_VERSION=${TARGET_VERSION:-"3.5.1"}

# 轻量级版本号比对函数 (例如: version_lt "3.3.1" "3.4.0" 返回 true)
version_lt() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" && test "$1" != "$2"
}

echo "========================================================"
echo "      🛡️ 欢迎使用 IP-Sentinel (边缘节点 Edge Agent)"
echo "               当前安装包版本: v${TARGET_VERSION}"
echo "========================================================"

# 1. 依赖检查与安装 (新增 python3 用于轻量级 Webhook 服务)
echo -e "\n[1/7] 正在安装必要环境依赖 (curl, jq, cron, procps, python3)..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl jq cron procps python3 >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl jq cronie procps-ng python3 >/dev/null 2>&1
    systemctl enable crond && systemctl start crond
else
    echo "⚠️ 未知系统，请确保已手动安装 curl, jq, pgrep 和 python3"
fi

# 2. 交互式引导与动态地图解析 (v3.0 全球网络)
echo -e "\n[2/7] 正在连线云端，拉取全球节点地图..."
curl -sL "${REPO_RAW_URL}/data/map.json" -o "/tmp/map.json"

if [ ! -s "/tmp/map.json" ]; then
    echo -e "\033[31m❌ 拉取全球地图失败！请检查网络或 GitHub 仓库地址。\033[0m"
    exit 1
fi

echo -e "\n请选择操作:"
echo "  1) 🚀 部署边缘节点 (进入全球节点配置)"
echo "  2) 🗑️ 一键卸载 IP-Sentinel"
read -p "请输入选择 [1-2] (默认1): " ACTION_CHOICE

# [v3.5.2 修复] 防止用户直接回车导致变量为空，从而漏过下方的平滑升级判定
ACTION_CHOICE=${ACTION_CHOICE:-1}

if [ "$ACTION_CHOICE" == "2" ]; then
    echo -e "\n⏳ 正在拉取卸载程序..."
    curl -sL "${REPO_RAW_URL}/core/uninstall.sh" -o "/tmp/ip_uninstall.sh"
    chmod +x "/tmp/ip_uninstall.sh"
    bash "/tmp/ip_uninstall.sh"
    rm -f "/tmp/ip_uninstall.sh"
    exit 0
fi

# ================== [v3.2.2 新增: 平滑升级模式嗅探] ==================
UPGRADE_MODE="false"
KEEP_LOGS="true"

if [ "$ACTION_CHOICE" == "1" ] && [ -f "$CONFIG_FILE" ]; then
    echo -e "\n\033[33m💡 哨兵雷达提示：检测到本机已部署过 IP-Sentinel。\033[0m"
    read -p "👉 是否按原配置直接进行平滑升级？(y/n, 默认y): " UPGRADE_CHOICE
    if [[ -z "$UPGRADE_CHOICE" || "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
        UPGRADE_MODE="true"
        read -p "👉 是否保留历史运行日志？(y/n, 默认y): " LOG_CHOICE
        if [[ "$LOG_CHOICE" =~ ^[Nn]$ ]]; then
            KEEP_LOGS="false"
        fi
        
        # 将原配置读入环境变量，为后续跳过配置步骤提供燃料
        source "$CONFIG_FILE"
        echo -e "\033[32m✅ 已激活 [平滑升级模式]，即将跳过基础配置，直接更新核心装甲...\033[0m"
    else
        echo -e "\033[33m🔄 您选择了重新配置，旧的哨兵数据将被彻底抹除。\033[0m"
    fi
fi
# ====================================================================

# ================== [v3.1.1/v3.2.2 优化: 安装前环境纯净度清理] ==================
echo -e "\n⏳ 正在清理旧版守护进程与冗余任务..."
# 1. 强制超度可能存活的 Webhook 及各类看门狗进程，释放端口
pkill -9 -f "webhook.py" >/dev/null 2>&1 || true
pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1 || true
pkill -9 -f "runner.sh" >/dev/null 2>&1 || true

# 2. 清除系统定时任务 (Cron) 中的旧版条目
if crontab -l >/dev/null 2>&1; then
    crontab -l | grep -v "ip_sentinel" > /tmp/cron_clean
    crontab /tmp/cron_clean
    rm -f /tmp/cron_clean
fi

# 3. 抹除旧版核心代码，杜绝代码冲突 (根据模式分流)
if [ "$UPGRADE_MODE" == "true" ]; then
    # 升级模式：仅销毁核心引擎，严格保留 config 与 data
    rm -rf "${INSTALL_DIR}/core" 2>/dev/null
    if [ "$KEEP_LOGS" == "false" ]; then
        rm -rf "${INSTALL_DIR}/logs" 2>/dev/null
        echo -e "🗑️ 历史日志已按指令清空。"
    else
        echo -e "📦 历史配置与战地日志已妥善保留。"
    fi
else
    # 全新安装模式：焦土政策，彻底抹除
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "${INSTALL_DIR}/core" "${INSTALL_DIR}/data" "${INSTALL_DIR}/config.conf" "${INSTALL_DIR}/.last_ip" 2>/dev/null
    fi
fi
echo -e "\033[32m✅ 环境清理完毕，幽灵进程已肃清！\033[0m"
# ========================================================================================

# ==========================================================
# 🛑 如果是全新部署，才执行以下所有交互逻辑；否则直接跳过
# ==========================================================
if [ "$UPGRADE_MODE" == "false" ]; then

    # 📍 动态零级菜单：战区(大洲)选择
    echo -e "\n\033[36m📍 【第零级】请选择目标战区 (Continent):\033[0m"
    jq -r '.continents[] | "\(.id)|\(.name)"' /tmp/map.json > /tmp/continents.txt
    i=1; CONT_MAP=()
    while IFS="|" read -r cont_id cont_name; do
        echo "  $i) $cont_name"
        CONT_MAP[$i]="$cont_id"
        ((i++))
    done < /tmp/continents.txt

    read -p "请输入选择 [1-$((i-1))] (默认1): " CONT_SEL
    CONT_SEL=${CONT_SEL:-1}
    CONT_ID="${CONT_MAP[$CONT_SEL]}"

    # 📍 动态一级菜单：国家选择 (基于选中战区)
    echo -e "\n\033[36m📍 【第一级】正在检索 [$CONT_ID] 战区下的国家/地区...\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | \"\(.id)|\(.name)|\(.keyword_file)\"" /tmp/map.json > /tmp/countries.txt
    i=1; COUNTRY_MAP=(); KEYWORD_MAP=()
    while IFS="|" read -r c_id c_name k_file; do
        echo "  $i) $c_name"
        COUNTRY_MAP[$i]="$c_id"
        KEYWORD_MAP[$i]="$k_file"
        ((i++))
    done < /tmp/countries.txt

    read -p "请输入选择 [1-$((i-1))] (默认1): " C_SEL
    C_SEL=${C_SEL:-1}
    COUNTRY_ID="${COUNTRY_MAP[$C_SEL]}"
    KEYWORD_FILE="${KEYWORD_MAP[$C_SEL]}"
    REGION_CODE="$COUNTRY_ID" # 兼容旧版的 config.conf

    # 📍 动态二级菜单：省/州选择 (基于选中战区和国家)
    echo -e "\n\033[36m📍 【第二级】正在检索 [$COUNTRY_ID] 的行政区数据...\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | \"\(.id)|\(.name)\"" /tmp/map.json > /tmp/states.txt
    STATE_COUNT=$(wc -l < /tmp/states.txt)

    if [ "$STATE_COUNT" -eq 1 ]; then
        IFS="|" read -r STATE_ID STATE_NAME < /tmp/states.txt
        echo -e "\033[32m💡 该国家下仅有单一配置 [$STATE_NAME]，已自动跃迁。\033[0m"
    else
        i=1; STATE_MAP=()
        while IFS="|" read -r s_id s_name; do
            echo "  $i) $s_name"
            STATE_MAP[$i]="$s_id"
            ((i++))
        done < /tmp/states.txt
        read -p "请输入选择 [1-$((i-1))] (默认1): " S_SEL
        S_SEL=${S_SEL:-1}
        STATE_ID="${STATE_MAP[$S_SEL]}"
    fi

    # 📍 动态三级菜单：城市选择 (基于战区、国家、州三层过滤)
    echo -e "\n\033[36m📍 【第三级】请锁定具体城市节点:\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | select(.id==\"$STATE_ID\") | .cities[] | \"\(.id)|\(.name)\"" /tmp/map.json > /tmp/cities.txt
    CITY_COUNT=$(wc -l < /tmp/cities.txt)

    if [ "$CITY_COUNT" -eq 1 ]; then
        IFS="|" read -r CITY_ID CITY_NAME < /tmp/cities.txt
        echo -e "\033[32m💡 该区域下仅有单一城市 [$CITY_NAME]，已自动锁定。\033[0m"
    else
        i=1; CITY_MAP=()
        while IFS="|" read -r c_id c_name; do
            echo "  $i) $c_name"
            CITY_MAP[$i]="$c_id"
            ((i++))
        done < /tmp/cities.txt
        read -p "请输入选择 [1-$((i-1))] (默认1): " CI_SEL
        CI_SEL=${CI_SEL:-1}
        CITY_ID="${CITY_MAP[$CI_SEL]}"
    fi

    # 清理临时文件 (增加清理 continents.txt)
    rm -f /tmp/map.json /tmp/continents.txt /tmp/countries.txt /tmp/states.txt /tmp/cities.txt

    # 本地工作目录初始化 (支持 v3.0 的深度层级)
    mkdir -p "${INSTALL_DIR}/core"
    mkdir -p "${INSTALL_DIR}/data/keywords"
    mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
    mkdir -p "${INSTALL_DIR}/logs"

    # 3. 功能模块前置开关 (按需加载)
    echo -e "\n[3/7] 请选择需要开启的养护模块 (按需开启，节省资源):"
    echo "  1) 📍 仅开启 [Google 区域纠偏] (默认，适合流媒体解锁机位漂移)"
    echo "  2) 🛡️ 仅开启 [IP 信用净化] (适合高风险机房 IP 降低 Scamalytics 分数)"
    echo "  3) 🔥 双管齐下 (同时开启以上两项)"
    read -p "请输入选择 [1-3] (默认1): " MODULE_CHOICE

    ENABLE_GOOGLE="true"
    ENABLE_TRUST="false"
    case ${MODULE_CHOICE:-1} in
        2) ENABLE_GOOGLE="false"; ENABLE_TRUST="true" ;;
        3) ENABLE_GOOGLE="true"; ENABLE_TRUST="true" ;;
        *) ENABLE_GOOGLE="true"; ENABLE_TRUST="false" ;;
    esac

    # 4. 接入 Master 中枢配置
    echo -e "\n[4/7] 是否接入 Master 司令部？(需要配置与主控相同的 TG 机器人) (y/n)"
    read -p "请输入选择 [y/n] (默认n): " TG_CHOICE
    TG_TOKEN=""
    CHAT_ID=""
    AGENT_PORT="9527"
    if [[ "$TG_CHOICE" =~ ^[Yy]$ ]]; then
        echo -e "\n\033[33m💡 提示：您可以选择使用自己的机器人，或者直接回车使用官方公共机器人。\033[0m"
        echo -e "\033[33m⚠️  注意：若使用官方机器人，请务必先在 TG 中关注 @OmniBeacon_bot 并发送 /start\033[0m"
        
        read -p "请输入您的 Telegram Bot Token (回车使用官方默认): " USER_TOKEN
        
        if [ -z "$USER_TOKEN" ]; then
            TG_TOKEN="OFFICIAL_GATEWAY_MODE" 
            TG_API_URL="https://omni-gateway.samanthaestime296.workers.dev" 
            echo -e "\033[32m✅ 已自动连接官方安全网关 (@OmniBeacon_bot)。\033[0m"
            echo -e "\033[33m👉 请确保您已关注官方机器人并发送过 /start，否则将无法接收消息。\033[0m"
        else
            TG_TOKEN="$USER_TOKEN"
            TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
            echo -e "\033[32m✅ 已记录您的私有机器人 Token。\033[0m"
        fi

        echo -e "\033[33m💡 提示：如果您不知道自己的 Chat ID，可以关注 @userinfobot 获取。\033[0m"
        read -p "请输入你的 Chat ID (与主控一致): " CHAT_ID
        
        # ================== [v3.0.3 变更: 智能随机高位端口生成系统] ==================
        echo -e "\n\033[36m[4.2/7] 正在构建 Webhook 安全通信隧道...\033[0m"
        echo -n "🎲 正在探测可用随机端口..."
        while true; do
            RANDOM_PORT=$((RANDOM % 55536 + 10000))
            # 同时兼容 ss (新) 和 netstat (旧) 检查端口占用
            if ! (ss -tuln 2>/dev/null | grep -q ":$RANDOM_PORT " || netstat -tuln 2>/dev/null | grep -q ":$RANDOM_PORT "); then
                break
            fi
            echo -n "."
        done
        echo -e " 完成！"
        
        echo -e "💡 系统为您生成的推荐随机高位端口为: \033[32m$RANDOM_PORT\033[0m"
        echo -e "\033[33m(该端口已通过本地占用校验，可直接使用)\033[0m"
        
        while true; do
            read -p "请输入 Webhook 监听端口 (回车采用推荐, 或手动输入): " INPUT_PORT
            
            if [ -z "$INPUT_PORT" ]; then
                AGENT_PORT="$RANDOM_PORT"
                break
            else
                # 校验手动输入的合法性与可用性
                if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
                    if (ss -tuln 2>/dev/null | grep -q ":$INPUT_PORT " || netstat -tuln 2>/dev/null | grep -q ":$INPUT_PORT "); then
                        echo -e "\033[31m❌ 端口 $INPUT_PORT 已被占用，请重新输入或使用推荐端口。\033[0m"
                    else
                        AGENT_PORT="$INPUT_PORT"
                        break
                    fi
                else
                    echo -e "\033[31m❌ 输入非法！端口范围应为 1-65535。\033[0m"
                fi
            fi
        done
        echo -e "✅ 已锁定 Webhook 通讯端口: \033[32m$AGENT_PORT\033[0m"
        # ====================================================================
    fi

    # ================== [v3.0.1新增修改 1: 冗余网络栈探测与锚点锁定] ==================
    echo -e "\n\033[36m[4.5/7] 正在探测本机网络栈与可用出口 (多节点雷达扫描中)...\033[0m"

    # 引入容灾机制：依次尝试三个不同的 API，拿到有效的 IP 格式就停止
    DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me || curl -4 -s -m 3 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
    DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

    # 构建动态选项数组
    IP_OPTIONS=()
    IP_PROTO=()

    [[ -n "$DETECT_V4" ]] && { IP_OPTIONS+=("$DETECT_V4"); IP_PROTO+=("4"); }
    [[ -n "$DETECT_V6" ]] && { IP_OPTIONS+=("$DETECT_V6"); IP_PROTO+=("6"); }

    if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
        echo -e "\033[33m⚠️ 雷达受阻：未能自动探测到公网 IP，请手动指定。\033[0m"
        read -p "请输入您要绑定的公网 IP (v4 或 v6): " PUBLIC_IP
        [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
    else
        echo "📍 发现可用出口 IP，请选择要注册与养护的锚点:"
        for i in "${!IP_OPTIONS[@]}"; do
            num=$((i+1))
            if [ "${IP_PROTO[$i]}" == "4" ]; then
                echo "  $num) 🌐 IPv4: ${IP_OPTIONS[$i]} (默认选项)"
            else
                echo "  $num) 🌌 IPv6: ${IP_OPTIONS[$i]}"
            fi
        done
        CUSTOM_OPT=$(( ${#IP_OPTIONS[@]} + 1 ))
        echo "  $CUSTOM_OPT) ✍️ 手动指定其他 IP (适合多 IP 站群机)"
        
        read -p "请输入选择 (默认1): " IP_CHOICE
        IP_CHOICE=${IP_CHOICE:-1}
        
        if [ "$IP_CHOICE" -le "${#IP_OPTIONS[@]}" ] && [ "$IP_CHOICE" -gt 0 ]; then
            idx=$((IP_CHOICE-1))
            PUBLIC_IP="${IP_OPTIONS[$idx]}"
            IP_PREF="${IP_PROTO[$idx]}"
        elif [ "$IP_CHOICE" -eq "$CUSTOM_OPT" ]; then
            read -p "请输入您要绑定的公网 IP (v4 或 v6): " PUBLIC_IP
            [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
        else
            # 兜底：乱输就默认选第一个
            PUBLIC_IP="${IP_OPTIONS[0]}"
            IP_PREF="${IP_PROTO[0]}"
        fi
    fi

    # ================== [v3.3.1 核心重构: 身份剥离与双栈实弹嗅探] ==================
    # 1. 固化对外通讯身份 (自动穿透方括号护甲)
    if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
        SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
    else
        SAFE_PUBLIC_IP="$PUBLIC_IP"
    fi

    # 2. 实弹打靶测试 (NAT 环境嗅探与双栈自适应)
    echo -n "🕵️ 正在进行出站链路试射 (NAT环境与双栈嗅探)..."
    RAW_TEST_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
    
    # 智能切换靶机：V6 机器打 Cloudflare V6 节点，V4 机器打 1.1.1.1
    if [[ "$RAW_TEST_IP" == *":"* ]]; then
        TEST_TARGET="https://[2606:4700:4700::1111]"
    else
        TEST_TARGET="https://1.1.1.1"
    fi
    
    # 执行实弹试射
    if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
        echo -e " \033[32m✅ 原生直连，物理网卡死锁已激活。\033[0m"
        BIND_IP="$SAFE_PUBLIC_IP"
    else
        echo -e " \033[33m⚠️ 发现 NAT/虚拟路由架构，自动卸除网卡枷锁，交由内核路由。\033[0m"
        BIND_IP=""
    fi
    echo -e "\033[32m✅ 哨兵对外联络点已永久锁定至: $SAFE_PUBLIC_IP\033[0m"
    # ========================================================================

    # ================== [v3.5.2 新增: 节点不可变主键与展示别名] ==================
    IP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | cut -c 1-10)-${IP_HASH}"
    NODE_ALIAS="$NODE_NAME"

    if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
        echo -e "\n\033[36m[4.8/7] 节点展示别名设定 (用于面板友好显示)...\033[0m"
        echo -e "💡 系统底层的不可变主键为: \033[33m${NODE_NAME}\033[0m"
        read -p "请输入节点展示别名 (如'纽约机房', 回车使用默认): " CUSTOM_ALIAS

        if [ -n "$CUSTOM_ALIAS" ]; then
            # 🛡️ 强制字符清洗：防御 Shell 注入，并限制长度防刷屏
            NODE_ALIAS=$(echo "$CUSTOM_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r' | cut -c 1-20)
            [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
        fi
        echo -e "✅ 已锁定节点展示别名: \033[32m$NODE_ALIAS\033[0m"
    fi
    # ========================================================================

    # 5. 远程拉取冷数据并解析固化
    echo -e "\n[5/7] 正在从云端数据仓库拉取 [${CITY_NAME}] 节点的底层规则..."
    REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
    curl -sL "${REPO_RAW_URL}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" -o "$REGION_JSON_FILE"

    if [ ! -s "$REGION_JSON_FILE" ]; then
        echo "❌ 拉取或解析规则失败！请检查 Forgejo 仓库是否公开或网络是否畅通。"
        exit 1
    fi

    # 使用 jq 提取 JSON 里的核心值
    REGION_NAME=$(jq -r '.region_name' "$REGION_JSON_FILE")
    BASE_LAT=$(jq -r '.google_module.base_lat' "$REGION_JSON_FILE")
    BASE_LON=$(jq -r '.google_module.base_lon' "$REGION_JSON_FILE")
    LANG_PARAMS=$(jq -r '.google_module.lang_params' "$REGION_JSON_FILE")
    VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix' "$REGION_JSON_FILE")

    # 写入本地静态配置文件 (v3.4.0 引入版本锚点)
    cat > "$CONFIG_FILE" << EOF
# IP-Sentinel 本地固化配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
AGENT_VERSION="$TARGET_VERSION"
REGION_CODE="$REGION_CODE"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

# 模块开关状态
ENABLE_GOOGLE="$ENABLE_GOOGLE"
ENABLE_TRUST="$ENABLE_TRUST"

TG_TOKEN="$TG_TOKEN"
TG_API_URL="$TG_API_URL"
CHAT_ID="$CHAT_ID"
AGENT_PORT="$AGENT_PORT"
INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# [v3.3.1修改: 双核身份剥离配置] 
IP_PREF="$IP_PREF"
PUBLIC_IP="$SAFE_PUBLIC_IP"
BIND_IP="$BIND_IP"

# [v3.5.2新增: 双轨身份系统]
NODE_NAME="$NODE_NAME"
NODE_ALIAS="$NODE_ALIAS"
EOF

    # ================== [v3.0.3 变更: 敏感配置文件权限收敛] ==================
    chmod 600 "$CONFIG_FILE"
    # ====================================================================

fi
# 🛑 拦截块结束 (全套交互配置跳过完毕)

# ================== [v3.3.1 核心修复: 老节点配置无损热迁移] ==================
if [ "$UPGRADE_MODE" == "true" ]; then
    if ! grep -q "PUBLIC_IP=" "$CONFIG_FILE"; then
        echo -e "\n🔄 [平滑迁移] 正在对老节点进行 v3.3.1 双核身份架构升级..."
        
        # 重新抓取公网面孔 (应对老节点 BIND_IP 可能已被手动清空的情况)
        MIGRATE_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')
        [[ "$MIGRATE_IP" == *":"* ]] && [[ "$MIGRATE_IP" != *"["* ]] && MIGRATE_IP="[${MIGRATE_IP}]"
        
        echo -n "🕵️ 正在进行补发链路试射 (NAT与双栈嗅探)..."
        RAW_TEST_IP=$(echo "$MIGRATE_IP" | tr -d '[]')
        if [[ "$RAW_TEST_IP" == *":"* ]]; then
            TEST_TARGET="https://[2606:4700:4700::1111]"
        else
            TEST_TARGET="https://1.1.1.1"
        fi
        
        if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
            echo -e " \033[32m✅ 原生直连，网卡死锁已继承。\033[0m"
            NEW_BIND_IP="$MIGRATE_IP"
        else
            echo -e " \033[33m⚠️ 发现 NAT 架构，已自动卸除老版本的物理枷锁。\033[0m"
            NEW_BIND_IP=""
        fi
        
        # 动态修改旧配置文件 (更新 BIND_IP，追加 PUBLIC_IP)
        sed -i "s/^BIND_IP=.*/BIND_IP=\"$NEW_BIND_IP\"/" "$CONFIG_FILE"
        echo "PUBLIC_IP=\"$MIGRATE_IP\"" >> "$CONFIG_FILE"
        
        # 刷新当前安装脚本的环境变量，防止底部代码报错
        SAFE_PUBLIC_IP="$MIGRATE_IP"
        BIND_IP="$NEW_BIND_IP"
    else
        # 如果是未来再升级，配置文件已是最新，直接提取变量供安装脚本尾部使用
        SAFE_PUBLIC_IP=$(grep "^PUBLIC_IP=" "$CONFIG_FILE" | cut -d'"' -f2)
    fi

    # [v3.5.2 热修复] 兼容老版本没有 NODE_NAME 和 NODE_ALIAS 的情况，无损补齐
    if ! grep -q "^NODE_NAME=" "$CONFIG_FILE"; then
        TMP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
        NODE_NAME="$(hostname | cut -c 1-10)-${TMP_HASH}"
        NODE_ALIAS="$NODE_NAME"
        echo "NODE_NAME=\"$NODE_NAME\"" >> "$CONFIG_FILE"
        echo "NODE_ALIAS=\"$NODE_ALIAS\"" >> "$CONFIG_FILE"
    else
        NODE_NAME=$(grep "^NODE_NAME=" "$CONFIG_FILE" | cut -d'"' -f2)
        NODE_ALIAS=$(grep "^NODE_ALIAS=" "$CONFIG_FILE" | cut -d'"' -f2)
        if [ -z "$NODE_ALIAS" ]; then
            NODE_ALIAS="$NODE_NAME"
            echo "NODE_ALIAS=\"$NODE_ALIAS\"" >> "$CONFIG_FILE"
        fi
    fi
fi
# ========================================================================

# 6. 拉取全套组件 (按需下载，绝不浪费空间)
echo -e "\n[6/7] 正在根据模块开关部署核心引擎与热数据..."
# 确保目录在升级模式下也能被正确建立
mkdir -p "${INSTALL_DIR}/core"
mkdir -p "${INSTALL_DIR}/data/keywords"

# 基础公共组件
curl -sL "${REPO_RAW_URL}/core/runner.sh" -o "${INSTALL_DIR}/core/runner.sh"
curl -sL "${REPO_RAW_URL}/core/updater.sh" -o "${INSTALL_DIR}/core/updater.sh"
curl -sL "${REPO_RAW_URL}/core/tg_report.sh" -o "${INSTALL_DIR}/core/tg_report.sh"
curl -sL "${REPO_RAW_URL}/core/agent_daemon.sh" -o "${INSTALL_DIR}/core/agent_daemon.sh"
curl -sL "${REPO_RAW_URL}/core/uninstall.sh" -o "${INSTALL_DIR}/core/uninstall.sh"
curl -sL "${REPO_RAW_URL}/data/user_agents.txt" -o "${INSTALL_DIR}/data/user_agents.txt"

# 动态按需组件
if [ "$ENABLE_GOOGLE" == "true" ]; then
    curl -sL "${REPO_RAW_URL}/core/mod_google.sh" -o "${INSTALL_DIR}/core/mod_google.sh"
    # [v3.2.2 修复] 动态匹配词库下载逻辑
    if [ "$UPGRADE_MODE" == "false" ]; then
        curl -sL "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}" -o "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
    else
        # 升级模式：利用已有的 REGION_CODE 更新通用词库
        curl -sL "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt" 2>/dev/null || true
    fi
fi

if [ "$ENABLE_TRUST" == "true" ]; then
    curl -sL "${REPO_RAW_URL}/core/mod_trust.sh" -o "${INSTALL_DIR}/core/mod_trust.sh"
fi

chmod +x ${INSTALL_DIR}/core/*.sh

# 7. 配置系统定时任务 (高频调度与看门狗)
echo -e "\n[7/7] 正在注入系统定时任务与看门狗进程..."
crontab -l 2>/dev/null | grep -v "ip_sentinel" > /tmp/cron_backup

# 核心养护模块: 每 30 分钟触发一次
echo "*/30 * * * * ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1" >> /tmp/cron_backup
# 养料更新模块: (v3.3.0升级) 每天凌晨 3 点触发，由中枢自动进行分频调度
echo "0 3 * * * ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> /tmp/cron_backup

# [v3.3.0 新增] 初始化 UA 指纹库更新时间戳，确立 30 天滚动周期的计算锚点
echo $(date +%s) > "${INSTALL_DIR}/core/.ua_last_update"

# 如果配置了联控，启动 Webhook 与战报任务
if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
    # 每天早上 8 点发送昨天的统计战报
    echo "0 8 * * * ${INSTALL_DIR}/core/tg_report.sh >/dev/null 2>&1" >> /tmp/cron_backup
    
    # [v3.0.1新增修改 3: 删除原来的 curl 取 IP，直接使用我们上方锁定的 BIND_IP]
    # 并提前写入 IP 缓存，彻底阻断 agent_daemon 首次启动时的重复推送
    # [修复竞态]: 提前写入公网 IP 缓存，彻底阻断 agent_daemon 首次启动时的抢跑推送
    echo "$SAFE_PUBLIC_IP" > "${INSTALL_DIR}/core/.last_ip"
    
    # 双保险守护进程看门狗
    echo "@reboot nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> /tmp/cron_backup
    echo "* * * * * nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> /tmp/cron_backup
    
    # 安装时立刻启动一次边缘守护进程
    nohup bash "${INSTALL_DIR}/core/agent_daemon.sh" >/dev/null 2>&1 &
fi

crontab /tmp/cron_backup
rm -f /tmp/cron_backup

# ================== [v3.4.0 核心: 状态机驱动的热更新路由] ==================
if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
    
    # [v3.5.2 核心] 发送携带双轨身份的注册指令 (追加 NODE_ALIAS 作为第 6 个字段)
    REG_MSG="#REGISTER#|${REGION_CODE}|${NODE_NAME}|${SAFE_PUBLIC_IP}|${AGENT_PORT}|${NODE_ALIAS}"
    
    if [ "$UPGRADE_MODE" == "true" ]; then
        # 读取本地老版本号，如果没有则视为远古版本 v3.3.1
        OLD_VERSION=$(grep "^AGENT_VERSION=" "$CONFIG_FILE" | cut -d'"' -f2)
        [ -z "$OLD_VERSION" ] && OLD_VERSION="3.3.1"
        
        # [路由表 1]: 跨代兼容 (老版本 < v3.3.2)
        # 必须强制下发带有 #REGISTER# 的警告，引导长官重新同步哈希身份
        if version_lt "$OLD_VERSION" "3.3.2"; then
            echo -e "\n📡 [路由枢纽] 正在执行跨代架构重组 (v${OLD_VERSION} -> v${TARGET_VERSION})..."
            curl -s -X POST "${TG_API_URL}" \
                -d "chat_id=${CHAT_ID}" \
                -d "parse_mode=Markdown" \
                -d "text=✨ *IP-Sentinel 引擎热更新完成！*
📍 节点：\`${NODE_ALIAS}\`
🌐 IP：\`${SAFE_PUBLIC_IP}\`
🚀 状态：v${TARGET_VERSION} OTA 动态活体引擎已部署

⚠️ *战区架构已重组，请务必点击下方指令并发送，以同步新的防撞档案：*
\`${REG_MSG}\`" >/dev/null 2>&1
            echo -e "\033[32m✅ 升级通知已推送！请前往 TG 点击注册指令完成身份同步！\033[0m"
            
        # [路由表 2]: 现代静默升级 (老版本 >= v3.3.2)
        else
            echo -e "\n📡 [路由枢纽] 正在执行静默平滑升级 (v${OLD_VERSION} -> v${TARGET_VERSION})..."
            curl -s -X POST "${TG_API_URL}" \
                -d "chat_id=${CHAT_ID}" \
                -d "parse_mode=Markdown" \
                -d "text=✨ *IP-Sentinel 引擎热更新完成！*
📍 节点：\`${NODE_ALIAS}\`
🌐 IP：\`${SAFE_PUBLIC_IP}\`
🚀 状态：v${TARGET_VERSION} OTA 动态活体引擎已部署" >/dev/null 2>&1
            echo -e "\033[32m✅ 升级成功通知已推送到您的 Telegram！\033[0m"
        fi
        
        # [清理遗留垃圾并刷新版本号]
        sed -i '/^NAME_HASHED=/d' "$CONFIG_FILE" 2>/dev/null # 抹除上个版本的临时基因锁
        if grep -q "^AGENT_VERSION=" "$CONFIG_FILE"; then
            sed -i "s/^AGENT_VERSION=.*/AGENT_VERSION=\"$TARGET_VERSION\"/" "$CONFIG_FILE"
        else
            echo "AGENT_VERSION=\"$TARGET_VERSION\"" >> "$CONFIG_FILE"
        fi
        
    else
        # [全新安装路由]
        echo -e "\n📡 正在向指挥部发送注册暗号..."
        PUSH_RESULT=$(curl -s -X POST "${TG_API_URL}" \
            -d "chat_id=${CHAT_ID}" \
            -d "parse_mode=Markdown" \
            -d "text=✨ *IP-Sentinel 部署成功！*
📍 区域：${REGION_NAME}
🌐 IP：${SAFE_PUBLIC_IP}
🔌 端口：${AGENT_PORT}

🔑 *请点击下方指令复制并回复给机器人：*
\`${REG_MSG}\`")

        if echo "$PUSH_RESULT" | grep -q '"ok":true'; then
            echo -e "\033[32m✅ 注册信息已推送到您的 Telegram，请按指令完成最终激活！\033[0m"
        else
            echo -e "\033[31m❌ 消息推送失败，请检查 Chat ID 是否正确或是否已关注机器人。\033[0m"
        fi
    fi
fi
# =========================================================================

echo "========================================================"
if [ "$UPGRADE_MODE" == "true" ]; then
    echo "🎉 边缘节点 (Agent) 平滑热更新已彻底完成！"
else
    echo "🎉 边缘节点 (Agent) 部署流程彻底完成！"
fi
echo "📍 你的本地守护区域已锁定为: $REGION_NAME"
echo "⚙️ 哨兵现已开启 [每30分钟] 的高频高拟真养护循环。"
if [[ -n "$TG_TOKEN" ]]; then
    echo "📡 Webhook 监听已启动 (端口: $AGENT_PORT) 并向中枢发送了注册请求。"
    
    # ================== [v3.0.3 变更: 智能防火墙检测与放行指引] ==================
    FW_MSG=""
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw active; then
        FW_MSG="ufw allow $AGENT_PORT/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld | grep -qw active; then
        FW_MSG="firewall-cmd --zone=public --add-port=$AGENT_PORT/tcp --permanent && firewall-cmd --reload"
    elif command -v iptables >/dev/null 2>&1; then
        # 智能双栈雷达：根据对外公网 IP 属性，动态下发对应的防火墙放行指令
        if [[ "$SAFE_PUBLIC_IP" == *":"* ]]; then
            FW_MSG="ip6tables -I INPUT -p tcp --dport $AGENT_PORT -j ACCEPT"
        else
            FW_MSG="iptables -I INPUT -p tcp --dport $AGENT_PORT -j ACCEPT"
        fi
    fi
    
    echo -e "\033[33m⚠️ 警告：请务必确保本机及云服务商安全组放行了 TCP $AGENT_PORT 端口！\033[0m"
    if [ -n "$FW_MSG" ]; then
        echo "💡 检测到本地防火墙开启，您可以尝试执行以下命令放行："
        echo -e "\033[36m   $FW_MSG\033[0m"
    fi
    # ====================================================================
fi
echo "🗑️ 若未来需卸载，可重新运行本脚本选择[2]或执行: bash ${INSTALL_DIR}/core/uninstall.sh"
echo "========================================================"

# ================== [v3.1.2 新增: 玻璃房透明装机统计] ==================
echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
AGENT_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/agent" || echo "")

if [ -n "$AGENT_COUNT" ] && [[ "$AGENT_COUNT" =~ ^[0-9]+$ ]]; then
    echo -e "\033[32m✅ 感谢您成为全球第 ${AGENT_COUNT} 名 IP-Sentinel 哨兵！\033[0m"
else
    echo -e "\033[32m✅ 感谢您加入 IP-Sentinel 哨兵阵列！\033[0m"
fi
echo -e "\n"