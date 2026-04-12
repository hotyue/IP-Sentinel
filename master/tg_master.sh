#!/bin/bash

# ==========================================================
# 脚本名称: tg_master.sh (Master 端调度枢纽 V3.0.4 动态签名版)
# 核心功能: 监听 TG、操作 SQLite、Webhook 精准调度、403权限拦截、僵尸节点清理
# ==========================================================

CONF="/opt/ip_sentinel_master/master.conf"
[ ! -f "$CONF" ] && exit 1
source "$CONF"

OFFSET_FILE="${MASTER_DIR}/.tg_offset"
[[ -f $OFFSET_FILE ]] || echo "0" > $OFFSET_FILE

# --- 工具函数 ---
send_ui() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"text\":\"$2\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$3}}" > /dev/null
}

send_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" -d "text=$2" -d "parse_mode=Markdown" > /dev/null
}

# ================== [v3.0.1 新增: 消息原位刷新函数] ==================
edit_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
        -d "chat_id=$1" -d "message_id=$2" -d "text=$3" -d "parse_mode=Markdown" > /dev/null
}

# 数据库执行函数
db_exec() {
    sqlite3 "$DB_FILE" "$1"
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
    echo "http://${target_ip}:${target_port}${action_path}?t=${current_t}&sign=${signature}"
}
# ========================================================================

# ================== [v3.1.3 核心: 数据库结构无损热升级] ==================
# 自动探测并增加 region 字段，屏蔽已存在的报错，保护老节点数据
db_exec "ALTER TABLE nodes ADD COLUMN region TEXT DEFAULT 'UNKNOWN';" 2>/dev/null
# ========================================================================

