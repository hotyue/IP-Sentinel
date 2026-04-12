#!/bin/bash

# ==========================================================
# 脚本名称: agent_daemon.sh (受控节点 Webhook 守护进程 V3.0.3)
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

# 1. [v3.0.1修复] 严格按照 install.sh 锁定的网络协议 (v4/v6) 获取 IP
RAW_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')

# 为新获取到的 v6 自动加方括号，以确保与之前锁定的格式对齐比对
if [[ "$RAW_IP" == *":"* ]] && [[ "$RAW_IP" != *"["* ]]; then
    AGENT_IP="[${RAW_IP}]"
else
    AGENT_IP="$RAW_IP"
fi

if [ -n "$AGENT_IP" ]; then
    # --- [重点升级 2: 智能防打扰注册机制] ---
    LAST_IP=""
    [ -f "$IP_CACHE" ] && LAST_IP=$(cat "$IP_CACHE" | tr -d '[:space:]')

    # 只有当这是第一次运行，或者公网 IP 发生变动时，才发送 Telegram 申请
    if [ "$AGENT_IP" != "$LAST_IP" ]; then
        # V3.1.3 协议升级: 在底部暗号中精准嵌入 ${REGION_CODE} 大区标识
        REG_MSG="👋 **[边缘节点接入申请]**%0A大区: \`${REGION_CODE}\`%0A节点: \`${NODE_NAME}\`%0A地址: \`${AGENT_IP}:${AGENT_PORT}\`%0A%0A⚠️ **安全验证**: 为防止非法节点接入，请长按复制下方代码，并**发送给我**以完成最终授权录入：%0A%0A\`#REGISTER#|${REGION_CODE}|${NODE_NAME}|${AGENT_IP}|${AGENT_PORT}\`"
        
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

# 🛡️ [安全修复] 路径遍历防护：验证 INSTALL_DIR 合法性
validate_install_dir() {
    local dir="$1"
    # 确保路径以 /opt/ip_sentinel 开头
    if [[ "$dir" != /opt/ip_sentinel* ]]; then
        echo "错误：非法的安装目录"
        exit 1
    fi
    # 确保路径不包含 .. 或 ~
    if [[ "$dir" == *".."* ]] || [[ "$dir" == *"~"* ]]; then
        echo "错误：路径包含非法字符"
        exit 1
    fi
}
validate_install_dir "$INSTALL_DIR"

# 3. 启动轻量级 Python3 Webhook 监听服务 (v3.0.4 动态 HMAC 签名防重放)
cat > "${INSTALL_DIR}/core/webhook.py" << 'EOF'
import http.server
import socketserver
import subprocess
import sys
import os
import html
# ================== [v3.0.4 新增密码学与解析依赖] ==================
import urllib.parse
import urllib.request  # [修复] 提升至全局作用域，防止局部变量遮蔽
import hmac
import hashlib
import time
# ====================================================================

PORT = int(sys.argv[1])

