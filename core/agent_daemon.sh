#!/bin/bash

# ==========================================================
# 脚本名称: agent_daemon.sh (受控节点 Webhook 守护进程 - 动态锚点版)
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
# [v3.5.2 核心] 载入不可变主键与可变展示名 (双轨身份)
if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"


# 1. 尝试获取实时公网 IP
RAW_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')

# [v3.3.1 修改] 为新获取到的 v6 自动加方括号；如果网络波动没抓到，强制信任本地 config 中的公网面孔
if [ -n "$RAW_IP" ]; then
    if [[ "$RAW_IP" == *":"* ]] && [[ "$RAW_IP" != *"["* ]]; then
        AGENT_IP="[${RAW_IP}]"
    else
        AGENT_IP="$RAW_IP"
    fi
else
    AGENT_IP="${PUBLIC_IP:-${BIND_IP:-Unknown}}"
fi

if [ -n "$AGENT_IP" ]; then
    # --- [重点升级 2: 智能防打扰注册机制] ---
    LAST_IP=""
    [ -f "$IP_CACHE" ] && LAST_IP=$(cat "$IP_CACHE" | tr -d '[:space:]')

    # 只有当这是第一次运行，或者公网 IP 发生变动时，才发送 Telegram 申请
    if [ "$AGENT_IP" != "$LAST_IP" ]; then
        # [v3.6.0 核心修复] 携带 7 字段身份发起注册申请 (追加 ENABLE_OTA，防止 IP 变动重新注册时丢失 OTA 权限)
        REG_MSG="👋 **[边缘节点接入申请]**%0A大区: \`${REGION_CODE}\`%0A节点: \`${NODE_ALIAS}\`%0A地址: \`${AGENT_IP}:${AGENT_PORT}\`%0A%0A⚠️ **安全验证**: 为防止非法节点接入，请长按复制下方代码，并**发送给我**以完成最终授权录入：%0A%0A\`#REGISTER#|${REGION_CODE}|${NODE_NAME}|${AGENT_IP}|${AGENT_PORT}|${NODE_ALIAS}|${ENABLE_OTA:-false}\`"
        
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

# ================== [v3.6.3 新增: 自动生成自签名 TLS 加密证书] ==================
# [修复] 彻底废除官方网关免 TLS 的裸奔逻辑，全网强制生成证书装甲
CERT_FILE="${INSTALL_DIR}/core/cert.pem"
KEY_FILE="${INSTALL_DIR}/core/key.pem"
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "🔐 [Agent] 正在生成本地自签名 TLS 加密证书 (2048位 RSA)..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -subj "/C=US/O=IP-Sentinel/CN=Agent-Sec" >/dev/null 2>&1 || true
fi
# ==============================================================================

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
import urllib.request
import hmac
import hashlib
import time
# ====================================================================

PORT = int(sys.argv[1])

