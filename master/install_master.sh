#!/bin/bash

# ==========================================================
# 脚本名称: install_master.sh (IP-Sentinel 控制中枢部署脚本 - 动态锚点版)
# 核心功能: 部署/卸载调度中枢、SQLite 资产管理、平滑热更新引擎
# ==========================================================

# ==========================================================
# 🛑 核心权限防线: 检查是否以 root 权限运行
# ==========================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

# 🟢 [防劫持沙盒] 引入司令部专属随机安全工作区
SECURE_TMP=$(mktemp -d /tmp/ips_master_install.XXXXXX)
trap 'rm -rf "$SECURE_TMP"' EXIT HUP INT QUIT TERM

# 你的 GitHub 仓库 Raw 数据直链前缀
REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为开发地址用于测试
# REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/v3.6.2-rc"

# [核心: 动态提取 Master 专属版本锚点 (KV 解析法)]
# 通过 grep 定位 MASTER_VERSION 行，再通过 cut 提取等号右侧的值
# [修复] 增加 -L 与双栈容灾 (-4)，解决纯 V6 或 V6 优先机器连接 GitHub Raw 易超时的问题
TARGET_VERSION=$( (curl -sL -m 5 "${REPO_RAW_URL}/version.txt" || curl -4 -sL -m 5 "${REPO_RAW_URL}/version.txt") 2>/dev/null | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')

# 🛡️ 兜底防线：如果网络波动拉取失败，启用内置的最新兜底版本
TARGET_VERSION=${TARGET_VERSION:-"4.0.0"}

MASTER_DIR="/opt/ip_sentinel_master"
DB_FILE="${MASTER_DIR}/sentinel.db"

echo "========================================================"
# [修改] 将欢迎语改为更通用的文案，因为现在不仅能部署，还能卸载
echo "      🧠 欢迎使用 IP-Sentinel Master (控制中枢) v${TARGET_VERSION}"
echo "========================================================"

# ==========================================================
# [v3.6.1 核心] 拦截司令部静默 OTA 升级模式 (强行接管执行流)
# ==========================================================
if [ "$SILENT_MASTER_OTA" == "true" ]; then
    echo -e "\n⏳ [OTA] 中枢重构指令已确认，正在剥离控制台交互..."
    ACTION_CHOICE=1
    UPGRADE_MODE="true"
    KEEP_DB="true"
    
    # 汲取原配置进入内存
    if [ -f "${MASTER_DIR}/master.conf" ]; then
        source "${MASTER_DIR}/master.conf"
        
        # 同步新版本号至配置文件
        if grep -q "^MASTER_VERSION=" "${MASTER_DIR}/master.conf"; then
            sed -i "s/^MASTER_VERSION=.*/MASTER_VERSION=\"$TARGET_VERSION\"/" "${MASTER_DIR}/master.conf"
        else
            echo "MASTER_VERSION=\"$TARGET_VERSION\"" >> "${MASTER_DIR}/master.conf"
        fi
    fi
    echo -e "\033[32m✅ 已激活 [中枢静默重构模式]，即将无损覆写内核...\033[0m"
else
    # [新增] 交互式操作菜单：支持选择部署或调用卸载程序
    echo -e "\n请选择操作:"
    echo "  1) 🚀 部署 Master 控制中枢"
    echo "  2) 🗑️ 一键卸载 Master 中枢"
    read -p "请输入选择 [1-2] (默认1): " ACTION_CHOICE

    # [v3.5.2 修复] 防止用户直接回车导致变量为空，从而漏过下方的平滑升级判定被误删档
    ACTION_CHOICE=${ACTION_CHOICE:-1}

    if [ "$ACTION_CHOICE" == "2" ]; then
        echo -e "\n⏳ 正在拉取卸载程序..."
        curl -sL "${REPO_RAW_URL}/master/uninstall_master.sh" -o "${SECURE_TMP}/uninstall_master.sh"
        chmod +x "${SECURE_TMP}/uninstall_master.sh"
        bash "${SECURE_TMP}/uninstall_master.sh"
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
            
            source "${MASTER_DIR}/master.conf"
            
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
fi

# ================== [v3.2.2 优化: 数据纯净度清理与保护] ==================
echo -e "\n⏳ 正在验证本地环境与数据..."

if [ "$UPGRADE_MODE" == "true" ]; then
    if [ "$KEEP_DB" == "false" ]; then
        rm -f "$DB_FILE" 2>/dev/null
        echo -e "🗑️ 历史节点数据库已按指令清空。"
    else
        echo -e "📦 历史节点数据库 (SQLite) 已绝密保留。"
    fi
    # [防砖修复] 移除过早的旧进程抹杀与脚本物理删除，防止拉取失败导致司令部变砖失联
else
    # 焦土政策：如果不是升级模式，直接扬了整个司令部目录
    rm -rf "$MASTER_DIR" 2>/dev/null
fi
# =======================================================================

# 1. 依赖检查与智能安装 (v3.6.0 兼容性与优雅性升级)
echo -e "\n[1/4] 正在探测核心依赖 (curl, jq, sqlite3, crontab, pgrep, openssl)..."

REQUIRED_CMDS=("curl" "jq" "sqlite3" "crontab" "pgrep" "openssl")
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
        # [v3.6.3 抽脂级优化] 注入 --no-install-recommends 拒绝捆绑销售
        apt-get install -y --no-install-recommends curl jq sqlite3 cron procps openssl >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        PKG_MGR="yum"
        OPT_ARGS=""
        if command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
            # [v3.6.3 抽脂级优化] 强行关闭 DNF 的弱依赖拉取
            OPT_ARGS="--setopt=install_weak_deps=False"
        fi
        $PKG_MGR install -y $OPT_ARGS curl jq sqlite cronie procps-ng openssl >/dev/null 2>&1
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        echo "Alpine 探测到系统类型为 Alpine Linux，正在执行轻量级安装..."
        # [修复] 优先尝试 cronie，若失败则回退至系统内置 cron，彻底避免单点依赖拖垮全局
        apk add --no-cache curl jq sqlite cronie procps bash openssl || apk add --no-cache curl jq sqlite procps bash openssl
        mkdir -p /var/spool/cron/crontabs
        rc-update add crond default >/dev/null 2>&1
        service crond start >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl jq sqlite cronie procps-ng openssl >/dev/null 2>&1
        mkdir -p /root/.cache/crontab 2>/dev/null
        systemctl enable cronie >/dev/null 2>&1 && systemctl start cronie >/dev/null 2>&1
    else
        echo -e "\033[31m❌ 自动安装失败：系统未知的包管理器。\033[0m"
        echo -e "\033[33m⚠️ 请手动执行以下安装命令后重新运行本脚本：\033[0m"
        echo -e "  Debian/Ubuntu: \033[36mapt-get update && apt-get install -y --no-install-recommends curl jq sqlite3 cron procps openssl\033[0m"
        echo -e "  CentOS/RHEL:   \033[36myum install -y curl jq sqlite cronie procps-ng openssl\033[0m"
        echo -e "  Alpine Linux:  \033[36mapk add --no-cache curl jq sqlite cronie procps bash openssl\033[0m"
        echo -e "  Arch Linux:    \033[36mpacman -Sy curl jq sqlite cronie procps-ng openssl\033[0m"
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
    ENABLE_MASTER_OTA="false"
    if [ "$GATEWAY_TYPE" == "2" ]; then
        IS_OFFICIAL_GATEWAY="true"
        echo -e "\033[33m⚠️ 已开启官方公共网关模式，全舰队与司令部的 OTA 将被强制屏蔽。\033[0m"
    else
        # [v3.6.1] 私有模式开放中枢 OTA 授权向导
        echo -e "\n[2.1/4] 司令部自我进化授权"
        echo -e "💡 开启后，您可以在 TG 菜单一键将中枢核心系统热更新至最新版本。"
        read -p "是否允许司令部接收 OTA 重构指令？(y/n, 默认y): " M_OTA_CHOICE
        if [[ "$M_OTA_CHOICE" =~ ^[Nn]$ ]]; then
            ENABLE_MASTER_OTA="false"
            echo -e "🛡️ \033[33m已关闭司令部 OTA 权限，中枢内核未来仅支持 SSH 升级。\033[0m"
        else
            ENABLE_MASTER_OTA="true"
            echo -e "✅ \033[32m已开启司令部 OTA 权限，金蝉脱壳引信已挂载。\033[0m"
        fi
    fi

    cat > "${MASTER_DIR}/master.conf" << EOF
# IP-Sentinel Master 本地固化配置 (v${TARGET_VERSION})
MASTER_VERSION="$TARGET_VERSION"
TG_TOKEN="$TG_TOKEN"
DB_FILE="$DB_FILE"
MASTER_DIR="$MASTER_DIR"
# [v3.6.0 核心] 官方网关 UI 熔断标识
IS_OFFICIAL_GATEWAY="$IS_OFFICIAL_GATEWAY"
# [v3.6.1 新增] 司令部自身 OTA 授权标识
ENABLE_MASTER_OTA="$ENABLE_MASTER_OTA"
EOF
fi

# [v3.6.1 热修复] 老司令部平滑升级时，自动补齐缺失字段
if [ "$UPGRADE_MODE" == "true" ]; then
    if ! grep -q "^IS_OFFICIAL_GATEWAY=" "${MASTER_DIR}/master.conf"; then
        echo "IS_OFFICIAL_GATEWAY=\"false\"" >> "${MASTER_DIR}/master.conf"
    fi
    if ! grep -q "^ENABLE_MASTER_OTA=" "${MASTER_DIR}/master.conf"; then
        echo "ENABLE_MASTER_OTA=\"false\"" >> "${MASTER_DIR}/master.conf"
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

-- [v4.0.0 新增, v4.0.2 扩容] 核心情报表：记录历史 IP 质量数据，用于绘制趋势图
CREATE TABLE IF NOT EXISTS ip_trend_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_name TEXT,
    check_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    scam_score INTEGER,
    goog_status TEXT,
    nf_status TEXT,
    gpt_status TEXT
);
EOF
echo "✅ 数据库创建成功: $DB_FILE"

