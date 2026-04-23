#!/bin/bash

# ==========================================================
# 脚本名称: tg_master.sh (Master 端调度枢纽 - 动态锚点版)
# 核心功能: 监听 TG、操作 SQLite、Webhook 精准调度、403权限拦截、僵尸节点清理
# ==========================================================

CONF="/opt/ip_sentinel_master/master.conf"
[ ! -f "$CONF" ] && exit 1
source "$CONF"

# [核心: 运行态版本继承与云通信地址]
REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
# 临时改为开发地址用于测试
# REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/v3.6.2-rc"
# MASTER_VERSION 已经在上方的 source "$CONF" 中被载入
# 如果本地极度陈旧没有该变量，才给定一个基础兜底值，避免变量为空导致崩溃
MASTER_VERSION=${MASTER_VERSION:-"3.5.0"}

OFFSET_FILE="${MASTER_DIR}/.tg_offset"
[[ -f $OFFSET_FILE ]] || echo "0" > $OFFSET_FILE

# --- 工具函数 ---
send_ui() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"text\":\"$2\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$3}}" > /dev/null
}

send_msg() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" -d "text=$2" -d "parse_mode=Markdown" > /dev/null
}

# ================== [v3.0.1 新增: 消息原位刷新函数] ==================
edit_msg() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
        -d "chat_id=$1" -d "message_id=$2" -d "text=$3" -d "parse_mode=Markdown" > /dev/null
}

# [v3.5.3 新增: 支持内联键盘的原位 UI 重绘函数]
edit_ui() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"message_id\":\"$2\",\"text\":\"$3\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$4}}" > /dev/null
}

# 数据库执行函数 (v3.6.3 终极静默版: 动用 .timeout 点命令防泄露)
db_exec() {
    printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"
}

# ================== [v3.0.4 核心: 动态 HMAC 签名生成器] ==================
# 用法: generate_signed_url <IP> <PORT> <PATH>
generate_signed_url() {
    local target_ip=$1
    local target_port=$2
    local action_path=$3
    local current_t=$(date +%s)
    
    # 构建加密载荷: "路径:时间戳"
    local payload="${action_path}:${current_t}"
    
    # 使用 CHAT_ID 作为密钥，生成 SHA256 HMAC 签名
    local signature=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$CHAT_ID" | awk '{print $NF}')
    
    # 返回最终带签名的 URL
    echo "https://${target_ip}:${target_port}${action_path}?t=${current_t}&sign=${signature}"
}
# ========================================================================

# ================== [v3.6.3 核心: 激活 SQLite 高并发 WAL 引擎] ==================
db_exec "PRAGMA journal_mode=WAL;" > /dev/null 2>&1
db_exec "PRAGMA synchronous=NORMAL;" > /dev/null 2>&1
# ==============================================================================

# ================== [v3.1.3-v3.6.0 核心: 数据库结构无损热升级] ==================
# 自动探测并增加缺失字段，屏蔽已存在的报错，保护老节点数据
db_exec "ALTER TABLE nodes ADD COLUMN region TEXT DEFAULT 'UNKNOWN';" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN node_alias TEXT;" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN enable_google TEXT DEFAULT 'true';" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN enable_trust TEXT DEFAULT 'true';" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN enable_ota TEXT DEFAULT 'false';" 2>/dev/null
# ========================================================================

# ================== [v4.0.0 核心: 增加 IP 质量趋势追踪表] ==================
db_exec "CREATE TABLE IF NOT EXISTS ip_trend_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_name TEXT,
    check_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    scam_score INTEGER,
    nf_status TEXT
);" 2>/dev/null
# ========================================================================

