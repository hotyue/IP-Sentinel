#!/bin/bash

# ==========================================================
# 脚本名称: install_master.sh (IP-Sentinel 控制中枢部署脚本 - 动态锚点版)
# 核心功能: 部署/卸载调度中枢、SQLite 资产管理、平滑热更新引擎
# ==========================================================

# 你的 GitHub 仓库 Raw 数据直链前缀
# REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为开发地址用于测试
REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/dev-v3.6.1"

# [核心: 动态提取 Master 专属版本锚点 (KV 解析法)]
# 通过 grep 定位 MASTER_VERSION 行，再通过 cut 提取等号右侧的值
TARGET_VERSION=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')

# 🛡️ 兜底防线：如果网络波动拉取失败，启用内置的安全兜底版本
TARGET_VERSION=${TARGET_VERSION:-"3.5.0"}

MASTER_DIR="/opt/ip_sentinel_master"
DB_FILE="${MASTER_DIR}/sentinel.db"

echo "========================================================"
# [修改] 将欢迎语改为更通用的文案，因为现在不仅能部署，还能卸载
echo "      🧠 欢迎使用 IP-Sentinel Master (控制中枢) v${TARGET_VERSION}"
echo "========================================================"

# [新增] 交互式操作菜单：支持选择部署或调用卸载程序
echo -e "\n请选择操作:"
echo "  1) 🚀 部署 Master 控制中枢"
echo "  2) 🗑️ 一键卸载 Master 中枢"
read -p "请输入选择 [1-2] (默认1): " ACTION_CHOICE

# [v3.5.2 修复] 防止用户直接回车导致变量为空，从而漏过下方的平滑升级判定被误删档
ACTION_CHOICE=${ACTION_CHOICE:-1}

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
        
        # [v3.4.0 核心] 升级后立即同步/补录版本号至配置文件
        if grep -q "^MASTER_VERSION=" "${MASTER_DIR}/master.conf"; then
            sed -i "s/^MASTER_VERSION=.*/MASTER_VERSION=\"$TARGET_VERSION\"/" "${MASTER_DIR}/master.conf"
        else
            echo "MASTER_VERSION=\"$TARGET_VERSION\"" >> "${MASTER_DIR}/master.conf"
        fi
        
        echo -e "\033[32m✅ 已激活 [平滑升级模式]，版本已锚定为 v${TARGET_VERSION}...\033[0m"
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

# 1. 依赖检查与智能安装 (v3.6.0 兼容性与优雅性升级)
echo -e "\n[1/4] 正在探测核心依赖 (curl, jq, sqlite3, crontab, pgrep)..."

REQUIRED_CMDS=("curl" "jq" "sqlite3" "crontab" "pgrep")
MISSING_CMDS=()

# 基础探测：预检查缺失的命令
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done

# 如果有缺失，才执行包管理器拉取逻辑
if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo "⏳ 发现缺失依赖: ${MISSING_CMDS[*]}，正在尝试自动补齐..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl jq sqlite3 cron procps >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        PKG_MGR="yum"
        command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
        $PKG_MGR install -y curl jq sqlite cronie procps-ng >/dev/null 2>&1
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        echo "Alpine 探测到系统类型为 Alpine Linux，正在执行轻量级安装..."
        apk add --no-cache curl jq sqlite dcron procps bash >/dev/null 2>&1
        mkdir -p /var/spool/cron/crontabs
        rc-update add crond default >/dev/null 2>&1
        service crond start >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl jq sqlite cronie procps-ng >/dev/null 2>&1
        mkdir -p /root/.cache/crontab 2>/dev/null
        systemctl enable cronie >/dev/null 2>&1 && systemctl start cronie >/dev/null 2>&1
    else
        echo -e "\033[31m❌ 自动安装失败：系统未知的包管理器。\033[0m"
        echo -e "\033[33m⚠️ 请手动执行以下安装命令后重新运行本脚本：\033[0m"
        echo -e "  Debian/Ubuntu: \033[36mapt-get update && apt-get install -y curl jq sqlite3 cron procps\033[0m"
        echo -e "  CentOS/RHEL:   \033[36myum install -y curl jq sqlite cronie procps-ng\033[0m"
        echo -e "  Alpine Linux:  \033[36mapk add --no-cache curl jq sqlite dcron procps bash\033[0m"
        exit 1
    fi
    
    # 安装后二次复检
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "\033[31m❌ 致命错误：核心命令 '$cmd' 仍未找到！\033[0m"
            echo -e "请手动修复您的包管理器源，或联系 VPS 供应商。"
            exit 1
        fi
    done
