#!/bin/bash
set -e

# ==========================================================
# IP-Sentinel Agent Entrypoint Script
# 读取环境变量并启动哨兵节点
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

echo "🚀 IP-Sentinel Agent 启动中..."

# 验证必需的环境变量
if [ -z "$REGION_CODE" ]; then
    echo "⚠️ 警告: REGION_CODE 未设置，默认为 UNKNOWN"
    REGION_CODE="UNKNOWN"
fi

if [ -z "$BIND_IP" ]; then
    echo "⚠️ 警告: BIND_IP 未设置，将自动检测"
    BIND_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
fi

if [ -z "$AGENT_PORT" ]; then
    echo "⚠️ 警告: AGENT_PORT 未设置，默认为 9527"
    AGENT_PORT="9527"
fi

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 警告: TG_TOKEN 或 CHAT_ID 未设置，部分功能可能受限"
fi

# 设置功能开关，默认为 true
ENABLE_GOOGLE=${ENABLE_GOOGLE:-true}
ENABLE_TRUST=${ENABLE_TRUST:-true}

# 创建配置目录
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/logs"

# 生成配置文件
cat > "${CONFIG_FILE}" << EOF
# IP-Sentinel Agent 配置文件
# 由 Docker entrypoint 自动生成

REGION_CODE="${REGION_CODE}"
BIND_IP="${BIND_IP}"
AGENT_PORT="${AGENT_PORT}"
TG_TOKEN="${TG_TOKEN}"
CHAT_ID="${CHAT_ID}"
ENABLE_GOOGLE="${ENABLE_GOOGLE}"
ENABLE_TRUST="${ENABLE_TRUST}"

# 日志配置
LOG_FILE="${INSTALL_DIR}/logs/agent.log"
EOF

echo "✅ 配置文件已生成: ${CONFIG_FILE}"
echo "📍 区域代码: ${REGION_CODE}"
echo "🌐 绑定 IP: ${BIND_IP}"
echo "🔌 端口: ${AGENT_PORT}"
echo "🔍 Google 纠偏: ${ENABLE_GOOGLE}"
echo "🛡️ 信用净化: ${ENABLE_TRUST}"

# 启动 cron 守护进程
echo "📅 启动 Cron 调度服务..."
cron

# 启动 tg_daemon.sh 后台报告服务（如果配置了 TG）
if [ -n "$TG_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    echo "📡 启动 TG 后台报告服务..."
    nohup bash "${INSTALL_DIR}/core/tg_daemon.sh" > "${INSTALL_DIR}/logs/tg_daemon.log" 2>&1 &
fi

# 启动 agent_daemon.sh 主守护进程
echo "🛡️ 启动 IP-Sentinel Agent 守护进程..."
nohup bash "${INSTALL_DIR}/core/agent_daemon.sh" > "${INSTALL_DIR}/logs/agent_daemon.log" 2>&1 &

# 保持容器运行
echo "✅ IP-Sentinel Agent 已启动，哨兵正在待命..."
echo "📊 查看日志: docker exec -it \$(docker ps -q -f name=ip-sentinel-agent) tail -f /opt/ip_sentinel/logs/agent.log"

# 等待并保持容器运行
tail -f /dev/null & 
wait $!