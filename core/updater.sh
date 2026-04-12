#!/bin/bash

# ==========================================================
# 脚本名称: updater.sh (IP-Sentinel V3.1.4 养料注入与维护中枢)
# 核心功能: 静默更新热数据(指纹/词库/LBS规则)、清理瘦身日志
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
# 你的 GitHub 仓库 Raw 数据直链前缀 (统一标准)
REPO_RAW_URL="https://raw.githubusercontent.com/Seameee/IP-Sentinel/main"
# 临时改为私库地址用于测试
# REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"

# 1. 加载本地冷数据配置
if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi
source "$CONFIG_FILE"

# 2. 全局日志写入函数
log() {
    mkdir -p "${INSTALL_DIR}/logs"
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] [%-5s] [%-7s] [%s] %s\n" "$2" "$1" "$REGION_CODE" "$3" >> "$LOG_FILE"
}

log "Updater" "INFO " "========== 触发后台静默 OTA 热数据更新 =========="

# 3. 容灾机制拉取 UA 指纹池 (强制遵循锚点协议)
TMP_UA="/tmp/ip_sentinel_ua.txt"
curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/data/user_agents.txt" -o "$TMP_UA"
if [ -s "$TMP_UA" ]; then
    mv "$TMP_UA" "${INSTALL_DIR}/data/user_agents.txt"
    log "Updater" "INFO " "✅ 设备指纹池 (User-Agents) 更新成功"
else
    log "Updater" "WARN " "❌ UA 池拉取失败，保留本地旧数据防崩溃"
    rm -f "$TMP_UA"
fi

# 4. 容灾机制拉取当地最新搜索词库
TMP_KW="/tmp/ip_sentinel_kw.txt"
curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "$TMP_KW"
if [ -s "$TMP_KW" ]; then
    mv "$TMP_KW" "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"
    log "Updater" "INFO " "✅ 区域搜索词库 (kw_${REGION_CODE}) 更新成功"
else
    log "Updater" "WARN " "❌ 搜索词库拉取失败，保留本地旧数据防崩溃"
    rm -f "$TMP_KW"
fi

# 5. 【V3.1.4 核心升级】自适应拉取本地 LBS 专属 JSON 规则库
# 利用 find 穿透寻找本地唯一的 json
REGION_JSON_FILE=$(find "${INSTALL_DIR}/data/regions" -name "*.json" 2>/dev/null | head -n 1)

if [ -n "$REGION_JSON_FILE" ] && [ -f "$REGION_JSON_FILE" ]; then
    # 提取本地文件的相对路径 (例如: data/regions/US/CA/San_Jose.json)
    REL_PATH=${REGION_JSON_FILE#*${INSTALL_DIR}/}
    TMP_JSON="/tmp/ip_sentinel_region.json"
    
    # 按照相同的相对路径去云端拉取更新
    curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/${REL_PATH}" -o "$TMP_JSON"
    if [ -s "$TMP_JSON" ]; then
        mv "$TMP_JSON" "$REGION_JSON_FILE"
        log "Updater" "INFO " "✅ 核心战区规则库 ($REL_PATH) 更新成功"
    else
        log "Updater" "WARN " "❌ 战区规则库拉取失败，保留本地旧数据"
        rm -f "$TMP_JSON"
    fi
fi

# 6. 日志防满瘦身机制 (保留最近 2000 行)
if [ -f "$LOG_FILE" ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "Updater" "INFO " "🧹 系统日志已完成定期清理瘦身 (保留最新 2000 行)"
fi

log "Updater" "INFO " "========== OTA 养料注入与系统维护结束 =========="