# --- 核心轮询循环 ---
while true; do
    OFFSET=$(cat $OFFSET_FILE)
    UPDATES=$(curl -s --connect-timeout 5 -m 35 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30")
    
    COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
    
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        echo "$UPDATES" | jq -c '.result[]' | while read -r UPDATE; do
            UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            
            CHAT_ID=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.message.chat.id')
            TEXT=$(echo "$UPDATE" | jq -r '.message.text // .callback_query.data')

            # ================== [v4.0.0 新增: 深海声呐暗号拦截与落盘] ==================
            if [[ "$TEXT" == *"[SYSTEM_REPORT]|QUALITY|"* ]]; then
                # 截获系统隐写报告，提取分数并存库 (格式: [SYSTEM_REPORT]|QUALITY|NODE_NAME|SCORE|NF_STAT)
                REPORT_DATA=$(echo "$TEXT" | grep -o "\[SYSTEM_REPORT\].*")
                NODE_ID=$(echo "$REPORT_DATA" | cut -d'|' -f3 | tr -cd 'a-zA-Z0-9_.-')
                SCORE=$(echo "$REPORT_DATA" | cut -d'|' -f4 | tr -cd '0-9')
                NF_ST=$(echo "$REPORT_DATA" | cut -d'|' -f5 | tr -cd 'a-zA-Z0-9_-')
                
                if [ -n "$NODE_ID" ] && [ -n "$SCORE" ]; then
                    db_exec "INSERT INTO ip_trend_log (node_name, scam_score, nf_status) VALUES ('$NODE_ID', '$SCORE', '$NF_ST');"
                fi
                # 无需回复用户，因为 Agent 原战报已发在群中
                continue
            fi
            # ======================================================================
            
            REPLY_TO_TEXT=$(echo "$UPDATE" | jq -r '.message.reply_to_message.text // empty')

            # ================== [v3.5.2 新增: 拦截别名修改的对话回复] ==================
            if [[ "$REPLY_TO_TEXT" == *"✏️ 请回复本消息以重命名节点:"* ]]; then
                # 精准提取被回复消息中的节点主键名
                TARGET_NODE=$(echo "$REPLY_TO_TEXT" | grep -v "✏️" | grep -v "仅限" | tr -d '\` ' | tr -cd 'a-zA-Z0-9_.-' | head -n 1)
                
                # [v3.5.2 热修复] 废除 Bash 原生 tr 命令的中文白名单 (不支持 Unicode 会误删中文)。
                # 改用黑名单策略：仅自动转化下划线，剔除引号、特殊符号和冒号(防止破坏内部路由)，
                # 将完整的中文原样送入 Base64 编码，最终严格正则清洗交由 Agent 的 Python 引擎处理！
                NEW_ALIAS=$(echo "$TEXT" | sed 's/_/-/g' | tr -d '"'\''\`\$\|&;<>\n\r:' | cut -c 1-30)
                
                if [ -n "$TARGET_NODE" ] && [ -n "$NEW_ALIAS" ]; then
                    # 强行重写内部路由
                    TEXT="do_rename:${TARGET_NODE}:${NEW_ALIAS}"
                fi
            fi

            # ================== [v3.0.1 新增: 消除转圈圈与获取消息ID] ==================
            CB_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
            MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')
            
            # 告诉 TG 官方“指令已收到”，立刻消除按钮上的加载圈圈
            if [ -n "$CB_ID" ]; then
                curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" -d "callback_query_id=${CB_ID}" > /dev/null
            fi

            # ==========================================
            # 1. 节点注册通道 (V3.1.3 大区拓扑升级版)
            # ==========================================
            if [[ "$TEXT" == *"#REGISTER#"* ]]; then
                REG_LINE=$(echo "$TEXT" | grep "#REGISTER#" | head -n 1 | tr -d '\` ')
                
                # V3.6.0 兼容性拆包: 支持 7字段(OTA)、6字段(双轨)、5字段(单轨)、4字段(远古)
                FIELD_COUNT=$(echo "$REG_LINE" | awk -F'|' '{print NF}')
                if [ "$FIELD_COUNT" -ge 7 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA <<< "$REG_LINE"
                elif [ "$FIELD_COUNT" -eq 6 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS <<< "$REG_LINE"
                    RAW_OTA="false"
                elif [ "$FIELD_COUNT" -eq 5 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT <<< "$REG_LINE"
                    RAW_ALIAS="$RAW_NODE"
                    RAW_OTA="false"
                else
                    IFS='|' read -r MAGIC RAW_NODE RAW_IP RAW_PORT <<< "$REG_LINE"
                    RAW_REGION="UNKNOWN"
                    RAW_ALIAS="$RAW_NODE"
                    RAW_OTA="false"
                fi
                
                # 🛡️ 强制字符白名单过滤：保留历史特征不变
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                AGENT_REGION=$(echo "$RAW_REGION" | tr -cd 'a-zA-Z0-9' | cut -c 1-10)
                NODE_NAME=$(echo "$RAW_NODE" | tr -cd 'a-zA-Z0-9_.-' | cut -c 1-30)
                AGENT_IP=$(echo "$RAW_IP" | tr -cd 'a-zA-Z0-9.:\[\]-' | cut -c 1-50)
                AGENT_PORT=$(echo "$RAW_PORT" | tr -cd '0-9' | cut -c 1-5)
                NODE_ALIAS=$(echo "$RAW_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r' | cut -c 1-30)
                [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
                AGENT_OTA=$(echo "$RAW_OTA" | tr -cd 'a-z')
                [ -z "$AGENT_OTA" ] && AGENT_OTA="false"
                
                if [[ "$AGENT_IP" =~ ^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^::1$|^localhost$ ]]; then
                    send_msg "$CHAT_ID" "⛔ **安全拦截**：禁止注册内网或回环 IP，防止 SSRF 攻击渗透。"
                    continue
                fi
                
                if [ -z "$NODE_NAME" ] || [ -z "$AGENT_IP" ] || [ -z "$AGENT_PORT" ] || [ -z "$CHAT_ID" ]; then
                    send_msg "$CHAT_ID" "⛔ **安全拦截**：检测到非法注册载荷，请求已拒绝。"
                    continue
                fi

                # [核心] 入库时追加 node_alias 与 enable_ota 字段
                db_exec "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen, region, node_alias, enable_ota) VALUES ('$CHAT_ID', '$NODE_NAME', '$AGENT_IP', '$AGENT_PORT', CURRENT_TIMESTAMP, '$AGENT_REGION', '$NODE_ALIAS', '$AGENT_OTA') ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$AGENT_IP', agent_port='$AGENT_PORT', last_seen=CURRENT_TIMESTAMP, region='$AGENT_REGION', node_alias='$NODE_ALIAS', enable_ota='$AGENT_OTA';"
                send_msg "$CHAT_ID" "✅ **司令部确认 (v${MASTER_VERSION})**%0A节点 \`${NODE_ALIAS}\` 档案已录入！"
                
                # ================== [v3.1.3 丝滑连招: 直接呼出全球大区雷达] ==================
                REGION_DATA=$(db_exec "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                if [ -n "$REGION_DATA" ]; then
                    BTNS="["
                    while IFS='|' read -r REGION_NAME NODE_COUNT; do
                        [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                        FLAG="🌐"
                        case "$REGION_NAME" in
                            "US") FLAG="🇺🇸" ;; "JP") FLAG="🇯🇵" ;; "HK") FLAG="🇭🇰" ;;
                            "SG") FLAG="🇸🇬" ;; "UK"|"GB") FLAG="🇬🇧" ;; "DE") FLAG="🇩🇪" ;; "FR") FLAG="🇫🇷" ;;
                            "CA") FLAG="🇨🇦" ;; "AU") FLAG="🇦🇺" ;; "KR") FLAG="🇰🇷" ;; "NL") FLAG="🇳🇱" ;;
                            "BR") FLAG="🇧🇷" ;; "IN") FLAG="🇮🇳" ;; "TW") FLAG="🇹🇼" ;;
                        esac
                        BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                    done <<< "$REGION_DATA"
                    BTNS="${BTNS%,}]"
                    send_ui "$CHAT_ID" "🌍 **全视界战略雷达**\n请选择要检阅的战区：" "$BTNS"
                fi
                # ========================================================================
                
                continue
            fi

            # ==========================================
            # 2. 交互菜单与下发通道
            # ==========================================
            case "$TEXT" in
                "/start"|"/menu")
                    # [核心: 抓取云端最新 Master 版本 (KV 解析法)]
                    REMOTE_VER=$(curl -s -m 2 "${REPO_RAW_URL}/version.txt" | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
                    VER_INFO="当前版本: \`v${MASTER_VERSION}\`"
                    
                    BTN_MASTER_OTA=""
                    if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$MASTER_VERSION" ]; then
                        VER_INFO="${VER_INFO}\n✨ **发现新版本**: \`v${REMOTE_VER}\` (可执行中枢热重载)"
                        
                        # 仅当非官方网关 且 开启了中枢 OTA 权限时，才渲染升级按钮
                        if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "${ENABLE_MASTER_OTA:-false}" == "true" ]; then
                            BTN_MASTER_OTA="[{\"text\":\"🆙 升级司令部至 v${REMOTE_VER}\",\"callback_data\":\"master_ota_confirm\"}],"
                        fi
                    fi

                    NODE_COUNT=$(db_exec "SELECT COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID';")
                    [ -z "$NODE_COUNT" ] && NODE_COUNT=0

                    # L0 扁平化重构：将司令部升级按钮动态置于最顶层
                    if [ "$IS_OFFICIAL_GATEWAY" != "true" ]; then
                        BTNS="[${BTN_MASTER_OTA}[{\"text\":\"🌍 进入全球战区雷达 (管理节点)\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 全军总攻\",\"callback_data\":\"all_run\"}, {\"text\":\"📊 全军简报\",\"callback_data\":\"all_reports\"}], [{\"text\":\"☢️ 全舰队 OTA 热重载\",\"callback_data\":\"all_ota_confirm\"}]]"
                    else
                        BTNS="[[{\"text\":\"🌍 进入全球战区雷达 (管理节点)\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 全军总攻\",\"callback_data\":\"all_run\"}, {\"text\":\"📊 全军简报\",\"callback_data\":\"all_reports\"}]]"
                    fi
                    TEXT_MSG="🛡️ **IP-Sentinel 司令部**\n${VER_INFO}\n\n📊 舰队状态: 共有 \`${NODE_COUNT}\` 台哨兵在线\n欢迎回来，长官。请下达战略指令："
                    send_ui "$CHAT_ID" "$TEXT_MSG" "$BTNS"
                    ;;
                    
                "all_ota_confirm")
                    CONFIRM_BTNS="[[{\"text\":\"🚨 我已了解风险，下发核按钮指令！\",\"callback_data\":\"all_ota_execute\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【最高指令：全舰队 OTA 升级】**\n\n此操作将向您名下**所有开启 OTA 权限的节点**下发重组指令，强制从云端拉取最新代码并进行热重载。\n\n⚠️ **核按钮风险提示**：\n1. 升级过程中守护进程会短暂重启，节点可能出现临时离线。\n2. 若遇 GitHub 源屏蔽或网络极度恶劣，少数节点可能需要手动干预。\n\n**是否确定挂载并执行 OTA 指令？**"
                    send_ui "$CHAT_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    ;;

                "all_ota_execute")
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND enable_ota='true';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无开启 OTA 权限的在线节点。"
                    else
                        send_msg "$CHAT_ID" "📢 **司令部指令下达：正在唤醒全舰队执行 OTA 升级...**%0A*(节点升级成功后会主动发回新的入库确认，请注意查收)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            TARGET_URL=$(generate_signed_url "$AIP" "$APORT" "/trigger_ota")
                            { curl -k -s -m 5 "$TARGET_URL" || curl -s -m 5 "${TARGET_URL/https:\/\//http:\/\/}"; } > /dev/null &
                            sleep 0.3  # 严格流量削峰
                        done
                    fi
                    ;;

                "master_ota_confirm")
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认重构司令部\",\"callback_data\":\"master_ota_execute\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【最高指令：中枢金蝉脱壳】**\n\n此操作将拉取最新源码并强行覆盖司令部核心进程。\n\n⚠️ **风险提示**：\n升级期间司令部将短暂失联（约3-5秒）。完成后会自动发送捷报。\n\n**是否确定执行司令部自我升级？**"
                    if [ -n "$MSG_ID" ]; then
                        edit_ui "$CHAT_ID" "$MSG_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    else
                        send_ui "$CHAT_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    fi
                    ;;

                "master_ota_execute")
                    if [ -n "$MSG_ID" ]; then
                        edit_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在下载重构图纸，司令部即将进入静默重启..."
                    else
                        send_msg "$CHAT_ID" "⏳ 正在下载重构图纸，司令部即将进入静默重启..."
                    fi

                    # 下载最新的 master install 脚本作为幽灵进程
                    curl -fsSL "${REPO_RAW_URL}/master/install_master.sh" -o "/tmp/install_master.sh"
                    
                    # [v3.6.3 修复] 🚀 OTA 防砖机制：严格校验脚本完整性
                    if ! bash -n "/tmp/install_master.sh" >/dev/null 2>&1; then
                        if [ -n "$MSG_ID" ]; then
                            edit_msg "$CHAT_ID" "$MSG_ID" "❌ OTA 传输受损：脚本下载不完整，已触发防砖熔断，升级取消！"
                        else
                            send_msg "$CHAT_ID" "❌ OTA 传输受损：脚本下载不完整，已触发防砖熔断，升级取消！"
                        fi
                        continue
                    fi
                    
                    chmod +x "/tmp/install_master.sh"
                    
                    # 抛出幽灵进程进行脱壳升级，传递静默变量与回执 ID
                    # [修复] 必须显式将环境变量注入到 bash -c 的指令串中，防止被 systemd-run 沙盒隔离丢弃
                    if command -v systemd-run >/dev/null 2>&1; then
                        systemd-run --quiet --no-block /bin/bash -c "export SILENT_MASTER_OTA='true'; export OTA_CHAT_ID='$CHAT_ID'; bash /tmp/install_master.sh"
                    else
                        export SILENT_MASTER_OTA="true"
                        export OTA_CHAT_ID="$CHAT_ID"
                        nohup bash /tmp/install_master.sh >/dev/null 2>&1 & disown
                    fi
                    
                    # 当前旧进程休眠并等待被幽灵进程处决
                    sleep 10
                    ;;

                "all_reports")
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点。"
                    else
                        # [文案优化] 提前告知指挥官需要排队等待
                        send_msg "$CHAT_ID" "📢 **司令部指令下达：正在召唤所有哨兵回传简报...**%0A*(为防止触发 TG 官方限流，简报将排队依次送达，请耐心等待)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            TARGET_URL=$(generate_signed_url "$AIP" "$APORT" "/trigger_report")
                            { curl -k -s -m 5 "$TARGET_URL" || curl -s -m 5 "${TARGET_URL/https:\/\//http:\/\/}"; } > /dev/null &
                            # [致命修复] 强行休眠 2 秒！错开 TG 官方 1条/秒 的发信红线
                            sleep 2  
                        done
                    fi
                    ;;

                # ================== [补充缺失的全节点一键维护功能] ==================
                "all_run")
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点。"
                    else
                        send_msg "$CHAT_ID" "📢 **司令部指令下达：正在唤醒所有哨兵执行系统维护...**"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            TARGET_URL=$(generate_signed_url "$AIP" "$APORT" "/trigger_run")
                            curl -k -s -m 5 "$TARGET_URL" > /dev/null &
                            sleep 0.2  # [新增] 流量削峰：防止瞬间 fork 导致句柄耗尽
                        done
                    fi
                    ;;
                # ====================================================================

                # ------------------- 🚨 请将下面这段代码插入在这里 -------------------
                
                # ================== [v4.0.0 新增: 文本指令直接控制通道] ==================
                "/quality"|"/quality@"*)
                    TARGET_NODE=$(echo "$TEXT" | awk '{print $2}')
                    if [ -z "$TARGET_NODE" ]; then
                        send_msg "$CHAT_ID" "⚠️ 请指定目标节点。例如: \`/quality HK-1\`\n或通过雷达面板进行选择操作。"
                    else
                        TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')
                        CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                        
                        # [加密通讯逻辑]
                        AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                        AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                        AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                        if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                            send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [quality] 指令，请稍候..."
                            
                            # 动态 HMAC 签名防篡改
                            TARGET_URL=$(generate_signed_url "$AGENT_IP" "$AGENT_PORT" "/trigger_quality")
                            RESPONSE=$(curl -k -s -m 5 "$TARGET_URL" || echo "FAILED")
                            if [ "$RESPONSE" == "FAILED" ] || [ -z "$RESPONSE" ]; then
                                TARGET_URL_HTTP="${TARGET_URL/https:\/\//http:\/\/}"
                                RESPONSE=$(curl -s -m 5 "$TARGET_URL_HTTP" || echo "FAILED")
                            fi
                            
                            # 结果判定
                            if [ "$RESPONSE" == "FAILED" ]; then
                                send_msg "$CHAT_ID" "❌ 指令下发超时或失败！请检查节点公网 IP 或防火墙端口 ($AGENT_PORT) 是否放行。"
                            elif [[ "$RESPONSE" == *"403"* ]]; then
                                send_msg "$CHAT_ID" "⚠️ **拒绝执行**：该节点未在本地开启此模块，请检查安装时的配置！"
                            else
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 回应: 🔍 深海声呐已投放！请等待异步战报回传。"
                            fi
                        else
                            send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                        fi
                    fi
                    ;;

                "/trend"|"/trend@"*)
                    TARGET_NODE=$(echo "$TEXT" | awk '{print $2}')
                    if [ -z "$TARGET_NODE" ]; then
                        send_msg "$CHAT_ID" "⚠️ 请指定目标节点。例如: \`/trend HK-1\`\n或通过雷达面板进行选择操作。"
                    else
                        TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')
                        CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                        
                        TREND_DATA=$(db_exec "SELECT datetime(check_time, 'localtime'), scam_score, nf_status FROM ip_trend_log WHERE node_name='$TARGET_NODE' ORDER BY check_time DESC LIMIT 10;")
                        
                        if [ -z "$TREND_DATA" ]; then
                            send_msg "$CHAT_ID" "⚠️ 节点 \`$TARGET_NODE\` 暂无历史体检档案。请先执行 /quality 投放声呐进行探测。"
                        else
                            TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                            TEXT_RES="📈 *[${TARGET_ALIAS}] IP 污染趋势图谱*\n\n"
                            TEXT_RES+="时间 (本地) | 风险分 | NF解锁\n"
                            TEXT_RES+="------------------------------------\n"
                            
                            while IFS='|' read -r c_time score nf; do
                                [ -z "$score" ] && score="0"
                                [ -z "$nf" ] && nf="Unknown"
                                if [ "$score" -le 20 ]; then SCORE_EMJ="🟢"
                                elif [ "$score" -le 60 ]; then SCORE_EMJ="🟡"
                                else SCORE_EMJ="🔴"
                                fi
                                TEXT_RES+="\`${c_time}\` | ${SCORE_EMJ} \`${score}\` | \`${nf}\`\n"
                            done <<< "$TREND_DATA"
                            TEXT_RES+="\n_💡 提示：高危风险分 (🔴 >60) 极易触发 Google 验证码及 Cloudflare 5秒盾拦截。_"
                            
                            send_msg "$CHAT_ID" "$TEXT_RES"
                        fi
                    fi
                    ;;
                # ------------------- 🚨 插入代码到此结束 -------------------

                "list_nodes")
                    # 【V3.1.3】一级菜单：大区聚合并列出数量
                    REGION_DATA=$(db_exec "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                    if [ -z "$REGION_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点，请先在边缘机执行部署。"
                    else
                        BTNS="["
                        while IFS='|' read -r REGION_NAME NODE_COUNT; do
                            [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                            FLAG="🌐"
                            case "$REGION_NAME" in
                                "US") FLAG="🇺🇸" ;; "JP") FLAG="🇯🇵" ;; "HK") FLAG="🇭🇰" ;;
                                "SG") FLAG="🇸🇬" ;; "UK"|"GB") FLAG="🇬🇧" ;; "DE") FLAG="🇩🇪" ;; "FR") FLAG="🇫🇷" ;;
                                "CA") FLAG="🇨🇦" ;; "AU") FLAG="🇦🇺" ;; "KR") FLAG="🇰🇷" ;; "NL") FLAG="🇳🇱" ;;
                                "BR") FLAG="🇧🇷" ;; "IN") FLAG="🇮🇳" ;; "TW") FLAG="🇹🇼" ;;
                            esac
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        # L1 追加返回中枢逃生舱
                        BTNS="$BTNS[{\"text\":\"🏠 回到司令部\",\"callback_data\":\"/start\"}]]"
                        send_ui "$CHAT_ID" "🌍 **全视界战略雷达**\n已为您聚合当前舰队的部署大区，请选择要检阅的战区：" "$BTNS"
                    fi
                    ;;

                region:*)
                    # 【V3.1.3】二级菜单：目标大区下的节点双列排版
                    TARGET_REGION=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    # [v3.5.2] 提取物理主键和展示别名
                    NODE_LIST=$(db_exec "SELECT node_name, IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND region='$TARGET_REGION';")
                    if [ -z "$NODE_LIST" ]; then
                        send_msg "$CHAT_ID" "⚠️ 该战区下暂无可用节点。"
                    else
                        BTNS="["
                        COL=0
                        ROW_STR="["
                        while IFS='|' read -r N_NAME N_ALIAS; do
                            [ -z "$N_NAME" ] && continue
                            ROW_STR="$ROW_STR{\"text\":\"🖥️ $N_ALIAS\",\"callback_data\":\"manage:$N_NAME\"},"
                            COL=$((COL+1))
                            if [ $COL -eq 2 ]; then
                                ROW_STR="${ROW_STR%,}]"
                                BTNS="$BTNS$ROW_STR,"
                                COL=0
                                ROW_STR="["
                            fi
                        done <<< "$NODE_LIST"
                        # 如果是奇数，补齐最后的尾巴
                        if [ $COL -eq 1 ]; then
                            ROW_STR="${ROW_STR%,}]"
                            BTNS="$BTNS$ROW_STR,"
                        fi
                        # L2 追加双重逃生舱
                        BTNS="$BTNS[{\"text\":\"⬅️ 返回战区地图\",\"callback_data\":\"list_nodes\"}, {\"text\":\"🏠 回到司令部\",\"callback_data\":\"/start\"}]]"
                        send_ui "$CHAT_ID" "📍 **[$TARGET_REGION] 战区哨兵矩阵**\n请锁定要执行战术动作的具体目标：" "$BTNS"
                    fi
                    ;;

                manage:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"
                    
                    # 抓取节点全景元数据
                    TOGGLE_INFO=$(db_exec "SELECT enable_google, enable_trust, enable_ota, agent_ip, IFNULL(last_seen, '未知') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    ST_GOOGLE=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                    ST_TRUST=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                    ST_OTA=$(echo "$TOGGLE_INFO" | cut -d'|' -f3)
                    A_IP=$(echo "$TOGGLE_INFO" | cut -d'|' -f4)
                    LAST_SEEN=$(echo "$TOGGLE_INFO" | cut -d'|' -f5)
                    
                    # 动态渲染状态文字
                    [ "$ST_GOOGLE" == "true" ] && BTN_G="🟢 Google巡逻: 已开" && ACT_G="false" || { BTN_G="🔴 Google巡逻: 已停"; ACT_G="true"; }
                    [ "$ST_TRUST" == "true" ] && BTN_T="🟢 信用净化: 已开" && ACT_T="false" || { BTN_T="🔴 信用净化: 已停"; ACT_T="true"; }

                    # 模块一：即时战术动作 (V4.0.0 引入深海声呐与趋势面板)
                    BTN_ACTION="[{\"text\":\"📍 触发 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 触发信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"🔍 投放深海声呐 (查IP质量)\",\"callback_data\":\"quality:$TARGET_NODE\"}, {\"text\":\"📈 查看 IP 污染趋势图\",\"callback_data\":\"trend:$TARGET_NODE\"}], [{\"text\":\"📜 提取终端实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 生成单机战报\",\"callback_data\":\"report:$TARGET_NODE\"}]"
                    
                    # 模块二：养护状态启停
                    BTN_TOGGLE="[{\"text\":\"$BTN_G\",\"callback_data\":\"toggle:google:$TARGET_NODE:$ACT_G\"}, {\"text\":\"$BTN_T\",\"callback_data\":\"toggle:trust:$TARGET_NODE:$ACT_T\"}]"

                    # 模块三：深度配置管理 (结合 UI 熔断)
                    if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "$ST_OTA" == "true" ]; then
                        BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}, {\"text\":\"🆙 OTA 静默升级\",\"callback_data\":\"ota_confirm:$TARGET_NODE\"}]"
                    else
                        BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}]"
                    fi
                    
                    # 模块四：危险区与逃生舱
                    BTN_DANGER="[{\"text\":\"🗑️ 从中枢销毁该档案\",\"callback_data\":\"del:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回战区列表\",\"callback_data\":\"list_nodes\"}]"

                    # 组合终极矩阵
                    BTNS="[$BTN_ACTION, $BTN_TOGGLE, $BTN_CONFIG, $BTN_DANGER]"
                    
                    TEXT_MSG="⚙️ **目标锁定**: \`$TARGET_ALIAS\`\n(底层标识: \`$TARGET_NODE\`)\n🌐 IP 坐标: \`$A_IP\`\n🕒 最后通讯: \`$LAST_SEEN\`\n\n请下达精确控制指令："

                    if [ -n "$MSG_ID" ]; then
                        edit_ui "$CHAT_ID" "$MSG_ID" "$TEXT_MSG" "$BTNS"
                    else
                        send_ui "$CHAT_ID" "$TEXT_MSG" "$BTNS"
                    fi
                    ;;

                toggle:*)
                    # [动态启停通信闭环]
                    IFS=':' read -r CMD MOD_NAME TARGET_NODE TARGET_STATE <<< "$TEXT"
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)
                    
                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        TARGET_URL=$(generate_signed_url "$AGENT_IP" "$AGENT_PORT" "/trigger_toggle")
                        TARGET_URL="${TARGET_URL}&mod=${MOD_NAME}&state=${TARGET_STATE}"
                        
                        RESPONSE=$(curl -k -s -m 5 "$TARGET_URL" || echo "FAILED")
                        # [向下兼容补丁] 若 HTTPS 拒绝或超时，回退 HTTP 试探老节点
                        if [ "$RESPONSE" == "FAILED" ] || [ -z "$RESPONSE" ]; then
                            TARGET_URL_HTTP="${TARGET_URL/https:\/\//http:\/\/}"
                            RESPONSE=$(curl -s -m 5 "$TARGET_URL_HTTP" || echo "FAILED")
                        fi
                        
                        if [[ "$RESPONSE" == *"Action Accepted"* ]]; then
                            # 下发成功，更新 DB，原位重绘
                            db_exec "UPDATE nodes SET enable_${MOD_NAME}='$TARGET_STATE' WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                            
                            TOGGLE_INFO=$(db_exec "SELECT enable_google, enable_trust FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            ST_GOOGLE=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                            ST_TRUST=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                            [ "$ST_GOOGLE" == "true" ] && BTN_G="🔴 停用 Google 纠偏" && ACT_G="false" || { BTN_G="🟢 启用 Google 纠偏"; ACT_G="true"; }
                            [ "$ST_TRUST" == "true" ] && BTN_T="🔴 停用信用净化" && ACT_T="false" || { BTN_T="🟢 启用信用净化"; ACT_T="true"; }
                            
                            # 切换后直接复用扁平化 L3 面板的重绘逻辑
                            TOGGLE_INFO=$(db_exec "SELECT enable_google, enable_trust, enable_ota, agent_ip, IFNULL(last_seen, '未知') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            ST_GOOGLE=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                            ST_TRUST=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                            ST_OTA=$(echo "$TOGGLE_INFO" | cut -d'|' -f3)
                            A_IP=$(echo "$TOGGLE_INFO" | cut -d'|' -f4)
                            LAST_SEEN=$(echo "$TOGGLE_INFO" | cut -d'|' -f5)

                            [ "$ST_GOOGLE" == "true" ] && BTN_G="🟢 Google巡逻: 已开" && ACT_G="false" || { BTN_G="🔴 Google巡逻: 已停"; ACT_G="true"; }
                            [ "$ST_TRUST" == "true" ] && BTN_T="🟢 信用净化: 已开" && ACT_T="false" || { BTN_T="🔴 信用净化: 已停"; ACT_T="true"; }

                            # 模块一：即时战术动作 (V4.0.0 引入深海声呐与趋势面板)
                    BTN_ACTION="[{\"text\":\"📍 触发 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 触发信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"🔍 投放深海声呐 (查IP质量)\",\"callback_data\":\"quality:$TARGET_NODE\"}, {\"text\":\"📈 查看 IP 污染趋势图\",\"callback_data\":\"trend:$TARGET_NODE\"}], [{\"text\":\"📜 提取终端实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 生成单机战报\",\"callback_data\":\"report:$TARGET_NODE\"}]"
                            BTN_TOGGLE="[{\"text\":\"$BTN_G\",\"callback_data\":\"toggle:google:$TARGET_NODE:$ACT_G\"}, {\"text\":\"$BTN_T\",\"callback_data\":\"toggle:trust:$TARGET_NODE:$ACT_T\"}]"
                            
                            if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "$ST_OTA" == "true" ]; then
                                BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}, {\"text\":\"🆙 OTA 静默升级\",\"callback_data\":\"ota_confirm:$TARGET_NODE\"}]"
                            else
                                BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}]"
                            fi
                            BTN_DANGER="[{\"text\":\"🗑️ 从中枢销毁该档案\",\"callback_data\":\"del:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回战区列表\",\"callback_data\":\"list_nodes\"}]"

                            BTNS="[$BTN_ACTION, $BTN_TOGGLE, $BTN_CONFIG, $BTN_DANGER]"
                            TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            
                            TEXT_MSG="⚙️ **目标锁定**: \`$TARGET_ALIAS\`\n(底层标识: \`$TARGET_NODE\`)\n🌐 IP 坐标: \`$A_IP\`\n🕒 最后通讯: \`$LAST_SEEN\`\n\n✅ **执行成功**: 模块 [$MOD_NAME] 状态已切换为 $TARGET_STATE！"
                            edit_ui "$CHAT_ID" "$MSG_ID" "$TEXT_MSG" "$BTNS"
                        else
                            send_msg "$CHAT_ID" "❌ 指令下发失败，节点可能离线或未更新至 v3.5.3。"
                        fi
                    fi
                    ;;

                del:*)
                    # 🛡️ 提取并强制过滤节点名与 CHAT_ID 防注入
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    db_exec "DELETE FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                    send_msg "$CHAT_ID" "🗑️ 节点 \`$TARGET_NODE\` 的档案已从司令部彻底销毁！"
                    
                    # 剔除后直接返回上级一级雷达菜单
                    REGION_DATA=$(db_exec "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                    if [ -z "$REGION_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 当前司令部已无任何节点挂载。"
                    else
                        BTNS="["
                        while IFS='|' read -r REGION_NAME NODE_COUNT; do
                            [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                            FLAG="🌐"
                            case "$REGION_NAME" in
                                "US") FLAG="🇺🇸" ;; "JP") FLAG="🇯🇵" ;; "HK") FLAG="🇭🇰" ;;
                                "SG") FLAG="🇸🇬" ;; "UK"|"GB") FLAG="🇬🇧" ;; "DE") FLAG="🇩🇪" ;; "FR") FLAG="🇫🇷" ;;
                                "CA") FLAG="🇨🇦" ;; "AU") FLAG="🇦🇺" ;; "KR") FLAG="🇰🇷" ;; "NL") FLAG="🇳🇱" ;;
                                "BR") FLAG="🇧🇷" ;; "IN") FLAG="🇮🇳" ;; "TW") FLAG="🇹🇼" ;;
                            esac
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="${BTNS%,}]"
                        send_ui "$CHAT_ID" "🌍 刷新后的全视界雷达：" "$BTNS"
                    fi
                    ;;

                rename:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    # [v3.5.2] 发送 ForceReply 引导用户回复
                    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"✏️ 请回复本消息以重命名节点:\n\`$TARGET_NODE\`\n(仅限中英文、数字，最长20字符)\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"force_reply\":true}}" > /dev/null
                    ;;

                do_rename:*)
                    # [v3.5.2] 内部重命名路由 (已被第2处的代码拦截并格式化)
                    IFS=':' read -r CMD TARGET_NODE NEW_ALIAS <<< "$TEXT"
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` 下发重命名指令，正在建立加密隧道..."
                        
                        TARGET_URL=$(generate_signed_url "$AGENT_IP" "$AGENT_PORT" "/trigger_rename")
                        
                        # [绝密防线: Base64 编码绕过一切传输限制与 WAF 拦截]
                        ALIAS_B64=$(echo -n "$NEW_ALIAS" | base64 | tr -d '\n' | tr '+/' '-_')
                        TARGET_URL="${TARGET_URL}&b64=${ALIAS_B64}"
                        
                        RESPONSE=$(curl -k -s -m 5 "$TARGET_URL" || echo "FAILED")
                        # [向下兼容补丁] 若 HTTPS 拒绝或超时，回退 HTTP 试探老节点
                        if [ "$RESPONSE" == "FAILED" ] || [ -z "$RESPONSE" ]; then
                            TARGET_URL_HTTP="${TARGET_URL/https:\/\//http:\/\/}"
                            RESPONSE=$(curl -s -m 5 "$TARGET_URL_HTTP" || echo "FAILED")
                        fi
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            send_msg "$CHAT_ID" "❌ 指令下发超时！请检查节点连通性。"
                        elif [[ "$RESPONSE" == *"Action Accepted"* ]]; then
                            # [v3.5.2 极致丝滑] 确认 Agent 修改成功后，Master 立即自动同步本地 SQLite 数据库！
                            db_exec "UPDATE nodes SET node_alias='$NEW_ALIAS' WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                            send_msg "$CHAT_ID" "✅ 通讯成功！节点别名已下发: \`$NEW_ALIAS\`%0A*(司令部档案已自动刷新，雷达面板已同步)*"
                        else
                            # 增加输出 RESPONSE 调试信息，排查任何拦截死因
                            send_msg "$CHAT_ID" "⚠️ 节点拒绝了请求，请确保 Agent 已更新至 v3.5.2%0A(回传信息: \`${RESPONSE}\`)"
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                ota_confirm:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    # 将取消动作引导回 manage，因为 adv 已经被删除了
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认执行远程升级\",\"callback_data\":\"ota_execute:$TARGET_NODE\"}], [{\"text\":\"取消\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                    send_ui "$CHAT_ID" "☢️ **操作确认**：即将向 \`$TARGET_NODE\` 下发 OTA 热更新指令。\n节点更新完成后会自动发送包含新版本号的注册回执，确定执行？" "$CONFIRM_BTNS"
                    ;;

                ota_execute:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        if [ -n "$MSG_ID" ]; then
                            edit_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在向 \`$TARGET_NODE\` 发送 OTA 触发报文..."
                        else
                            send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` 发送 OTA 触发报文..."
                        fi
                        
                        TARGET_URL=$(generate_signed_url "$AGENT_IP" "$AGENT_PORT" "/trigger_ota")
                        RESPONSE=$(curl -k -s -m 5 "$TARGET_URL" || echo "FAILED")
                        # [向下兼容补丁] 若 HTTPS 拒绝或超时，回退 HTTP 试探老节点
                        if [ "$RESPONSE" == "FAILED" ] || [ -z "$RESPONSE" ]; then
                            TARGET_URL_HTTP="${TARGET_URL/https:\/\//http:\/\/}"
                            RESPONSE=$(curl -s -m 5 "$TARGET_URL_HTTP" || echo "FAILED")
                        fi
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            TEXT_RES="❌ OTA 指令下发超时！请检查节点公网连通性。"
                        elif [[ "$RESPONSE" == *"403"* ]]; then
                            TEXT_RES="⚠️ **节点拒绝执行**：该节点本地未开启 OTA 权限或运行在官方网关下！"
                        else
                            TEXT_RES="✅ OTA 触发成功！节点正在后台执行拉取重构，请等待其发送更新完成的回执消息。"
                        fi
                        
                        if [ -n "$MSG_ID" ]; then
                            edit_msg "$CHAT_ID" "$MSG_ID" "$TEXT_RES"
                        else
                            send_msg "$CHAT_ID" "$TEXT_RES"
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                # 【核心升级 v4.0.0】增加拦截规则，支持 quality 前缀
                google:*|trust:*|run:*|report:*|log:*|quality:*)
                    # 🛡️ 提取并强制过滤动作参数、节点名与 CHAT_ID
                    ACTION_TYPE=$(echo "$TEXT" | cut -d':' -f1)
                    TARGET_NODE=$(echo "$TEXT" | cut -d':' -f2 | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        # [v3.0.2 防刷屏] 原位刷新菜单为等待状态
                        if [ -n "$MSG_ID" ]; then
                            edit_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [$ACTION_TYPE] 指令，请稍候..."
                        else
                            send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [$ACTION_TYPE] 指令，请稍候..."
                        fi
                        
                        # 🛡️ [v3.0.4] 动态签名生成与触发 (防重放与防篡改)
                        TARGET_URL=$(generate_signed_url "$AGENT_IP" "$AGENT_PORT" "/trigger_${ACTION_TYPE}")
                        RESPONSE=$(curl -k -s -m 5 "$TARGET_URL" || echo "FAILED")
                        # [向下兼容补丁] 若 HTTPS 拒绝或超时，回退 HTTP 试探老节点
                        if [ "$RESPONSE" == "FAILED" ] || [ -z "$RESPONSE" ]; then
                            TARGET_URL_HTTP="${TARGET_URL/https:\/\//http:\/\/}"
                            RESPONSE=$(curl -s -m 5 "$TARGET_URL_HTTP" || echo "FAILED")
                        fi
                        
                        # 结果判定
                        if [ "$RESPONSE" == "FAILED" ]; then
                            TEXT_RES="❌ 指令下发超时或失败！请检查节点公网 IP 或防火墙端口 ($AGENT_PORT) 是否放行。"
                        elif [[ "$RESPONSE" == *"403"* ]]; then
                            TEXT_RES="⚠️ **拒绝执行**：该节点未在本地开启此模块，请检查安装时的配置！"
                        else
                            if [ "$ACTION_TYPE" == "google" ] || [ "$ACTION_TYPE" == "run" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 📍 Google 纠偏程序启动。"
                            elif [ "$ACTION_TYPE" == "trust" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 🛡️ IP 信用净化程序启动。"
                            elif [ "$ACTION_TYPE" == "quality" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 🔍 深海声呐已投放！请等待异步战报回传。"
                            elif [ "$ACTION_TYPE" == "log" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 正在抓取日志..."
                            else 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 接收指令: $ACTION_TYPE"
                            fi
                        fi
                        
                        # [v3.0.1 防刷屏] 将等待状态刷新为最终结果
                        if [ -n "$MSG_ID" ]; then
                            edit_msg "$CHAT_ID" "$MSG_ID" "$TEXT_RES"
                        else
                            send_msg "$CHAT_ID" "$TEXT_RES"
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;


                trend:*)
                    # [v4.0.0 新增: 生成 IP 质量趋势图]
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    TREND_DATA=$(db_exec "SELECT datetime(check_time, 'localtime'), scam_score, nf_status FROM ip_trend_log WHERE node_name='$TARGET_NODE' ORDER BY check_time DESC LIMIT 10;")
                    
                    if [ -z "$TREND_DATA" ]; then
                        TEXT_RES="⚠️ 节点 \`$TARGET_NODE\` 暂无历史体检档案。请先执行 [🔍 投放深海声呐] 进行探测。"
                    else
                        TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                        [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                        TEXT_RES="📈 *[${TARGET_ALIAS}] IP 污染趋势图谱*\n\n"
                        TEXT_RES+="时间 (本地) | 风险分 | NF解锁\n"
                        TEXT_RES+="------------------------------------\n"
                        
                        while IFS='|' read -r c_time score nf; do
                            # 清洗数据防空
                            [ -z "$score" ] && score="0"
                            [ -z "$nf" ] && nf="Unknown"
                            
                            if [ "$score" -le 20 ]; then SCORE_EMJ="🟢"
                            elif [ "$score" -le 60 ]; then SCORE_EMJ="🟡"
                            else SCORE_EMJ="🔴"
                            fi
                            TEXT_RES+="\`${c_time}\` | ${SCORE_EMJ} \`${score}\` | \`${nf}\`\n"
                        done <<< "$TREND_DATA"
                        TEXT_RES+="\n_💡 提示：高危风险分 (🔴 >60) 极易触发 Google 验证码及 Cloudflare 5秒盾拦截。_"
                    fi
                    
                    if [ -n "$MSG_ID" ]; then
                        edit_msg "$CHAT_ID" "$MSG_ID" "$TEXT_RES"
                    else
                        send_msg "$CHAT_ID" "$TEXT_RES"
                    fi
                    ;;
                    
            esac
        done
    fi
    sleep 1
done