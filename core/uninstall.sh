#!/bin/bash

# ==========================================================
# 脚本名称: uninstall.sh (IP-Sentinel 一键卸载脚本 - 动态锚点版)
# 核心功能: 无痕清理守护进程、定时任务、运行目录及临时缓存
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"

echo "========================================================"
echo "      🗑️ 准备卸载 IP-Sentinel (边缘节点 Edge Agent)"

# [核心: 动态读取并播报即将销毁的本地版本号]
CONFIG_FILE="${INSTALL_DIR}/config.conf"
if [ -f "$CONFIG_FILE" ]; then
    CURRENT_VER=$(grep "^AGENT_VERSION=" "$CONFIG_FILE" | cut -d'"' -f2)
    [ -n "$CURRENT_VER" ] && echo "        📍 目标版本: v${CURRENT_VER}"
fi
echo "========================================================"

# 1. 停止运行中的守护进程与主控模块 (涵盖所有历史版本进程)
echo "[1/3] 正在终止后台守护进程与所有养护任务..."

# 使用 pkill 替代传统的 pgrep | xargs，指令更短、容错率更高
pkill -9 -f "tg_daemon.sh" >/dev/null 2>&1
pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1
# [v3.4.0 优化] 确保清理所有 python3 调起的 Webhook 实例
pkill -9 -f "python3.*webhook.py" >/dev/null 2>&1
pkill -9 -f "webhook.py" >/dev/null 2>&1
pkill -9 -f "runner.sh" >/dev/null 2>&1
pkill -9 -f "updater.sh" >/dev/null 2>&1
pkill -9 -f "tg_report.sh" >/dev/null 2>&1
pkill -9 -f "mod_google.sh" >/dev/null 2>&1
pkill -9 -f "mod_trust.sh" >/dev/null 2>&1

# 2. 清除系统定时任务 (Cron)
echo "[2/3] 正在清理系统定时任务 (Cron)..."
if crontab -l >/dev/null 2>&1; then
    crontab -l | grep -v "ip_sentinel" > /tmp/cron_backup
    crontab /tmp/cron_backup
    rm -f /tmp/cron_backup
fi

# 3. 删除所有文件、日志与临时缓存
echo "[3/3] 正在抹除核心程序、配置文件与系统痕迹..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

# 拔除 /tmp 目录下的所有更新下载临时文件和 V1/V2 遗留的偏移量记录
rm -f /tmp/ip_sentinel_*.txt
rm -f /tmp/ip_sentinel_*.json

echo "========================================================"
echo "✅ 卸载彻底完成！IP-Sentinel 已从您的系统中无痕移除。"
echo "💡 提示：如果安装时在防火墙放行了 Webhook 随机端口，请您按需手动关闭。"
echo "👋 感谢您的使用，期待未来再次为您守护资产！"
echo "========================================================"