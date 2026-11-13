#!/bin/bash

# ==========================================================
# 脚本名称: install.sh
# 核心功能: 动态环境解析、无感原子交接、防砖部署、沙盒隔离
# ==========================================================

# ==========================================================
# [权限鉴权] 严格防范低权限执行导致的组件缺失
# ==========================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

# [沙盒机制] 创建含高强度熵值的安全挂载点，并在异常断开时确保物理覆写销毁
SECURE_TMP=$(mktemp -d /tmp/ips_install.XXXXXX)
trap 'rm -rf "$SECURE_TMP"' EXIT HUP INT QUIT TERM

# ==========================================================
# [环境侦测] 靶机架构预检与调度器降级决策
# ==========================================================
is_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    return 0
}

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        uname -srm
    fi
}

get_virt_info() {
    if grep -qaE 'docker|containerd|podman' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        echo "Docker/OCI Container"
    elif grep -qa container=lxc /proc/1/environ 2>/dev/null || [ -d /proc/vz ]; then
        echo "LXC/OpenVZ"
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt
    else
        echo "Unknown/Bare Metal"
    fi
}

echo -e "\n======================================"
echo -e "📊 \033[36mIP-Sentinel 靶机环境侦测预检\033[0m"
echo -e "--------------------------------------"
echo -e "OS 架构   : $(get_os_info)"
echo -e "虚拟化    : $(get_virt_info)"
if is_systemd; then
    echo -e "Init 系统 : systemd ✅"
else
    echo -e "Init 系统 : 非 systemd ⚠️ (将自动降维至守护循环)"
fi
echo -e "======================================\n"
sleep 1

REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# [网络容灾] 挂载双栈并利用防抖重试护甲，从远端解析运行态版本约束
TARGET_VERSION=$( (curl -fsSL --connect-timeout 5 --retry 2 "${REPO_RAW_URL}/version.txt" || curl -4 -fsSL --connect-timeout 5 --retry 2 "${REPO_RAW_URL}/version.txt") 2>/dev/null | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
TARGET_VERSION=${TARGET_VERSION:-"4.1.1"}

version_lt() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" && test "$1" != "$2"
}

# ==========================================================
# [依赖装甲] 多分支包管理器嗅探与极简系统补全
# ==========================================================
echo -e "\n[1/7] 正在探测并安装基础环境依赖 (curl, jq, cron, procps, python3)..."
REQUIRED_CMDS=("curl" "jq" "crontab" "pgrep" "python3" "openssl")
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo "⏳ 发现缺失依赖: ${MISSING_CMDS[*]}，正在尝试自动补齐..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y --no-install-recommends curl jq cron procps python3 openssl >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1
        
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
        PKG_MGR="yum"
        OPT_ARGS=""
        if command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
            OPT_ARGS="--setopt=install_weak_deps=False"
        elif command -v microdnf >/dev/null 2>&1; then
            PKG_MGR="microdnf"
        fi
        
        echo -e "\033[90m   (正在安装 epel-release 扩展源，请稍候...)\033[0m"
        $PKG_MGR install -y epel-release >/dev/null 2>&1 || true
        
        echo -e "\033[90m   (正在拉取核心组件...)\033[0m"
        $PKG_MGR install -y $OPT_ARGS curl jq cronie procps-ng python3 openssl
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1
        
    elif command -v apk >/dev/null 2>&1; then
        echo "Alpine 探测到系统类型为 Alpine Linux，正在执行轻量级安装..."
        apk add --no-cache curl jq cronie procps python3 bash openssl || apk add --no-cache curl jq procps python3 bash openssl
        mkdir -p /var/spool/cron/crontabs
        rc-update add crond default >/dev/null 2>&1
        service crond start >/dev/null 2>&1
        
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm curl jq cronie procps-ng python openssl >/dev/null 2>&1
        mkdir -p /root/.cache/crontab 2>/dev/null
        systemctl enable cronie >/dev/null 2>&1 && systemctl start cronie >/dev/null 2>&1
        
    else
        echo -e "\033[31m❌ 自动安装失败：系统未知的包管理器。\033[0m"
        echo -e "\033[33m⚠️ 请根据您的操作系统，手动执行以下安装命令后重新运行本脚本：\033[0m"
        echo -e "  Debian/Ubuntu: \033[36mapt-get update && apt-get install -y --no-install-recommends curl jq cron procps python3 openssl\033[0m"
        echo -e "  CentOS/RHEL:   \033[36myum install -y curl jq cronie procps-ng python3 openssl\033[0m"
        echo -e "  Alpine Linux:  \033[36mapk add --no-cache curl jq cronie procps python3 bash openssl\033[0m"
        echo -e "  Arch Linux:    \033[36mpacman -Syu --needed curl jq cronie procps-ng python openssl\033[0m"
        exit 1
    fi
    
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "\033[31m❌ 致命错误：核心命令 '$cmd' 仍未找到！\033[0m"
            echo -e "这通常是因为您的系统源配置错误或缺失基础组件库导致。"
            echo -e "请手动修复您的包管理器源，或联系 VPS 供应商重新格式化系统。"
            exit 1
        fi
    done
fi
echo -e "\033[32m✅ 基础环境检测通过。\033[0m"

# ----------------------------------------------------------
# [交互中枢] LBS 地理图谱树预载
# ----------------------------------------------------------
echo -e "\n[2/7] 正在连线云端，拉取全球节点地图..."
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/map.json" -o "${SECURE_TMP}/map.json"
if [ ! -s "${SECURE_TMP}/map.json" ]; then
    echo -e "\033[31m❌ 拉取全球地图失败！请检查网络或 GitHub 仓库地址。\033[0m"
    exit 1
fi

# [自动化架构] 拦截交互菜单，接受云端重载指令直接执行 OTA
if [ "$SILENT_OTA" == "true" ]; then
    echo -e "\n⏳ [OTA] 静默升级指令已确认，正在剥离控制台交互..."
    ACTION_CHOICE=1
    UPGRADE_MODE="true"
    KEEP_LOGS="true"
    source "$CONFIG_FILE"
