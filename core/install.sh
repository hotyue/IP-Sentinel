#!/bin/bash

# ==========================================================
# 脚本名称: install.sh (IP-Sentinel 分布式边缘节点部署脚本 v3.0.0 - Global Nexus)
# 核心功能: 区域选择、模块按需开启、官方机器人一键配置
# ==========================================================

# 你的 GitHub 仓库 Raw 数据直链前缀
# REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为私库地址用于测试
REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

echo "========================================================"
echo "      🛡️ 欢迎使用 IP-Sentinel (边缘节点 Edge Agent)"
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

if [ "$ACTION_CHOICE" == "2" ]; then
    echo -e "\n⏳ 正在拉取卸载程序..."
    curl -sL "${REPO_RAW_URL}/core/uninstall.sh" -o "/tmp/ip_uninstall.sh"
    chmod +x "/tmp/ip_uninstall.sh"
    bash "/tmp/ip_uninstall.sh"
    rm -f "/tmp/ip_uninstall.sh"
    exit 0
fi

# 📍 动态一级菜单：国家选择
echo -e "\n\033[36m📍 【第一级】请选择目标国家/地区:\033[0m"
jq -r '.countries[] | "\(.id)|\(.name)|\(.keyword_file)"' /tmp/map.json > /tmp/countries.txt
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

# 📍 动态二级菜单：省/州选择
echo -e "\n\033[36m📍 【第二级】正在检索 [$COUNTRY_ID] 的行政区数据...\033[0m"
jq -r ".countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | \"\(.id)|\(.name)\"" /tmp/map.json > /tmp/states.txt
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

# 📍 动态三级菜单：城市选择
echo -e "\n\033[36m📍 【第三级】请锁定具体城市节点:\033[0m"
jq -r ".countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | select(.id==\"$STATE_ID\") | .cities[] | \"\(.id)|\(.name)\"" /tmp/map.json > /tmp/cities.txt
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

# 清理临时文件
rm -f /tmp/map.json /tmp/countries.txt /tmp/states.txt /tmp/cities.txt

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
        TG_API_URL="https://omni-gateway.yuezhongjun.workers.dev" 
        echo -e "\033[32m✅ 已自动连接官方安全网关 (@OmniBeacon_bot)。\033[0m"
        echo -e "\033[33m👉 请确保您已关注官方机器人并发送过 /start，否则将无法接收消息。\033[0m"
    else
        TG_TOKEN="$USER_TOKEN"
        TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
        echo -e "\033[32m✅ 已记录您的私有机器人 Token。\033[0m"
    fi

    echo -e "\033[33m💡 提示：如果您不知道自己的 Chat ID，可以关注 @userinfobot 获取。\033[0m"
    read -p "请输入你的 Chat ID (与主控一致): " CHAT_ID
    read -p "请输入本机用于接收指令的 Webhook 端口 (默认 9527): " INPUT_PORT
    [ -n "$INPUT_PORT" ] && AGENT_PORT="$INPUT_PORT"
fi

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

# 写入本地静态配置文件
cat > "$CONFIG_FILE" << EOF
# IP-Sentinel 本地固化配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
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
EOF

# 6. 拉取全套组件 (按需下载，绝不浪费空间)
echo -e "\n[6/7] 正在根据模块开关部署核心引擎与热数据..."
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
    # 根据 map.json 动态匹配的词库文件进行下载
    curl -sL "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}" -o "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
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
# 养料更新模块: 每周日凌晨 3 点静默去云端更新热数据
echo "0 3 * * 0 ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> /tmp/cron_backup

# 如果配置了联控，启动 Webhook 与战报任务
if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
    # 每天早上 8 点发送昨天的统计战报
    echo "0 8 * * * ${INSTALL_DIR}/core/tg_report.sh >/dev/null 2>&1" >> /tmp/cron_backup
    
    # 双保险守护进程看门狗
    echo "@reboot nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> /tmp/cron_backup
    echo "* * * * * nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> /tmp/cron_backup
    
    # 安装时立刻启动一次边缘守护进程
    nohup bash "${INSTALL_DIR}/core/agent_daemon.sh" >/dev/null 2>&1 &
fi

crontab /tmp/cron_backup
rm -f /tmp/cron_backup

if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
    echo -e "\n📡 正在向指挥部发送注册暗号..."
    
    # 获取公网 IP
    PUBLIC_IP=$(curl -s https://api64.ipify.org || curl -s https://ifconfig.me || echo "未知IP")
    
    # 构造注册暗号
    REG_MSG="#REGISTER#:${REGION_NAME}:${PUBLIC_IP}:${AGENT_PORT}"
    
# 执行主动推送
    PUSH_RESULT=$(curl -s -X POST "${TG_API_URL}" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=✨ *IP-Sentinel 部署成功！*
📍 区域：${REGION_NAME}
🌐 IP：${PUBLIC_IP}
🔌 端口：${AGENT_PORT}

🔑 *请点击下方指令复制并回复给机器人：*
\`${REG_MSG}\`")

    if echo "$PUSH_RESULT" | grep -q '"ok":true'; then
        echo -e "\033[32m✅ 注册信息已推送到您的 Telegram，请按指令完成最终激活！\033[0m"
    else
        echo -e "\033[31m❌ 消息推送失败，请检查 Chat ID 是否正确或是否已关注机器人。\033[0m"
    fi
fi

echo "========================================================"
echo "🎉 边缘节点 (Agent) 部署流程彻底完成！"
echo "📍 你的本地守护区域已锁定为: $REGION_NAME"
echo "⚙️ 哨兵现已开启 [每30分钟] 的高频高拟真养护循环。"
if [[ -n "$TG_TOKEN" ]]; then
    echo "📡 Webhook 监听已启动 (端口: $AGENT_PORT) 并向中枢发送了注册请求。"
    echo "⚠️ 请务必确保本机的防火墙放行了 TCP $AGENT_PORT 端口！"
fi
echo "🗑️ 若未来需卸载，可重新运行本脚本选择[3]或执行: bash ${INSTALL_DIR}/core/uninstall.sh"
echo "========================================================"