# ================== [v3.0.3 变更: 敏感文件权限收敛] ==================
chmod 600 "${MASTER_DIR}/master.conf"
chmod 600 "$DB_FILE"
# ====================================================================

# 4. 拉取核心调度代码并执行原子化交接
echo -e "\n[4/4] 正在拉取新版司令部核心引擎..."

TMP_MASTER="${SECURE_TMP}/tg_master.sh"
curl -sL "${REPO_RAW_URL}/master/tg_master.sh" -o "$TMP_MASTER"

# 🛡️ 防砖终极校验
if [ ! -s "$TMP_MASTER" ]; then
    echo -e "\033[31m❌ 致命错误：中枢核心代码拉取失败！网络阻断或 GitHub Raw 异常。\033[0m"
    echo "🛡️ 防砖机制触发：已中止覆盖，旧版司令部仍在安全运行中。"
    rm -f "$TMP_MASTER"
    exit 1
fi

# 🟢 [原子化交接核心]: 校验完美通过，新代码已备妥！
# 以雷霆手段抹杀旧版调度进程，杜绝文件覆写时的并发错乱
echo "⏳ 新引擎校验通过，正在抹杀旧版守护进程..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl kill --signal=SIGKILL ip-sentinel-master.service >/dev/null 2>&1 || true
    systemctl stop ip-sentinel-master.service >/dev/null 2>&1 || true
