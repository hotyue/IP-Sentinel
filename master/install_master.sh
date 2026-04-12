#!/bin/bash

# [新增] 提取仓库直链前缀变量，方便后续在官方库和私库间一键切换
REPO_RAW_URL="https://raw.githubusercontent.com/Seameee/IP-Sentinel/main"
# 临时改为私库地址用于测试
# REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"

MASTER_DIR="/opt/ip_sentinel_master"
DB_FILE="${MASTER_DIR}/sentinel.db"

echo "========================================================"
# [修改] 将欢迎语改为更通用的文案，因为现在不仅能部署，还能卸载
echo "      🧠 欢迎使用 IP-Sentinel Master (控制中枢)"
echo "========================================================"

# [新增] 交互式操作菜单：支持选择部署或调用卸载程序
echo -e "\n请选择操作:"
echo "  1) 🚀 部署 Master 控制中枢"
echo "  2) 🗑️ 一键卸载 Master 中枢"
read -p "请输入选择 [1-2] (默认1): " ACTION_CHOICE

if [ "$ACTION_CHOICE" == "2" ]; then
    echo -e "\n⏳ 正在拉取卸载程序..."
    # [新增逻辑] 使用上面定义的 REPO_RAW_URL 动态拉取卸载脚本，执行后自动销毁临时文件
    curl -sL "${REPO_RAW_URL}/master/uninstall_master.sh" -o "/tmp/uninstall_master.sh"
    chmod +x "/tmp/uninstall_master.sh"
    bash "/tmp/uninstall_master.sh"
    rm -f "/tmp/uninstall_master.sh"
    exit 0
fi

# ================== [v3.1.1 延续: 安装前环境纯净度清理] ==================
echo -e "\n⏳ 正在清理旧版 Master 守护进程 (绝对安全保留 SQLite 数据库)..."
pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true
# =======================================================================

# 1. 环境依赖安装
echo "[1/4] 安装核心依赖 (curl, jq, sqlite3)..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl jq sqlite3 procps >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl jq sqlite >/dev/null 2>&1
fi

mkdir -p "$MASTER_DIR"

# 2. 交互配置机器人
echo -e "\n[2/4] 配置控制中枢机器人:"
read -p "请输入 Telegram Bot Token: " TG_TOKEN

cat > "${MASTER_DIR}/master.conf" << EOF
TG_TOKEN="$TG_TOKEN"
DB_FILE="$DB_FILE"
MASTER_DIR="$MASTER_DIR"
EOF

# 3. 初始化 SQLite 数据库
echo -e "\n[3/4] 正在初始化 SQLite 数据库表结构..."
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS nodes (
    chat_id TEXT,
    node_name TEXT,
    agent_ip TEXT,
    agent_port TEXT,
    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(chat_id, node_name)
);
EOF
echo "✅ 数据库创建成功: $DB_FILE"

# ================== [v3.0.3 变更: 敏感文件权限收敛] ==================
chmod 600 "${MASTER_DIR}/master.conf"
chmod 600 "$DB_FILE"
# ====================================================================

# 4. 拉取核心调度代码并运行
echo -e "\n[4/4] 部署 TG 调度守护进程..."
# [修改] 剥离了写死的网址，改用顶部的 ${REPO_RAW_URL} 变量，确保与卸载脚本的数据源同源
curl -sL "${REPO_RAW_URL}/master/tg_master.sh" -o "${MASTER_DIR}/tg_master.sh"
chmod +x "${MASTER_DIR}/tg_master.sh"

# 写入看门狗 Cron
crontab -l 2>/dev/null | grep -v "tg_master.sh" > /tmp/cron_master
echo "* * * * * pgrep -f tg_master.sh >/dev/null || nohup bash ${MASTER_DIR}/tg_master.sh >/dev/null 2>&1 &" >> /tmp/cron_master
crontab /tmp/cron_master
rm -f /tmp/cron_master

# 立刻启动
pgrep -f tg_master.sh >/dev/null || nohup bash "${MASTER_DIR}/tg_master.sh" >/dev/null 2>&1 &

echo "========================================================"
echo "🎉 Master 控制中枢部署完成！"
echo "🤖 机器人现已开始全局接客，等待边缘节点注册。"
echo "========================================================"

# ================== [v3.1.2 新增: 玻璃房透明装机统计] ==================
echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
MASTER_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/master" || echo "")

if [ -n "$MASTER_COUNT" ] && [[ "$MASTER_COUNT" =~ ^[0-9]+$ ]]; then
    echo -e "\033[32m✅ 感谢您成为全球第 ${MASTER_COUNT} 名 IP-Sentinel 指挥官！\033[0m"
else
    echo -e "\033[32m✅ 感谢您建立 IP-Sentinel 司令部！\033[0m"
fi
echo -e "\n"