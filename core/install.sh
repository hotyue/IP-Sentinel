#!/bin/bash

# ==========================================================
# 脚本名称: install.sh (IP-Sentinel 分布式边缘节点部署脚本 V6.0)
# 核心功能: 区域选择、模块按需开启(Feature Flag)、配置生成与双重守护
# ==========================================================

# 你的专属 Forgejo 仓库 Raw 数据直链前缀
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

# 2. 交互式引导 (包含卸载选项)
echo -e "\n[2/7] 请选择你要伪装的目标区域或执行卸载:"
echo "  1) 🇯🇵 日本 (东京 - JP)"
echo "  2) 🇺🇸 美国 (美西 - US)"
echo "  3) 🗑️ 一键卸载 IP-Sentinel"
read -p "请输入选择 [1-3] (默认1): " REGION_CHOICE

# 如果选择卸载，拉取卸载脚本执行并退出
if [ "$REGION_CHOICE" == "3" ]; then
    echo -e "\n⏳ 正在拉取卸载程序..."
    curl -sL "${REPO_RAW_URL}/core/uninstall.sh" -o "/tmp/ip_uninstall.sh"
    chmod +x "/tmp/ip_uninstall.sh"
    bash "/tmp/ip_uninstall.sh"
    rm -f "/tmp/ip_uninstall.sh"
    exit 0
fi

# 正常安装流程匹配区域
case ${REGION_CHOICE:-1} in
    2) REGION_CODE="US" ;;
    *) REGION_CODE="JP" ;;
esac

# 本地工作目录初始化
mkdir -p "${INSTALL_DIR}/core"
mkdir -p "${INSTALL_DIR}/data/keywords"
mkdir -p "${INSTALL_DIR}/data/regions"
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
    read -p "请输入 Telegram Bot Token (与主控一致): " TG_TOKEN
    read -p "请输入你的 Chat ID (与主控一致): " CHAT_ID
    read -p "请输入本机用于接收指令的 Webhook 端口 (默认 9527，请确保防火墙已放开此端口): " INPUT_PORT
    [ -n "$INPUT_PORT" ] && AGENT_PORT="$INPUT_PORT"
fi

# 5. 远程拉取冷数据并解析固化
echo -e "\n[5/7] 正在从你的数据仓库拉取 [${REGION_CODE}] 节点的底层规则..."
REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${REGION_CODE}.json"
curl -sL "${REPO_RAW_URL}/data/regions/${REGION_CODE}.json" -o "$REGION_JSON_FILE"

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
    curl -sL "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"
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