# 🛡️ 提取全局鉴权 Token (利用 CHAT_ID 作为 PSK 预共享密钥)
AUTH_TOKEN = ""
if os.path.exists('/opt/ip_sentinel/config.conf'):
    with open('/opt/ip_sentinel/config.conf', 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('CHAT_ID='):
                AUTH_TOKEN = line.split('=', 1)[1].strip('"\'')
                break

class AgentHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # 🛡️ [v3.0.4 核心] URL 解析与动态 HMAC-SHA256 签名校验
        parsed = urllib.parse.urlparse(self.path)
        req_path = parsed.path
        
        if AUTH_TOKEN:
            query = urllib.parse.parse_qs(parsed.query)
            req_t = query.get('t', [''])[0]
            req_sign = query.get('sign', [''])[0]
            
            # 校验 1：参数是否齐全
            if not req_t or not req_sign:
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b"401 Unauthorized: Missing Signature\n")
                return
                
            try:
                # 校验 2：时间戳防重放 (误差 ±60秒 内有效，拒绝隔夜抓包重放)
                if abs(int(time.time()) - int(req_t)) > 60:
                    self.send_response(401)
                    self.end_headers()
                    self.wfile.write(b"401 Unauthorized: Request Expired\n")
                    return
            except ValueError:
                self.send_response(401)
                self.end_headers()
                return
                
            # 校验 3：HMAC 数据完整性与身份合法性校验
            msg = f"{req_path}:{req_t}".encode('utf-8')
            expected_sign = hmac.new(AUTH_TOKEN.encode('utf-8'), msg, hashlib.sha256).hexdigest()
            
            # 使用 compare_digest 防御时序攻击
            if not hmac.compare_digest(expected_sign, req_sign):
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b"401 Unauthorized: Signature Mismatch\n")
                return

        # ================== 路由分发 (恢复为安全的精确匹配) ==================
        # 🛡️ [安全修复] 任意代码执行防护：使用命令白名单和路径校验
        import os as os_module
        
        # 定义允许执行的脚本白名单
        ALLOWED_SCRIPTS = {
            '/trigger_run': '/opt/ip_sentinel/core/runner.sh',
            '/trigger_google': '/opt/ip_sentinel/core/mod_google.sh',
            '/trigger_trust': '/opt/ip_sentinel/core/mod_trust.sh',
            '/trigger_report': '/opt/ip_sentinel/core/tg_report.sh'
        }
        
        def execute_script(trigger_path):
            """安全执行脚本，带白名单和路径校验"""
            if trigger_path not in ALLOWED_SCRIPTS:
                return None, "Not Found"
            
            script_path = ALLOWED_SCRIPTS[trigger_path]
            
            # 验证脚本路径合法性：必须以/opt/ip_sentinel/core/开头
            if not script_path.startswith('/opt/ip_sentinel/core/'):
                return None, "Invalid Path"
            
            # 验证文件存在且不是软链接（防止路径欺骗）
            if not os_module.path.isfile(script_path) or os_module.path.islink(script_path):
                return None, "Disabled"
            
            try:
                subprocess.Popen(['bash', script_path])
                return True, "OK"
            except Exception as e:
                return None, str(e)
        
        # 路由 0: 全局统筹调度 (处理 /trigger_run 一键全节点维护)
        if req_path == '/trigger_run':
            result, status = execute_script(req_path)
            if result:
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: runner\n")
            elif status == "Disabled":
                self.send_response(404)
                self.end_headers()
            else:
                self.send_response(500)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(f"500 Error: {status}\n".encode())
                
        # 路由 1: Google 区域纠偏
        elif req_path == '/trigger_google':
            result, status = execute_script(req_path)
            if result:
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_google\n")
            elif status == "Disabled":
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Google Module Disabled\n")
            else:
                self.send_response(500)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(f"500 Error: {status}\n".encode())

        # 路由 2: IP 信用净化
        elif req_path == '/trigger_trust':
            result, status = execute_script(req_path)
            if result:
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_trust\n")
            elif status == "Disabled":
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Trust Module Disabled\n")
            else:
                self.send_response(500)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(f"500 Error: {status}\n".encode())

        # 路由 3: 触发战报推送
        elif req_path == '/trigger_report':
            # 🛡️ [安全修复] 使用白名单函数执行
            result, status = execute_script(req_path)
            if result:
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: tg_report\n")
            else:
                self.send_response(500)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(f"500 Error: {status}\n".encode())

        # 路由 4: 抓取并回传实时日志
        elif req_path == '/trigger_log':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: fetch_log\n")
                        
            try:
                config = {}
                if os.path.exists('/opt/ip_sentinel/config.conf'):
                    with open('/opt/ip_sentinel/config.conf', 'r') as f:
                        for line in f:
                            line = line.strip()
                            if '=' in line and not line.startswith('#'):
                                key, val = line.split('=', 1)
                                config[key] = val.strip('"\'')
                
                log_data = "日志文件不存在或为空"
                log_path = '/opt/ip_sentinel/logs/sentinel.log'
                if os.path.exists(log_path):
                    with open(log_path, 'r', errors='ignore') as f:
                        lines = f.readlines()
                        if lines:
                            log_data = html.escape("".join(lines[-15:]))
                
                node_name = subprocess.check_output(['hostname']).decode('utf-8').strip()[:15]
                text_msg = f"📄 <b>[{node_name}] 实时运行日志:</b>\n<pre><code>{log_data}</code></pre>"
                
                data = urllib.parse.urlencode({
                    'chat_id': config.get('CHAT_ID', ''),
                    'text': text_msg,
                    'parse_mode': 'HTML'
                }).encode('utf-8')
                
                req = urllib.request.Request(
                    config.get('TG_API_URL', ''), 
                    data=data,
                    headers={'User-Agent': 'IP-Sentinel-Agent/3.0.4'}
                )
                urllib.request.urlopen(req, timeout=10)
                
            except Exception as e:
                print(f"Log transmission failed: {e}")
            
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

import socket
# ================== [v3.0.3 变更: 引入多线程模型抵抗 Slowloris 攻击] ==================
class ThreadedDualStackServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True # 开启端口复用，防止热重启时端口冲突
    address_family = socket.AF_INET6 if socket.has_ipv6 else socket.AF_INET

try:
    bind_addr = "::" if socket.has_ipv6 else ""
    with ThreadedDualStackServer((bind_addr, PORT), AgentHandler) as httpd:
        httpd.serve_forever()
except Exception as e:
    sys.exit(1)
# ====================================================================================
EOF

# --- [重点升级 3: 真正的静默后台启动] ---
echo "🚀 [Agent] 正在后台启动 Webhook 监听服务 (端口: $AGENT_PORT)..."
nohup python3 "${INSTALL_DIR}/core/webhook.py" "$AGENT_PORT" > /dev/null 2>&1 &
disown 2>/dev/null || true
echo "✅ [Agent] 守护进程启动完毕，可安全关闭终端。"