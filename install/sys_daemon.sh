#!/bin/bash
# IPS-MAGIC:IP-SENTINEL-SYSDAEMON-v4.3.0
# ==========================================================
# 模块名称: sys_daemon.sh
# 核心功能: 安装前物理清洗、双缓冲下载执行域、Systemd/Cron 进程注入
# ==========================================================

# ----------------------------------------------------------
# [时序 6] 安装前的环境纯净度构建与幽灵进程抹除
# ----------------------------------------------------------
do_clean_env() {
    echo -e "\n⏳ 正在清理系统定时任务中的旧版条目..."

    crontab -l 2>/dev/null | grep -v "ip_sentinel" > "${SECURE_TMP}/cron_clean" || true
    [ -f "${SECURE_TMP}/cron_clean" ] && crontab "${SECURE_TMP}/cron_clean" >/dev/null 2>&1
    rm -f "${SECURE_TMP}/cron_clean"

    for CRON_FILE in "/var/spool/cron/crontabs/root" "/etc/crontabs/root"; do
        if [ -f "$CRON_FILE" ]; then
            grep -v "ip_sentinel" "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
            cat "${CRON_FILE}.tmp" > "$CRON_FILE" 2>/dev/null || true
            rm -f "${CRON_FILE}.tmp" 2>/dev/null
        fi
    done
    rm -f /etc/local.d/ip_sentinel.start 2>/dev/null

    if [ "$UPGRADE_MODE" == "true" ]; then
        # [v4.2.2 终极保障] 平滑升级时强制销毁旧版 TLS 证书与旧版 IP 缓存，逼迫下层组件重铸健康双栈装甲
        rm -f "${INSTALL_DIR}/core/cert.pem" "${INSTALL_DIR}/core/key.pem" "${INSTALL_DIR}/core/.last_ip" 2>/dev/null
        echo -e "🧹 历史底层缓存及残旧 TLS 证书已强制销毁，准备重铸安全装甲。"

        if [ "$KEEP_LOGS" == "false" ]; then
            rm -rf "${INSTALL_DIR}/logs" 2>/dev/null
            echo -e "🗑️ 历史战地日志已按指令清空。"
        else
            echo -e "📦 历史配置与战地日志已妥善保留。"
        fi
    else
        if [ -d "$INSTALL_DIR" ]; then
            rm -rf "${INSTALL_DIR}/core" "${INSTALL_DIR}/data" "${INSTALL_DIR}/config.conf" "${INSTALL_DIR}/.last_ip" 2>/dev/null
        fi
    fi
    echo -e "\033[32m✅ 环境清理完毕，幽灵进程已肃清！\033[0m"
}

