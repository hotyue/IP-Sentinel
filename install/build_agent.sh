#!/bin/bash
# IPS-MAGIC:IP-SENTINEL-BUILD-AGENT-v4.3.0
# ==========================================================
# 模块名称: build_agent.sh (Orchestrator 编排大管家)
# 核心功能: 严格遵循原版 install.sh 判定树时序，实现无损热更新
# ==========================================================

# [安全修复] 供应链完整性校验 — 防止远程脚本被投毒替换
verify_magic() {
    local file="$1"
    local expected_magic="# IPS-MAGIC:"
    if ! head -5 "$file" 2>/dev/null | grep -q "$expected_magic"; then
        echo -e "\033[31m❌ 完整性校验失败：${file} 缺少 MAGIC STRING，疑似供应链投毒！\033[0m"
        exit 1
    fi
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

MODULES=(
    "env_setup.sh"
    "ui_menu.sh"
    "net_engine.sh"
    "sys_daemon.sh"
)

# 1. 串行拉取子模块资产
for mod in "${MODULES[@]}"; do
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/${mod}?t=$(date +%s)" -o "${SECURE_TMP}/${mod}"
    if [ ! -s "${SECURE_TMP}/${mod}" ]; then
        echo -e "\033[31m❌ 致命错误：依赖模块 [${mod}] 装载失败！\033[0m"
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
# 2. 核心业务原子流 (100% 忠实于原版 install.sh 执行时序)
# ==========================================================

# [环境预检阶段]
do_env_precheck       # 架构预检、系统级诊断 (原版第 26-55 行)
do_fetch_version      # 动态解析远端版本约束 (原版第 59-66 行)
do_install_deps       # 多分支包管理器嗅探与系统补全 (原版第 70-137 行)

# [菜单与策略拦截阶段]
do_fetch_map          # LBS 地理图谱树预载 (原版第 141-146 行)
do_handle_menu        # 区分全新安装、平滑升级与一键卸载 (原版第 149-188 行)

# [物理清洗阶段]
do_clean_env          # 幽灵进程抹除、无损清空与数据保护 (原版第 192-225 行)

# [配置生成阶段 (仅限全新安装)]
do_interactive_setup  # 逐级锁定战区城市、联控配置、端口探测 (原版第 229-373 行)

# [网络雷达与身份装配阶段]
do_network_probe      # 冗余双栈探测、网卡锁、WARP假公网隔离 (原版第 375-430 行)
do_assemble_fallback  # 智能多宿主容灾弹匣装填、主键别名分离 (原版第 432-475 行)
do_write_config       # 固化本地本地 config.conf 档案 (原版第 477-512 行)

# [老节点热重载平滑升级阶段 (仅限升级模式)]
do_smooth_migrate     # 强行覆写、重铸双栈容灾装甲 (原版第 516-590 行)

# [核心引擎原子覆写阶段]
do_deploy_core        # 双缓冲防变砖下载域、物理覆写核心文件 (原版第 594-620 行)

# [进程守护与首播激活阶段]
do_inject_daemon      # Systemd/Alpine 看门狗死循环双重注入 (原版第 622-728 行)
do_final_report       # 首播暗号同步、Markdown防断开下划线发送 (原版第 732-793 行)
do_show_summary       # 防火墙端口提示、装机量统计、开源 Star 推广 (原版第 795-832 行)

exit 0