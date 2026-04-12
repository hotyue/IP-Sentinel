#!/bin/bash
set -e

# ==========================================================
# IP-Sentinel Master Entrypoint Script
# 读取环境变量并启动Master控制中心
# ==========================================================

MASTER_DIR="/opt/ip_sentinel_master"
CONF_FILE="${MASTER_DIR}/master.conf"
DB_FILE="${MASTER_DIR}/data/nodes.db"

echo "🚀 IP-Sentinel Master 启动中..."

# 验证必需的环境变量
if [ -z "$TG_TOKEN" ]; then
    echo "❌ 错误: TG_TOKEN 必须设置!"
    exit 1
fi

if [ -z "$MASTER_PORT" ]; then
    echo "⚠️ 警告: MASTER_PORT 未设置，默认为 8080"
    MASTER_PORT="8080"
fi

# 创建必要的目录
mkdir -p "${MASTER_DIR}/logs"
mkdir -p "${MASTER_DIR}/data"

# 初始化 SQLite 数据库
if [ ! -f "$DB_FILE" ]; then
    echo "📦 初始化 SQLite 数据库..."
    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS nodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    node_name TEXT NOT NULL,
    agent_ip TEXT NOT NULL,
    agent_port TEXT NOT NULL,
    last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    region TEXT DEFAULT 'UNKNOWN',
    UNIQUE(chat_id, node_name)
);
CREATE INDEX IF NOT EXISTS idx_chat_id ON nodes(chat_id);
CREATE INDEX IF NOT EXISTS idx_region ON nodes(region);
EOF
    echo "✅ 数据库已初始化: ${DB_FILE}"
fi

# 生成配置文件
cat > "${CONF_FILE}" << EOF
# IP-Sentinel Master 配置文件
# 由 Docker entrypoint 自动生成

TG_TOKEN="${TG_TOKEN}"
MASTER_PORT="${MASTER_PORT}"
MASTER_DIR="${MASTER_DIR}"
DB_FILE="${DB_FILE}"
EOF

echo "✅ 配置文件已生成: ${CONF_FILE}"
echo "🔌 Master 端口: ${MASTER_PORT}"
echo "🗄️ 数据库: ${DB_FILE}"

# 启动 tg_master.sh 主服务
echo "🧠 启动 IP-Sentinel Master 控制中心..."
nohup bash "${MASTER_DIR}/tg_master.sh" > "${MASTER_DIR}/logs/tg_master.log" 2>&1 &

# 记录进程ID
echo $! > "${MASTER_DIR}/.master_pid"

echo "✅ IP-Sentinel Master 已启动，司令部开始运作..."
echo "📊 查看日志: docker exec -it \$(docker ps -q -f name=ip-sentinel-master) tail -f /opt/ip_sentinel_master/logs/tg_master.log"

# 保持容器运行
tail -f /dev/null & 
wait $!