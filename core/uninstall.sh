#!/bin/bash

# ==========================================================
# 脚本名称: uninstall.sh (IP-Sentinel 一键卸载脚本 - 动态锚点版)
# 核心功能: 无痕清理守护进程、定时任务、运行目录及临时缓存
# ==========================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 卸载 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请使用 \033[36msudo bash -c \"\$(curl -fsSL ...)\"\033[0m 或切换到 root 执行。"
  exit 1
fi

INSTALL_DIR="/opt/ip_sentinel"

echo "========================================================"
echo "      🗑️ 准备卸载 IP-Sentinel (边缘节点 Edge Agent)"

CONFIG_FILE="${INSTALL_DIR}/config.conf"
if [ -f "$CONFIG_FILE" ]; then
    CURRENT_VER=$(grep "^AGENT_VERSION=" "$CONFIG_FILE" | cut -d'"' -f2)
    [ -n "$CURRENT_VER" ] && echo "        📍 目标版本: v${CURRENT_VER}"
fi
echo "========================================================"

echo "[1/3] 正在终止后台守护进程与 Systemd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now ip-sentinel-runner.service ip-sentinel-runner.timer \
        ip-sentinel-updater.service ip-sentinel-updater.timer \
        ip-sentinel-report.service ip-sentinel-report.timer \
        ip-sentinel-agent-daemon.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ip-sentinel-*.service
    rm -f /etc/systemd/system/ip-sentinel-*.timer
    systemctl daemon-reload
    systemctl reset-failed
fi

pkill -9 -f "tg_daemon.sh" >/dev/null 2>&1
pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1
pkill -9 -f "python3.*webhook.py" >/dev/null 2>&1
pkill -9 -f "webhook.py" >/dev/null 2>&1
pkill -9 -f "runner.sh" >/dev/null 2>&1
pkill -9 -f "updater.sh" >/dev/null 2>&1
pkill -9 -f "tg_report.sh" >/dev/null 2>&1
pkill -9 -f "mod_google.sh" >/dev/null 2>&1
pkill -9 -f "mod_trust.sh" >/dev/null 2>&1

echo "[2/3] 正在清理系统定时任务 (Cron)..."
if crontab -l >/dev/null 2>&1; then
    crontab -l | grep -v "ip_sentinel" > /tmp/cron_backup
    crontab /tmp/cron_backup
    rm -f /tmp/cron_backup
fi

echo "[3/3] 正在抹除核心程序、配置文件与系统痕迹..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

rm -f /tmp/ip_sentinel_*.txt
rm -f /tmp/ip_sentinel_*.json

echo "========================================================"
echo "✅ 卸载彻底完成！IP-Sentinel 已从您的系统中无痕移除。"
echo "💡 提示：如果安装时在防火墙放行了 Webhook 随机端口，请按需手动关闭。"
echo "========================================================"