else
    echo -e "\n请选择操作:"
    echo "  1) 🚀 部署边缘节点 (进入全球节点配置)"
    echo "  2) 🗑️ 一键卸载 IP-Sentinel"
    echo "  3) 📡 重新发送注册指令"
    read -p "请输入选择 [1-3] (默认1): " ACTION_CHOICE

    ACTION_CHOICE=${ACTION_CHOICE:-1}

    if [ "$ACTION_CHOICE" == "2" ]; then
        echo -e "\n⏳ 正在拉取卸载程序..."
        curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/uninstall.sh" -o "${SECURE_TMP}/ip_uninstall.sh"
        chmod +x "${SECURE_TMP}/ip_uninstall.sh"
        bash "${SECURE_TMP}/ip_uninstall.sh"
        rm -f "${SECURE_TMP}/ip_uninstall.sh"
        exit 0
    fi

    # [重新注册] 读取已有配置，重新组装并推送注册指令
    if [ "$ACTION_CHOICE" == "3" ]; then
        echo -e "\n📡 [重新注册] 正在读取本地配置..."

        if [ ! -f "$CONFIG_FILE" ]; then
            echo -e "\033[31m❌ 未检测到配置文件 (${CONFIG_FILE})，无法执行重新注册。\033[0m"
            echo -e "💡 请先完成一次正常部署后再使用此功能。"
            exit 1
        fi

        source "$CONFIG_FILE"

        # 校验关键字段
        MISSING_FIELDS=()
        [ -z "$TG_TOKEN" ] && MISSING_FIELDS+=("TG_TOKEN")
        [ -z "$CHAT_ID" ] && MISSING_FIELDS+=("CHAT_ID")
        [ -z "$NODE_NAME" ] && MISSING_FIELDS+=("NODE_NAME")
        [ -z "$COMM_IP" ] && MISSING_FIELDS+=("COMM_IP")
        [ -z "$AGENT_PORT" ] && MISSING_FIELDS+=("AGENT_PORT")

        if [ ${#MISSING_FIELDS[@]} -gt 0 ]; then
            echo -e "\033[31m❌ 配置不完整，缺少字段: ${MISSING_FIELDS[*]}\033[0m"
            echo -e "💡 配置文件可能已损坏，请重新部署。"
            exit 1
        fi

        # 补齐可能缺失的字段
        NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"
        ENABLE_OTA="${ENABLE_OTA:-false}"
        REGION_CODE="${REGION_CODE:-unknown}"

        echo -e "📋 当前配置信息:"
        echo -e "   节点名称 : ${NODE_NAME}"
        echo -e "   节点别名 : ${NODE_ALIAS}"
        echo -e "   通讯弹匣 : ${COMM_IP}"
        echo -e "   监听端口 : ${AGENT_PORT}"
        echo -e "   OTA权限  : ${ENABLE_OTA}"

        # 重新探测当前公网IP，对比COMM_IP
        echo -e "\n🕵️ 正在探测当前公网出口..."
        RAW_CUR_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
        RAW_CUR_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

        # 过滤WARP等异常出口
        V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_CUR_V4" =~ ^104\.28\. ]]; then
            RAW_CUR_V4=""
        fi

        V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]]; then
            RAW_CUR_V6=""
        fi

        # 组装新的通讯弹匣
        NEW_COMM_IP=""
        if [ -n "$RAW_CUR_V4" ]; then
            NEW_COMM_IP="$RAW_CUR_V4"
        fi
        if [ -n "$RAW_CUR_V6" ]; then
            SAFE_CUR_V6="${RAW_CUR_V6}"
            [[ "$SAFE_CUR_V6" != *"["* ]] && SAFE_CUR_V6="[${SAFE_CUR_V6}]"
            if [ -z "$NEW_COMM_IP" ]; then
                NEW_COMM_IP="$SAFE_CUR_V6"
            else
                NEW_COMM_IP="${NEW_COMM_IP}_${SAFE_CUR_V6}"
            fi
        fi

        # 对比IP是否变化
        if [ -n "$NEW_COMM_IP" ] && [ "$NEW_COMM_IP" != "$COMM_IP" ]; then
            echo -e "\033[33m⚠️ 检测到通讯IP已变更！\033[0m"
            echo -e "   旧弹匣 : ${COMM_IP}"
            echo -e "   新弹匣 : ${NEW_COMM_IP}"
            read -p "👉 是否使用新的通讯弹匣重新注册？(y/n, 默认y): " IP_CHANGE_CHOICE
            if [[ "$IP_CHANGE_CHOICE" =~ ^[Nn]$ ]]; then
                echo -e "🔄 已保留原通讯弹匣: ${COMM_IP}"
            else
                COMM_IP="$NEW_COMM_IP"
                echo -e "\033[32m✅ 已更新通讯弹匣: ${COMM_IP}\033[0m"
            fi
        elif [ -z "$NEW_COMM_IP" ]; then
            echo -e "\033[33m⚠️ 未能自动探测到公网IP，将使用配置中的通讯弹匣: ${COMM_IP}\033[0m"
        else
            echo -e "\033[32m✅ 通讯IP未变化，继续使用: ${COMM_IP}\033[0m"
        fi

        # 组装注册指令
        REG_MSG="#REGISTER#|${REGION_CODE}|${NODE_NAME}|${COMM_IP}|${AGENT_PORT}|${NODE_ALIAS}|${ENABLE_OTA}"

        echo -e "\n📤 正在向 Telegram 推送注册指令..."
        TEXT_MSG="✨ *IP-Sentinel 重新发送注册指令！*
