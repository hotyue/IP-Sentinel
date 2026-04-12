# IP-Sentinel Master Docker Image
# 司令部 - 负责管理所有Agent节点和SQLite数据库

FROM debian:bookworm-slim

LABEL maintainer="IP-Sentinel" \
      version="3.2.2" \
      description="IP-Sentinel Master Control - Agent management and SQLite database"

# 安装依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    sqlite3 \
    procps \
    openssl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# 创建工作目录
WORKDIR /opt/ip_sentinel_master

# 复制Master脚本
COPY master/ /opt/ip_sentinel_master/

# 创建必要的目录
RUN mkdir -p /opt/ip_sentinel_master/logs \
    /opt/ip_sentinel_master/data

# 设置权限
RUN chmod +x /opt/ip_sentinel_master/*.sh

# 暴露默认Master端口
EXPOSE 8080

# 数据卷挂载点
VOLUME ["/opt/ip_sentinel_master/data", "/opt/ip_sentinel_master/logs"]

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f "tg_master.sh" > /dev/null || exit 1

# 复制启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]