fi
echo -e "\033[32m✅ 基础环境检测通过。\033[0m"

mkdir -p "$MASTER_DIR"

# ==========================================================
# 🛑 如果是全新部署，才询问 Token 并写入配置
# ==========================================================
if [ "$UPGRADE_MODE" == "false" ]; then
    # 2. 交互配置机器人
    echo -e "\n[2/4] 配置控制中枢机器人:"
    read -p "请输入 Telegram Bot Token: " TG_TOKEN
    
    # [v3.6.0 新增] 官方网关模式选项 (用于屏蔽全局 OTA 按钮)
    echo -e "\n请选择您的部署环境身份:"
    echo "  1) 🛡️ 私有独立中枢 (默认推荐，保留完整 OTA 遥控权限)"
    echo "  2) ☁️ 官方公共网关 (面向大众服务，将强制物理隐藏全局 OTA 按钮防滥用)"
    read -p "请输入选择 [1-2] (默认1): " GATEWAY_TYPE
    GATEWAY_TYPE=${GATEWAY_TYPE:-1}
    
    IS_OFFICIAL_GATEWAY="false"
    if [ "$GATEWAY_TYPE" == "2" ]; then
        IS_OFFICIAL_GATEWAY="true"
        echo -e "\033[33m⚠️ 已开启官方公共网关模式，全局 OTA 按钮将被屏蔽。\033[0m"
    fi

    cat > "${MASTER_DIR}/master.conf" << EOF
# IP-Sentinel Master 本地固化配置 (v${TARGET_VERSION})
MASTER_VERSION="$TARGET_VERSION"
TG_TOKEN="$TG_TOKEN"
DB_FILE="$DB_FILE"
MASTER_DIR="$MASTER_DIR"
# [v3.6.0 核心] 官方网关 UI 熔断标识
IS_OFFICIAL_GATEWAY="$IS_OFFICIAL_GATEWAY"
EOF
fi

# [v3.6.0 热修复] 老司令部平滑升级时，自动补齐该字段并默认为 false
if [ "$UPGRADE_MODE" == "true" ]; then
    if ! grep -q "^IS_OFFICIAL_GATEWAY=" "${MASTER_DIR}/master.conf"; then
        echo "IS_OFFICIAL_GATEWAY=\"false\"" >> "${MASTER_DIR}/master.conf"
    fi
fi
# 🛑 拦截块结束

# 3. 初始化 SQLite 数据库 (幂等操作，升级模式下由 tg_master.sh 负责热修补)
echo -e "\n[3/4] 正在初始化 SQLite 数据库表结构..."
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS nodes (
    chat_id TEXT,
    node_name TEXT,
    agent_ip TEXT,
    agent_port TEXT,
    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    region TEXT DEFAULT 'UNKNOWN',
    node_alias TEXT,
    enable_google TEXT DEFAULT 'true',
    enable_trust TEXT DEFAULT 'true',
    enable_ota TEXT DEFAULT 'false',
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

# 写入看门狗 Cron (容错版)
crontab -l 2>/dev/null | grep -v "tg_master.sh" > /tmp/cron_master || true
echo "* * * * * pgrep -f tg_master.sh >/dev/null || nohup bash ${MASTER_DIR}/tg_master.sh >/dev/null 2>&1 &" >> /tmp/cron_master
[ -f /tmp/cron_master ] && crontab /tmp/cron_master 2>/dev/null
rm -f /tmp/cron_master

# 立刻启动 (追加 disown 彻底脱离终端管控，实现绝对静默)
pgrep -f tg_master.sh >/dev/null || { nohup bash "${MASTER_DIR}/tg_master.sh" >/dev/null 2>&1 & disown 2>/dev/null; }

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