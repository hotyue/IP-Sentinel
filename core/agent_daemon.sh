#!/bin/bash

# ==========================================================
# 脚本名称: agent_daemon.sh (受控节点 Webhook 守护进程 V2.0)
# 核心功能: 智能防打扰注册、进程自检、模块级路由分发(403拦截)
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
IP_CACHE="${INSTALL_DIR}/core/.last_ip"

[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

# 如果没有配置 TG，说明未开启联控模式，直接退出
[ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ] && exit 0

# 默认 Webhook 监听端口
AGENT_PORT=${AGENT_PORT:-9527}
NODE_NAME=$(hostname | cut -c 1-15)

# --- [重点升级 1: 守护进程防冲突自检] ---
if pgrep -f "webhook.py $AGENT_PORT" > /dev/null; then
    exit 0
fi

# 1. 获取本机原生公网 IPv4 (强制去除所有不可见换行符和空格)
AGENT_IP=$(curl -4 -s -m 5 api.ip.sb/ip | tr -d '[:space:]')

if [ -n "$AGENT_IP" ]; then
    # --- [重点升级 2: 智能防打扰注册机制] ---
    LAST_IP=""
    [ -f "$IP_CACHE" ] && LAST_IP=$(cat "$IP_CACHE" | tr -d '[:space:]')

    # 只有当这是第一次运行，或者公网 IP 发生变动时，才发送 Telegram 申请
    if [ "$AGENT_IP" != "$LAST_IP" ]; then
        REG_MSG="👋 **[边缘节点接入申请]**%0A节点: \`${NODE_NAME}\`%0A地址: \`${AGENT_IP}:${AGENT_PORT}\`%0A%0A⚠️ **安全验证**: 为防止非法节点接入，请长按复制下方代码，并**发送给我**以完成最终授权录入：%0A%0A\`#REGISTER#|${NODE_NAME}|${AGENT_IP}|${AGENT_PORT}\`"
        
        curl -s -m 5 -X POST "${TG_API_URL}" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=${REG_MSG}" \
            -d "parse_mode=Markdown" > /dev/null
        
        echo "✅ [Agent] 已向司令部发送接入申请，请在 Telegram 手机端完成授权！"
        echo "$AGENT_IP" > "$IP_CACHE"
    else
        echo "ℹ️ [Agent] IP 未变动 ($AGENT_IP)，跳过重复注册申请。"
    fi
fi

# 3. 启动轻量级 Python3 Webhook 监听服务 (带 403 权限校验路由)
cat > "${INSTALL_DIR}/core/webhook.py" << 'EOF'
import http.server
import socketserver
import subprocess
import sys
import os

PORT = int(sys.argv[1])

class AgentHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # 路由 1: Google 区域纠偏 (含老版 run 指令兼容)
        if self.path == '/trigger_google' or self.path == '/trigger_run':
            if os.path.exists('/opt/ip_sentinel/core/mod_google.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_google\n")
                subprocess.Popen(['bash', '/opt/ip_sentinel/core/mod_google.sh'])
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Google Module Disabled\n")

        # 路由 2: IP 信用净化
        elif self.path == '/trigger_trust':
            if os.path.exists('/opt/ip_sentinel/core/mod_trust.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_trust\n")
                subprocess.Popen(['bash', '/opt/ip_sentinel/core/mod_trust.sh'])
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Trust Module Disabled\n")

        # 路由 3: 触发战报推送
        elif self.path == '/trigger_report':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: tg_report\n")
            subprocess.Popen(['bash', '/opt/ip_sentinel/core/tg_report.sh'])

        # 路由 4: 抓取并回传实时日志
        elif self.path == '/trigger_log':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: fetch_log\n")
            bash_cmd = """
            source /opt/ip_sentinel/config.conf
            LOG_DATA=$(tail -n 15 /opt/ip_sentinel/logs/sentinel.log)
            NODE=$(hostname | cut -c 1-15)
            curl -s -X POST "${TG_API_URL}" \
                -d "chat_id=${CHAT_ID}" \
                -d "text=📄 **[${NODE}] 实时运行日志:**%0A\`\`\`log%0A${LOG_DATA}%0A\`\`\`" \
                -d "parse_mode=Markdown"
            """
            subprocess.Popen(['bash', '-c', bash_cmd])
            
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

try:
    with socketserver.TCPServer(("", PORT), AgentHandler) as httpd:
        httpd.serve_forever()
except Exception as e:
    sys.exit(1)
EOF

# --- [重点升级 3: 真正的静默后台启动] ---
echo "🚀 [Agent] 正在后台启动 Webhook 监听服务 (端口: $AGENT_PORT)..."
nohup python3 "${INSTALL_DIR}/core/webhook.py" "$AGENT_PORT" > /dev/null 2>&1 &
disown 2>/dev/null || true
echo "✅ [Agent] 守护进程启动完毕，可安全关闭终端。"