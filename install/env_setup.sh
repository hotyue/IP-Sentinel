#!/bin/bash
# IPS-MAGIC:IP-SENTINEL-ENV-SETUP-v4.3.0
# ==========================================================
# 模块名称: env_setup.sh
# 核心功能: 靶机架构预检、多分支包管理器依赖补全
# ==========================================================

is_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    return 0
}

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        uname -srm
    fi
}

get_virt_info() {
    if grep -qaE 'docker|containerd|podman' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        echo "Docker/OCI Container"
    elif grep -qa container=lxc /proc/1/environ 2>/dev/null || [ -d /proc/vz ]; then
        echo "LXC/OpenVZ"
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt
    else
        echo "Unknown/Bare Metal"
    fi
}

version_lt() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" && test "$1" != "$2"
}

do_env_precheck() {
    echo -e "\n======================================"
    echo -e "📊 \033[36mIP-Sentinel 靶机环境侦测预检\033[0m"
    echo -e "--------------------------------------"
    echo -e "OS 架构   : $(get_os_info)"
    echo -e "虚拟化    : $(get_virt_info)"
    if is_systemd; then
        echo -e "Init 系统 : systemd ✅"
    else
        echo -e "Init 系统 : 非 systemd ⚠️ (将自动降维至守护循环)"
    fi
    echo -e "======================================\n"
    sleep 1
    
    INSTALL_DIR="/opt/ip_sentinel"
    CONFIG_FILE="${INSTALL_DIR}/config.conf"
}

do_fetch_version() {
    # 已由外壳入口拉取并 export TARGET_VERSION，此处只需保障兜底容错
    TARGET_VERSION=${TARGET_VERSION:-"4.3.1"}
}

do_install_deps() {
    echo -e "\n[1/7] 正在探测并安装基础环境依赖 (curl, jq, cron, procps, python3, sqlite3)..."
    
    REQUIRED_CMDS=("curl" "jq" "crontab" "pgrep" "python3" "openssl" "sqlite3")
    MISSING_CMDS=()

    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            MISSING_CMDS+=("$cmd")
        fi
    done

    if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
        echo "⏳ 发现缺失依赖: ${MISSING_CMDS[*]}，正在尝试自动补齐..."
        
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y --no-install-recommends curl jq cron procps python3 openssl sqlite3 >/dev/null 2>&1
            systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1
            
        elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
            PKG_MGR="yum"
            OPT_ARGS=""
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
                OPT_ARGS="--setopt=install_weak_deps=False"
            elif command -v microdnf >/dev/null 2>&1; then
                PKG_MGR="microdnf"
            fi
            
            echo -e "\033[90m   (正在安装 epel-release 扩展源，请稍候...)\033[0m"
            $PKG_MGR install -y epel-release >/dev/null 2>&1 || true
            
            echo -e "\033[90m   (正在拉取核心组件...)\033[0m"
            $PKG_MGR install -y $OPT_ARGS curl jq cronie procps-ng python3 openssl sqlite
            systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1
            
        elif command -v apk >/dev/null 2>&1; then
            echo "Alpine 探测到系统类型为 Alpine Linux，正在执行轻量级安装..."
            apk add --no-cache curl jq cronie procps python3 bash openssl sqlite || apk add --no-cache curl jq procps python3 bash openssl sqlite
            mkdir -p /var/spool/cron/crontabs
            rc-update add crond default >/dev/null 2>&1
            service crond start >/dev/null 2>&1
            
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S --needed --noconfirm curl jq cronie procps-ng python openssl sqlite >/dev/null 2>&1
            mkdir -p /root/.cache/crontab 2>/dev/null
            systemctl enable cronie >/dev/null 2>&1 && systemctl start cronie >/dev/null 2>&1
            
        else
            echo -e "\033[31m❌ 自动安装失败：系统未知的包管理器。\033[0m"
            echo -e "\033[33m⚠️ 请根据您的操作系统，手动执行以下安装命令后重新运行本脚本：\033[0m"
            echo -e "  Debian/Ubuntu: \033[36mapt-get update && apt-get install -y --no-install-recommends curl jq cron procps python3 openssl sqlite3\033[0m"
            echo -e "  CentOS/RHEL:   \033[36myum install -y curl jq cronie procps-ng python3 openssl sqlite\033[0m"
            echo -e "  Alpine Linux:  \033[36mapk add --no-cache curl jq cronie procps python3 bash openssl sqlite\033[0m"
            echo -e "  Arch Linux:    \033[36mpacman -Syu --needed curl jq cronie procps-ng python openssl sqlite\033[0m"
            exit 1
        fi
        
        for cmd in "${REQUIRED_CMDS[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo -e "\033[31m❌ 致命错误：核心命令 '$cmd' 仍未找到！\033[0m"
                echo -e "这通常是因为您的系统源配置错误或缺失基础组件库导致。"
                echo -e "请手动修复您的包管理器源，或联系 VPS 供应商重新格式化系统。"
                exit 1
            fi
        done
    fi
    echo -e "\033[32m✅ 基础环境检测通过。\033[0m"
}
