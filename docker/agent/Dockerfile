# IP-Sentinel Agent Docker Image
# 边缘节点Agent - 负责IP养护和伪装

FROM debian:bookworm-slim

LABEL maintainer="IP-Sentinel" \
      version="3.2.2" \
      description="IP-Sentinel Agent Node - IP reputation maintenance and geo-correction"

# 安装依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    cron \
    procps \
    python3 \
    openssl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# 创建工作目录
WORKDIR /opt/ip_sentinel

# 复制核心脚本和数据
COPY core/ /opt/ip_sentinel/core/
COPY data/ /opt/ip_sentinel/data/

# 创建必要的目录
RUN mkdir -p /opt/ip_sentinel/logs \
    /opt/ip_sentinel/data/keywords \
    /opt/ip_sentinel/data/regions

# 设置权限
RUN chmod +x /opt/ip_sentinel/core/*.sh

# 暴露默认Webhook端口
EXPOSE 9527

# 数据卷挂载点
VOLUME ["/opt/ip_sentinel/config", "/opt/ip_sentinel/logs"]

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f "runner.sh" > /dev/null || exit 1

# 复制启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]