fi
pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true

# 执行物理替换
mv "$TMP_MASTER" "${MASTER_DIR}/tg_master.sh"
chmod +x "${MASTER_DIR}/tg_master.sh"

if command -v systemctl >/dev/null 2>&1; then
    echo "💡 检测到 Systemd 环境，正在部署原生守护服务..."
    
    cat > /etc/systemd/system/ip-sentinel-master.service << EOF
[Unit]
Description=IP-Sentinel Master Command Center Service
After=network.target

[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=simple
ExecStart=/bin/bash ${MASTER_DIR}/tg_master.sh
Restart=always
RestartSec=5
User=root
WorkingDirectory=${MASTER_DIR}
CPUSchedulingPolicy=idle
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ip-sentinel-master.service
    systemctl restart ip-sentinel-master.service
    
    # 清理可能残留的历史 Cron (无落地内存流防劫持)
    crontab -l 2>/dev/null | grep -v "tg_master.sh" | crontab - >/dev/null 2>&1 || true
else
    echo "💡 未检测到 Systemd，回退到 Cron 看门狗调度模式..."
    crontab -l 2>/dev/null | grep -v "tg_master.sh" > "${SECURE_TMP}/cron_master" || true
    echo "* * * * * pgrep -f tg_master.sh >/dev/null || nohup bash ${MASTER_DIR}/tg_master.sh >/dev/null 2>&1 &" >> "${SECURE_TMP}/cron_master"
    [ -f "${SECURE_TMP}/cron_master" ] && crontab "${SECURE_TMP}/cron_master" 2>/dev/null
    
    pgrep -f tg_master.sh >/dev/null || { nohup bash "${MASTER_DIR}/tg_master.sh" >/dev/null 2>&1 & disown 2>/dev/null; }
fi

# ================== [v3.2.2 优化 & v3.6.1 OTA捷报: 战报文案分流] ==================
echo "========================================================"
if [ "$UPGRADE_MODE" == "true" ]; then
    echo "🎉 Master 控制中枢平滑热更新完成！"
    echo "🤖 新版中枢引擎已接管数据库，继续等待边缘节点汇报。"
    
    # [v3.6.1 核心] 静默 OTA 完成后，由幽灵进程主动向指挥官发送捷报
    if [ "$SILENT_MASTER_OTA" == "true" ] && [ -n "$OTA_CHAT_ID" ] && [ -n "$TG_TOKEN" ]; then
        echo -e "\n📡 正在向指挥官发送司令部重构捷报..."
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d "chat_id=${OTA_CHAT_ID}" \
            -d "parse_mode=Markdown" \
            -d "text=✨ *司令部中枢热重载完成！*
🚀 当前内核已跃升至：\`v${TARGET_VERSION}\`
🤖 新版金蝉脱壳引擎已接管阵地，全舰队指控链路恢复正常。" > /dev/null
    fi
else
    echo "🎉 Master 控制中枢部署完成！"
    echo "🤖 机器人现已开始全局接客，等待边缘节点注册。"
fi
echo "========================================================"
# =================================================================

# ================== [v3.1.2 新增: 玻璃房透明装机统计] ==================
# [修复] 仅在全新部署时触发统计，司令部热重载时绝对不触发
if [ "$UPGRADE_MODE" == "false" ]; then
    echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
    MASTER_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/master" || echo "")

    if [ -n "$MASTER_COUNT" ] && [[ "$MASTER_COUNT" =~ ^[0-9]+$ ]]; then
        echo -e "\033[32m✅ 感谢您成为全球第 ${MASTER_COUNT} 名 IP-Sentinel 指挥官！\033[0m"
    else
        echo -e "\033[32m✅ 感谢您建立 IP-Sentinel 司令部！\033[0m"
    fi
    echo -e "\n"
fi
