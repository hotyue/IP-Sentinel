#!/bin/bash

# ==========================================================
# 脚本名称: uninstall_master.sh (IP-Sentinel Master 一键卸载脚本 - 动态锚点版)
# 核心功能: 终止调度进程、清理看门狗定时任务、抹除数据库与配置
# ==========================================================

# ==========================================================
# 🛑 核心权限防线: 检查是否以 root 权限运行
# ==========================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 卸载 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

MASTER_DIR="/opt/ip_sentinel_master"
CONF_FILE="${MASTER_DIR}/master.conf"

echo "========================================================"
echo "      🗑️ 准备卸载 IP-Sentinel Master (控制中枢)"

# [v3.4.0 优化] 卸载前读取并播报中枢版本号
if [ -f "$CONF_FILE" ]; then
    MASTER_VER=$(grep "^MASTER_VERSION=" "$CONF_FILE" | cut -d'"' -f2)
    [ -n "$MASTER_VER" ] && echo "        📍 目标版本: v${MASTER_VER}"
fi
echo "========================================================"

echo -e "\n⚠️ 警告: 此操作将永久删除包含所有节点档案的 SQLite 数据库！"
read -p "确定要继续卸载吗？(y/n) [默认 n]: " CONFIRM_DEL
if [[ ! "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
    echo "已取消卸载操作。"
    exit 0
fi

# 1. 停止并删除 Systemd 服务 (适配新架构)
echo "[1/4] 正在停止并删除 Systemd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    echo "💡 检测到 Systemd 环境，正在抹除 Systemd 服务单元..."
    # [防死锁修复] 先发送 SIGKILL 瞬间抹杀，防止卡死
    systemctl kill --signal=SIGKILL ip-sentinel-master.service >/dev/null 2>&1 || true
    systemctl disable --now ip-sentinel-master.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ip-sentinel-master.service
    systemctl daemon-reload
    systemctl reset-failed
else
    echo "💡 未检测到 Systemd，跳过此步骤..."
fi

# 2. 停止运行中的 Master 守护进程 (兜底清理老版进程)
echo "[2/4] 正在终止后台中枢调度进程..."
pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true

# 3. 清除看门狗定时任务 (Cron)
echo "[3/4] 正在清理系统定时任务 (Cron)..."
# [终极防御] 内存管道流过滤，绝不写硬盘
crontab -l 2>/dev/null | grep -v "tg_master.sh" | crontab - >/dev/null 2>&1 || true

# 4. 删除所有文件、配置与数据库
echo "[4/4] 正在抹除核心程序、配置文件与 SQLite 数据库..."
if [ -d "$MASTER_DIR" ]; then
    rm -rf "$MASTER_DIR"
fi

echo "========================================================"
echo "✅ 卸载彻底完成！Master 司令部已从您的系统中无痕移除。"
echo "========================================================"