📍 节点：\`${NODE_ALIAS}\`
🌐 通讯弹匣：\`${COMM_IP}\`
🔌 端口：\`${AGENT_PORT}\`

🔑 *请点击下方指令复制并回复给机器人：*
\`${REG_MSG}\`"

        # 确定API URL
        if [ "$TG_TOKEN" == "OFFICIAL_GATEWAY_MODE" ]; then
            TG_API_URL="https://omni-gateway.samanthaestime296.workers.dev"
        else
            TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
        fi

        JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
        PUSH_RESULT=$(curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD")

        if echo "$PUSH_RESULT" | grep -q '"ok":true'; then
            echo -e "\033[32m✅ 注册指令已成功推送到您的 Telegram！\033[0m"
            echo -e "👉 请前往 Telegram 复制注册指令并回复给机器人完成重新注册。"
        else
            echo -e "\033[31m❌ 消息推送失败！\033[0m"
            echo -e "   响应: $(echo "$PUSH_RESULT" | head -c 200)"
            echo -e "\n💡 请检查:"
            echo -e "   1. Chat ID 是否正确"
            echo -e "   2. Bot Token 是否有效"
            echo -e "   3. 网络是否正常"
            exit 1
        fi

        echo -e "\n========================================================"
        echo -e "📡 重新注册指令发送完成！"
        echo -e "⚠️ 此操作未修改任何本地文件或运行中的服务。"
        echo -e "========================================================\n"
        exit 0
    fi

    # [态势传承] 平滑升级探测，防用户误删配置档案
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
            
            source "$CONFIG_FILE"
            echo -e "\033[32m✅ 已激活 [平滑升级模式]，即将跳过基础配置，直接更新核心装甲...\033[0m"
        else
            echo -e "\033[33m🔄 您选择了重新配置，旧的哨兵数据将被彻底抹除。\033[0m"
        fi
    fi
fi

# ==========================================================
# [物理清洗] 安装前的环境纯净度构建与幽灵进程抹除
# ==========================================================
echo -e "\n⏳ 正在清理系统定时任务中的旧版条目..."

crontab -l 2>/dev/null | grep -v "ip_sentinel" > "${SECURE_TMP}/cron_clean" || true
[ -f "${SECURE_TMP}/cron_clean" ] && crontab "${SECURE_TMP}/cron_clean" >/dev/null 2>&1
rm -f "${SECURE_TMP}/cron_clean"

for CRON_FILE in "/var/spool/cron/crontabs/root" "/etc/crontabs/root"; do
    if [ -f "$CRON_FILE" ]; then
        grep -v "ip_sentinel" "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
        cat "${CRON_FILE}.tmp" > "$CRON_FILE" 2>/dev/null || true
        rm -f "${CRON_FILE}.tmp" 2>/dev/null
    fi
done
rm -f /etc/local.d/ip_sentinel.start 2>/dev/null

if [ "$UPGRADE_MODE" == "true" ]; then
    # [v4.2.2 终极保障] 平滑升级时强制销毁旧版 TLS 证书与旧版 IP 缓存，逼迫下层组件重铸健康双栈装甲
    rm -f "${INSTALL_DIR}/core/cert.pem" "${INSTALL_DIR}/core/key.pem" "${INSTALL_DIR}/core/.last_ip" 2>/dev/null
    echo -e "🧹 历史底层缓存及残旧 TLS 证书已强制销毁，准备重铸安全装甲。"

    if [ "$KEEP_LOGS" == "false" ]; then
        rm -rf "${INSTALL_DIR}/logs" 2>/dev/null
        echo -e "🗑️ 历史战地日志已按指令清空。"
    else
        echo -e "📦 历史配置与战地日志已妥善保留。"
    fi
else
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "${INSTALL_DIR}/core" "${INSTALL_DIR}/data" "${INSTALL_DIR}/config.conf" "${INSTALL_DIR}/.last_ip" 2>/dev/null
    fi
fi
echo -e "\033[32m✅ 环境清理完毕，幽灵进程已肃清！\033[0m"

# ==========================================================
# [交互装配] 从云端拓扑树中摘取节点信息并构建关联
# ==========================================================
if [ "$UPGRADE_MODE" == "false" ]; then

    echo -e "\n\033[36m📍 【第零级】请选择目标战区 (Continent):\033[0m"
    jq -r '.continents[] | "\(.id)|\(.name)"' "${SECURE_TMP}/map.json" > "${SECURE_TMP}/continents.txt"
    i=1; CONT_MAP=()
    while IFS="|" read -r cont_id cont_name; do
        echo "  $i) $cont_name"
        CONT_MAP[$i]="$cont_id"
        ((i++))
    done < "${SECURE_TMP}/continents.txt"

    read -p "请输入选择 [1-$((i-1))] (默认1): " CONT_SEL
    CONT_SEL=${CONT_SEL:-1}
    CONT_ID="${CONT_MAP[$CONT_SEL]}"

    echo -e "\n\033[36m📍 【第一级】正在检索 [$CONT_ID] 战区下的国家/地区...\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | \"\(.id)|\(.name)|\(.keyword_file)\"" "${SECURE_TMP}/map.json" > "${SECURE_TMP}/countries.txt"
    i=1; COUNTRY_MAP=(); KEYWORD_MAP=()
    while IFS="|" read -r c_id c_name k_file; do
        echo "  $i) $c_name"
        COUNTRY_MAP[$i]="$c_id"
        KEYWORD_MAP[$i]="$k_file"
        ((i++))
    done < "${SECURE_TMP}/countries.txt"

    read -p "请输入选择 [1-$((i-1))] (默认1): " C_SEL
    C_SEL=${C_SEL:-1}
    COUNTRY_ID="${COUNTRY_MAP[$C_SEL]}"
    KEYWORD_FILE="${KEYWORD_MAP[$C_SEL]}"
    REGION_CODE="$COUNTRY_ID" 

    echo -e "\n\033[36m📍 【第二级】正在检索 [$COUNTRY_ID] 的行政区数据...\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | \"\(.id)|\(.name)\"" "${SECURE_TMP}/map.json" > "${SECURE_TMP}/states.txt"
    STATE_COUNT=$(wc -l < "${SECURE_TMP}/states.txt")

    if [ "$STATE_COUNT" -eq 1 ]; then
        IFS="|" read -r STATE_ID STATE_NAME < "${SECURE_TMP}/states.txt"
        echo -e "\033[32m💡 该国家下仅有单一配置 [$STATE_NAME]，已自动跃迁。\033[0m"
    else
        i=1; STATE_MAP=()
        while IFS="|" read -r s_id s_name; do
            echo "  $i) $s_name"
            STATE_MAP[$i]="$s_id"
            ((i++))
        done < "${SECURE_TMP}/states.txt"
        read -p "请输入选择 [1-$((i-1))] (默认1): " S_SEL
        S_SEL=${S_SEL:-1}
        STATE_ID="${STATE_MAP[$S_SEL]}"
    fi

    echo -e "\n\033[36m📍 【第三级】请锁定具体城市节点:\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | select(.id==\"$STATE_ID\") | .cities[] | \"\(.id)|\(.name)\"" "${SECURE_TMP}/map.json" > "${SECURE_TMP}/cities.txt"
    CITY_COUNT=$(wc -l < "${SECURE_TMP}/cities.txt")

    if [ "$CITY_COUNT" -eq 1 ]; then
        IFS="|" read -r CITY_ID CITY_NAME < "${SECURE_TMP}/cities.txt"
        echo -e "\033[32m💡 该区域下仅有单一城市 [$CITY_NAME]，已自动锁定。\033[0m"
    else
        i=1; CITY_MAP=(); CITY_NAME_MAP=()
        while IFS="|" read -r c_id c_name; do
            echo "  $i) $c_name"
            CITY_MAP[$i]="$c_id"
            CITY_NAME_MAP[$i]="$c_name"
            ((i++))
        done < "${SECURE_TMP}/cities.txt"
        read -p "请输入选择 [1-$((i-1))] (默认1): " CI_SEL
        CI_SEL=${CI_SEL:-1}
        CITY_ID="${CITY_MAP[$CI_SEL]}"
        CITY_NAME="${CITY_NAME_MAP[$CI_SEL]}"
    fi

    rm -f "${SECURE_TMP}/map.json" "${SECURE_TMP}/continents.txt" "${SECURE_TMP}/countries.txt" "${SECURE_TMP}/states.txt" "${SECURE_TMP}/cities.txt"

    mkdir -p "${INSTALL_DIR}/core"
    mkdir -p "${INSTALL_DIR}/data/keywords"
    mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
    mkdir -p "${INSTALL_DIR}/logs"

    echo -e "\n[3/7] 正在初始化养护模块 (默认全量部署，支持 TG 远程动态启停)..."
    ENABLE_GOOGLE="true"
    ENABLE_TRUST="true"

    echo -e "\n[4/7] 是否接入 Master 司令部进行远程联控？ (y/n)"
    read -p "请输入选择 [y/n] (默认n): " TG_CHOICE
    TG_TOKEN=""
    CHAT_ID=""
    AGENT_PORT="9527"
    if [[ "$TG_CHOICE" =~ ^[Yy]$ ]]; then
        echo -e "\n请选择中枢接入模式 (推荐私有部署，支持后续 OTA 远程静默升级):"
        echo "  1) 🛡️ 私有独立中枢 (需提供自建 Bot Token，推荐)"
        echo "  2) ☁️ 官方公共网关 (@OmniBeacon_bot，新手免配置)"
        read -p "请输入选择 [1-2] (默认1): " MASTER_TYPE
        MASTER_TYPE=${MASTER_TYPE:-1}
        
        if [ "$MASTER_TYPE" == "2" ]; then
            TG_TOKEN="OFFICIAL_GATEWAY_MODE" 
            TG_API_URL="https://omni-gateway.samanthaestime296.workers.dev" 
            ENABLE_OTA="false"
            echo -e "\033[32m✅ 已自动连接官方安全网关 (@OmniBeacon_bot)。\033[0m"
            echo -e "\033[33m👉 请确保您已在 TG 中关注官方机器人并发送过 /start，否则将无法接收消息。\033[0m"
            echo -e "\n\033[33m⚠️ 【安全熔断提示】\033[0m"
            echo -e "\033[33m由于您使用了官方公共网关，为防止潜在的滥用或供应链风险，本节点的 [OTA 远程升级] 权限已被系统底层强制禁用。\033[0m"
            echo -e "\033[33m💡 若未来需要启用 OTA，请自建私有中枢后重新部署本节点。\033[0m"
        else
            echo -e "\n\033[36m📘 私有 Bot 创建教程: \033[4m\033]8;;https://blog.iot-architect.com/engineering-practice/create-private-telegram-bot-via-botfather/\033\\👉 [点击此处直接在浏览器中打开]\033]8;;\033\\ 👈\033[0m"
            echo -e "\033[90m   (若您的终端较老不支持点击，请手动复制: https://blog.iot-architect.com/engineering-practice/create-private-telegram-bot-via-botfather/ )\033[0m"
            read -p "请输入您的私有 Telegram Bot Token: " RAW_TOKEN
            USER_TOKEN=$(echo "$RAW_TOKEN" | tr -cd 'a-zA-Z0-9_:-')
            while [ -z "$USER_TOKEN" ]; do
                read -p "⚠️ Token 不能为空或包含非法字符，请重新输入: " RAW_TOKEN
                USER_TOKEN=$(echo "$RAW_TOKEN" | tr -cd 'a-zA-Z0-9_:-')
            done
            
            TG_TOKEN="$USER_TOKEN"
            TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
            echo -e "\033[32m✅ 已记录您的私有机器人 Token。\033[0m"
            
            echo -e "\n\033[36m[4.1/7] OTA 远程静默升级授权\033[0m"
            echo -e "💡 开启后，您可以在 TG 面板一键将本节点热更新至最新版本。"
            read -p "是否允许本节点接收 OTA 升级指令？(y/n, 默认y): " OTA_CHOICE
            if [[ "$OTA_CHOICE" =~ ^[Nn]$ ]]; then
                ENABLE_OTA="false"
                echo -e "🛡️ \033[33m已关闭 OTA 权限，本节点未来将只能通过 SSH 手动升级。\033[0m"
            else
                ENABLE_OTA="true"
                echo -e "✅ \033[32m已开启 OTA 权限，核按钮已挂载至您的私有中枢。\033[0m"
            fi
        fi

        echo -e "\n\033[33m💡 提示：如果您不知道下方自己的 Chat ID 是什么，可以关注 @userinfobot 获取。\033[0m"
        echo -e "\033[36m📘 查看图文教程: \033[4m\033]8;;https://blog.iot-architect.com/engineering-practice/get-telegram-personal-id-via-userinfobot/\033\\👉 [点击此处直接在浏览器中打开]\033]8;;\033\\ 👈\033[0m"
        echo -e "\033[90m   (若您的终端较老不支持点击，请手动复制: https://blog.iot-architect.com/engineering-practice/get-telegram-personal-id-via-userinfobot/ )\033[0m"
        read -p "请输入你的 Chat ID (必须准确，否则无法联控): " RAW_CHAT_ID
        CHAT_ID=$(echo "$RAW_CHAT_ID" | tr -cd '0-9-')
        
        echo -e "\n\033[36m[4.2/7] 正在构建 Webhook 安全通信隧道...\033[0m"
        echo -n "🎲 正在探测可用随机端口..."
        while true; do
            RANDOM_PORT=$((RANDOM % 55536 + 10000))
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
    fi

    # ----------------------------------------------------------
    # [网络锚定] 冗余网络栈探测与多出口智能嗅探
    # ----------------------------------------------------------
    echo -e "\n\033[36m[4.5/7] 正在探测本机网络栈与可用出口 (多节点雷达扫描中)...\033[0m"

    RAW_DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me || curl -4 -s -m 3 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
    RAW_DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

    # [v4.2.2 源头防线] 引入工业级网卡追踪，双重过滤 WARP/TUN/NAT 等假公网环境
    DETECT_V4=""
    if [[ -n "$RAW_DETECT_V4" ]]; then
        V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || \
           [[ "$RAW_DETECT_V4" =~ ^104\.28\. ]] || \
           [[ "$RAW_DETECT_V4" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
            echo -e " \033[33m⚠️ 雷达警告: 发现异常 IPv4 出口 ($RAW_DETECT_V4) 经由虚拟网卡 ($V4_DEV)，已从通讯候选池中隔离。\033[0m"
        else
            DETECT_V4="$RAW_DETECT_V4"
        fi
    fi

    DETECT_V6=""
    if [[ -n "$RAW_DETECT_V6" ]]; then
        V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_DETECT_V6" =~ ^fe80:|^::1 ]]; then
            echo -e " \033[33m⚠️ 雷达警告: 发现异常 IPv6 出口 ($RAW_DETECT_V6) 经由虚拟网卡 ($V6_DEV)，已从通讯候选池中隔离。\033[0m"
        else
            DETECT_V6="$RAW_DETECT_V6"
        fi
    fi

    IP_OPTIONS=()
    IP_PROTO=()

    [[ -n "$DETECT_V4" ]] && { IP_OPTIONS+=("$DETECT_V4"); IP_PROTO+=("4"); }
    [[ -n "$DETECT_V6" ]] && { IP_OPTIONS+=("$DETECT_V6"); IP_PROTO+=("6"); }

    if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
        echo -e "\033[33m⚠️ 雷达受阻：未能自动探测到公网 IP，请手动指定。\033[0m"
        read -p "请输入您要绑定的公网 IP (v4 或 v6): " RAW_PUBLIC_IP
        PUBLIC_IP=$(echo "$RAW_PUBLIC_IP" | tr -cd 'a-fA-F0-9.:[]')
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
            PUBLIC_IP="${IP_OPTIONS[0]}"
            IP_PREF="${IP_PROTO[0]}"
        fi
    fi

    # [容灾防线] 为含冒号的 IPv6 数据自动装卸方括号护盾，保障下游组件识别不崩溃
    if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
        SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
    else
        SAFE_PUBLIC_IP="$PUBLIC_IP"
    fi

    # ==========================================================
    # [v4.2.2 终极架构] 智能主副容灾弹药装填 (Multi-IP Fallback)
    # 严格排序: 1.养护IP (SAFE_PUBLIC_IP) 2.可用IPv4 3.可用IPv6
    # ==========================================================
    echo -e "\n\033[36m[4.6/7] 正在装填通讯容灾防线 (Multi-IP Fallback)...\033[0m"
    COMM_IP="$SAFE_PUBLIC_IP"
    
    # 注入次发弹药 (可用 IPv4)
    if [[ -n "$DETECT_V4" ]] && [[ "$DETECT_V4" != "$PUBLIC_IP" ]]; then
        COMM_IP="${COMM_IP}_${DETECT_V4}"
    fi
    
    # 注入保底弹药 (可用 IPv6，带括号保护)
    if [[ -n "$DETECT_V6" ]] && [[ "$DETECT_V6" != "$PUBLIC_IP" ]]; then
        [[ "$DETECT_V6" != *"["* ]] && SAFE_V6="[${DETECT_V6}]" || SAFE_V6="$DETECT_V6"
        COMM_IP="${COMM_IP}_${SAFE_V6}"
    fi
    
    SAFE_COMM_IP="$COMM_IP"
    
    if [[ "$COMM_IP" == *"_"* ]]; then
        echo -e " \033[32m✅ 成功组装多宿主容灾通讯专线: $SAFE_COMM_IP\033[0m"
    else
        echo -e " \033[33m⚠️ 本机仅有单一出口，建立单轨通讯模式: $SAFE_COMM_IP\033[0m"
    fi

    echo -n "🕵️ 正在进行出站链路试射 (NAT环境与双栈嗅探)..."
    
    RAW_TEST_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
    
    if [[ "$RAW_TEST_IP" == *":"* ]]; then
        TEST_TARGET="https://[2606:4700:4700::1111]"
    else
        TEST_TARGET="https://1.1.1.1"
    fi
    
    if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
        echo -e " \033[32m✅ 原生直连，物理网卡死锁已激活。\033[0m"
        BIND_IP="$SAFE_PUBLIC_IP"
    else
        echo -e " \033[33m⚠️ 发现 NAT/虚拟路由架构，自动卸除网卡枷锁，交由内核路由。\033[0m"
        BIND_IP=""
    fi
    echo -e "\033[32m✅ 哨兵对外联络点已永久锁定至: $SAFE_PUBLIC_IP\033[0m"

    # [身份分离] 分离底层系统锚定的不可变主键，与暴露给上层展示的可变别名
    IP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${IP_HASH}"
    NODE_ALIAS="$NODE_NAME"

    if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
        echo -e "\n\033[36m[4.8/7] 节点展示别名设定 (用于面板友好显示)...\033[0m"
        echo -e "💡 系统底层的不可变主键为: \033[33m${NODE_NAME}\033[0m"
        read -p "请输入节点展示别名 (如'纽约机房', 回车使用默认): " CUSTOM_ALIAS

        if [ -n "$CUSTOM_ALIAS" ]; then
            NODE_ALIAS=$(echo "$CUSTOM_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r' | cut -c 1-20)
            [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
        fi
        echo -e "✅ 已锁定节点展示别名: \033[32m$NODE_ALIAS\033[0m"
    fi

    # 5. 远程拉取冷数据并解析固化
    echo -e "\n[5/7] 正在从云端数据仓库拉取 [${CITY_NAME}] 节点的底层规则..."
    REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" -o "$REGION_JSON_FILE"

    if [ ! -s "$REGION_JSON_FILE" ]; then
        echo "❌ 拉取或解析规则失败！请检查 Forgejo 仓库是否公开或网络是否畅通。"
        exit 1
    fi

    REGION_NAME=$(jq -r '.region_name' "$REGION_JSON_FILE")
    BASE_LAT=$(jq -r '.google_module.base_lat' "$REGION_JSON_FILE")
    BASE_LON=$(jq -r '.google_module.base_lon' "$REGION_JSON_FILE")
    LANG_PARAMS=$(jq -r '.google_module.lang_params' "$REGION_JSON_FILE")
    VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix' "$REGION_JSON_FILE")

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

IP_PREF="$IP_PREF"
PUBLIC_IP="$SAFE_PUBLIC_IP"
BIND_IP="$BIND_IP"
COMM_IP="$SAFE_COMM_IP"

NODE_NAME="$NODE_NAME"
NODE_ALIAS="$NODE_ALIAS"

ENABLE_OTA="$ENABLE_OTA"
EOF

    chmod 600 "$CONFIG_FILE"

fi

# ----------------------------------------------------------
# [无感热重载] 老节点数据格式迁移兼容机制
# ----------------------------------------------------------
if [ "$UPGRADE_MODE" == "true" ]; then
    if ! grep -q "PUBLIC_IP=" "$CONFIG_FILE"; then
        echo -e "\n🔄 [平滑迁移] 正在对老节点进行无损双核身份架构升级..."
        
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
        
        sed -i "s/^BIND_IP=.*/BIND_IP=\"$NEW_BIND_IP\"/" "$CONFIG_FILE"
        echo "PUBLIC_IP=\"$MIGRATE_IP\"" >> "$CONFIG_FILE"
        
        SAFE_PUBLIC_IP="$MIGRATE_IP"
        BIND_IP="$NEW_BIND_IP"
    else
        SAFE_PUBLIC_IP="${PUBLIC_IP}"
    fi

    # [v4.2.2 热修复] 为所有老节点 (无论是否已有残缺的 COMM_IP) 强行重铸多宿主容灾弹匣
    echo -e "\n🔄 [平滑迁移] 正在对老节点执行 v4.2.2 全域容灾弹匣重构..."
    
    RAW_V4=$(curl -4 -s -m 3 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
    RAW_V6=$(curl -6 -s -m 3 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
    
    V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_V4" =~ ^104\.28\. ]] || [[ "$RAW_V4" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
        RAW_V4=""
    fi
    
    V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_V6" =~ ^fe80:|^::1 ]]; then
        RAW_V6=""
    fi
    
    # 绝对基座：始终确保养护 IP (SAFE_PUBLIC_IP) 处于弹匣的首发位置
    NEW_COMM_IP="$SAFE_PUBLIC_IP"
    RAW_BASE_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
    
    # 追加 V4 容灾备弹
    if [[ -n "$RAW_V4" ]] && [[ "$NEW_COMM_IP" != *"$RAW_V4"* ]]; then
        NEW_COMM_IP="${NEW_COMM_IP}_${RAW_V4}"
    fi
    
    # 追加 V6 容灾备弹
    if [[ -n "$RAW_V6" ]]; then
        [[ "$RAW_V6" != *"["* ]] && SAFE_V6="[${RAW_V6}]" || SAFE_V6="$RAW_V6"
        if [[ "$NEW_COMM_IP" != *"$SAFE_V6"* ]]; then
            NEW_COMM_IP="${NEW_COMM_IP}_${SAFE_V6}"
        fi
    fi
    
    # 强制覆盖 config.conf 中的旧 COMM_IP 记录
    sed -i '/^COMM_IP=/d' "$CONFIG_FILE"
    echo "COMM_IP=\"$NEW_COMM_IP\"" >> "$CONFIG_FILE"
    SAFE_COMM_IP="$NEW_COMM_IP"
    
    echo -e " \033[32m✅ 重铸容灾通讯专线完成: $SAFE_COMM_IP\033[0m"

    if ! grep -q "^NODE_NAME=" "$CONFIG_FILE"; then
        TMP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
        NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${TMP_HASH}"
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

    if ! grep -q "^ENABLE_OTA=" "$CONFIG_FILE"; then
        echo "ENABLE_OTA=\"false\"" >> "$CONFIG_FILE"
        ENABLE_OTA="false"
    else
        ENABLE_OTA=$(grep "^ENABLE_OTA=" "$CONFIG_FILE" | cut -d'"' -f2)
    fi
fi

# ==========================================================
# [原子交接] 防变砖双缓冲下载执行域
# 必须保证核心模块物理就绪后，才允许向当前正在运行的旧引擎开火
# ==========================================================
echo -e "\n[6/7] 正在部署核心引擎与热数据..."
mkdir -p "${INSTALL_DIR}/data/keywords"

TMP_CORE="${SECURE_TMP}/core_update"
mkdir -p "$TMP_CORE"

curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/runner.sh" -o "${TMP_CORE}/runner.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/updater.sh" -o "${TMP_CORE}/updater.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/tg_report.sh" -o "${TMP_CORE}/tg_report.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/extract_report_stats.sh" -o "${TMP_CORE}/extract_report_stats.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/agent_daemon.sh" -o "${TMP_CORE}/agent_daemon.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/uninstall.sh" -o "${TMP_CORE}/uninstall.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/mod_google.sh" -o "${TMP_CORE}/mod_google.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/mod_trust.sh" -o "${TMP_CORE}/mod_trust.sh"
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/mod_quality.sh" -o "${TMP_CORE}/mod_quality.sh"

# 🛡️ 终极自检墙：一旦任意文件缺失或长度为零，直接熔断放弃覆写，确保宿主不宕机
if [ ! -s "${TMP_CORE}/runner.sh" ] || [ ! -s "${TMP_CORE}/agent_daemon.sh" ] || \
   [ ! -s "${TMP_CORE}/tg_report.sh" ] || [ ! -s "${TMP_CORE}/extract_report_stats.sh" ]; then
    echo -e "\033[31m❌ 致命错误：核心代码拉取失败！网络阻断或 GitHub Raw 异常。\033[0m"
    echo "🛡️ 防砖机制触发：已中止覆盖，旧版哨兵引擎仍安全存活中。"
    rm -rf "$TMP_CORE"
    exit 1
fi

echo "⏳ 新引擎校验通过，正在抹杀旧版守护进程..."
if is_systemd; then
    systemctl kill --signal=SIGKILL ip-sentinel-agent-daemon.service >/dev/null 2>&1 || true
    systemctl stop ip-sentinel-runner.timer ip-sentinel-updater.timer ip-sentinel-report.timer ip-sentinel-agent-daemon.service >/dev/null 2>&1 || true
fi
pkill -9 -f "webhook.py" >/dev/null 2>&1 || true
pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1 || true
pkill -9 -f "runner.sh" >/dev/null 2>&1 || true
pkill -9 -f "tg_report.sh" >/dev/null 2>&1 || true
pkill -9 -f "updater.sh" >/dev/null 2>&1 || true
pkill -9 -f "sentinel_scheduler.sh" >/dev/null 2>&1 || true

rm -rf "${INSTALL_DIR}/core" 2>/dev/null
mv "$TMP_CORE" "${INSTALL_DIR}/core"
chmod +x ${INSTALL_DIR}/core/*.sh

curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/user_agents.txt" -o "${INSTALL_DIR}/data/user_agents.txt"
if [ "$UPGRADE_MODE" == "false" ]; then
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}" -o "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
else
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt" 2>/dev/null || true
fi

# ==========================================================
# [进程守护] Systemd 原生注入与微内核定时降级兜底
# ==========================================================
echo -e "\n[7/7] 正在注入系统守护进程与调度器..."

DEPLOY_UTC_HOUR=$(date -u +%H)
DEPLOY_UTC_MIN=$(date -u +%M)

echo $(date -u +%s) > "${INSTALL_DIR}/core/.ua_last_update"

if is_systemd; then
    echo "💡 检测到 Systemd 环境，正在部署原生守护服务..."
    
    cat > /etc/systemd/system/ip-sentinel-runner.service << EOF
[Unit]
Description=IP-Sentinel Runner Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/runner.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ip-sentinel-runner.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Runner Service
[Timer]
OnCalendar=*:0/20
RandomizedDelaySec=180
Persistent=true
Unit=ip-sentinel-runner.service
[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/ip-sentinel-updater.service << EOF
[Unit]
Description=IP-Sentinel Updater Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/updater.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ip-sentinel-updater.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Updater Service
[Timer]
OnCalendar=*-*-* ${DEPLOY_UTC_HOUR}:${DEPLOY_UTC_MIN}:00 UTC
Persistent=true
Unit=ip-sentinel-updater.service
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ip-sentinel-runner.timer ip-sentinel-updater.timer

    if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
        cat > /etc/systemd/system/ip-sentinel-report.service << EOF
[Unit]
Description=IP-Sentinel Telegram Report Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/tg_report.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

        cat > /etc/systemd/system/ip-sentinel-report.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Telegram Report Service
[Timer]
OnCalendar=*-*-* 16:00:00 UTC
Unit=ip-sentinel-report.service
[Install]
WantedBy=timers.target
EOF

        cat > /etc/systemd/system/ip-sentinel-agent-daemon.service << EOF
[Unit]
Description=IP-Sentinel Agent Daemon Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=simple
ExecStart=/bin/bash ${INSTALL_DIR}/core/agent_daemon.sh
Restart=always
RestartSec=5
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
EOF

        DAEMON_IP=$( (curl -s -m 5 api.ip.sb/ip || curl -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
        [ -n "$DAEMON_IP" ] && echo "$DAEMON_IP" > "${INSTALL_DIR}/core/.last_ip" || echo "$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')" > "${INSTALL_DIR}/core/.last_ip"
        
        systemctl daemon-reload
        systemctl enable --now ip-sentinel-report.timer
        systemctl enable --now ip-sentinel-agent-daemon.service
    fi
    else
        echo "💡 未检测到 Systemd，正在配置备用调度器 (兼容 Alpine/OpenRC)..."
        
        IS_RESTRICTED_ALPINE="false"
        if [ -f /etc/alpine-release ]; then
            if [ -d /proc/vz ] || grep -qa container=lxc /proc/1/environ 2>/dev/null || [ -f /.dockerenv ]; then
                IS_RESTRICTED_ALPINE="true"
            fi
        fi

        if [ "$IS_RESTRICTED_ALPINE" == "true" ]; then
            echo -e "⚠️ 探测到受限的 LXC/OpenVZ Alpine 环境，系统自带 Cron 极易假死。"
            echo -e "🔧 自动降维打击：启用 [自定义高可用死循环调度器] 接管全局任务..."
            
            rc-update del crond default >/dev/null 2>&1 || true
            rc-service crond stop >/dev/null 2>&1 || true
            pkill -9 crond >/dev/null 2>&1 || true
            crontab -l 2>/dev/null | grep -v "ip_sentinel" > "${SECURE_TMP}/cron_clean" || true
            [ -f "${SECURE_TMP}/cron_clean" ] && crontab "${SECURE_TMP}/cron_clean" >/dev/null 2>&1
            rm -f "${SECURE_TMP}/cron_clean"

            cat > ${INSTALL_DIR}/core/sentinel_scheduler.sh << EOF
#!/bin/bash
while true; do
    MIN=\$(date -u +%M)
    HOUR=\$(date -u +%H)
    if [ "\$MIN" == "00" ] || [ "\$MIN" == "20" ] || [ "\$MIN" == "40" ]; then
        /bin/bash /opt/ip_sentinel/core/runner.sh >/dev/null 2>&1
    fi
    if [ "\$HOUR" == "${DEPLOY_UTC_HOUR}" ] && [ "\$MIN" == "${DEPLOY_UTC_MIN}" ]; then
        /bin/bash /opt/ip_sentinel/core/updater.sh >/dev/null 2>&1
    fi
    if [ "\$HOUR" == "16" ] && [ "\$MIN" == "00" ]; then
        /bin/bash /opt/ip_sentinel/core/tg_report.sh >/dev/null 2>&1
    fi
    if ! pgrep -f 'webhook.py' >/dev/null; then
        /bin/bash /opt/ip_sentinel/core/agent_daemon.sh >/dev/null 2>&1 &
    fi
    sleep 60
done
EOF
            chmod +x ${INSTALL_DIR}/core/sentinel_scheduler.sh

            if command -v rc-update >/dev/null 2>&1 && [ -d "/etc/local.d" ]; then
                echo "nohup bash ${INSTALL_DIR}/core/sentinel_scheduler.sh >/dev/null 2>&1 &" > /etc/local.d/ip_sentinel_scheduler.start
                chmod +x /etc/local.d/ip_sentinel_scheduler.start
                rc-update add local default >/dev/null 2>&1
            else
                grep -q "sentinel_scheduler" /etc/profile || echo "nohup bash ${INSTALL_DIR}/core/sentinel_scheduler.sh >/dev/null 2>&1 &" >> /etc/profile
            fi
            
            [ -n "$PUBLIC_IP" ] && echo "$PUBLIC_IP" > "${INSTALL_DIR}/core/.last_ip"
            nohup bash ${INSTALL_DIR}/core/sentinel_scheduler.sh >/dev/null 2>&1 &
            
        else
            crontab -l 2>/dev/null | grep -v "ip_sentinel" > "${SECURE_TMP}/cron_backup" || true
            echo "*/20 * * * * ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
            echo "${DEPLOY_UTC_MIN} ${DEPLOY_UTC_HOUR} * * * ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
            
            if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
                echo "0 16 * * * ${INSTALL_DIR}/core/tg_report.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
                echo "$SAFE_PUBLIC_IP" > "${INSTALL_DIR}/core/.last_ip"
                DAEMON_IP=$( (curl -s -m 5 api.ip.sb/ip || curl -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
                [ -n "$DAEMON_IP" ] && echo "$DAEMON_IP" > "${INSTALL_DIR}/core/.last_ip" || echo "$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')" > "${INSTALL_DIR}/core/.last_ip"
                
                if command -v rc-update >/dev/null 2>&1 && [ -d "/etc/local.d" ]; then
                    echo "nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" > /etc/local.d/ip_sentinel.start
                    chmod +x /etc/local.d/ip_sentinel.start
                    rc-update add local default >/dev/null 2>&1
                else
                    echo "@reboot nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> "${SECURE_TMP}/cron_backup"
                fi
                
                echo "* * * * * pgrep -f 'webhook.py' >/dev/null || nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> "${SECURE_TMP}/cron_backup"
                
                nohup bash "${INSTALL_DIR}/core/agent_daemon.sh" >/dev/null 2>&1 &
            fi
            
            [ -f "${SECURE_TMP}/cron_backup" ] && crontab "${SECURE_TMP}/cron_backup" >/dev/null 2>&1
            
            if [ -d "/etc/crontabs" ] && [ -f "/var/spool/cron/crontabs/root" ]; then
                cp -f /var/spool/cron/crontabs/root /etc/crontabs/root 2>/dev/null || true
                chmod 600 /etc/crontabs/root 2>/dev/null || true
            fi
            
            if command -v rc-service >/dev/null 2>&1; then
                rc-service crond restart >/dev/null 2>&1 || crond -b >/dev/null 2>&1
            else
                pkill -9 crond 2>/dev/null || true
                crond -b >/dev/null 2>&1 || true
            fi
            
            rm -f "${SECURE_TMP}/cron_backup"
        fi
    fi

# ----------------------------------------------------------
# [通讯指控] 部署后首播，打入中枢通信网关及指令态势传递
# ----------------------------------------------------------
if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
    
    # 注册报文中塞入多宿主弹匣 SAFE_COMM_IP
    REG_MSG="#REGISTER#|${REGION_CODE}|${NODE_NAME}|${SAFE_COMM_IP}|${AGENT_PORT}|${NODE_ALIAS}|${ENABLE_OTA}"
    
    if [ "$UPGRADE_MODE" == "true" ]; then
        OLD_VERSION=$(grep "^AGENT_VERSION=" "$CONFIG_FILE" | cut -d'"' -f2)
        [ -z "$OLD_VERSION" ] && OLD_VERSION="3.3.1"
        
        # [v4.2.2 跨代升级防线] 只要是从低于 4.2.2 的版本升上来，强制要求用户点击注册指令同步多宿主弹匣
        if version_lt "$OLD_VERSION" "4.2.2"; then
            echo -e "\n📡 [路由枢纽] 正在执行容灾架构重组 (v${OLD_VERSION} -> v${TARGET_VERSION})..."
            TEXT_MSG="✨ *IP-Sentinel 容灾引擎热更新完成！*
📍 节点：\`${NODE_ALIAS}\`
🌐 养护 IP：\`${SAFE_PUBLIC_IP}\`
📡 容灾弹匣：\`${SAFE_COMM_IP}\`
🚀 状态：v${TARGET_VERSION} 全域双栈引擎已部署

⚠️ *通讯架构已升级为多宿主容灾模式！*
👉 **请务必点击下方指令并发送，将新版通讯弹匣同步至司令部：**
\`${REG_MSG}\`"
            
            JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
            curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" >/dev/null 2>&1
            
            echo -e "\033[32m✅ 升级通知已推送！请前往 TG 点击注册指令完成身份同步！\033[0m"
            
        else
            echo -e "\n📡 [路由枢纽] 正在执行静默平滑升级 (v${OLD_VERSION} -> v${TARGET_VERSION})..."
            TEXT_MSG="✨ *IP-Sentinel 引擎热更新完成！*
📍 节点：\`${NODE_ALIAS}\`
🌐 养护 IP：\`${SAFE_PUBLIC_IP}\`
📡 容灾 IP：\`${SAFE_COMM_IP}\`
🚀 状态：v${TARGET_VERSION} OTA 动态活体引擎已部署"

            JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
            curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" >/dev/null 2>&1

            echo -e "\033[32m✅ 升级成功通知已推送到您的 Telegram！\033[0m"
        fi
        
        sed -i '/^NAME_HASHED=/d' "$CONFIG_FILE" 2>/dev/null
        if grep -q "^AGENT_VERSION=" "$CONFIG_FILE"; then
            sed -i "s/^AGENT_VERSION=.*/AGENT_VERSION=\"$TARGET_VERSION\"/" "$CONFIG_FILE"
        else
            echo "AGENT_VERSION=\"$TARGET_VERSION\"" >> "$CONFIG_FILE"
        fi
        
    else
        echo -e "\n📡 正在向指挥部发送注册暗号..."
        
        TEXT_MSG="✨ *IP-Sentinel 部署成功！*
📍 区域：${REGION_NAME}
🌐 养护 IP：\`${SAFE_PUBLIC_IP}\`
📡 容灾 IP：\`${SAFE_COMM_IP}\`
🔌 端口：\`${AGENT_PORT}\`

🔑 *请点击下方指令复制并回复给机器人：*
\`${REG_MSG}\`"

        JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
        PUSH_RESULT=$(curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD")

        if echo "$PUSH_RESULT" | grep -q '"ok":true'; then
            echo -e "\033[32m✅ 注册信息已推送到您的 Telegram，请按指令完成最终激活！\033[0m"
        else
            echo -e "\033[31m❌ 消息推送失败，请检查 Chat ID 是否正确或是否已关注机器人。\033[0m"
        fi
    fi
fi

echo "========================================================"
if [ "$UPGRADE_MODE" == "true" ]; then
    echo "🎉 边缘节点 (Agent) 平滑热更新已彻底完成！"
else
    echo "🎉 边缘节点 (Agent) 部署流程彻底完成！"
fi
echo "📍 你的本地守护区域已锁定为: $REGION_NAME"
echo "⚙️ 哨兵现已开启 [每20分钟] 的高频高拟真养护循环。"
if [[ -n "$TG_TOKEN" ]]; then
    echo "📡 Webhook 监听已启动 (端口: $AGENT_PORT) 并向中枢发送了注册请求。"
    
    # [v4.2.2 防火墙修正] 适配多宿主 IP 提示
    IS_V6_COMM="false"
    [[ "$SAFE_COMM_IP" == *":"* ]] && IS_V6_COMM="true"
    
    FW_MSG=""
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw active; then
        FW_MSG="ufw allow $AGENT_PORT/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld | grep -qw active; then
        FW_MSG="firewall-cmd --zone=public --add-port=$AGENT_PORT/tcp --permanent && firewall-cmd --reload"
    elif command -v iptables >/dev/null 2>&1; then
        if [ "$IS_V6_COMM" == "true" ]; then
            if command -v ip6tables >/dev/null 2>&1; then
                FW_MSG="ip6tables -I INPUT -p tcp --dport $AGENT_PORT -j ACCEPT"
            else
                FW_MSG="iptables -I INPUT -p tcp --dport $AGENT_PORT -j ACCEPT  # 提示: 系统缺失 ip6tables"
            fi
        else
            FW_MSG="iptables -I INPUT -p tcp --dport $AGENT_PORT -j ACCEPT"
        fi
    fi
    
    echo -e "\n\033[31m⚠️ 【高危警告】您的节点通讯寻址池已锁定为: $SAFE_COMM_IP\033[0m"
    echo -e "\033[33m为确保 Master 司令部能够成功下发指令，您【必须】前往云服务商 (如 AWS/Oracle/阿里云 等) 的网页控制台中，将安全组 (Security Group) 防火墙的 TCP $AGENT_PORT 端口彻底放行！\033[0m"
    echo -e "\033[31m⛔ 本系统已开启全域双栈监听，禁止尝试通过修改脚本强行绑定局域网 IP 来绕过通信阻断！\033[0m\n"
    if [ -n "$FW_MSG" ]; then
        echo "💡 检测到本地系统防火墙开启，您可以尝试执行以下命令放行本机端口 (注意: 云端安全组仍需您手动放行)："
        echo -e "\033[36m   $FW_MSG\033[0m"
    fi
fi
echo "🗑️ 若未来需卸载，可重新运行本脚本选择[2]或执行: bash ${INSTALL_DIR}/core/uninstall.sh"
echo "========================================================"

if [ "$UPGRADE_MODE" == "false" ]; then
    echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
    AGENT_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/agent" || echo "")

    if [ -n "$AGENT_COUNT" ] && [[ "$AGENT_COUNT" =~ ^[0-9]+$ ]]; then
        echo -e "\033[32m✅ 感谢您成为全球第 ${AGENT_COUNT} 名 IP-Sentinel 节点维护者！\033[0m"
    else
        echo -e "\033[32m✅ 感谢您部署 IP-Sentinel！\033[0m"
    fi
fi

echo -e "\n========================================================"
echo -e "⭐ \033[33m开源不易，如果 IP-Sentinel 提升了您的节点稳定性，请赐予我们一枚星标！\033[0m"
echo -e "💡 \033[32m您的每一颗 Star 都是我们持续对抗风控、维护更新指纹库的核心动力。\033[0m"
echo -e "👉 \033[36m\033[4m\033]8;;https://github.com/hotyue/IP-Sentinel\033\\点击此处直达 GitHub 仓库点亮 Star 🌟\033[0m\033]8;;\033\\"
echo -e "========================================================\n"