# ----------------------------------------------------------
# [时序 11] 防变砖双缓冲下载执行域 (覆写引擎)
# ----------------------------------------------------------
do_deploy_core() {
    echo -e "\n[6/7] 正在部署核心引擎与热数据..."
    mkdir -p "${INSTALL_DIR}/data/keywords"

    TMP_CORE="${SECURE_TMP}/core_update"
    mkdir -p "$TMP_CORE"

    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/runner.sh" -o "${TMP_CORE}/runner.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/updater.sh" -o "${TMP_CORE}/updater.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/tg_report.sh" -o "${TMP_CORE}/tg_report.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/agent_daemon.sh" -o "${TMP_CORE}/agent_daemon.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/uninstall.sh" -o "${TMP_CORE}/uninstall.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/mod_google.sh" -o "${TMP_CORE}/mod_google.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/mod_trust.sh" -o "${TMP_CORE}/mod_trust.sh"
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/mod_quality.sh" -o "${TMP_CORE}/mod_quality.sh"

    # 🛡️ 终极自检墙：一旦任意文件缺失或长度为零，直接熔断放弃覆写，确保宿主不宕机
    if [ ! -s "${TMP_CORE}/runner.sh" ] || [ ! -s "${TMP_CORE}/agent_daemon.sh" ]; then
        echo -e "\033[31m❌ 致命错误：核心代码拉取失败！网络阻断或 GitHub Raw 异常。\033[0m"
        echo "🛡️ 防砖机制触发：已中止覆盖，旧版哨兵引擎仍安全存活中。"
        rm -rf "$TMP_CORE"
        exit 1
    fi

    echo "⏳ 新引擎校验通过，正在抹杀旧版守护进程..."
    if is_systemd; then
        systemctl kill --signal=SIGKILL ip-sentinel-agent-daemon.service >/dev/null 2>&1 || true
        systemctl stop ip-sentinel-runner.timer ip-sentinel-updater.timer ip-sentinel-report.timer ip-sentinel-agent-daemon.service >/dev/null 2>&1 || true
    fi
    pkill -9 -f "webhook.py" >/dev/null 2>&1 || true
    pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1 || true
    pkill -9 -f "runner.sh" >/dev/null 2>&1 || true
    pkill -9 -f "tg_report.sh" >/dev/null 2>&1 || true
    pkill -9 -f "updater.sh" >/dev/null 2>&1 || true
    pkill -9 -f "sentinel_scheduler.sh" >/dev/null 2>&1 || true

    rm -rf "${INSTALL_DIR}/core" 2>/dev/null
    mv "$TMP_CORE" "${INSTALL_DIR}/core"
    chmod +x ${INSTALL_DIR}/core/*.sh

    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/user_agents.txt" -o "${INSTALL_DIR}/data/user_agents.txt"
    if [ "$UPGRADE_MODE" == "false" ]; then
        curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}" -o "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
    else
        curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------
# [时序 12] Systemd 原生注入与微内核定时降级兜底
# ----------------------------------------------------------
do_inject_daemon() {
    echo -e "\n[7/7] 正在注入系统守护进程与调度器..."

    DEPLOY_UTC_HOUR=$(date -u +%H)
    DEPLOY_UTC_MIN=$(date -u +%M)

    echo $(date -u +%s) > "${INSTALL_DIR}/core/.ua_last_update"

    if is_systemd; then
        echo "💡 检测到 Systemd 环境，正在部署原生守护服务..."
        
        cat > /etc/systemd/system/ip-sentinel-runner.service << EOF
[Unit]
Description=IP-Sentinel Runner Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/runner.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

        cat > /etc/systemd/system/ip-sentinel-runner.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Runner Service
[Timer]
OnCalendar=*:0/20
RandomizedDelaySec=180
Persistent=true
Unit=ip-sentinel-runner.service
[Install]
WantedBy=timers.target
EOF

        cat > /etc/systemd/system/ip-sentinel-updater.service << EOF
[Unit]
Description=IP-Sentinel Updater Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/updater.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

        cat > /etc/systemd/system/ip-sentinel-updater.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Updater Service
[Timer]
OnCalendar=*-*-* ${DEPLOY_UTC_HOUR}:${DEPLOY_UTC_MIN}:00 UTC
Persistent=true
Unit=ip-sentinel-updater.service
[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable --now ip-sentinel-runner.timer ip-sentinel-updater.timer

        if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
            cat > /etc/systemd/system/ip-sentinel-report.service << EOF
[Unit]
Description=IP-Sentinel Telegram Report Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/tg_report.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

            cat > /etc/systemd/system/ip-sentinel-report.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Telegram Report Service
[Timer]
OnCalendar=*-*-* 16:00:00 UTC
Unit=ip-sentinel-report.service
[Install]
WantedBy=timers.target
EOF

            cat > /etc/systemd/system/ip-sentinel-agent-daemon.service << EOF
[Unit]
Description=IP-Sentinel Agent Daemon Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=simple
ExecStart=/bin/bash ${INSTALL_DIR}/core/agent_daemon.sh
Restart=always
RestartSec=5
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
EOF

            DAEMON_IP=$( (curl -s -m 5 api.ip.sb/ip || curl -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
            [ -n "$DAEMON_IP" ] && echo "$DAEMON_IP" > "${INSTALL_DIR}/core/.last_ip" || echo "$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')" > "${INSTALL_DIR}/core/.last_ip"
            
            systemctl daemon-reload
            systemctl enable --now ip-sentinel-report.timer
            systemctl enable --now ip-sentinel-agent-daemon.service
        fi
    else
        echo "💡 未检测到 Systemd，正在配置备用调度器 (兼容 Alpine/OpenRC)..."
        
        IS_RESTRICTED_ALPINE="false"
        if [ -f /etc/alpine-release ]; then
            if [ -d /proc/vz ] || grep -qa container=lxc /proc/1/environ 2>/dev/null || [ -f /.dockerenv ]; then
                IS_RESTRICTED_ALPINE="true"
            fi
        fi

        if [ "$IS_RESTRICTED_ALPINE" == "true" ]; then
            echo -e "⚠️ 探测到受限的 LXC/OpenVZ Alpine 环境，系统自带 Cron 极易假死。"
            echo -e "🔧 自动降维打击：启用 [自定义高可用死循环调度器] 接管全局任务..."
            
            rc-update del crond default >/dev/null 2>&1 || true
            rc-service crond stop >/dev/null 2>&1 || true
            pkill -9 crond >/dev/null 2>&1 || true
            crontab -l 2>/dev/null | grep -v "ip_sentinel" > "${SECURE_TMP}/cron_clean" || true
            [ -f "${SECURE_TMP}/cron_clean" ] && crontab "${SECURE_TMP}/cron_clean" >/dev/null 2>&1
            rm -f "${SECURE_TMP}/cron_clean"

            cat > ${INSTALL_DIR}/core/sentinel_scheduler.sh << EOF
#!/bin/bash
while true; do
    MIN=\$(date -u +%M)
    HOUR=\$(date -u +%H)
    if [ "\$MIN" == "00" ] || [ "\$MIN" == "20" ] || [ "\$MIN" == "40" ]; then
        /bin/bash /opt/ip_sentinel/core/runner.sh >/dev/null 2>&1
    fi
    if [ "\$HOUR" == "${DEPLOY_UTC_HOUR}" ] && [ "\$MIN" == "${DEPLOY_UTC_MIN}" ]; then
        /bin/bash /opt/ip_sentinel/core/updater.sh >/dev/null 2>&1
    fi
    if [ "\$HOUR" == "16" ] && [ "\$MIN" == "00" ]; then
        /bin/bash /opt/ip_sentinel/core/tg_report.sh >/dev/null 2>&1
    fi
    if ! pgrep -f 'webhook.py' >/dev/null; then
        /bin/bash /opt/ip_sentinel/core/agent_daemon.sh >/dev/null 2>&1 &
    fi
    sleep 60
done
EOF
            chmod +x ${INSTALL_DIR}/core/sentinel_scheduler.sh

            if command -v rc-update >/dev/null 2>&1 && [ -d "/etc/local.d" ]; then
                echo "nohup bash ${INSTALL_DIR}/core/sentinel_scheduler.sh >/dev/null 2>&1 &" > /etc/local.d/ip_sentinel_scheduler.start
                chmod +x /etc/local.d/ip_sentinel_scheduler.start
                rc-update add local default >/dev/null 2>&1
            else
                grep -q "sentinel_scheduler" /etc/profile || echo "nohup bash ${INSTALL_DIR}/core/sentinel_scheduler.sh >/dev/null 2>&1 &" >> /etc/profile
            fi
            
            [ -n "$PUBLIC_IP" ] && echo "$PUBLIC_IP" > "${INSTALL_DIR}/core/.last_ip"
            nohup bash ${INSTALL_DIR}/core/sentinel_scheduler.sh >/dev/null 2>&1 &
            
        else
            crontab -l 2>/dev/null | grep -v "ip_sentinel" > "${SECURE_TMP}/cron_backup" || true
            echo "*/20 * * * * ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
            echo "${DEPLOY_UTC_MIN} ${DEPLOY_UTC_HOUR} * * * ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
            
            if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
                echo "0 16 * * * ${INSTALL_DIR}/core/tg_report.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
                echo "$SAFE_PUBLIC_IP" > "${INSTALL_DIR}/core/.last_ip"
                DAEMON_IP=$( (curl -s -m 5 api.ip.sb/ip || curl -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
                [ -n "$DAEMON_IP" ] && echo "$DAEMON_IP" > "${INSTALL_DIR}/core/.last_ip" || echo "$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')" > "${INSTALL_DIR}/core/.last_ip"
                
                if command -v rc-update >/dev/null 2>&1 && [ -d "/etc/local.d" ]; then
                    echo "nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" > /etc/local.d/ip_sentinel.start
                    chmod +x /etc/local.d/ip_sentinel.start
                    rc-update add local default >/dev/null 2>&1
                else
                    echo "@reboot nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> "${SECURE_TMP}/cron_backup"
                fi
                
                echo "* * * * * pgrep -f 'webhook.py' >/dev/null || nohup bash ${INSTALL_DIR}/core/agent_daemon.sh >/dev/null 2>&1 &" >> "${SECURE_TMP}/cron_backup"
                
                nohup bash "${INSTALL_DIR}/core/agent_daemon.sh" >/dev/null 2>&1 &
            fi
            
            [ -f "${SECURE_TMP}/cron_backup" ] && crontab "${SECURE_TMP}/cron_backup" >/dev/null 2>&1
            
            if [ -d "/etc/crontabs" ] && [ -f "/var/spool/cron/crontabs/root" ]; then
                cp -f /var/spool/cron/crontabs/root /etc/crontabs/root 2>/dev/null || true
                chmod 600 /etc/crontabs/root 2>/dev/null || true
            fi
            
            if command -v rc-service >/dev/null 2>&1; then
                rc-service crond restart >/dev/null 2>&1 || crond -b >/dev/null 2>&1
            else
                pkill -9 crond 2>/dev/null || true
                crond -b >/dev/null 2>&1 || true
            fi
            
            rm -f "${SECURE_TMP}/cron_backup"
        fi
    fi
}
