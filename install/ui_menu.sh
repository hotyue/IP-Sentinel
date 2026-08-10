#!/bin/bash
# IPS-MAGIC:IP-SENTINEL-UI-MENU-v4.3.0
# ==========================================================
# 模块名称: ui_menu.sh
# 核心功能: 交互式状态机、LBS 地图解析、Telegram 控制中枢配置
# ==========================================================

do_fetch_map() {
    echo -e "\n[2/7] 正在连线云端，拉取全球节点地图..."
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/map.json" -o "${SECURE_TMP}/map.json"
    if [ ! -s "${SECURE_TMP}/map.json" ]; then
        echo -e "\033[31m❌ 拉取全球地图失败！请检查网络或 GitHub 仓库地址。\033[0m"
        exit 1
    fi
}

do_handle_menu() {
    if [ "$SILENT_OTA" == "true" ]; then
        echo -e "\n⏳ [OTA] 静默升级指令已确认，正在剥离控制台交互..."
        ACTION_CHOICE=1
        UPGRADE_MODE="true"
        KEEP_LOGS="true"
        source "$CONFIG_FILE"
    else
        echo -e "\n请选择操作:"
        echo "  1) 🚀 部署边缘节点 (进入全球节点配置)"
        echo "  2) 🗑️ 一键卸载 IP-Sentinel"
        echo "  3) 📡 重新发送注册指令"
        read -p "请输入选择 [1-3] (默认1): " ACTION_CHOICE

        ACTION_CHOICE=${ACTION_CHOICE:-1}

        if [ "$ACTION_CHOICE" == "2" ]; then
            echo -e "\n⏳ 正在拉取卸载程序..."
            curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/uninstall.sh" -o "${SECURE_TMP}/ip_uninstall.sh"
            chmod +x "${SECURE_TMP}/ip_uninstall.sh"
            bash "${SECURE_TMP}/ip_uninstall.sh"
            rm -f "${SECURE_TMP}/ip_uninstall.sh"
            exit 0
        fi

        # [重新注册] 读取已有配置，重新组装并推送注册指令
        if [ "$ACTION_CHOICE" == "3" ]; then
            echo -e "\n📡 [重新注册] 正在读取本地配置..."

            if [ ! -f "$CONFIG_FILE" ]; then
                echo -e "\033[31m❌ 未检测到配置文件 (${CONFIG_FILE})，无法执行重新注册。\033[0m"
                echo -e "💡 请先完成一次正常部署后再使用此功能。"
                exit 1
            fi

            source "$CONFIG_FILE"

            # 校验关键字段
            MISSING_FIELDS=()
            [ -z "$TG_TOKEN" ] && MISSING_FIELDS+=("TG_TOKEN")
            [ -z "$CHAT_ID" ] && MISSING_FIELDS+=("CHAT_ID")
            [ -z "$NODE_NAME" ] && MISSING_FIELDS+=("NODE_NAME")
            [ -z "$COMM_IP" ] && MISSING_FIELDS+=("COMM_IP")
            [ -z "$AGENT_PORT" ] && MISSING_FIELDS+=("AGENT_PORT")

            if [ ${#MISSING_FIELDS[@]} -gt 0 ]; then
                echo -e "\033[31m❌ 配置不完整，缺少字段: ${MISSING_FIELDS[*]}\033[0m"
                echo -e "💡 配置文件可能已损坏，请重新部署。"
                exit 1
            fi

            # 补齐可能缺失的字段
            NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"
            ENABLE_OTA="${ENABLE_OTA:-false}"
            REGION_CODE="${REGION_CODE:-unknown}"

            echo -e "📋 当前配置信息:"
            echo -e "   节点名称 : ${NODE_NAME}"
            echo -e "   节点别名 : ${NODE_ALIAS}"
            echo -e "   通讯弹匣 : ${COMM_IP}"
            echo -e "   监听端口 : ${AGENT_PORT}"
            echo -e "   OTA权限  : ${ENABLE_OTA}"

            # 重新探测当前公网IP，对比COMM_IP
            echo -e "\n🕵️ 正在探测当前公网出口..."
            RAW_CUR_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
            RAW_CUR_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

            # 过滤WARP等异常出口
            V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
            if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_CUR_V4" =~ ^104\.28\. ]]; then
                RAW_CUR_V4=""
            fi

            V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
            if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]]; then
                RAW_CUR_V6=""
            fi

            # 组装新的通讯弹匣
            NEW_COMM_IP=""
            if [ -n "$RAW_CUR_V4" ]; then
                NEW_COMM_IP="$RAW_CUR_V4"
            fi
            if [ -n "$RAW_CUR_V6" ]; then
                SAFE_CUR_V6="${RAW_CUR_V6}"
                [[ "$SAFE_CUR_V6" != *"["* ]] && SAFE_CUR_V6="[${SAFE_CUR_V6}]"
                if [ -z "$NEW_COMM_IP" ]; then
                    NEW_COMM_IP="$SAFE_CUR_V6"
                else
                    NEW_COMM_IP="${NEW_COMM_IP}_${SAFE_CUR_V6}"
                fi
            fi

            # 对比IP是否变化
            if [ -n "$NEW_COMM_IP" ] && [ "$NEW_COMM_IP" != "$COMM_IP" ]; then
                echo -e "\033[33m⚠️ 检测到通讯IP已变更！\033[0m"
                echo -e "   旧弹匣 : ${COMM_IP}"
                echo -e "   新弹匣 : ${NEW_COMM_IP}"
                read -p "👉 是否使用新的通讯弹匣重新注册？(y/n, 默认y): " IP_CHANGE_CHOICE
                if [[ "$IP_CHANGE_CHOICE" =~ ^[Nn]$ ]]; then
                    echo -e "🔄 已保留原通讯弹匣: ${COMM_IP}"
                else
                    COMM_IP="$NEW_COMM_IP"
                    echo -e "\033[32m✅ 已更新通讯弹匣: ${COMM_IP}\033[0m"
                fi
            elif [ -z "$NEW_COMM_IP" ]; then
                echo -e "\033[33m⚠️ 未能自动探测到公网IP，将使用配置中的通讯弹匣: ${COMM_IP}\033[0m"
            else
                echo -e "\033[32m✅ 通讯IP未变化，继续使用: ${COMM_IP}\033[0m"
            fi

            # 组装注册指令
            REG_MSG="#REGISTER#|${REGION_CODE}|${NODE_NAME}|${COMM_IP}|${AGENT_PORT}|${NODE_ALIAS}|${ENABLE_OTA}"

            echo -e "\n📤 正在向 Telegram 推送注册指令..."
            TEXT_MSG="✨ *IP-Sentinel 重新发送注册指令！*
📍 节点：\`${NODE_ALIAS}\`
🌐 通讯弹匣：\`${COMM_IP}\`
🔌 端口：\`${AGENT_PORT}\`

🔑 *请点击下方指令复制并回复给机器人：*
\`${REG_MSG}\`"

            # 确定API URL
            if [ "$TG_TOKEN" == "OFFICIAL_GATEWAY_MODE" ]; then
                TG_API_URL="https://omni-gateway.samanthaestime296.workers.dev"
            else
                TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
            fi

            JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
            PUSH_RESULT=$(curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD")

            if echo "$PUSH_RESULT" | grep -q '"ok":true'; then
                echo -e "\033[32m✅ 注册指令已成功推送到您的 Telegram！\033[0m"
                echo -e "👉 请前往 Telegram 复制注册指令并回复给机器人完成重新注册。"
            else
                echo -e "\033[31m❌ 消息推送失败！\033[0m"
                echo -e "   响应: $(echo "$PUSH_RESULT" | head -c 200)"
                echo -e "\n💡 请检查:"
                echo -e "   1. Chat ID 是否正确"
                echo -e "   2. Bot Token 是否有效"
                echo -e "   3. 网络是否正常"
                exit 1
            fi

            echo -e "\n========================================================"
            echo -e "📡 重新注册指令发送完成！"
            echo -e "⚠️ 此操作未修改任何本地文件或运行中的服务。"
            echo -e "========================================================\n"
            exit 0
        fi

        UPGRADE_MODE="false"
        KEEP_LOGS="true"

        if [ "$ACTION_CHOICE" == "1" ] && [ -f "$CONFIG_FILE" ]; then
            echo -e "\n\033[33m💡 哨兵雷达提示：检测到本机已部署过 IP-Sentinel。\033[0m"
            read -p "👉 是否按原配置直接进行平滑升级？(y/n, 默认y): " UPGRADE_CHOICE
            if [[ -z "$UPGRADE_CHOICE" || "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
                UPGRADE_MODE="true"
                read -p "👉 是否保留历史运行日志？(y/n, 默认y): " LOG_CHOICE
                if [[ "$LOG_CHOICE" =~ ^[Nn]$ ]]; then
                    KEEP_LOGS="false"
                fi
                
                source "$CONFIG_FILE"
                echo -e "\033[32m✅ 已激活 [平滑升级模式]，即将跳过基础配置，直接更新核心装甲...\033[0m"
            else
                echo -e "\033[33m🔄 您选择了重新配置，旧的哨兵数据将被彻底抹除。\033[0m"
            fi
        fi
    fi
}

do_interactive_setup() {
    if [ "$UPGRADE_MODE" == "false" ]; then

        # [v4.3.1 重构] 引入有限状态机 (State Machine) 与输入边界防御
        local step=0
        while [ $step -lt 4 ]; do
            case $step in
                0)
                    echo -e "\n\033[36m📍 【第零级】请选择目标战区 (Continent):\033[0m"
                    jq -r '.continents[] | "\(.id)|\(.name)"' "${SECURE_TMP}/map.json" > "${SECURE_TMP}/continents.txt"
                    i=1; CONT_MAP=()
                    while IFS="|" read -r cont_id cont_name; do
                        echo "  $i) $cont_name"
                        CONT_MAP[$i]="$cont_id"
                        ((i++))
                    done < "${SECURE_TMP}/continents.txt"

                    read -p "请输入选择 [1-$((i-1))] (默认1): " CONT_SEL
                    CONT_SEL=${CONT_SEL:-1}
                    if ! [[ "$CONT_SEL" =~ ^[0-9]+$ ]] || [ "$CONT_SEL" -lt 1 ] || [ "$CONT_SEL" -ge "$i" ]; then
                        echo -e "\033[31m❌ 输入非法，请输入列表中的正确数字。\033[0m"
                        continue
                    fi
                    CONT_ID="${CONT_MAP[$CONT_SEL]}"
                    step=1
                    ;;
                1)
                    echo -e "\n\033[36m📍 【第一级】正在检索 [$CONT_ID] 战区下的国家/地区...\033[0m"
                    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | \"\(.id)|\(.name)|\(.keyword_file)\"" "${SECURE_TMP}/map.json" > "${SECURE_TMP}/countries.txt"
                    i=1; COUNTRY_MAP=(); KEYWORD_MAP=()
                    echo "  0) 🔙 返回上一级 (重新选择战区)"
                    while IFS="|" read -r c_id c_name k_file; do
                        echo "  $i) $c_name"
                        COUNTRY_MAP[$i]="$c_id"
                        KEYWORD_MAP[$i]="$k_file"
                        ((i++))
                    done < "${SECURE_TMP}/countries.txt"

                    read -p "请输入选择 [0-$((i-1))] (默认1): " C_SEL
                    C_SEL=${C_SEL:-1}
                    if [ "$C_SEL" -eq 0 ]; then
                        step=0
                        continue
                    fi
                    if ! [[ "$C_SEL" =~ ^[0-9]+$ ]] || [ "$C_SEL" -lt 1 ] || [ "$C_SEL" -ge "$i" ]; then
                        echo -e "\033[31m❌ 输入非法，请输入列表中的正确数字。\033[0m"
                        continue
                    fi
                    COUNTRY_ID="${COUNTRY_MAP[$C_SEL]}"
                    KEYWORD_FILE="${KEYWORD_MAP[$C_SEL]}"
                    REGION_CODE="$COUNTRY_ID" 
                    step=2
                    ;;
                2)
                    echo -e "\n\033[36m📍 【第二级】正在检索 [$COUNTRY_ID] 的行政区数据...\033[0m"
                    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | \"\(.id)|\(.name)\"" "${SECURE_TMP}/map.json" > "${SECURE_TMP}/states.txt"
                    STATE_COUNT=$(wc -l < "${SECURE_TMP}/states.txt")

                    if [ "$STATE_COUNT" -eq 1 ]; then
                        IFS="|" read -r STATE_ID STATE_NAME < "${SECURE_TMP}/states.txt"
                        echo -e "\033[32m💡 该国家下仅有单一配置 [$STATE_NAME]，已自动跃迁。\033[0m"
                        step=3
                        continue
                    else
                        i=1; STATE_MAP=()
                        echo "  0) 🔙 返回上一级 (重新选择国家)"
                        while IFS="|" read -r s_id s_name; do
                            echo "  $i) $s_name"
                            STATE_MAP[$i]="$s_id"
                            ((i++))
                        done < "${SECURE_TMP}/states.txt"
                        read -p "请输入选择 [0-$((i-1))] (默认1): " S_SEL
                        S_SEL=${S_SEL:-1}
                        if [ "$S_SEL" -eq 0 ]; then
                            step=1
                            continue
                        fi
                        if ! [[ "$S_SEL" =~ ^[0-9]+$ ]] || [ "$S_SEL" -lt 1 ] || [ "$S_SEL" -ge "$i" ]; then
                            echo -e "\033[31m❌ 输入非法，请输入列表中的正确数字。\033[0m"
                            continue
                        fi
                        STATE_ID="${STATE_MAP[$S_SEL]}"
                        step=3
                    fi
                    ;;
                3)
                    echo -e "\n\033[36m📍 【第三级】请锁定具体城市节点:\033[0m"
                    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | select(.id==\"$STATE_ID\") | .cities[] | \"\(.id)|\(.name)\"" "${SECURE_TMP}/map.json" > "${SECURE_TMP}/cities.txt"
                    CITY_COUNT=$(wc -l < "${SECURE_TMP}/cities.txt")

                    if [ "$CITY_COUNT" -eq 1 ]; then
                        IFS="|" read -r CITY_ID CITY_NAME < "${SECURE_TMP}/cities.txt"
                        echo -e "\033[32m💡 该区域下仅有单一城市 [$CITY_NAME]，已自动锁定。\033[0m"
                        step=4
                        continue
                    else
                        i=1; CITY_MAP=(); CITY_NAME_MAP=()
                        echo "  0) 🔙 返回上一级 (重新选择行政区)"
                        while IFS="|" read -r c_id c_name; do
                            echo "  $i) $c_name"
                            CITY_MAP[$i]="$c_id"
                            CITY_NAME_MAP[$i]="$c_name"
                            ((i++))
                        done < "${SECURE_TMP}/cities.txt"
                        read -p "请输入选择 [0-$((i-1))] (默认1): " CI_SEL
                        CI_SEL=${CI_SEL:-1}
                        if [ "$CI_SEL" -eq 0 ]; then
                            if [ "$STATE_COUNT" -eq 1 ]; then
                                step=1
                            else
                                step=2
                            fi
                            continue
                        fi
                        if ! [[ "$CI_SEL" =~ ^[0-9]+$ ]] || [ "$CI_SEL" -lt 1 ] || [ "$CI_SEL" -ge "$i" ]; then
                            echo -e "\033[31m❌ 输入非法，请输入列表中的正确数字。\033[0m"
                            continue
                        fi
                        CITY_ID="${CITY_MAP[$CI_SEL]}"
                        CITY_NAME="${CITY_NAME_MAP[$CI_SEL]}"
                        step=4
                    fi
                    ;;
            esac
        done

        rm -f "${SECURE_TMP}/map.json" "${SECURE_TMP}/continents.txt" "${SECURE_TMP}/countries.txt" "${SECURE_TMP}/states.txt" "${SECURE_TMP}/cities.txt"

        mkdir -p "${INSTALL_DIR}/core"
        mkdir -p "${INSTALL_DIR}/data/keywords"
        mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
        mkdir -p "${INSTALL_DIR}/logs"

        echo -e "\n[3/7] 正在初始化养护模块 (默认全量部署，支持 TG 远程动态启停)..."
        ENABLE_GOOGLE="true"
        ENABLE_TRUST="true"

        echo -e "\n[4/7] 是否接入 Master 司令部进行远程联控？ (y/n)"
        read -p "请输入选择 [y/n] (默认y): " TG_CHOICE
        TG_CHOICE=${TG_CHOICE:-y}
        
        TG_TOKEN=""
        CHAT_ID=""
        AGENT_PORT="9527"
        if [[ "$TG_CHOICE" =~ ^[Yy]$ ]]; then
            echo -e "\n请选择中枢接入模式 (推荐私有部署，支持后续 OTA 远程静默升级):"
            echo "  1) 🛡️ 私有独立中枢 (需提供自建 Bot Token，推荐)"
            echo "  2) ☁️ 官方公共网关 (@OmniBeacon_bot，新手免配置)"
            read -p "请输入选择 [1-2] (默认1): " MASTER_TYPE
            MASTER_TYPE=${MASTER_TYPE:-1}
            
            if [ "$MASTER_TYPE" == "2" ]; then
                TG_TOKEN="OFFICIAL_GATEWAY_MODE" 
                TG_API_URL="https://omni-gateway.samanthaestime296.workers.dev" 
                ENABLE_OTA="false"
                echo -e "\033[32m✅ 已自动连接官方安全网关 (@OmniBeacon_bot)。\033[0m"
                echo -e "\033[33m👉 请确保您已在 TG 中关注官方机器人并发送过 /start，否则将无法接收消息。\033[0m"
                echo -e "\n\033[33m⚠️ 【安全熔断提示】\033[0m"
                echo -e "\033[33m由于您使用了官方公共网关，为防止潜在的滥用或供应链风险，本节点的 [OTA 远程升级] 权限已被系统底层强制禁用。\033[0m"
                echo -e "\033[33m💡 若未来需要启用 OTA，请自建私有中枢后重新部署本节点。\033[0m"
            else
                echo -e "\n\033[36m📘 私有 Bot 创建教程: \033[4m\033]8;;https://blog.iot-architect.com/engineering-practice/create-private-telegram-bot-via-botfather/\033\\👉 [点击此处直接在浏览器中打开]\033]8;;\033\\ 👈\033[0m"
                echo -e "\033[90m   (若您的终端较老不支持点击，请手动复制: https://blog.iot-architect.com/engineering-practice/create-private-telegram-bot-via-botfather/ )\033[0m"
                read -p "请输入您的私有 Telegram Bot Token: " RAW_TOKEN
                USER_TOKEN=$(echo "$RAW_TOKEN" | tr -cd 'a-zA-Z0-9_:-')
                while [ -z "$USER_TOKEN" ]; do
                    read -p "⚠️ Token 不能为空或包含非法字符，请重新输入: " RAW_TOKEN
                    USER_TOKEN=$(echo "$RAW_TOKEN" | tr -cd 'a-zA-Z0-9_:-')
                done
                
                TG_TOKEN="$USER_TOKEN"
                TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
                echo -e "\033[32m✅ 已记录您的私有机器人 Token。\033[0m"
                
                echo -e "\n\033[36m[4.1/7] OTA 远程静默升级授权\033[0m"
                echo -e "💡 开启后，您可以在 TG 面板一键将本节点热更新至最新版本。"
                read -p "是否允许本节点接收 OTA 升级指令？(y/n, 默认y): " OTA_CHOICE
                if [[ "$OTA_CHOICE" =~ ^[Nn]$ ]]; then
                    ENABLE_OTA="false"
                    echo -e "🛡️ \033[33m已关闭 OTA 权限，本节点未来将只能通过 SSH 手动升级。\033[0m"
                else
                    ENABLE_OTA="true"
                    echo -e "✅ \033[32m已开启 OTA 权限，核按钮已挂载至您的私有中枢。\033[0m"
                fi
            fi

            echo -e "\n\033[33m💡 提示：如果您不知道下方自己的 Chat ID 是什么，可以关注 @userinfobot 获取。\033[0m"
            echo -e "\033[36m📘 查看图文教程: \033[4m\033]8;;https://blog.iot-architect.com/engineering-practice/get-telegram-personal-id-via-userinfobot/\033\\👉 [点击此处直接在浏览器中打开]\033]8;;\033\\ 👈\033[0m"
            echo -e "\033[90m   (若您的终端较老不支持点击，请手动复制: https://blog.iot-architect.com/engineering-practice/get-telegram-personal-id-via-userinfobot/ )\033[0m"
            read -p "请输入你的 Chat ID (必须准确，否则无法联控): " RAW_CHAT_ID
            CHAT_ID=$(echo "$RAW_CHAT_ID" | tr -cd '0-9-')
            
            echo -e "\n\033[36m[4.2/7] 正在构建 Webhook 安全通信隧道...\033[0m"
            echo -n "🎲 正在探测可用随机端口..."
            while true; do
                RANDOM_PORT=$((RANDOM % 55536 + 10000))
                if ! (ss -tuln 2>/dev/null | grep -q ":$RANDOM_PORT " || netstat -tuln 2>/dev/null | grep -q ":$RANDOM_PORT "); then
                    break
                fi
                echo -n "."
            done
            echo -e " 完成！"
            
            echo -e "💡 系统为您生成的推荐随机高位端口为: \033[32m$RANDOM_PORT\033[0m"
            echo -e "\033[33m(该端口已通过本地占用校验，可直接使用)\033[0m"
            
            while true; do
                read -p "请输入 Webhook 监听端口 (回车采用推荐, 或手动输入): " INPUT_PORT
                
                if [ -z "$INPUT_PORT" ]; then
                    AGENT_PORT="$RANDOM_PORT"
                    break
                else
                    if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
                        if (ss -tuln 2>/dev/null | grep -q ":$INPUT_PORT " || netstat -tuln 2>/dev/null | grep -q ":$INPUT_PORT "); then
                            echo -e "\033[31m❌ 端口 $INPUT_PORT 已被占用，请重新输入或使用推荐端口。\033[0m"
                        else
                            AGENT_PORT="$INPUT_PORT"
                            break
                        fi
                    else
                        echo -e "\033[31m❌ 输入非法！端口范围应为 1-65535。\033[0m"
                    fi
                fi
            done
            echo -e "✅ 已锁定 Webhook 通讯端口: \033[32m$AGENT_PORT\033[0m"
        fi
    fi
}

do_final_report() {
    if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
        
        # 注册报文中塞入多宿主弹匣 SAFE_COMM_IP
        REG_MSG="#REGISTER#|${REGION_CODE}|${NODE_NAME}|${SAFE_COMM_IP}|${AGENT_PORT}|${NODE_ALIAS}|${ENABLE_OTA}"
        
        if [ "$UPGRADE_MODE" == "true" ]; then
            OLD_VERSION=$(grep "^AGENT_VERSION=" "$CONFIG_FILE" | cut -d'"' -f2)
            [ -z "$OLD_VERSION" ] && OLD_VERSION="3.3.1"
            
            if version_lt "$OLD_VERSION" "4.2.2"; then
                echo -e "\n📡 [路由枢纽] 正在执行容灾架构重组 (v${OLD_VERSION} -> v${TARGET_VERSION})..."
                TEXT_MSG="✨ *IP-Sentinel 容灾引擎热更新完成！*
📍 节点：\`${NODE_ALIAS}\`
🌐 养护 IP：\`${SAFE_PUBLIC_IP}\`
📡 容灾弹匣：\`${SAFE_COMM_IP}\`
🚀 状态：v${TARGET_VERSION} 全域双栈引擎已部署

⚠️ *通讯架构已升级为多宿主容灾模式！*
👉 **请务必点击下方指令并发送，将新版通讯弹匣同步至司令部：**
\`${REG_MSG}\`"
                
                JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
                curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" >/dev/null 2>&1
                
                echo -e "\033[32m✅ 升级通知已推送！请前往 TG 点击注册指令完成身份同步！\033[0m"
                
            else
                echo -e "\n📡 [路由枢纽] 正在执行静默平滑升级 (v${OLD_VERSION} -> v${TARGET_VERSION})..."
                TEXT_MSG="✨ *IP-Sentinel 引擎热更新完成！*
📍 节点：\`${NODE_ALIAS}\`
🌐 养护 IP：\`${SAFE_PUBLIC_IP}\`
📡 容灾 IP：\`${SAFE_COMM_IP}\`
🚀 状态：v${TARGET_VERSION} OTA 动态活体引擎已部署"

                JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
                curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" >/dev/null 2>&1

                echo -e "\033[32m✅ 升级成功通知已推送到您的 Telegram！\033[0m"
            fi
            
            sed -i '/^NAME_HASHED=/d' "$CONFIG_FILE" 2>/dev/null
            if grep -q "^AGENT_VERSION=" "$CONFIG_FILE"; then
                sed -i "s/^AGENT_VERSION=.*/AGENT_VERSION=\"$TARGET_VERSION\"/" "$CONFIG_FILE"
            else
                echo "AGENT_VERSION=\"$TARGET_VERSION\"" >> "$CONFIG_FILE"
            fi
            
        else
            echo -e "\n📡 正在向指挥部发送注册暗号..."
            
            # [修补重点] 必须转义，否则含有下划线的 SAFE_COMM_IP_ESC 在 Telegram Markdown 中会引发 400 Bad Request
            SAFE_COMM_IP_ESC=$(echo "$SAFE_COMM_IP" | sed 's/_/\\_/g')
            
            TEXT_MSG="✨ *IP-Sentinel 部署成功！*
📍 区域：${REGION_NAME}
🌐 养护 IP：\`${SAFE_PUBLIC_IP}\`
📡 容灾 IP：\`${SAFE_COMM_IP_ESC}\`
🔌 端口：\`${AGENT_PORT}\`

🔑 *请点击下方指令复制并回复给机器人：*
\`${REG_MSG}\`"

            JSON_PAYLOAD=$(jq -n --arg cid "$CHAT_ID" --arg txt "$TEXT_MSG" --arg cb "manage:${NODE_NAME}" '{chat_id: $cid, text: $txt, parse_mode: "Markdown", reply_markup: {inline_keyboard: [[{text: "⚙️ 调出该节点控制台", callback_data: $cb}]]}}')
            PUSH_RESULT=$(curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD")

            if echo "$PUSH_RESULT" | grep -q '"ok":true'; then
                echo -e "\033[32m✅ 注册信息已推送到您的 Telegram，请按指令完成最终激活！\033[0m"
            else
                echo -e "\033[31m❌ 消息推送失败，请检查 Chat ID 是否正确或是否已关注机器人。\033[0m"
            fi
        fi
    fi
}

do_show_summary() {
    echo "========================================================"
    if [ "$UPGRADE_MODE" == "true" ]; then
        echo "🎉 边缘节点 (Agent) 平滑热更新已彻底完成！"
    else
        echo "🎉 边缘节点 (Agent) 部署流程彻底完成！"
    fi
    echo "📍 你的本地守护区域已锁定为: $REGION_NAME"
    echo "⚙️ 哨兵现已开启 [每20分钟] 的高频高拟真养护循环。"
    if [[ -n "$TG_TOKEN" ]]; then
        echo "📡 Webhook 监听已启动 (端口: $AGENT_PORT) 并向中枢发送了注册请求。"
        
        echo -e "\n🛡️ \033[36m[🔥 防火墙自动化操纵] 正在检测本地防线并全开双栈对空通道...\033[0m"
        
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw active; then
            ufw allow "$AGENT_PORT"/tcp >/dev/null 2>&1
            echo -e " ✅ \033[32mUFW 防火墙检测到活跃态，规则注入成功 (IPv4 & IPv6 双栈已通)。\033[0m"
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld | grep -qw active; then
            firewall-cmd --zone=public --add-port="$AGENT_PORT"/tcp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            echo -e " ✅ \033[32mFirewalld 防火墙检测到活跃态，持久化策略重载完成。\033[0m"
        else
            local fw_applied=false
            if command -v iptables >/dev/null 2>&1; then
                iptables -I INPUT -p tcp --dport "$AGENT_PORT" -j ACCEPT >/dev/null 2>&1
                fw_applied=true
            fi
            if command -v ip6tables >/dev/null 2>&1; then
                ip6tables -I INPUT -p tcp --dport "$AGENT_PORT" -j ACCEPT >/dev/null 2>&1
                fw_applied=true
            fi
            
            if [ "$fw_applied" = true ]; then
                echo -e " ✅ \033[32mRaw Netfilter 链条锁定，已通过 iptables/ip6tables 强行挂载入站例外。\033[0m"
            else
                echo -e " 💡 \033[33m未检测到本机活跃的常规 Linux 防火墙组件，维持全通态势。\033[0m"
            fi
        fi
        
        echo -e "\n\033[31m⚠️ 【高危警告】您的节点通讯寻址池已锁定为: $SAFE_COMM_IP\033[0m"
        echo -e "\033[33m为确保 Master 司令部能够成功下发指令，您【必须】前往云服务商 (如 AWS/Oracle/阿里云 等) 的网页控制台中，将安全组 (Security Group) 防火墙的 TCP $AGENT_PORT 端口彻底放行！\033[0m"
        echo -e "\033[31m⛔ 本系统已开启全域双栈监听，禁止尝试通过修改脚本强行绑定局域网 IP 来绕过通信阻断！\033[0m\n"
    fi
    echo "🗑️ 若未来需卸载，可重新运行本脚本选择[2]或执行: bash ${INSTALL_DIR}/core/uninstall.sh"
    echo "========================================================"

    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
        AGENT_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/agent" || echo "")

        if [ -n "$AGENT_COUNT" ] && [[ "$AGENT_COUNT" =~ ^[0-9]+$ ]]; then
            echo -e "\033[32m✅ 感谢您成为全球第 ${AGENT_COUNT} 名 IP-Sentinel 节点维护者！\033[0m"
        else
            echo -e "\033[32m✅ 感谢您部署 IP-Sentinel！\033[0m"
        fi
    fi

    echo -e "\n========================================================"
    echo -e "⭐ \033[33m开源不易，如果 IP-Sentinel 提升了您的节点稳定性，请赐予我们一枚星标！\033[0m"
    echo -e "💡 \033[32m您的每一颗 Star 都是我们持续对抗风控、维护更新指纹库的核心动力。\033[0m"
    echo -e "👉 \033[36m\033[4m\033]8;;https://github.com/hotyue/IP-Sentinel\033\\点击此处直达 GitHub 仓库点亮 Star 🌟\033[0m\033]8;;\033\\"
    echo -e "========================================================\n"
}
