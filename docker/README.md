# 🛡️ IP-Sentinel Docker 部署指南

## 📋 概述

本目录包含 IP-Sentinel 的 Docker 部署配置，支持 Master-Agent 分布式架构。

## 🏗️ 架构说明

```
┌─────────────────────────────────────────────────────────┐
│                    Telegram Bot                        │
└─────────────────────┬─────────────────────────────────┘
                      │
┌─────────────────────▼─────────────────────────────────┐
│                  Master (司令部)                       │
│              docker/master/Dockerfile                 │
│  - tg_master.sh: TG监听与Webhook调度                   │
│  - SQLite数据库: 节点管理与指令记录                     │
│  - 端口: 8080 (可配置)                                 │
└─────────────────────┬─────────────────────────────────┘
                      │ HMAC签名WebSocket
┌─────────────────────▼─────────────────────────────────┐
│                 Agent (边缘哨兵)                        │
│              docker/agent/Dockerfile                   │
│  - runner.sh: 任务调度引擎                             │
│  - mod_google.sh: Google区域纠偏                       │
│  - mod_trust.sh: IP信用净化                           │
│  - 端口: 9527 (可配置)                                 │
└─────────────────────────────────────────────────────────┘
```

## 🚀 快速开始

### 前置要求

- Docker Engine 20.10+
- Docker Compose 2.0+
- Telegram Bot Token (从 [@BotFather](https://t.me/BotFather) 获取)

### 1. 准备环境

```bash
# 进入项目目录
cd IP-Sentinel

# 进入docker目录
cd docker

# 复制环境变量配置文件
cp .env.example .env

# 编辑 .env 文件，填入您的配置
vim .env
```

### 2. 配置环境变量

编辑 `.env` 文件:

```env
# Telegram Bot Token (必需)
TG_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz

# Master 端口
MASTER_PORT=8080

# Agent 区域代码
REGION_CODE=US

# Telegram Chat ID
CHAT_ID=123456789

# Agent 端口
AGENT_PORT=9527

# 功能开关
ENABLE_GOOGLE=true
ENABLE_TRUST=true
```

### 3. 启动服务

```bash
# 构建并启动所有服务
docker compose up -d

# 查看服务状态
docker compose ps

# 查看日志
docker compose logs -f
```

### 4. 单独启动服务

**仅启动 Master:**
```bash
docker compose up -d master
```

**仅启动 Agent:**
```bash
docker compose up -d agent
```

## 🔧 服务管理

### 查看日志

```bash
# Master 日志
docker compose logs -f master

# Agent 日志
docker compose logs -f agent

# 所有服务日志
docker compose logs -f
```

### 重启服务

```bash
# 重启所有服务
docker compose restart

# 重启 Master
docker compose restart master

# 重启 Agent
docker compose restart agent
```

### 停止服务

```bash
# 停止所有服务
docker compose down

# 停止并删除数据卷
docker compose down -v
```

### 进入容器

```bash
# 进入 Master 容器
docker exec -it ip-sentinel-master /bin/bash

# 进入 Agent 容器
docker exec -it ip-sentinel-agent /bin/bash
```

## 📊 健康检查

```bash
# 检查容器健康状态
docker inspect --format='{{.State.Health.Status}}' ip-sentinel-master
docker inspect --format='{{.State.Health.Status}}' ip-sentinel-agent
```

## 🗄️ 数据持久化

Docker Compose 会创建以下卷:

| 卷名 | 用途 |
|------|------|
| `master-data` | Master SQLite 数据库 |
| `master-logs` | Master 日志文件 |
| `agent-config` | Agent 配置文件 |
| `agent-logs` | Agent 日志文件 |

### 备份数据库

```bash
# 备份 Master 数据库
docker exec ip-sentinel-master sqlite3 /opt/ip_sentinel_master/data/nodes.db ".backup /tmp/nodes.db"
docker cp ip-sentinel-master:/tmp/nodes.db ./backup_nodes.db

# 恢复数据库
docker cp ./backup_nodes.db ip-sentinel-master:/tmp/nodes.db
docker exec ip-sentinel-master sqlite3 /opt/ip_sentinel_master/data/nodes.db ".restore /tmp/nodes.db"
```

## 🔐 安全说明

- 首次部署请修改默认端口
- 生产环境建议使用 Docker 网络隔离
- 定期备份数据库卷
- Telegram Token 应妥善保管，切勿提交到版本控制

## 🐛 故障排除

### 容器无法启动

```bash
# 查看详细错误
docker compose up
```

### 健康检查失败

```bash
# 检查进程是否运行
docker exec ip-sentinel-master ps aux
docker exec ip-sentinel-agent ps aux
```

### 网络问题

```bash
# 检查网络连接
docker exec ip-sentinel-master ping -c 3 api.telegram.org
docker exec ip-sentinel-agent ping -c 3 ifconfig.me
```

## 📝 目录结构

```
docker/
├── agent/
│   ├── Dockerfile        # Agent 镜像定义
│   └── entrypoint.sh     # Agent 启动脚本
├── master/
│   ├── Dockerfile        # Master 镜像定义
│   └── entrypoint.sh     # Master 启动脚本
├── .env.example          # 环境变量示例
├── .env                   # 环境变量 (需手动创建)
├── docker-compose.yml     # Docker Compose 配置
└── README.md             # 本文档
```

## 🔗 相关链接

- 项目主页: https://github.com/Seameee/IP-Sentinel
- 问题反馈: https://github.com/Seameee/IP-Sentinel/issues
- Telegram 频道: [@IP_Sentinel_Matrix](https://t.me/IP_Sentinel_Matrix)