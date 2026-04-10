#!/bin/bash

# ==========================================================
# 脚本名称: tg_master.sh (Master 端调度枢纽 V2.0 模块化适配版)
# 核心功能: 监听 TG、操作 SQLite、Webhook 精准调度、403权限拦截、僵尸节点清理
# ==========================================================

CONF="/opt/ip_sentinel_master/master.conf"
[ ! -f "$CONF" ] && exit 1
source "$CONF"

OFFSET_FILE="/tmp/tg_master_offset"
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
            # 1. 节点注册通道
            # ==========================================
            if [[ "$TEXT" == *"#REGISTER#"* ]]; then
                REG_LINE=$(echo "$TEXT" | grep "#REGISTER#" | head -n 1 | tr -d '\` ')
                IFS='|' read -r MAGIC NODE_NAME AGENT_IP AGENT_PORT <<< "$REG_LINE"
                
                db_exec "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen) VALUES ('$CHAT_ID', '$NODE_NAME', '$AGENT_IP', '$AGENT_PORT', CURRENT_TIMESTAMP) ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$AGENT_IP', agent_port='$AGENT_PORT', last_seen=CURRENT_TIMESTAMP;"
                send_msg "$CHAT_ID" "✅ 司令部已确认！节点接入成功: \`$NODE_NAME\` ($AGENT_IP:$AGENT_PORT)"
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
                            curl -s -m 5 "http://${AIP}:${APORT}/trigger_report" > /dev/null &
                        done
                    fi
                    ;;

                "list_nodes")
                    NODE_LIST=$(db_exec "SELECT node_name FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_LIST" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点，请先在边缘机执行部署。"
                    else
                        BTNS="["
                        for N in $NODE_LIST; do
                            BTNS="$BTNS[{\"text\":\"🖥️ $N\",\"callback_data\":\"manage:$N\"}],"
                        done
                        BTNS="${BTNS%,}]"
                        send_ui "$CHAT_ID" "🔍 您名下的活跃节点：" "$BTNS"
                    fi
                    ;;

                manage:*)
                    TARGET_NODE=${TEXT#*:}
                    # 【核心升级】拆分下发按钮，精准对应 Google 与 Trust 两个模块，并排版为 3 行 2 列
                    BTNS="[[{\"text\":\"📍 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"📜 实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 统计战报\",\"callback_data\":\"report:$TARGET_NODE\"}], [{\"text\":\"🗑️ 剔除失联节点\",\"callback_data\":\"del:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回主列表\",\"callback_data\":\"list_nodes\"}]]"
                    send_ui "$CHAT_ID" "⚙️ **目标锁定**: \`$TARGET_NODE\`\n请选择战术动作：" "$BTNS"
                    ;;

                del:*)
                    TARGET_NODE=${TEXT#*:}
                    db_exec "DELETE FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                    send_msg "$CHAT_ID" "🗑️ 节点 \`$TARGET_NODE\` 的档案已从司令部彻底销毁！"
                    
                    NODE_LIST=$(db_exec "SELECT node_name FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_LIST" ]; then
                        send_msg "$CHAT_ID" "⚠️ 当前司令部已无任何节点挂载。"
                    else
                        BTNS="["
                        for N in $NODE_LIST; do
                            BTNS="$BTNS[{\"text\":\"🖥️ $N\",\"callback_data\":\"manage:$N\"}],"
                        done
                        BTNS="${BTNS%,}]"
                        send_ui "$CHAT_ID" "🔍 刷新后的节点列表：" "$BTNS"
                    fi
                    ;;

                # 【核心升级】增加拦截规则，支持 google 和 trust 前缀
                google:*|trust:*|run:*|report:*|log:*)
                    ACTION_TYPE=$(echo "$TEXT" | cut -d':' -f1)
                    TARGET_NODE=$(echo "$TEXT" | cut -d':' -f2)
                    
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
                        
                        # 触发 Webhook
                        RESPONSE=$(curl -s -m 5 "http://${AGENT_IP}:${AGENT_PORT}/trigger_${ACTION_TYPE}" || echo "FAILED")
                        
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