# 🛡️ 防重放攻击 (Nonce 缓存池)
USED_SIGNS = {}
def clean_used_signs():
    now = time.time()
    # 清理过期签名 (超 60 秒的安全窗口)
    expired = [s for s, t in USED_SIGNS.items() if now - t > 65]
    for s in expired:
        del USED_SIGNS[s]

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
                current_time = int(time.time())
                # 校验 2：时间戳防重放 (误差 ±60秒 内有效，拒绝隔夜抓包重放)
                if abs(current_time - int(req_t)) > 60:
                    self.send_response(401)
                    self.end_headers()
                    self.wfile.write(b"401 Unauthorized: Request Expired\n")
                    return
            except ValueError:
                self.send_response(401)
                self.end_headers()
                return
            
            # 校验 2.5：基于 60秒 窗口的精确重放拦截 (拦截 MITM 并发洗劫)
            clean_used_signs()
            if req_sign in USED_SIGNS:
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b"401 Unauthorized: Replay Attack Detected\n")
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
            
            # 鉴权通过，记录该签名至防重放内存池
            USED_SIGNS[req_sign] = current_time

        # ================== 路由分发 (恢复为安全的精确匹配) ==================
        
        # 路由 0: 全局统筹调度
        if req_path == '/trigger_run':
            if os.path.exists('/opt/ip_sentinel/core/runner.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: runner\n")
                os.system("nohup bash /opt/ip_sentinel/core/runner.sh >/dev/null 2>&1 &")
            else:
                self.send_response(404)
                self.end_headers()
                
        # 路由 1: Google 区域纠偏
        elif req_path == '/trigger_google':
            if os.path.exists('/opt/ip_sentinel/core/mod_google.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_google\n")
                os.system("nohup bash /opt/ip_sentinel/core/mod_google.sh >/dev/null 2>&1 &")
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Google Module Disabled\n")

        # 路由 2: IP 信用净化
        elif req_path == '/trigger_trust':
            if os.path.exists('/opt/ip_sentinel/core/mod_trust.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_trust\n")
                os.system("nohup bash /opt/ip_sentinel/core/mod_trust.sh >/dev/null 2>&1 &")
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Trust Module Disabled\n")

        # 路由 3: 触发战报推送
        elif req_path == '/trigger_report':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: tg_report\n")
            os.system("nohup bash /opt/ip_sentinel/core/tg_report.sh >/dev/null 2>&1 &")

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
                
                # [v3.5.2 核心] 获取版本与节点展示别名
                local_ver = config.get('AGENT_VERSION', '未知')
                node_alias = config.get('NODE_ALIAS', config.get('NODE_NAME', 'Unknown-Node'))
                
                text_msg = f"📄 <b>[{node_alias}] 实时日志 (v{local_ver}):</b>\n<pre><code>{log_data}</code></pre>"
                
                # [v4.0.3 体验升级] 引入 json 模块并改用 JSON Payload，挂载返回控制台按钮
                import json
                node_name_cb = config.get('NODE_NAME', 'Unknown')
                payload = {
                    'chat_id': config.get('CHAT_ID', ''),
                    'text': text_msg,
                    'parse_mode': 'HTML',
                    'reply_markup': {
                        'inline_keyboard': [[{'text': '⚙️ 调出该节点控制台', 'callback_data': f'manage:{node_name_cb}'}]]
                    }
                }
                data = json.dumps(payload).encode('utf-8')
                
                req = urllib.request.Request(
                    config.get('TG_API_URL', ''), 
                    data=data,
                    # [动态化] 彻底消灭硬编码，使用运行态版本号，并声明 JSON 头
                    headers={
                        'User-Agent': f'IP-Sentinel-Agent/{local_ver}',
                        'Content-Type': 'application/json'
                    }
                )
                urllib.request.urlopen(req, timeout=10)
                
            except Exception as e:
                print(f"Log transmission failed: {e}")

        # ================== [v4.0.0 新增: 触发深海声呐] ==================
        elif req_path == '/trigger_quality':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: trigger_quality\n")
            
            if os.path.exists('/opt/ip_sentinel/core/mod_quality.sh'):
                os.system("nohup bash /opt/ip_sentinel/core/mod_quality.sh >/dev/null 2>&1 &")
        # =================================================================


        # 路由 5: 节点重命名展示别名同步接口 (Base64 终极防御版)
        elif req_path == '/trigger_rename':
            b64_alias = query.get('b64', [''])[0]
            if not b64_alias:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"400 Bad Request: Alias is empty\n")
                return
                
            import re
            import base64
            try:
                # 1. 还原 URL 安全的 Base64 字符并解码 (杜绝乱码与 WAF 拦截)
                pad = len(b64_alias) % 4
                if pad > 0:
                    b64_alias += '=' * (4 - pad)
                b64_alias = b64_alias.replace('-', '+').replace('_', '/')
                raw_alias = base64.b64decode(b64_alias).decode('utf-8', errors='ignore')
                
                # 2. 强清洗：杜绝 TG Markdown 崩溃，严格限制中英数，最大20字符
                decoded_alias = raw_alias.replace('_', '-')
                safe_alias = re.sub(r'[^a-zA-Z0-9\-\u4e00-\u9fa5]', '', decoded_alias)[:20]
                
                if safe_alias:
                    # 3. 强容错读写 config.conf (引入 fcntl 排他锁与 r+ 模式防并发清空)
                    config_path = '/opt/ip_sentinel/config.conf'
                    import fcntl
                    with open(config_path, 'r+', encoding='utf-8', errors='ignore') as f:
                        fcntl.flock(f, fcntl.LOCK_EX)
                        lines = f.readlines()
                        
                        alias_found = False
                        for i, line in enumerate(lines):
                            if line.startswith('NODE_ALIAS='):
                                lines[i] = f'NODE_ALIAS="{safe_alias}"\n'
                                alias_found = True
                                break
                                
                        if not alias_found:
                            lines.append(f'NODE_ALIAS="{safe_alias}"\n')
                            
                        f.seek(0)
                        f.writelines(lines)
                        f.truncate()
                        fcntl.flock(f, fcntl.LOCK_UN)
                        
                    # [v3.5.2 极致丝滑] 移除向 TG 推送冗余报文的逻辑，直接向 Master 回执成功状态即可
                    self.send_response(200)
                    self.send_header("Content-type", "text/plain")
                    self.end_headers()
                    self.wfile.write(b"Action Accepted: trigger_rename\n")
                    return
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"500 Internal Error: {str(e)}\n".encode('utf-8'))
                return
            
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"400 Bad Request: Invalid Characters\n")

        # ================== [v3.5.3 新增: 模块动态启停接口] ==================
        elif req_path == '/trigger_toggle':
            mod_name = query.get('mod', [''])[0]
            target_state = query.get('state', [''])[0].lower()
            
            if mod_name not in ['google', 'trust'] or target_state not in ['true', 'false']:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"400 Bad Request: Invalid parameters\n")
                return
                
            config_key = f"ENABLE_{mod_name.upper()}="
            
            try:
                config_path = '/opt/ip_sentinel/config.conf'
                import fcntl
                
                with open(config_path, 'r+', encoding='utf-8', errors='ignore') as f:
                    fcntl.flock(f, fcntl.LOCK_EX)
                    lines = f.readlines()
                    
                    found = False
                    for i, line in enumerate(lines):
                        if line.startswith(config_key):
                            lines[i] = f'{config_key}"{target_state}"\n'
                            found = True
                            break
                            
                    if not found:
                        lines.append(f'{config_key}"{target_state}"\n')
                        
                    f.seek(0)
                    f.writelines(lines)
                    f.truncate()
                    fcntl.flock(f, fcntl.LOCK_UN)
                
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: trigger_toggle\n")
                
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"500 Internal Error: {str(e)}\n".encode('utf-8'))

        # ================== [v3.6.0 新增: 零信任 OTA 远程静默升级路由] ==================
        elif req_path == '/trigger_ota':
            try:
                # 动态读取最新 config 内存态
                config_mem = {}
                config_path = '/opt/ip_sentinel/config.conf'
                if os.path.exists(config_path):
                    with open(config_path, 'r', errors='ignore') as f:
                        for line in f:
                            line = line.strip()
                            if '=' in line and not line.startswith('#'):
                                key, val = line.split('=', 1)
                                config_mem[key] = val.strip('"\'')
                                
                # 🛡️ 熔断校验 1: Agent 本地是否开启了 OTA 授权
                if config_mem.get('ENABLE_OTA', 'false').lower() != 'true':
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b"403 Forbidden: OTA Upgrade Disabled locally\n")
                    return
                    
                # 🛡️ 熔断校验 2: 是否处于官方公共网关下 (强行硬编码拦截)
                if config_mem.get('TG_TOKEN', '') == 'OFFICIAL_GATEWAY_MODE':
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b"403 Forbidden: OTA strictly disabled under Public Gateway mode\n")
                    return
                    
                # 校验通过，立即返回 200 回执，释放 Master 连接池
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: trigger_ota\n")
                
                # [修复] 逃逸 Systemd Cgroup，并引入 bash -n 语法树校验防砖机制
                import shutil
                import base64
                # 动态提取部署时的源地址，废除强制写死 main 分支，保障隔离测试环境
                repo_url = "https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
                if os.path.exists('/opt/ip_sentinel/core/install.sh'):
                    with open('/opt/ip_sentinel/core/install.sh', 'r') as f:
                        for line in f:
                            if line.startswith('REPO_RAW_URL='):
                                repo_url = line.split('=', 1)[1].strip('"\'')
                                break
                
                # 动态构建报错回执文本 (第一层 Base64 隔离换行与特殊字符)
                err_msg = f"❌ **OTA 熔断告警**\n📍 节点: `{config_mem.get('NODE_ALIAS', '未知')}`\n⚠️ 原因: 脚本语法校验(bash -n)未通过，下载可能不完整。\n🚀 状态: 升级已取消，节点安全。"
                err_msg_b64 = base64.b64encode(err_msg.encode('utf-8')).decode('utf-8')
                
                tg_url = config_mem.get('TG_API_URL', '')
                chat_id = config_mem.get('CHAT_ID', '')
                
                # [v3.6.3 究极防御] 采用 Base64 将整个 OTA 执行脚本封装 (第二层隔离)
                # 彻底免疫因为 python 变量掺杂引号而导致的 shell 注入或截断
                ota_script = f"""
export SILENT_OTA="true"
curl -fsSL {repo_url}/core/install.sh -o /tmp/ota_agent.sh
if bash -n /tmp/ota_agent.sh; then
    bash /tmp/ota_agent.sh > /opt/ip_sentinel/logs/ota_upgrade.log 2>&1
else
    MSG=$(echo '{err_msg_b64}' | base64 -d)
    curl -s -m 10 -X POST "{tg_url}" -d "chat_id={chat_id}" -d "text=$MSG" -d "parse_mode=Markdown" > /dev/null 2>&1
    echo "OTA Checksum Failed: Script corrupted" > /opt/ip_sentinel/logs/ota_upgrade.log
fi
"""
                ota_script_b64 = base64.b64encode(ota_script.encode('utf-8')).decode('utf-8')
                
                # 安全解包并执行
                if shutil.which("systemd-run"):
                    full_cmd = f"systemd-run --quiet --no-block bash -c \"echo '{ota_script_b64}' | base64 -d | bash\""
                else:
                    full_cmd = f"nohup bash -c \"echo '{ota_script_b64}' | base64 -d | bash\" >/dev/null 2>&1 &"
                    
                # 彻底统一为 os.system，消灭最后一个可能游离的 Popen 僵尸进程
                os.system(full_cmd)
                
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"500 Internal Error: {str(e)}\n".encode('utf-8'))

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

