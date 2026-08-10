#!/bin/bash
# IPS-MAGIC:IP-SENTINEL-BUILD-MASTER-v4.3.0
# ==========================================================
# 模块名称: build_master.sh (v4.3.0 Orchestrator)
# 核心功能: Master 安装业务总指挥，按原版时序复用组件
# ==========================================================

# [安全修复] 供应链完整性校验 — 防止远程脚本被投毒替换
verify_magic() {
    local file="$1"
    local expected_magic="# IPS-MAGIC:"
    if ! head -5 "$file" 2>/dev/null | grep -q "$expected_magic"; then
        echo -e "\033[31m❌ 完整性校验失败：${file} 缺少 MAGIC STRING，疑似供应链投毒！\033[0m"
        exit 1
    fi
    # [安全修复] 文件大小检查 — 拒绝空脚本和异常大的脚本（>500KB）
    local fsize=$(stat -c%s "$file" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 50 ]; then
        echo -e "\033[31m❌ 完整性校验失败：${file} 文件过小 (${fsize} bytes)，疑似被截断！\033[0m"
        exit 1
    fi
    if [ "$fsize" -gt 512000 ]; then
        echo -e "\033[31m❌ 完整性校验失败：${file} 文件过大 (${fsize} bytes)，疑似注入攻击！\033[0m"
        exit 1
    fi
}

# 传递中断引信
trap 'exit 1' INT QUIT TERM

# Master 仅需要复用 env_setup 和专属的 master_setup
MODULES=(
    "env_setup.sh"
    "master_setup.sh"
)

for mod in "${MODULES[@]}"; do
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/${mod}?t=$(date +%s)" -o "${SECURE_TMP}/${mod}"
    if [ ! -s "${SECURE_TMP}/${mod}" ]; then
        echo -e "\033[31m❌ 致命错误：中枢依赖模块 [${mod}] 装载失败！\033[0m"
        exit 1
    fi
    # [安全修复] 下载后校验完整性再执行
    verify_magic "${SECURE_TMP}/${mod}"
    bash -n "${SECURE_TMP}/${mod}" >/dev/null 2>&1 || {
        echo -e "\033[31m❌ 语法校验失败：${mod} 脚本格式异常，已熔断！\033[0m"
        exit 1
    }
    source "${SECURE_TMP}/${mod}"
done

# ==========================================================
# 核心业务原子流 (100% 忠实于原版 install_master.sh 执行时序)
# ==========================================================

# [复用模块: env_setup.sh]
do_master_env_precheck   # 预检 (复用了与 Agent 相同逻辑但修改了提示语，见下方)
do_fetch_master_version  # 抓取版本
do_master_handle_menu    # 拦截指令或展示交互菜单
do_install_deps          # [复用 Agent] 多分支依赖安装

# [专属模块: master_setup.sh]
do_master_clean_env      # 环境清理
do_master_config         # 令牌收集与 conf 生成
do_master_init_db        # SQLite 表结构固化
do_master_deploy_core    # 覆写内核、守护进程注入
do_master_summary        # 态势汇报与回执

exit 0