# --- 核心轮询循环 ---
while true; do
    OFFSET=$(cat $OFFSET_FILE)
    UPDATES=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30")
    
    COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
    
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        echo "$UPDATES" | jq -c '.result[]' | while read -r UPDATE; do
            UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            
            CHAT_ID=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.message.chat.id')
            TEXT=$(echo "$UPDATE" | jq -r '.message.text // .callback_query.data')

            # ================== [v3.0.1 新增: 消除转圈圈与获取消息ID] ==================
            CB_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
            MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')
            
            # 告诉 TG 官方“指令已收到”，立刻消除按钮上的加载圈圈
            if [ -n "$CB_ID" ]; then
                curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" -d "callback_query_id=${CB_ID}" > /dev/null
            fi

            # ==========================================
            # 1. 节点注册通道 (V3.1.3 大区拓扑升级版)
            # ==========================================
            if [[ "$TEXT" == *"#REGISTER#"* ]]; then
                REG_LINE=$(echo "$TEXT" | grep "#REGISTER#" | head -n 1 | tr -d '\` ')
                
                # V3.1.3 兼容性拆包: 判断是新版协议 (5个字段) 还是老版协议 (4个字段)
                FIELD_COUNT=$(echo "$REG_LINE" | awk -F'|' '{print NF}')
                if [ "$FIELD_COUNT" -ge 5 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT <<< "$REG_LINE"
                else
                    IFS='|' read -r MAGIC RAW_NODE RAW_IP RAW_PORT <<< "$REG_LINE"
                    RAW_REGION="UNKNOWN"
                fi
                
                # 🛡️ 强制字符白名单过滤：保留历史特征不变
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                AGENT_REGION=$(echo "$RAW_REGION" | tr -cd 'a-zA-Z0-9' | cut -c 1-10) # 提取国家大区
                NODE_NAME=$(echo "$RAW_NODE" | tr -cd 'a-zA-Z0-9_.-' | cut -c 1-30)
                AGENT_IP=$(echo "$RAW_IP" | tr -cd 'a-zA-Z0-9.:\[\]-' | cut -c 1-50)
                AGENT_PORT=$(echo "$RAW_PORT" | tr -cd '0-9' | cut -c 1-5)
                
                if [[ "$AGENT_IP" =~ ^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^::1$|^localhost$ ]]; then
                    send_msg "$CHAT_ID" "⛔ **安全拦截**：禁止注册内网或回环 IP，防止 SSRF 攻击渗透。"
                    continue
                fi
                
                if [ -z "$NODE_NAME" ] || [ -z "$AGENT_IP" ] || [ -z "$AGENT_PORT" ] || [ -z "$CHAT_ID" ]; then
                    send_msg "$CHAT_ID" "⛔ **安全拦截**：检测到非法注册载荷，请求已拒绝。"
                    continue
                fi

                # 入库时追加 region 字段
                # 🛡️ [安全修复] SQL注入防护：对输入进行转义
db_exec "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen, region) VALUES ('$(echo "$CHAT_ID" | sed "s/'/''/g")', '$(echo "$NODE_NAME" | sed "s/'/''/g")', '$(echo "$AGENT_IP" | sed "s/'/''/g")', '$(echo "$AGENT_PORT" | sed "s/'/''/g")', CURRENT_TIMESTAMP, '$(echo "$AGENT_REGION" | sed "s/'/''/g")') ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$(echo "$AGENT_IP" | sed "s/'/''/g")', agent_port='$(echo "$AGENT_PORT" | sed "s/'/''/g")', last_seen=CURRENT_TIMESTAMP, region='$(echo "$AGENT_REGION" | sed "s/'/''/g")';"
                send_msg "$CHAT_ID" "✅ 司令部已确认！节点接入成功: \`$NODE_NAME\` ($AGENT_IP:$AGENT_PORT)"
                
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
                    BTNS="[[{\"text\":\"🖥️ 我的节点列表\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 全节点日报汇总\",\"callback_data\":\"all_reports\"}], [{\"text\":\"🛠️ 全节点一键维护\",\"callback_data\":\"all_run\"}]]"
                    send_ui "$CHAT_ID" "🛡️ **IP-Sentinel 司令部**\n欢迎回来，长官。请下达指令：" "$BTNS"
                    ;;

                "all_reports")
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点。"
                    else
                        send_msg "$CHAT_ID" "📢 **司令部指令下达：正在召唤所有哨兵回传简报...**"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            # 🛡️ [v3.0.4] 动态签名防重放批量下发
                            TARGET_URL=$(generate_signed_url "$AIP" "$APORT" "/trigger_report")
                            curl -s -m 5 "$TARGET_URL" > /dev/null &
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
                            # 🛡️ [v3.0.4] 动态签名防重放批量下发 (维护模块)
                            TARGET_URL=$(generate_signed_url "$AIP" "$APORT" "/trigger_run")
                            curl -s -m 5 "$TARGET_URL" > /dev/null &
                        done
                    fi
                    ;;
                # ====================================================================

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
                            esac
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="${BTNS%,}]"
                        send_ui "$CHAT_ID" "🌍 **全视界战略雷达**\n请选择要检阅的战区：" "$BTNS"
                    fi
                    ;;

                region:*)
                    # 【V3.1.3】二级菜单：目标大区下的节点双列排版
                    TARGET_REGION=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    NODE_LIST=$(db_exec "SELECT node_name FROM nodes WHERE chat_id='$CHAT_ID' AND region='$TARGET_REGION';")
                    if [ -z "$NODE_LIST" ]; then
                        send_msg "$CHAT_ID" "⚠️ 该战区下暂无可用节点。"
                    else
                        BTNS="["
                        COL=0
                        ROW_STR="["
                        for N in $NODE_LIST; do
                            ROW_STR="$ROW_STR{\"text\":\"🖥️ $N\",\"callback_data\":\"manage:$N\"},"
                            COL=$((COL+1))
                            if [ $COL -eq 2 ]; then
                                ROW_STR="${ROW_STR%,}]"
                                BTNS="$BTNS$ROW_STR,"
                                COL=0
                                ROW_STR="["
                            fi
                        done
                        # 如果是奇数，补齐最后的尾巴
                        if [ $COL -eq 1 ]; then
                            ROW_STR="${ROW_STR%,}]"
                            BTNS="$BTNS$ROW_STR,"
                        fi
                        # 添加返回上级大区雷达的按钮
                        BTNS="$BTNS[{\"text\":\"⬅️ 返回全球战区分布\",\"callback_data\":\"list_nodes\"}]]"
                        send_ui "$CHAT_ID" "📍 **[$TARGET_REGION] 战区哨兵矩阵**\n请下达控制指令：" "$BTNS"
                    fi
                    ;;

                manage:*)
                    # 🛡️ 强制过滤节点名，防止面板渲染时发生 XSS 或注入
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    # 【核心升级】拆分下发按钮，精准对应 Google 与 Trust 两个模块，并排版为 3 行 2 列
                    BTNS="[[{\"text\":\"📍 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"📜 实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 统计战报\",\"callback_data\":\"report:$TARGET_NODE\"}], [{\"text\":\"🗑️ 剔除失联节点\",\"callback_data\":\"del:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回大区目录\",\"callback_data\":\"list_nodes\"}]]"
                    send_ui "$CHAT_ID" "⚙️ **目标锁定**: \`$TARGET_NODE\`\n请选择战术动作：" "$BTNS"
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
                            esac
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="${BTNS%,}]"
                        send_ui "$CHAT_ID" "🌍 刷新后的全视界雷达：" "$BTNS"
                    fi
                    ;;

                # 【核心升级】增加拦截规则，支持 google 和 trust 前缀
                google:*|trust:*|run:*|report:*|log:*)
                    # 🛡️ 提取并强制过滤动作参数、节点名与 CHAT_ID
                    ACTION_TYPE=$(echo "$TEXT" | cut -d':' -f1 | tr -cd 'a-z')
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
                        RESPONSE=$(curl -s -m 5 "$TARGET_URL" || echo "FAILED")
                        
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
            esac
        done
    fi
    sleep 1
done