#!/bin/bash
# IPS-MAGIC:IP-SENTINEL-NET-ENGINE-v4.3.0
# ==========================================================
# 模块名称: net_engine.sh
# 核心功能: 冗余网络栈探测、多出口容灾弹匣装填、老节点平滑迁移网络配置
# ==========================================================

do_network_probe() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n\033[36m[4.5/7] 正在探测本机网络栈与可用出口 (多节点雷达扫描中)...\033[0m"

        RAW_DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me || curl -4 -s -m 3 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
        RAW_DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

        # [v4.2.2 源头防线] 引入工业级网卡追踪，双重过滤 WARP/TUN/NAT 等假公网环境
        DETECT_V4=""
        if [[ -n "$RAW_DETECT_V4" ]]; then
            V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
            if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || \
               [[ "$RAW_DETECT_V4" =~ ^104\.28\. ]] || \
               [[ "$RAW_DETECT_V4" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
                echo -e " \033[33m⚠️ 雷达警告: 发现异常 IPv4 出口 ($RAW_DETECT_V4) 经由虚拟网卡 ($V4_DEV)，已从通讯候选池中隔离。\033[0m"
            else
                DETECT_V4="$RAW_DETECT_V4"
            fi
        fi

        DETECT_V6=""
        if [[ -n "$RAW_DETECT_V6" ]]; then
            V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
            if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_DETECT_V6" =~ ^fe80:|^::1 ]]; then
                echo -e " \033[33m⚠️ 雷达警告: 发现异常 IPv6 出口 ($RAW_DETECT_V6) 经由虚拟网卡 ($V6_DEV)，已从通讯候选池中隔离。\033[0m"
            else
                DETECT_V6="$RAW_DETECT_V6"
            fi
        fi

        IP_OPTIONS=()
        IP_PROTO=()

        [[ -n "$DETECT_V4" ]] && { IP_OPTIONS+=("$DETECT_V4"); IP_PROTO+=("4"); }
        [[ -n "$DETECT_V6" ]] && { IP_OPTIONS+=("$DETECT_V6"); IP_PROTO+=("6"); }

        if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
            echo -e "\033[33m⚠️ 雷达受阻：未能自动探测到公网 IP，请手动指定。\033[0m"
            read -p "请输入您要绑定的公网 IP (v4 或 v6): " RAW_PUBLIC_IP
            PUBLIC_IP=$(echo "$RAW_PUBLIC_IP" | tr -cd 'a-fA-F0-9.:[]')
            [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
        else
            echo "📍 发现可用出口 IP，请选择要注册与养护的锚点:"
            for i in "${!IP_OPTIONS[@]}"; do
                num=$((i+1))
                if [ "${IP_PROTO[$i]}" == "4" ]; then
                    echo "  $num) 🌐 IPv4: ${IP_OPTIONS[$i]} (默认选项)"
                else
                    echo "  $num) 🌌 IPv6: ${IP_OPTIONS[$i]}"
                fi
            done
            CUSTOM_OPT=$(( ${#IP_OPTIONS[@]} + 1 ))
            echo "  $CUSTOM_OPT) ✍️ 手动指定其他 IP (适合多 IP 站群机)"
            
            read -p "请输入选择 (默认1): " IP_CHOICE
            IP_CHOICE=${IP_CHOICE:-1}
            
            if [ "$IP_CHOICE" -le "${#IP_OPTIONS[@]}" ] && [ "$IP_CHOICE" -gt 0 ]; then
                idx=$((IP_CHOICE-1))
                PUBLIC_IP="${IP_OPTIONS[$idx]}"
                IP_PREF="${IP_PROTO[$idx]}"
            elif [ "$IP_CHOICE" -eq "$CUSTOM_OPT" ]; then
                read -p "请输入您要绑定的公网 IP (v4 或 v6): " PUBLIC_IP
                [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
            else
                PUBLIC_IP="${IP_OPTIONS[0]}"
                IP_PREF="${IP_PROTO[0]}"
            fi
        fi

        # [容灾防线] 为含冒号的 IPv6 数据自动装卸方括号护盾，保障下游组件识别不崩溃
        if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
            SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
        else
            SAFE_PUBLIC_IP="$PUBLIC_IP"
        fi
    fi
}

do_assemble_fallback() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n\033[36m[4.6/7] 正在装填通讯容灾防线 (Multi-IP Fallback)...\033[0m"
        COMM_IP="$SAFE_PUBLIC_IP"
        
        # 注入次发弹药 (可用 IPv4)
        if [[ -n "$DETECT_V4" ]] && [[ "$DETECT_V4" != "$PUBLIC_IP" ]]; then
            COMM_IP="${COMM_IP}_${DETECT_V4}"
        fi
        
        # 注入保底弹药 (可用 IPv6，带括号保护)
        if [[ -n "$DETECT_V6" ]] && [[ "$DETECT_V6" != "$PUBLIC_IP" ]]; then
            [[ "$DETECT_V6" != *"["* ]] && SAFE_V6="[${DETECT_V6}]" || SAFE_V6="$DETECT_V6"
            COMM_IP="${COMM_IP}_${SAFE_V6}"
        fi
        
        SAFE_COMM_IP="$COMM_IP"
        
        if [[ "$COMM_IP" == *"_"* ]]; then
            echo -e " \033[32m✅ 成功组装多宿主容灾通讯专线: $SAFE_COMM_IP\033[0m"
        else
            echo -e " \033[33m⚠️ 本机仅有单一出口，建立单轨通讯模式: $SAFE_COMM_IP\033[0m"
        fi

        echo -n "🕵️ 正在进行出站链路试射 (NAT环境与双栈嗅探)..."
        
        RAW_TEST_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
        
        if [[ "$RAW_TEST_IP" == *":"* ]]; then
            TEST_TARGET="https://[2606:4700:4700::1111]"
        else
            TEST_TARGET="https://1.1.1.1"
        fi
        
        if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
            echo -e " \033[32m✅ 原生直连，物理网卡死锁已激活。\033[0m"
            BIND_IP="$SAFE_PUBLIC_IP"
        else
            echo -e " \033[33m⚠️ 发现 NAT/虚拟路由架构，自动卸除网卡枷锁，交由内核路由。\033[0m"
            BIND_IP=""
        fi
        echo -e "\033[32m✅ 哨兵对外联络点已永久锁定至: $SAFE_PUBLIC_IP\033[0m"

        # [身份分离] 分离底层系统锚定的不可变主键，与暴露给上层展示的可变别名
        IP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
        NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${IP_HASH}"
        NODE_ALIAS="$NODE_NAME"

        if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
            echo -e "\n\033[36m[4.8/7] 节点展示别名设定 (用于面板友好显示)...\033[0m"
            echo -e "💡 系统底层的不可变主键为: \033[33m${NODE_NAME}\033[0m"
            read -p "请输入节点展示别名 (如'纽约机房', 回车使用默认): " CUSTOM_ALIAS

            if [ -n "$CUSTOM_ALIAS" ]; then
                # 挂载 UTF-8 环境，防止原生 Bash 在 C Locale 下对多字节汉字进行错误截断
                export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true
                CLEAN_ALIAS=$(echo "$CUSTOM_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r')
                NODE_ALIAS="${CLEAN_ALIAS:0:20}"
                [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
            fi
            echo -e "✅ 已锁定节点展示别名: \033[32m$NODE_ALIAS\033[0m"
        fi
    fi
}

do_write_config() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n[5/7] 正在从云端数据仓库拉取 [${CITY_NAME}] 节点的底层规则..."
        REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
        curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" -o "$REGION_JSON_FILE"

        if [ ! -s "$REGION_JSON_FILE" ]; then
            echo "❌ 拉取或解析规则失败！请检查 Forgejo 仓库是否公开或网络是否畅通。"
            exit 1
        fi

        REGION_NAME=$(jq -r '.region_name' "$REGION_JSON_FILE")
        BASE_LAT=$(jq -r '.google_module.base_lat' "$REGION_JSON_FILE")
        BASE_LON=$(jq -r '.google_module.base_lon' "$REGION_JSON_FILE")
        LANG_PARAMS=$(jq -r '.google_module.lang_params' "$REGION_JSON_FILE")
        VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix' "$REGION_JSON_FILE")

        cat > "$CONFIG_FILE" << EOF
# IP-Sentinel 本地固化配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
AGENT_VERSION="$TARGET_VERSION"
REGION_CODE="$REGION_CODE"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

# 模块开关状态
ENABLE_GOOGLE="$ENABLE_GOOGLE"
ENABLE_TRUST="$ENABLE_TRUST"

TG_TOKEN="$TG_TOKEN"
TG_API_URL="$TG_API_URL"
CHAT_ID="$CHAT_ID"
AGENT_PORT="$AGENT_PORT"
INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

IP_PREF="$IP_PREF"
PUBLIC_IP="$SAFE_PUBLIC_IP"
BIND_IP="$BIND_IP"
COMM_IP="$SAFE_COMM_IP"

NODE_NAME="$NODE_NAME"
NODE_ALIAS="$NODE_ALIAS"

ENABLE_OTA="$ENABLE_OTA"
EOF

        chmod 600 "$CONFIG_FILE"
    fi
}

do_smooth_migrate() {
    if [ "$UPGRADE_MODE" == "true" ]; then
        if ! grep -q "PUBLIC_IP=" "$CONFIG_FILE"; then
            echo -e "\n🔄 [平滑迁移] 正在对老节点进行无损双核身份架构升级..."
            
            MIGRATE_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')
            [[ "$MIGRATE_IP" == *":"* ]] && [[ "$MIGRATE_IP" != *"["* ]] && MIGRATE_IP="[${MIGRATE_IP}]"
            
            echo -n "🕵️ 正在进行补发链路试射 (NAT与双栈嗅探)..."
            RAW_TEST_IP=$(echo "$MIGRATE_IP" | tr -d '[]')
            if [[ "$RAW_TEST_IP" == *":"* ]]; then
                TEST_TARGET="https://[2606:4700:4700::1111]"
            else
                TEST_TARGET="https://1.1.1.1"
            fi
            
            if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
                echo -e " \033[32m✅ 原生直连，网卡死锁已继承。\033[0m"
                NEW_BIND_IP="$MIGRATE_IP"
            else
                echo -e " \033[33m⚠️ 发现 NAT 架构，已自动卸除老版本的物理枷锁。\033[0m"
                NEW_BIND_IP=""
            fi
            
            sed -i "s/^BIND_IP=.*/BIND_IP=\"$NEW_BIND_IP\"/" "$CONFIG_FILE"
            echo "PUBLIC_IP=\"$MIGRATE_IP\"" >> "$CONFIG_FILE"
            
            SAFE_PUBLIC_IP="$MIGRATE_IP"
            BIND_IP="$NEW_BIND_IP"
        else
            SAFE_PUBLIC_IP="${PUBLIC_IP}"
        fi

        # [v4.2.2 热修复] 为所有老节点 (无论是否已有残缺的 COMM_IP) 强行重铸多宿主容灾弹匣
        echo -e "\n🔄 [平滑迁移] 正在对老节点执行 v4.2.2 全域容灾弹匣重构..."
        
        RAW_V4=$(curl -4 -s -m 3 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
        RAW_V6=$(curl -6 -s -m 3 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
        
        V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_V4" =~ ^104\.28\. ]] || [[ "$RAW_V4" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
            RAW_V4=""
        fi
        
        V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_V6" =~ ^fe80:|^::1 ]]; then
            RAW_V6=""
        fi
        
        # 绝对基座：始终确保养护 IP (SAFE_PUBLIC_IP) 处于弹匣的首发位置
        NEW_COMM_IP="$SAFE_PUBLIC_IP"
        RAW_BASE_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
        
        # 追加 V4 容灾备弹
        if [[ -n "$RAW_V4" ]] && [[ "$NEW_COMM_IP" != *"$RAW_V4"* ]]; then
            NEW_COMM_IP="${NEW_COMM_IP}_${RAW_V4}"
        fi
        
        # 追加 V6 容灾备弹
        if [[ -n "$RAW_V6" ]]; then
            [[ "$RAW_V6" != *"["* ]] && SAFE_V6="[${RAW_V6}]" || SAFE_V6="$RAW_V6"
            if [[ "$NEW_COMM_IP" != *"$SAFE_V6"* ]]; then
                NEW_COMM_IP="${NEW_COMM_IP}_${SAFE_V6}"
            fi
        fi
        
        # 强制覆盖 config.conf 中的旧 COMM_IP 记录
        sed -i '/^COMM_IP=/d' "$CONFIG_FILE"
        echo "COMM_IP=\"$NEW_COMM_IP\"" >> "$CONFIG_FILE"
        SAFE_COMM_IP="$NEW_COMM_IP"
        
        echo -e " \033[32m✅ 重铸容灾通讯专线完成: $SAFE_COMM_IP\033[0m"

        if ! grep -q "^NODE_NAME=" "$CONFIG_FILE"; then
            TMP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
            NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${TMP_HASH}"
            NODE_ALIAS="$NODE_NAME"
            echo "NODE_NAME=\"$NODE_NAME\"" >> "$CONFIG_FILE"
            echo "NODE_ALIAS=\"$NODE_ALIAS\"" >> "$CONFIG_FILE"
        else
            NODE_NAME=$(grep "^NODE_NAME=" "$CONFIG_FILE" | cut -d'"' -f2)
            NODE_ALIAS=$(grep "^NODE_ALIAS=" "$CONFIG_FILE" | cut -d'"' -f2)
            if [ -z "$NODE_ALIAS" ]; then
                NODE_ALIAS="$NODE_NAME"
                echo "NODE_ALIAS=\"$NODE_ALIAS\"" >> "$CONFIG_FILE"
            fi
        fi

        if ! grep -q "^ENABLE_OTA=" "$CONFIG_FILE"; then
            echo "ENABLE_OTA=\"false\"" >> "$CONFIG_FILE"
            ENABLE_OTA="false"
        else
            ENABLE_OTA=$(grep "^ENABLE_OTA=" "$CONFIG_FILE" | cut -d'"' -f2)
        fi
    fi
}
