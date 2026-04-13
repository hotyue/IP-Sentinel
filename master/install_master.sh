#!/bin/bash

# ==========================================================
# 脚本名称: install_master.sh (IP-Sentinel 控制中枢部署脚本 v3.2.2)
# 核心功能: 部署/卸载调度中枢、SQLite 资产管理、平滑热更新引擎
# ==========================================================

# [新增] 提取仓库直链前缀变量，方便后续在官方库和私库间一键切换
REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为私库地址用于测试
# REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"

MASTER_DIR="/opt/ip_sentinel_master"
DB_FILE="${MASTER_DIR}/sentinel.db"

echo "========================================================"
# [修改] 将欢迎语改为更通用的文案，因为现在不仅能部署，还能卸载
echo "      🧠 欢迎使用 IP-Sentinel Master (控制中枢) v3.2.2"
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

# ================== [v3.2.2 新增: 平滑升级模式嗅探] ==================
UPGRADE_MODE="false"
KEEP_DB="true"

if [ "$ACTION_CHOICE" == "1" ] && [ -f "${MASTER_DIR}/master.conf" ]; then
    echo -e "\n\033[33m💡 司令部雷达提示：检测到本机已部署过 Master 中枢。\033[0m"
    read -p "👉 是否按原配置直接进行平滑升级？(y/n, 默认y): " UPGRADE_CHOICE
    if [[ -z "$UPGRADE_CHOICE" || "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
        UPGRADE_MODE="true"
        read -p "👉 是否保留历史节点数据库 (SQLite)？(y/n, 默认y): " DB_CHOICE
        if [[ "$DB_CHOICE" =~ ^[Nn]$ ]]; then
            KEEP_DB="false"
        fi
        
        # 汲取原配置进入内存
        source "${MASTER_DIR}/master.conf"
        echo -e "\033[32m✅ 已激活 [平滑升级模式]，即将跳过基础配置，直接更新核心中枢...\033[0m"
    else
        echo -e "\033[33m🔄 您选择了重新配置，旧的中枢数据将被彻底抹除。\033[0m"
    fi
fi
# ====================================================================

# ================== [v3.2.2 优化: 安装前环境纯净度清理与数据保护] ==================
echo -e "\n⏳ 正在清理旧版 Master 守护进程..."
pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true

if [ "$UPGRADE_MODE" == "true" ]; then
    if [ "$KEEP_DB" == "false" ]; then
        rm -f "$DB_FILE" 2>/dev/null
        echo -e "🗑️ 历史节点数据库已按指令清空。"
    else
        echo -e "📦 历史节点数据库 (SQLite) 已绝密保留。"
    fi
    # 删除旧的核心脚本，准备拉取新的
    rm -f "${MASTER_DIR}/tg_master.sh" 2>/dev/null
else
    # 焦土政策：如果不是升级模式，直接扬了整个司令部目录
    rm -rf "$MASTER_DIR" 2>/dev/null
fi
echo -e "\033[32m✅ 旧进程已肃清！\033[0m"
# =======================================================================

# 1. 环境依赖安装
echo -e "\n[1/4] 安装核心依赖 (curl, jq, sqlite3)..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl jq sqlite3 procps >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl jq sqlite >/dev/null 2>&1
fi

mkdir -p "$MASTER_DIR"

# ==========================================================
# 🛑 如果是全新部署，才询问 Token 并写入配置
# ==========================================================
if [ "$UPGRADE_MODE" == "false" ]; then
    # 2. 交互配置机器人
    echo -e "\n[2/4] 配置控制中枢机器人:"
    read -p "请输入 Telegram Bot Token: " TG_TOKEN

    cat > "${MASTER_DIR}/master.conf" << EOF
TG_TOKEN="$TG_TOKEN"
DB_FILE="$DB_FILE"
MASTER_DIR="$MASTER_DIR"
EOF
fi
# 🛑 拦截块结束

# 3. 初始化 SQLite 数据库 (幂等操作，升级模式下可安全修补表结构)
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

# ================== [v3.2.2 优化: 战报文案分流] ==================
echo "========================================================"
if [ "$UPGRADE_MODE" == "true" ]; then
    echo "🎉 Master 控制中枢平滑热更新完成！"
    echo "🤖 新版中枢引擎已接管数据库，继续等待边缘节点汇报。"
else
    echo "🎉 Master 控制中枢部署完成！"
    echo "🤖 机器人现已开始全局接客，等待边缘节点注册。"
fi
echo "========================================================"
# =================================================================

# ================== [v3.1.2 新增: 玻璃房透明装机统计] ==================
echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
MASTER_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/master" || echo "")

if [ -n "$MASTER_COUNT" ] && [[ "$MASTER_COUNT" =~ ^[0-9]+$ ]]; then
    echo -e "\033[32m✅ 感谢您成为全球第 ${MASTER_COUNT} 名 IP-Sentinel 指挥官！\033[0m"
else
    echo -e "\033[32m✅ 感谢您建立 IP-Sentinel 司令部！\033[0m"
fi
echo -e "\n"