import socket
# ================== [v3.0.3 变更: 引入多线程模型抵抗 Slowloris 攻击] ==================
class ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True # 开启端口复用，防止热重启时端口冲突
    
    # [核心修复] 显式关闭 V6ONLY 参数，治愈大量云主机纯双栈下的 IPv4 耳聋现象
    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except Exception:
                pass
        super().server_bind()

try:
    # 1. 优先尝试监听双栈/IPv6
    ThreadedServer.address_family = socket.AF_INET6
    httpd = ThreadedServer(("::", PORT), AgentHandler)
except Exception:
    # 2. [核心修复 Issue #23] 若系统内核已禁用 IPv6，抛弃报错，智能回退至纯 IPv4 监听
    ThreadedServer.address_family = socket.AF_INET
    httpd = ThreadedServer(("0.0.0.0", PORT), AgentHandler)

# ================== [v3.6.3 核心: 挂载 TLS 加密隧道 (强制装甲版)] ==================
import ssl
cert_path = '/opt/ip_sentinel/core/cert.pem'
key_path = '/opt/ip_sentinel/core/key.pem'

# 全网强制启用 TLS 装甲，彻底消灭 HTTP 裸奔漏洞
if os.path.exists(cert_path) and os.path.exists(key_path):
    try:
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.load_cert_chain(certfile=cert_path, keyfile=key_path)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    except Exception as e:
        print(f"SSL 隧道构建失败，退化为 HTTP: {e}")
# ======================================================================================

try:
    httpd.serve_forever()
except Exception as e:
    sys.exit(1)
# ====================================================================================
EOF

# --- [重点升级 3: 移交系统级守护进程接管 (阻塞模式)] ---
echo "🚀 [Agent] 正在启动 Webhook 监听服务 (端口: $AGENT_PORT)..."
exec python3 "${INSTALL_DIR}/core/webhook.py" "$AGENT_PORT"